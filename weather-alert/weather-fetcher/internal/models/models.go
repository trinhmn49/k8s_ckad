package models

import "time"

type WeatherData struct {
	Location          string    `json:"location"`
	AQI               int       `json:"aqi"`
	Temperature       float64   `json:"temperature"`
	Humidity          int       `json:"humidity"`
	Condition         string    `json:"condition"`
	FetchedAt         time.Time `json:"fetched_at"`
	TomorrowTempMax   float64   `json:"tomorrow_temp_max"`
	TomorrowTempMin   float64   `json:"tomorrow_temp_min"`
	TomorrowCondition string    `json:"tomorrow_condition"`
}

type WeatherRawEvent struct {
	Event       string    `json:"event"`
	Location    string    `json:"location"`
	AQI         int       `json:"aqi"`
	Temperature float64   `json:"temperature"`
	Humidity    int       `json:"humidity"`
	Condition   string    `json:"condition"`
	Timestamp   time.Time `json:"timestamp"`
}

type HealthResponse struct {
	Status string `json:"status"`
	Time   string `json:"time"`
}