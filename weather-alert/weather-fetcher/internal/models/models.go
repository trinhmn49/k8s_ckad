package models

import "time"

type WeatherData struct {
	Location    string    `json:"location"`
	Temperature float64   `json:"temperature"`
	Humidity    int       `json:"humidity"`
	Condition   string    `json:"condition"`
	FetchedAt   time.Time `json:"fetched_at"`
}

type WeatherRawEvent struct {
	Event       string    `json:"event"`
	Location    string    `json:"location"`
	Temperature float64   `json:"temperature"`
	Humidity    int       `json:"humidity"`
	Condition   string    `json:"condition"`
	Timestamp   time.Time `json:"timestamp"`
}

type HealthResponse struct {
	Status string `json:"status"`
	Time   string `json:"time"`
}