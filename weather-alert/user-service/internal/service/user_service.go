package service

import (
	"context"
	"encoding/json"
	"log"

	"github.com/nats-io/nats.go"
	"github.com/trinhmn/weather-alert/user-service/internal/models"
	"github.com/trinhmn/weather-alert/user-service/internal/storage"
)

type UserService struct {
	db        *storage.PostgresDB
	natsConn  *nats.Conn
}

func NewUserService(db *storage.PostgresDB, nc *nats.Conn) *UserService {
	return &UserService{
		db:       db,
		natsConn: nc,
	}
}

// CreateUser handles user registration
func (s *UserService) CreateUser(ctx context.Context, req *models.CreateUserRequest) (*models.User, error) {
	user, err := s.db.CreateUser(ctx, req)
	if err != nil {
		log.Printf("Error creating user: %v", err)
		return nil, err
	}

	// Publish user.registered event to NATS
	event := map[string]interface{}{
		"event":     "user.registered",
		"user_id":   user.ID,
		"email":     user.Email,
		"timestamp": user.CreatedAt,
	}
	eventBytes, _ := json.Marshal(event)
	if err := s.natsConn.Publish("user.registered", eventBytes); err != nil {
		log.Printf("Error publishing user.registered event: %v", err)
	}

	return user, nil
}

// GetUser retrieves a user by ID
func (s *UserService) GetUser(ctx context.Context, userID int64) (*models.User, error) {
	return s.db.GetUser(ctx, userID)
}

// DeleteUser deletes a user
func (s *UserService) DeleteUser(ctx context.Context, userID int64) error {
	return s.db.DeleteUser(ctx, userID)
}

// UpdateAlertRules creates or updates alert rules for a user
func (s *UserService) UpdateAlertRules(ctx context.Context, userID int64, req *models.UpdateRulesRequest) (*models.AlertRule, error) {
	rule, err := s.db.CreateAlertRule(ctx, userID, req)
	if err != nil {
		log.Printf("Error creating alert rule: %v", err)
		return nil, err
	}

	log.Printf("Created alert rule for user %d: %+v", userID, rule)
	return rule, nil
}

// RegisterDevice registers a push notification device for a user
func (s *UserService) RegisterDevice(ctx context.Context, req *models.RegisterDeviceRequest) (*models.DeviceToken, error) {
	device, err := s.db.RegisterDeviceToken(ctx, req)
	if err != nil {
		log.Printf("Error registering device: %v", err)
		return nil, err
	}

	log.Printf("Registered device for user %d", req.UserID)
	return device, nil
}

// GetDeviceTokensByUser retrieves all device tokens for a user
func (s *UserService) GetDeviceTokensByUser(ctx context.Context, userID int64) ([]models.DeviceToken, error) {
	return s.db.GetDeviceTokensByUser(ctx, userID)
}
