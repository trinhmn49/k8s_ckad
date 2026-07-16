package models

import "time"

type User struct {
	ID        int64     `json:"id"`
	Email     string    `json:"email"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type CreateUserRequest struct {
	Email string `json:"email"`
	Name  string `json:"name"`
}

type AlertRule struct {
	ID             int64   `json:"id"`
	UserID         int64   `json:"user_id"`
	Location       string  `json:"location"`
	AlertType      string  `json:"alert_type"`
	ThresholdValue float64 `json:"threshold_value"`
	Enabled        bool    `json:"enabled"`
}

type UpdateRulesRequest struct {
	Location       string  `json:"location"`
	AlertType      string  `json:"alert_type"`
	ThresholdValue float64 `json:"threshold_value"`
}

type DeviceToken struct {
	ID        int64     `json:"id"`
	UserID    int64     `json:"user_id"`
	Token     string    `json:"token"`
	Platform  string    `json:"platform"`
	IsActive  bool      `json:"is_active"`
	CreatedAt time.Time `json:"created_at"`
}

type RegisterDeviceRequest struct {
	UserID   int64  `json:"user_id"`
	Token    string `json:"token"`
	Platform string `json:"platform"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

type HealthResponse struct {
	Status string `json:"status"`
	Time   string `json:"time"`
}