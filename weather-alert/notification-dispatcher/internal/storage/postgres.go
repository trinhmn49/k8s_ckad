package storage

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/trinhmn/weather-alert/notification-dispatcher/internal/models"
)

type PostgresDB struct {
	pool *pgxpool.Pool
}

func NewPostgres(pool *pgxpool.Pool) *PostgresDB {
	return &PostgresDB{pool: pool}
}

// GetDeviceTokensByUser retrieves all active device tokens for a user
func (db *PostgresDB) GetDeviceTokensByUser(ctx context.Context, userID int64) ([]string, error) {
	query := `SELECT token FROM device_tokens WHERE user_id = $1 AND is_active = true`

	rows, err := db.pool.Query(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tokens []string
	for rows.Next() {
		var token string
		if err := rows.Scan(&token); err != nil {
			return nil, err
		}
		tokens = append(tokens, token)
	}

	return tokens, rows.Err()
}

// LogNotification records a notification send attempt
func (db *PostgresDB) LogNotification(ctx context.Context, userID int64, ruleID int64, title string, body string, status string, apnsCode *int, errMsg *string) error {
	query := `INSERT INTO notification_log (user_id, alert_rule_id, title, body, status, apns_response_code, error_message, created_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`

	_, err := db.pool.Exec(ctx, query, userID, ruleID, title, body, status, apnsCode, errMsg, time.Now())
	return err
}

// GetNotificationsByUser retrieves notification history for a user
func (db *PostgresDB) GetNotificationsByUser(ctx context.Context, userID int64, limit int) ([]models.NotificationLog, error) {
	if limit > 100 {
		limit = 100 // Cap limit for performance
	}

	query := `SELECT id, user_id, device_token_id, alert_rule_id, title, body, status, apns_response_code, error_message, created_at
             FROM notification_log WHERE user_id = $1 ORDER BY created_at DESC LIMIT $2`

	rows, err := db.pool.Query(ctx, query, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var notifications []models.NotificationLog
	for rows.Next() {
		var notif models.NotificationLog
		if err := rows.Scan(
			&notif.ID, &notif.UserID, &notif.DeviceTokenID, &notif.AlertRuleID,
			&notif.Title, &notif.Body, &notif.Status, &notif.ApnsResponseCode,
			&notif.ErrorMessage, &notif.CreatedAt,
		); err != nil {
			return nil, err
		}
		notifications = append(notifications, notif)
	}

	return notifications, rows.Err()
}
