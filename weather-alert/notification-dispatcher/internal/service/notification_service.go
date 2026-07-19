package service

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/trinhmn/weather-alert/notification-dispatcher/internal/config"
	"github.com/trinhmn/weather-alert/notification-dispatcher/internal/models"
	"github.com/trinhmn/weather-alert/notification-dispatcher/internal/storage"
)

type NotificationService struct {
	db     *storage.PostgresDB
	nats   *nats.Conn
	config *config.Config
}

func NewNotificationService(db *storage.PostgresDB, nc *nats.Conn, cfg *config.Config) *NotificationService {
	return &NotificationService{
		db:     db,
		nats:   nc,
		config: cfg,
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

// dispatchNotification sends notifications to user devices
func (s *NotificationService) dispatchNotification(alert *models.AlertTriggeredEvent) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	defer wg.Wait()

	// Get device tokens for the user
	tokens, err := s.db.GetDeviceTokensByUser(ctx, alert.UserID)
	if err != nil {
		log.Printf("Error fetching device tokens: %v", err)
		errMsg := fmt.Sprintf("Failed to fetch device tokens: %v", err)
		s.logNotification(ctx, alert, "failed", nil, &errMsg)
		return
	}

	if len(tokens) == 0 {
		log.Printf("No device tokens found for user %d", alert.UserID)
		errMsg := "No device tokens found"
		s.logNotification(ctx, alert, "failed", nil, &errMsg)
		return
	}

	log.Printf("Sending notifications to %d devices for user %d", len(tokens), alert.UserID)

	// Send to all devices
	for _, token := range tokens {
		wg.Add(1)
		go func(token string) {
			defer wg.Done()
			s.sendAPNsNotification(ctx, alert, token)
		}(token)
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
