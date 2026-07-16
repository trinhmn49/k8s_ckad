package handlers

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/trinhmn/weather-alert/alert-evaluator/internal/models"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/service"
)

type AlertHandler struct {
	svc *service.AlertEvaluatorService
}

func NewAlertHandler(svc *service.AlertEvaluatorService) *AlertHandler {
	return &AlertHandler{svc: svc}
}

// HealthCheck returns service health status
func (h *AlertHandler) HealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	resp := models.HealthResponse{
		Status: "ok",
		Time:   time.Now().UTC().Format(time.RFC3339),
	}
	json.NewEncoder(w).Encode(resp)
}

// GetStats handles GET /api/v1/stats
func (h *AlertHandler) GetStats(w http.ResponseWriter, r *http.Request) {
	stats := h.svc.GetStats()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}
