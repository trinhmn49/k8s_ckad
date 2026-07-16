package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"time"

	"github.com/gorilla/mux"
	"github.com/nats-io/nats.go"
	"github.com/redis/go-redis/v9"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/config"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/handlers"
	"github.com/trinhmn/weather-alert/weather-fetcher/internal/service"
)

func main() {
	cfg := config.LoadConfig()

	log.Printf("Starting weather-fetcher on port %s", cfg.Port)

	// Initialize Redis client
	redisClient := redis.NewClient(&redis.Options{
		Addr: cfg.RedisURL,
	})
	defer redisClient.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	if err := redisClient.Ping(ctx).Err(); err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}
	cancel()
	log.Println("✓ Redis connected")

	// Initialize NATS connection. RetryOnFailedConnect keeps retrying in the
	// background instead of crash-looping the pod if NATS isn't up yet — in
	// Kubernetes, Deployments have no guaranteed startup ordering.
	nc, err := nats.Connect(
		cfg.NatsURL,
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2*time.Second),
		nats.ReconnectHandler(func(c *nats.Conn) {
			log.Println("✓ NATS connected")
		}),
		nats.DisconnectErrHandler(func(c *nats.Conn, err error) {
			log.Printf("NATS disconnected: %v", err)
		}),
	)
	if err != nil {
		log.Fatalf("Failed to initialize NATS connection: %v", err)
	}
	defer nc.Close()
	log.Println("NATS connection initialized (connecting in background if unavailable)")

	// Initialize service
	svc := service.NewWeatherService(redisClient, nc, cfg)
	h := handlers.NewWeatherHandler(svc)

	// Setup router
	router := mux.NewRouter()
	router.HandleFunc("/health", h.HealthCheck).Methods("GET")
	router.HandleFunc("/api/v1/weather/{location}", h.GetWeather).Methods("GET")

	// Setup HTTP server
	server := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      router,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start fetcher routine (runs every 30 minutes)
	go func() {
		ticker := time.NewTicker(30 * time.Minute)
		defer ticker.Stop()

		locations := []string{"London", "New York", "Tokyo", "Paris", "Sydney"}
		for {
			log.Println("Fetching weather data...")
			for _, loc := range locations {
				go func(location string) {
					if err := svc.FetchAndPublish(context.Background(), location); err != nil {
						log.Printf("Error fetching weather for %s: %v", location, err)
					}
				}(loc)
			}
			<-ticker.C
		}
	}()

	// Start server in goroutine
	go func() {
		log.Printf("Listening on %s", server.Addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	// Graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt)
	<-sigChan

	log.Println("Shutting down...")
	ctx, cancel = context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("Server shutdown error: %v", err)
	}
	log.Println("weather-fetcher stopped")
}