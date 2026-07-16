package config

import "os"

type Config struct {
	Port             string
	LogLevel         string
	RedisURL         string
	NatsURL          string
	WeatherAPIKey    string
	WeatherAPIBase   string
}

func LoadConfig() *Config {
	return &Config{
		Port:             getEnv("PORT", "8002"),
		LogLevel:         getEnv("LOG_LEVEL", "info"),
		RedisURL:         getEnv("REDIS_URL", "localhost:6379"),
		NatsURL:          getEnv("NATS_URL", "nats://localhost:4222"),
		WeatherAPIKey:    getEnv("WEATHER_API_KEY", "demo"),
		WeatherAPIBase:   getEnv("WEATHER_API_BASE_URL", "https://api.openweathermap.org"),
	}
}

func getEnv(key, defaultVal string) string {
	if val, exists := os.LookupEnv(key); exists {
		return val
	}
	return defaultVal
}
