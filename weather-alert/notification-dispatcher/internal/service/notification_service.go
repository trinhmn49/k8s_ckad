package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/trinhmn/weather-alert/notification-dispatcher/internal/config"
	"github.com/trinhmn/weather-alert/notification-dispatcher/internal/models"
	"github.com/trinhmn/weather-alert/notification-dispatcher/internal/storage"
)

// alertBatchWindow is how long dispatchNotification waits for more alerts for
// the same user before sending a single combined message. weather-fetcher
// polls all locations in one cycle, so their alerts land within milliseconds
// of each other - this window is just enough to catch them all as one batch.
const alertBatchWindow = 2 * time.Second

type NotificationService struct {
	db     *storage.PostgresDB
	nats   *nats.Conn
	config *config.Config

	mu            sync.Mutex
	pendingAlerts map[int64][]*models.AlertTriggeredEvent
	pendingTimers map[int64]*time.Timer
}

func NewNotificationService(db *storage.PostgresDB, nc *nats.Conn, cfg *config.Config) *NotificationService {
	return &NotificationService{
		db:            db,
		nats:          nc,
		config:        cfg,
		pendingAlerts: make(map[int64][]*models.AlertTriggeredEvent),
		pendingTimers: make(map[int64]*time.Timer),
	}
}

// SubscribeToAlertEvents subscribes to alert.triggered events and sends notifications
func (s *NotificationService) SubscribeToAlertEvents() error {
	_, err := s.nats.Subscribe("alert.triggered", func(msg *nats.Msg) {
		var alertEvent models.AlertTriggeredEvent
		if err := json.Unmarshal(msg.Data, &alertEvent); err != nil {
			log.Printf("Error unmarshaling alert event: %v", err)
			return
		}

		s.dispatchNotification(&alertEvent)
	})

	return err
}

// dispatchNotification batches alerts per user for alertBatchWindow so alerts
// for multiple locations (e.g. Hanoi and Nam Dinh firing in the same fetch
// cycle) are sent as a single combined notification instead of one each.
func (s *NotificationService) dispatchNotification(alert *models.AlertTriggeredEvent) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.pendingAlerts[alert.UserID] = append(s.pendingAlerts[alert.UserID], alert)

	if timer, ok := s.pendingTimers[alert.UserID]; ok {
		timer.Stop()
	}
	s.pendingTimers[alert.UserID] = time.AfterFunc(alertBatchWindow, func() {
		s.flushPendingAlerts(alert.UserID)
	})
}

// flushPendingAlerts sends the batched alerts for a user as one combined
// Telegram message, and logs/sends per-device APNs notifications for each.
func (s *NotificationService) flushPendingAlerts(userID int64) {
	s.mu.Lock()
	alerts := s.pendingAlerts[userID]
	delete(s.pendingAlerts, userID)
	delete(s.pendingTimers, userID)
	s.mu.Unlock()

	if len(alerts) == 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	defer wg.Wait()

	wg.Add(1)
	go func() {
		defer wg.Done()
		s.sendTelegramNotification(ctx, alerts)
	}()

	// Get device tokens for the user
	tokens, err := s.db.GetDeviceTokensByUser(ctx, userID)
	if err != nil {
		log.Printf("Error fetching device tokens: %v", err)
		errMsg := fmt.Sprintf("Failed to fetch device tokens: %v", err)
		for _, alert := range alerts {
			s.logNotification(ctx, alert, "failed", nil, &errMsg)
		}
		return
	}

	if len(tokens) == 0 {
		log.Printf("No device tokens found for user %d", userID)
		errMsg := "No device tokens found"
		for _, alert := range alerts {
			s.logNotification(ctx, alert, "failed", nil, &errMsg)
		}
		return
	}

	log.Printf("Sending notifications to %d devices for user %d (%d alerts)", len(tokens), userID, len(alerts))

	// Send to all devices, once per alert
	for _, alert := range alerts {
		for _, token := range tokens {
			wg.Add(1)
			go func(alert *models.AlertTriggeredEvent, token string) {
				defer wg.Done()
				s.sendAPNsNotification(ctx, alert, token)
			}(alert, token)
		}
	}
}

// sendTelegramNotification sends a single combined message for a batch of
// alerts (e.g. one per location) via the Telegram Bot API.
func (s *NotificationService) sendTelegramNotification(ctx context.Context, alerts []*models.AlertTriggeredEvent) {
	if s.config.TelegramBotToken == "" || s.config.TelegramChatID == "" {
		log.Println("Telegram not configured (TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID unset), skipping")
		return
	}

	lines := make([]string, 0, len(alerts))
	for _, alert := range alerts {
		lines = append(lines, alert.Body)
	}
	text := strings.Join(lines, "\n")

	payload, err := json.Marshal(map[string]string{
		"chat_id": s.config.TelegramChatID,
		"text":    text,
	})
	if err != nil {
		errMsg := fmt.Sprintf("failed to encode telegram payload: %v", err)
		s.logAll(ctx, alerts, "failed", nil, &errMsg)
		return
	}

	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", s.config.TelegramBotToken)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		errMsg := fmt.Sprintf("failed to build telegram request: %v", err)
		s.logAll(ctx, alerts, "failed", nil, &errMsg)
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		errMsg := fmt.Sprintf("telegram request failed: %v", err)
		s.logAll(ctx, alerts, "failed", nil, &errMsg)
		return
	}
	defer resp.Body.Close()

	code := resp.StatusCode
	if code != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		errMsg := fmt.Sprintf("telegram API error: %s", string(body))
		log.Printf("Telegram send failed: %s", errMsg)
		s.logAll(ctx, alerts, "failed", &code, &errMsg)
		return
	}

	log.Printf("Sent combined Telegram notification for user %d (%d locations)", alerts[0].UserID, len(alerts))
	s.logAll(ctx, alerts, "sent", &code, nil)
}

// logAll records the same send result for every alert in a batch
func (s *NotificationService) logAll(ctx context.Context, alerts []*models.AlertTriggeredEvent, status string, code *int, errMsg *string) {
	for _, alert := range alerts {
		s.logNotification(ctx, alert, status, code, errMsg)
	}
}

// sendAPNsNotification sends a notification via APNs
// In production, this would use the APNs HTTP/2 API
func (s *NotificationService) sendAPNsNotification(ctx context.Context, alert *models.AlertTriggeredEvent, deviceToken string) {
	// Simulate APNs API call
	// In production: use github.com/sideshow/apns2 or similar
	log.Printf("Sending APNs notification to device token %s: %s", deviceToken[:20]+"...", alert.Title)

	// Simulate success (90%) or failure (10%)
	// In real implementation, parse actual APNs response
	success := true
	var respCode *int
	var errMsg *string

	if !success {
		code := 400
		respCode = &code
		msg := "Invalid token"
		errMsg = &msg
	}

	status := "sent"
	if !success {
		status = "failed"
	}

	s.logNotification(ctx, alert, status, respCode, errMsg)
}

// logNotification records notification send result
func (s *NotificationService) logNotification(ctx context.Context, alert *models.AlertTriggeredEvent, status string, apnsCode *int, errMsg *string) {
	if err := s.db.LogNotification(ctx, alert.UserID, alert.RuleID, alert.Title, alert.Body, status, apnsCode, errMsg); err != nil {
		log.Printf("Error logging notification: %v", err)
	}
}

// GetNotifications retrieves notification history for a user
func (s *NotificationService) GetNotifications(ctx context.Context, userID int64, limit int) ([]models.NotificationLog, error) {
	return s.db.GetNotificationsByUser(ctx, userID, limit)
}
