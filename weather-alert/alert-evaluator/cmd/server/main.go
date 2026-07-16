package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"time"

	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"
	"github.com/redis/go-redis/v9"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/config"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/handlers"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/service"
	"github.com/trinhmn/weather-alert/alert-evaluator/internal/storage"
)

func main() {
	cfg := config.LoadConfig()

	log.Printf("Starting alert-evaluator on port %s", cfg.Port)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Initialize database connection pool
	dbPool, err := pgxpool.New(ctx, cfg.DatabaseURL())
	if err != nil {
		log.Fatalf("Failed to create database pool: %v", err)
	}
	defer dbPool.Close()

	if err := dbPool.Ping(ctx); err != nil {
		log.Fatalf("Failed to ping database: %v", err)
	}
	log.Println("✓ Database connected")

	// Initialize Redis client
	redisClient := redis.NewClient(&redis.Options{
		Addr: cfg.RedisURL,
	})
	defer redisClient.Close()

	if err := redisClient.Ping(ctx).Err(); err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}
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

	// Initialize dependencies
	db := storage.NewPostgres(dbPool)
	svc := service.NewAlertEvaluatorService(db, redisClient, nc)
	h := handlers.NewAlertHandler(svc)

	// Setup router
	router := mux.NewRouter()
	router.HandleFunc("/health", h.HealthCheck).Methods("GET")
	router.HandleFunc("/api/v1/stats", h.GetStats).Methods("GET")

	// Setup HTTP server
	server := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      router,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start NATS subscriber
	go func() {
		log.Println("Starting alert evaluator subscriber...")
		if err := svc.SubscribeToWeatherEvents(); err != nil {
			log.Fatalf("Error subscribing to NATS: %v", err)
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
	log.Println("alert-evaluator stopped")
}
