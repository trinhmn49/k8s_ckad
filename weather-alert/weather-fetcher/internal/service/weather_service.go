package service

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/redis/go-redis/v9"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/config"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/models"
)

type WeatherService struct {
	redis      *redis.Client
	nats       *nats.Conn
	config     *config.Config
	httpClient *http.Client
}

func NewWeatherService(redis *redis.Client, nats *nats.Conn, cfg *config.Config) *WeatherService {
	return &WeatherService{
		redis:      redis,
		nats:       nats,
		config:     cfg,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

// locationCoords maps the locations this service polls to their lat/lon,
// since Open-Meteo's forecast endpoint takes coordinates, not city names.
var locationCoords = map[string][2]float64{
	"Hanoi":    {21.0285, 105.8542},
	"Nam Dinh": {20.4388, 106.1621},
}

type openMeteoResponse struct {
	Current struct {
		Temperature2m      float64 `json:"temperature_2m"`
		RelativeHumidity2m int     `json:"relative_humidity_2m"`
		WeatherCode        int     `json:"weather_code"`
	} `json:"current"`
	Daily struct {
		Time             []string  `json:"time"`
		Temperature2mMax []float64 `json:"temperature_2m_max"`
		Temperature2mMin []float64 `json:"temperature_2m_min"`
		WeatherCode      []int     `json:"weather_code"`
	} `json:"daily"`
}

// FetchAndPublish fetches weather data and publishes to NATS
func (s *WeatherService) FetchAndPublish(ctx context.Context, location string) error {
	weatherData, err := s.fetchFromAPI(ctx, location)
	if err != nil {
		return err
	}

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
		AQI:         weatherData.AQI,
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

	log.Printf(
		"Published weather for %s: aqi=%d, temp=%.1f°C, humidity=%d%%, tomorrow=%.1f-%.1f°C (%s)",
		location, weatherData.AQI, weatherData.Temperature, weatherData.Humidity,
		weatherData.TomorrowTempMin, weatherData.TomorrowTempMax, weatherData.TomorrowCondition,
	)
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
	data, err := s.fetchFromAPI(ctx, location)
	if err != nil {
		return nil, err
	}

	// Cache it
	dataBytes, _ := json.Marshal(data)
	s.redis.Set(ctx, key, dataBytes, 1*time.Hour)

	return data, nil
}

// fetchFromAPI calls Open-Meteo for current conditions and tomorrow's forecast
func (s *WeatherService) fetchFromAPI(ctx context.Context, location string) (*models.WeatherData, error) {
	coords, ok := locationCoords[location]
	if !ok {
		return nil, fmt.Errorf("no coordinates configured for location %q", location)
	}

	url := fmt.Sprintf(
		"https://api.open-meteo.com/v1/forecast?latitude=%f&longitude=%f&current=temperature_2m,relative_humidity_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,weather_code&timezone=Asia%%2FBangkok&forecast_days=2",
		coords[0], coords[1],
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to build open-meteo request: %w", err)
	}

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("open-meteo request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("open-meteo returned %d: %s", resp.StatusCode, string(body))
	}

	var result openMeteoResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode open-meteo response: %w", err)
	}

	var tomorrowMax, tomorrowMin float64
	tomorrowCondition := "Unknown"
	if len(result.Daily.Time) > 1 {
		tomorrowMax = result.Daily.Temperature2mMax[1]
		tomorrowMin = result.Daily.Temperature2mMin[1]
		tomorrowCondition = weatherCodeToCondition(result.Daily.WeatherCode[1])
	}

	aqi, err := s.fetchAirQuality(ctx, coords[0], coords[1])
	if err != nil {
		log.Printf("Failed to fetch air quality for %s: %v", location, err)
		aqi = -1
	}

	return &models.WeatherData{
		Location:          location,
		AQI:               aqi,
		Temperature:       result.Current.Temperature2m,
		Humidity:          result.Current.RelativeHumidity2m,
		Condition:         weatherCodeToCondition(result.Current.WeatherCode),
		FetchedAt:         time.Now(),
		TomorrowTempMax:   tomorrowMax,
		TomorrowTempMin:   tomorrowMin,
		TomorrowCondition: tomorrowCondition,
	}, nil
}

// fetchAirQuality calls Open-Meteo's air quality API for the US AQI (0-500 scale)
func (s *WeatherService) fetchAirQuality(ctx context.Context, lat, lon float64) (int, error) {
	url := fmt.Sprintf(
		"https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%f&longitude=%f&current=us_aqi",
		lat, lon,
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, fmt.Errorf("failed to build air quality request: %w", err)
	}

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("air quality request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("air quality API returned %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		Current struct {
			USAQI int `json:"us_aqi"`
		} `json:"current"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, fmt.Errorf("failed to decode air quality response: %w", err)
	}

	return result.Current.USAQI, nil
}

// weatherCodeToCondition maps Open-Meteo's WMO weather codes to a simple label
func weatherCodeToCondition(code int) string {
	switch {
	case code == 0:
		return "Clear"
	case code >= 1 && code <= 3:
		return "Cloudy"
	case code >= 45 && code <= 48:
		return "Fog"
	case code >= 51 && code <= 67:
		return "Rainy"
	case code >= 71 && code <= 77:
		return "Snow"
	case code >= 80 && code <= 82:
		return "Rainy"
	case code >= 95 && code <= 99:
		return "Thunderstorm"
	default:
		return "Unknown"
	}
}
