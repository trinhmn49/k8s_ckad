package models

import "time"

type WeatherEvent struct {
	Event       string    `json:"event"`
	Location    string    `json:"location"`
	AQI         int       `json:"aqi"`
	Temperature float64   `json:"temperature"`
	Humidity    int       `json:"humidity"`
	Condition   string    `json:"condition"`
	Timestamp   time.Time `json:"timestamp"`
}

type AlertRule struct {
	ID             int64   `json:"id"`
	UserID         int64   `json:"user_id"`
	Location       string  `json:"location"`
	AlertType      string  `json:"alert_type"`
	ThresholdValue float64 `json:"threshold_value"`
	Enabled        bool    `json:"enabled"`
}

type AlertTriggeredEvent struct {
	Event      string    `json:"event"`
	UserID     int64     `json:"user_id"`
	RuleID     int64     `json:"rule_id"`
	Location   string    `json:"location"`
	AlertType  string    `json:"alert_type"`
	Title      string    `json:"title"`
	Body       string    `json:"body"`
	Timestamp  time.Time `json:"timestamp"`
}

type EvaluationStats struct {
	TotalProcessed int64  `json:"total_processed"`
	AlertsTriggered int64  `json:"alerts_triggered"`
	CooldownBlocked int64  `json:"cooldown_blocked"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type HealthResponse struct {
	Status string `json:"status"`
	Time   string `json:"time"`
}
