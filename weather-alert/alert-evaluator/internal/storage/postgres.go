package storage

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/models"
)

type PostgresDB struct {
	pool *pgxpool.Pool
}

func NewPostgres(pool *pgxpool.Pool) *PostgresDB {
	return &PostgresDB{pool: pool}
}

// GetAlertRulesByLocation retrieves all enabled alert rules for a specific location
func (db *PostgresDB) GetAlertRulesByLocation(ctx context.Context, location string) ([]models.AlertRule, error) {
	query := `SELECT id, user_id, location, alert_type, threshold_value, enabled
             FROM alert_rules WHERE location = $1 AND enabled = true`

	rows, err := db.pool.Query(ctx, query, location)
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

// GetAlertRulesByUserAndLocation retrieves alert rules for a specific user and location
func (db *PostgresDB) GetAlertRulesByUserAndLocation(ctx context.Context, userID int64, location string) ([]models.AlertRule, error) {
	query := `SELECT id, user_id, location, alert_type, threshold_value, enabled
             FROM alert_rules WHERE user_id = $1 AND location = $2 AND enabled = true`

	rows, err := db.pool.Query(ctx, query, userID, location)
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
