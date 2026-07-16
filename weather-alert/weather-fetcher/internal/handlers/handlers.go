package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/gorilla/mux"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/models"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/service"
)

type WeatherHandler struct {
	svc *service.WeatherService
}

func NewWeatherHandler(svc *service.WeatherService) *WeatherHandler {
	return &WeatherHandler{svc: svc}
}

// HealthCheck returns service health status
func (h *WeatherHandler) HealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	resp := models.HealthResponse{
		Status: "ok",
		Time:   time.Now().UTC().Format(time.RFC3339),
	}
	json.NewEncoder(w).Encode(resp)
}

// GetWeather handles GET /api/v1/weather/{location}
func (h *WeatherHandler) GetWeather(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	location := vars["location"]

	if location == "" {
		http.Error(w, "Location is required", http.StatusBadRequest)
		return
	}

	weather, err := h.svc.GetWeather(r.Context(), location)
	if err != nil {
		log.Printf("Error getting weather: %v", err)
		http.Error(w, "Failed to get weather", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cache-Age", strconv.FormatInt(int64(time.Since(weather.FetchedAt).Seconds()), 10))
	json.NewEncoder(w).Encode(weather)
}
