package config

import (
	"fmt"
	"os"
)

type Config struct {
	Port     string
	LogLevel string
	DBHost   string
	DBPort   string
	DBUser   string
	DBPass   string
	DBName   string
	RedisURL string
	NatsURL  string
}

func LoadConfig() *Config {
	return &Config{
		Port:     getEnv("PORT", "8003"),
		LogLevel: getEnv("LOG_LEVEL", "info"),
		DBHost:   getEnv("DB_HOST", "localhost"),
		DBPort:   getEnv("DB_PORT", "5432"),
		DBUser:   getEnv("DB_USER", "weather_app"),
		DBPass:   getEnv("DB_PASSWORD", "weather_app"),
		DBName:   getEnv("DB_NAME", "weather_alert"),
		RedisURL: getEnv("REDIS_URL", "localhost:6379"),
		NatsURL:  getEnv("NATS_URL", "nats://localhost:4222"),
	}
}

func (c *Config) DatabaseURL() string {
	return fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s?sslmode=disable",
		c.DBUser, c.DBPass, c.DBHost, c.DBPort, c.DBName,
	)
}

func getEnv(key, defaultVal string) string {
	if val, exists := os.LookupEnv(key); exists {
		return val
	}
	return defaultVal
}
