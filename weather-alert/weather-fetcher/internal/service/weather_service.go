package service

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/redis/go-redis/v9"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/config"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/models"
)

type WeatherService struct {
	redis  *redis.Client
	nats   *nats.Conn
	config *config.Config
}

func NewWeatherService(redis *redis.Client, nats *nats.Conn, cfg *config.Config) *WeatherService {
	return &WeatherService{
		redis:  redis,
		nats:   nats,
		config: cfg,
	}
}

// FetchAndPublish fetches weather data and publishes to NATS
func (s *WeatherService) FetchAndPublish(ctx context.Context, location string) error {
	// Simulate fetching weather from external API
	// In production, this would call openweathermap.org or similar
	weatherData := s.fetchFromAPI(ctx, location)

	// Cache in Redis (TTL: 1 hour)
	key := fmt.Sprintf("weather:%s", location)
	data, _ := json.Marshal(weatherData)
	if err := s.redis.Set(ctx, key, data, 1*time.Hour).Err(); err != nil {
		log.Printf("Error caching weather data: %v", err)
	}

	// Publish to NATS topic
	event := models.WeatherRawEvent{
		Event:       "weather.raw",
		Location:    weatherData.Location,
		Temperature: weatherData.Temperature,
		Humidity:    weatherData.Humidity,
		Condition:   weatherData.Condition,
		Timestamp:   time.Now(),
	}

	eventBytes, _ := json.Marshal(event)
	if err := s.nats.Publish("weather.raw", eventBytes); err != nil {
		log.Printf("Error publishing weather event: %v", err)
		return err
	}

	log.Printf("Published weather for %s: temp=%.1f°C, humidity=%d%%", location, weatherData.Temperature, weatherData.Humidity)
	return nil
}

// GetWeather retrieves weather data for a location (from cache if available)
func (s *WeatherService) GetWeather(ctx context.Context, location string) (*models.WeatherData, error) {
	key := fmt.Sprintf("weather:%s", location)

	// Try to get from cache
	cached, err := s.redis.Get(ctx, key).Result()
	if err == nil {
		var data models.WeatherData
		if err := json.Unmarshal([]byte(cached), &data); err == nil {
			log.Printf("Returning cached weather for %s", location)
			return &data, nil
		}
	}

	// Cache miss or decode error - fetch fresh data
	data := s.fetchFromAPI(ctx, location)

	// Cache it
	dataBytes, _ := json.Marshal(data)
	s.redis.Set(ctx, key, dataBytes, 1*time.Hour)

	return data, nil
}

// fetchFromAPI simulates fetching from external weather API
func (s *WeatherService) fetchFromAPI(ctx context.Context, location string) *models.WeatherData {
	// In production, make actual HTTP request to weather API
	// For now, return mock data
	temps := map[string]float64{
		"London": 15.0,
		"New York": 22.0,
		"Tokyo": 18.0,
		"Paris": 14.0,
		"Sydney": 25.0,
	}
	humidity := map[string]int{
		"London": 70,
		"New York": 65,
		"Tokyo": 60,
		"Paris": 75,
		"Sydney": 55,
	}
	conditions := []string{"Clear", "Cloudy", "Rainy", "Partly Cloudy"}

	temp := temps[location]
	if temp == 0 {
		temp = 20.0 + (rand.Float64() * 10 - 5)
	}

	hum := humidity[location]
	if hum == 0 {
		hum = 50 + rand.Intn(40)
	}

	condition := conditions[rand.Intn(len(conditions))]

	return &models.WeatherData{
		Location:    location,
		Temperature: temp + (rand.Float64() * 2 - 1),
		Humidity:    hum,
		Condition:   condition,
		FetchedAt:   time.Now(),
	}
}
