package service

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync/atomic"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/redis/go-redis/v9"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/models"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/storage"
)

type AlertEvaluatorService struct {
	db      *storage.PostgresDB
	redis   *redis.Client
	nats    *nats.Conn
	stats   struct {
		processed       int64
		triggered       int64
		cooldownBlocked int64
	}
}

func NewAlertEvaluatorService(db *storage.PostgresDB, redis *redis.Client, nc *nats.Conn) *AlertEvaluatorService {
	return &AlertEvaluatorService{
		db:    db,
		redis: redis,
		nats:  nc,
	}
}

// SubscribeToWeatherEvents subscribes to weather.raw events from NATS and evaluates alerts
func (s *AlertEvaluatorService) SubscribeToWeatherEvents() error {
	_, err := s.nats.Subscribe("weather.raw", func(msg *nats.Msg) {
		var weatherEvent models.WeatherEvent
		if err := json.Unmarshal(msg.Data, &weatherEvent); err != nil {
			log.Printf("Error unmarshaling weather event: %v", err)
			return
		}

		s.evaluateAlerts(&weatherEvent)
	})

	return err
}

// evaluateAlerts evaluates weather data against user alert rules
func (s *AlertEvaluatorService) evaluateAlerts(weather *models.WeatherEvent) {
	atomic.AddInt64(&s.stats.processed, 1)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Get all alert rules for this location
	rules, err := s.db.GetAlertRulesByLocation(ctx, weather.Location)
	if err != nil {
		log.Printf("Error fetching alert rules: %v", err)
		return
	}

	log.Printf("Evaluating %d rules for location: %s", len(rules), weather.Location)

	for _, rule := range rules {
		if s.shouldTriggerAlert(&rule, weather) {
			// Check cooldown to prevent alert spam
			if s.checkCooldown(ctx, rule.UserID, rule.Location) {
				log.Printf("Alert blocked by cooldown for user %d, location %s", rule.UserID, rule.Location)
				atomic.AddInt64(&s.stats.cooldownBlocked, 1)
				continue
			}

			// Trigger alert
			s.publishAlert(&rule, weather)
			atomic.AddInt64(&s.stats.triggered, 1)
		}
	}
}

// shouldTriggerAlert checks if alert conditions are met
func (s *AlertEvaluatorService) shouldTriggerAlert(rule *models.AlertRule, weather *models.WeatherEvent) bool {
	switch rule.AlertType {
	case "high_temp":
		return weather.Temperature > rule.ThresholdValue
	case "low_temp":
		return weather.Temperature < rule.ThresholdValue
	case "high_humidity":
		return float64(weather.Humidity) > rule.ThresholdValue
	case "rain":
		return weather.Condition == "Rainy"
	case "storm":
		return weather.Condition == "Storm"
	default:
		return false
	}
}

// checkCooldown checks if alert is on cooldown (prevents alert spam)
func (s *AlertEvaluatorService) checkCooldown(ctx context.Context, userID int64, location string) bool {
	key := fmt.Sprintf("alert:cooldown:%d:%s", userID, location)
	_, err := s.redis.Get(ctx, key).Result()

	// If key exists, alert is on cooldown
	if err == nil {
		return true
	}

	// Set cooldown (1 hour)
	s.redis.Set(ctx, key, "1", 1*time.Hour)
	return false
}

// publishAlert publishes an alert.triggered event to NATS
func (s *AlertEvaluatorService) publishAlert(rule *models.AlertRule, weather *models.WeatherEvent) {
	title := fmt.Sprintf("Weather Alert: %s", rule.AlertType)

	aqiPart := "AQI: N/A"
	if weather.AQI >= 0 {
		aqiPart = fmt.Sprintf("AQI: %d", weather.AQI)
	}
	body := fmt.Sprintf("%s (%s, temp: %.1f°C, humidity: %d%%)", weather.Location, aqiPart, weather.Temperature, weather.Humidity)

	event := models.AlertTriggeredEvent{
		Event:     "alert.triggered",
		UserID:    rule.UserID,
		RuleID:    rule.ID,
		Location:  weather.Location,
		AlertType: rule.AlertType,
		Title:     title,
		Body:      body,
		Timestamp: time.Now(),
	}

	eventBytes, _ := json.Marshal(event)
	if err := s.nats.Publish("alert.triggered", eventBytes); err != nil {
		log.Printf("Error publishing alert.triggered event: %v", err)
		return
	}

	log.Printf("Alert triggered for user %d: %s", rule.UserID, title)
}

// GetStats returns evaluation statistics
func (s *AlertEvaluatorService) GetStats() models.EvaluationStats {
	return models.EvaluationStats{
		TotalProcessed:  atomic.LoadInt64(&s.stats.processed),
		AlertsTriggered: atomic.LoadInt64(&s.stats.triggered),
		CooldownBlocked: atomic.LoadInt64(&s.stats.cooldownBlocked),
		UpdatedAt:       time.Now(),
	}
}
