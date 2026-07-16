package storage

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/trinhmn/weather-alert/user-service/internal/models"
)

type PostgresDB struct {
	pool *pgxpool.Pool
}

func NewPostgres(pool *pgxpool.Pool) *PostgresDB {
	return &PostgresDB{pool: pool}
}

// CreateUser inserts a new user and returns the created user
func (db *PostgresDB) CreateUser(ctx context.Context, req *models.CreateUserRequest) (*models.User, error) {
	user := &models.User{
		Email:     req.Email,
		Name:      req.Name,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}

	query := `INSERT INTO users (email, name, created_at, updated_at)
             VALUES ($1, $2, $3, $4) RETURNING id`

	err := db.pool.QueryRow(ctx, query, user.Email, user.Name, user.CreatedAt, user.UpdatedAt).Scan(&user.ID)
	if err != nil {
		return nil, err
	}

	return user, nil
}

// GetUser retrieves a user by ID
func (db *PostgresDB) GetUser(ctx context.Context, userID int64) (*models.User, error) {
	user := &models.User{}

	query := `SELECT id, email, name, created_at, updated_at FROM users WHERE id = $1 AND deleted_at IS NULL`
	err := db.pool.QueryRow(ctx, query, userID).Scan(
		&user.ID, &user.Email, &user.Name, &user.CreatedAt, &user.UpdatedAt,
	)

	return user, err
}

// DeleteUser soft-deletes a user by setting deleted_at
func (db *PostgresDB) DeleteUser(ctx context.Context, userID int64) error {
	query := `UPDATE users SET deleted_at = $1 WHERE id = $2 AND deleted_at IS NULL`
	_, err := db.pool.Exec(ctx, query, time.Now(), userID)
	return err
}

// GetAlertRules retrieves all alert rules for a user
func (db *PostgresDB) GetAlertRules(ctx context.Context, userID int64) ([]models.AlertRule, error) {
	query := `SELECT id, user_id, location, alert_type, threshold_value, enabled
             FROM alert_rules WHERE user_id = $1 AND enabled = true`

	rows, err := db.pool.Query(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var rules []models.AlertRule
	for rows.Next() {
		var rule models.AlertRule
		if err := rows.Scan(
			&rule.ID, &rule.UserID, &rule.Location, &rule.AlertType, &rule.ThresholdValue, &rule.Enabled,
		); err != nil {
			return nil, err
		}
		rules = append(rules, rule)
	}

	return rules, rows.Err()
}

// CreateAlertRule inserts a new alert rule
func (db *PostgresDB) CreateAlertRule(ctx context.Context, userID int64, req *models.UpdateRulesRequest) (*models.AlertRule, error) {
	rule := &models.AlertRule{
		UserID:         userID,
		Location:       req.Location,
		AlertType:      req.AlertType,
		ThresholdValue: req.ThresholdValue,
		Enabled:        true,
	}

	query := `INSERT INTO alert_rules (user_id, location, alert_type, threshold_value, enabled, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`

	now := time.Now()
	err := db.pool.QueryRow(ctx, query, rule.UserID, rule.Location, rule.AlertType, rule.ThresholdValue, rule.Enabled, now, now).Scan(&rule.ID)
	if err != nil {
		return nil, err
	}

	return rule, nil
}

// RegisterDeviceToken inserts a new device token
func (db *PostgresDB) RegisterDeviceToken(ctx context.Context, req *models.RegisterDeviceRequest) (*models.DeviceToken, error) {
	device := &models.DeviceToken{
		UserID:    req.UserID,
		Token:     req.Token,
		Platform:  req.Platform,
		IsActive:  true,
		CreatedAt: time.Now(),
	}

	query := `INSERT INTO device_tokens (user_id, token, platform, is_active, created_at, last_active)
             VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`

	err := db.pool.QueryRow(ctx, query, device.UserID, device.Token, device.Platform, device.IsActive, device.CreatedAt, device.CreatedAt).Scan(&device.ID)
	if err != nil {
		return nil, err
	}

	return device, nil
}

// GetDeviceTokensByUser retrieves all active device tokens for a user
func (db *PostgresDB) GetDeviceTokensByUser(ctx context.Context, userID int64) ([]models.DeviceToken, error) {
	query := `SELECT id, user_id, token, platform, is_active, created_at
             FROM device_tokens WHERE user_id = $1 AND is_active = true`

	rows, err := db.pool.Query(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []models.DeviceToken
	for rows.Next() {
		var d models.DeviceToken
		if err := rows.Scan(&d.ID, &d.UserID, &d.Token, &d.Platform, &d.IsActive, &d.CreatedAt); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}

	return devices, rows.Err()
}
