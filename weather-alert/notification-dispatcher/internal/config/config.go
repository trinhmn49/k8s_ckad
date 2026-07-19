package config

import (
	"fmt"
	"os"
)

type Config struct {
	Port             string
	LogLevel         string
	DBHost           string
	DBPort           string
	DBUser           string
	DBPass           string
	DBName           string
	NatsURL          string
	ApnsKeyPath      string
	ApnsKeyID        string
	ApnsTeamID       string
	TelegramBotToken string
	TelegramChatID   string
}

func LoadConfig() *Config {
	return &Config{
		Port:             getEnv("PORT", "8004"),
		LogLevel:         getEnv("LOG_LEVEL", "info"),
		DBHost:           getEnv("DB_HOST", "localhost"),
		DBPort:           getEnv("DB_PORT", "5432"),
		DBUser:           getEnv("DB_USER", "weather_app"),
		DBPass:           getEnv("DB_PASSWORD", "weather_app"),
		DBName:           getEnv("DB_NAME", "weather_alert"),
		NatsURL:          getEnv("NATS_URL", "nats://localhost:4222"),
		ApnsKeyPath:      getEnv("APNS_KEY_PATH", "./apns-key.p8"),
		ApnsKeyID:        getEnv("APNS_KEY_ID", "XXXXXXXXXX"),
		ApnsTeamID:       getEnv("APNS_TEAM_ID", "XXXXXXXXXX"),
		TelegramBotToken: getEnv("TELEGRAM_BOT_TOKEN", ""),
		TelegramChatID:   getEnv("TELEGRAM_CHAT_ID", ""),
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
