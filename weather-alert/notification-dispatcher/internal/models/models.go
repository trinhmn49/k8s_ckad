package models

import "time"

type AlertTriggeredEvent struct {
	Event     string    `json:"event"`
	UserID    int64     `json:"user_id"`
	RuleID    int64     `json:"rule_id"`
	Location  string    `json:"location"`
	AlertType string    `json:"alert_type"`
	Title     string    `json:"title"`
	Body      string    `json:"body"`
	Timestamp time.Time `json:"timestamp"`
}

type NotificationLog struct {
	ID              int64     `json:"id"`
	UserID          int64     `json:"user_id"`
	DeviceTokenID   *int64    `json:"device_token_id"`
	AlertRuleID     *int64    `json:"alert_rule_id"`
	Title           string    `json:"title"`
	Body            string    `json:"body"`
	Status          string    `json:"status"` // sent, failed, pending
	ApnsResponseCode *int    `json:"apns_response_code"`
	ErrorMessage    *string   `json:"error_message"`
	CreatedAt       time.Time `json:"created_at"`
}

type HealthResponse struct {
	Status string `json:"status"`
	Time   string `json:"time"`
}
