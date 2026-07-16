# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Context

Weather Alert is a microservices application providing real-time weather notifications. It demonstrates cloud-native architecture with Go, Kubernetes-ready deployment, and event-driven patterns.

**Key Design Principle:** Stateless services, external backing services (PostgreSQL, Redis, NATS), 12-Factor compliance.

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed system design.

## Project Structure

```
weather-alert/
├── user-service/              # User management microservice
│   ├── cmd/server/main.go
│   ├── internal/
│   │   ├── models/
│   │   ├── handlers/
│   │   ├── storage/           # Database queries
│   │   └── service/           # Business logic
│   ├── go.mod
│   └── Dockerfile
├── weather-fetcher/
│   ├── cmd/server/main.go
│   ├── internal/...
│   ├── go.mod
│   └── Dockerfile
├── alert-evaluator/
│   ├── cmd/server/main.go
│   ├── internal/...
│   ├── go.mod
│   └── Dockerfile
├── notification-dispatcher/
│   ├── cmd/server/main.go
│   ├── internal/...
│   ├── go.mod
│   └── Dockerfile
├── db/
│   ├── schema.sql             # PostgreSQL schema
│   └── migrations/
├── scripts/
│   ├── local-setup.sh          # Local dev environment setup
│   └── reset-db.sh
├── docker-compose.yml         # Local development
├── k8s/
│   ├── namespace.yaml
│   ├── services/
│   ├── deployments/
│   ├── configmaps/
│   └── secrets/
├── ARCHITECTURE.md
├── CLAUDE.md
└── README.md
```

## Service Interaction Patterns

### Event Flow (NATS Topics)
- **weather.raw** — Weather fetcher → Alert evaluator (raw weather data)
- **alert.triggered** — Alert evaluator → Notification dispatcher (user alerts)
- **user.registered** — User service → (future expansion)

### Database Queries
- **user-service:** Full CRUD on users, subscriptions, devices, rules
- **alert-evaluator:** Read-only access to user alert rules, write cooldown state to Redis
- **notification-dispatcher:** Write-only to notification_log, read device_tokens

## Development Setup

### Prerequisites
```bash
# Ensure these are installed:
Go 1.21+
Docker & Docker Compose
PostgreSQL CLI (psql) - optional, for direct DB access
```

### Local Environment (Docker Compose)

1. **Start all services:**
   ```bash
   docker-compose up -d
   ```
   Services listen on:
   - user-service: http://localhost:8001
   - weather-fetcher: http://localhost:8002
   - alert-evaluator: http://localhost:8003
   - notification-dispatcher: http://localhost:8004
   - PostgreSQL: localhost:5432 (user: weather_app, db: weather_alert)
   - Redis: localhost:6379
   - NATS: localhost:4222

2. **Verify services are healthy:**
   ```bash
   curl http://localhost:8001/health
   curl http://localhost:8002/health
   curl http://localhost:8003/health
   curl http://localhost:8004/health
   ```

3. **View logs:**
   ```bash
   docker-compose logs -f user-service
   docker-compose logs -f notification-dispatcher
   ```

4. **Reset database:**
   ```bash
   docker-compose down -v
   docker-compose up -d
   # Or: ./scripts/reset-db.sh
   ```

## Local Development (Debugging Individual Service)

If working on a single service (e.g., user-service), you can run it locally against Docker services:

1. **Start only backing services:**
   ```bash
   docker-compose up -d postgres redis nats
   ```

2. **Set environment variables:**
   ```bash
   export DB_HOST=localhost
   export DB_PORT=5432
   export DB_USER=weather_app
   export DB_PASSWORD=weather_app
   export REDIS_URL=localhost:6379
   export NATS_URL=nats://localhost:4222
   export APNS_KEY_PATH=./apns-key.p8
   export PORT=8001
   ```

3. **Run service locally:**
   ```bash
   cd user-service
   go run cmd/server/main.go
   ```

## Testing

### Unit Tests
```bash
cd user-service
go test ./...
```

### Integration Tests (requires running services)
```bash
cd user-service
go test -tags=integration ./...
```

### Manual Testing with curl

**Create user:**
```bash
curl -X POST http://localhost:8001/api/v1/users \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","name":"John Doe"}'
```

**Register alert rule:**
```bash
curl -X PUT http://localhost:8001/api/v1/users/1/rules \
  -H "Content-Type: application/json" \
  -d '{"location":"London","temp_threshold":30,"alert_type":"high_temp"}'
```

## Key Code Patterns

### Service Initialization (All services follow this pattern)
```go
// main.go
func main() {
    cfg := config.Load()
    db := database.New(cfg.DatabaseURL)
    cache := redis.New(cfg.RedisURL)
    natsConn := nats.Connect(cfg.NatsURL)
    
    svc := service.New(db, cache, natsConn)
    handler := handlers.New(svc)
    
    server := &http.Server{
        Addr:    ":" + cfg.Port,
        Handler: handler.Routes(),
    }
    
    log.Fatal(server.ListenAndServe())
}
```

### NATS Subscriber Pattern
```go
// internal/service/nats.go
func (s *Service) SubscribeToWeatherEvents() {
    s.nats.Subscribe("weather.raw", func(msg *nats.Msg) {
        var event WeatherEvent
        json.Unmarshal(msg.Data, &event)
        s.evaluateAlerts(event)
    })
}
```

### Database Query Pattern
```go
// internal/storage/postgres.go
func (db *PostgreSQL) GetUserRules(ctx context.Context, userID int64) ([]Rule, error) {
    query := `SELECT id, user_id, location, temp_threshold 
              FROM alert_rules WHERE user_id = $1`
    rows, err := db.pool.Query(ctx, query, userID)
    // ... scan rows
    return rules, nil
}
```

## Environment Variables (12-Factor Config)

| Variable | Service | Default | Required |
|----------|---------|---------|----------|
| `PORT` | All | 8001+ | Yes |
| `LOG_LEVEL` | All | "info" | No |
| `DB_HOST` | user-service, alert-evaluator, notification-dispatcher | localhost | Yes |
| `DB_PORT` | ↑ | 5432 | Yes |
| `DB_USER` | ↑ | weather_app | Yes |
| `DB_PASSWORD` | ↑ | - | Yes |
| `REDIS_URL` | weather-fetcher, alert-evaluator | localhost:6379 | Yes |
| `NATS_URL` | All except user-service | nats://localhost:4222 | Yes |
| `APNS_KEY_PATH` | notification-dispatcher | ./apns-key.p8 | Yes |
| `WEATHER_API_KEY` | weather-fetcher | - | Yes |
| `WEATHER_API_BASE_URL` | weather-fetcher | https://api.openweathermap.org | No |

## Common Tasks

### Add a new database migration
1. Create file: `db/migrations/001_add_user_table.sql`
2. Run at startup: `psql postgres://... < db/migrations/001_add_user_table.sql`

### Add a new NATS event
1. Define event struct: `internal/models/events.go`
2. Publish: `natsConn.Publish("topic.name", data)`
3. Subscribe in consuming service

### Deploy to Kubernetes
1. Build images: `docker build -t weather-alert/user-service:latest user-service/`
2. Push to registry: `docker push registry.example.com/weather-alert/user-service:latest`
3. Apply manifests: `kubectl apply -f k8s/`

## Debugging Tips

- **Service won't start?** Check `docker-compose logs <service>`
- **NATS connection timeout?** Verify NATS is running: `docker-compose ps`
- **Database query errors?** Check connection string in env vars, run `docker-compose logs postgres`
- **API endpoint 404?** Verify service port and endpoint path match handler definition
- **Event not propagating?** Check NATS subscription is active; print to logs with `log.Printf("Event: %+v", event)`

## Notes for AI Assistance

- When adding features, maintain separation of concerns (handlers → service → storage)
- All external I/O (DB, cache, NATS, HTTP) should be injected at initialization
- Error handling: Log with context, return structured errors to API clients
- Concurrency: Use goroutines for NATS subscribers, not goroutine pools
- Never log sensitive data (API keys, user emails, device tokens)
- Config validation: Fail fast at startup if required env vars missing
