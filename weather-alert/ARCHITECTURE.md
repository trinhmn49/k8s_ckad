# Weather Alert Microservices Architecture

## System Overview

Weather Alert is a cloud-native microservices application that monitors weather conditions and sends real-time push notifications to users. It follows the Twelve-Factor App methodology and is designed for horizontal scalability on Kubernetes.

**Business Goal:** Enable users to receive timely weather alerts based on their subscribed conditions (temperature thresholds, severe weather events, etc.)

## Microservices Architecture

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│ user-service │◄────────│   APNs API   │         │  PostgreSQL  │
└──────────────┘         └──────────────┘         └──────────────┘
       │                                                  ▲
       │ (User profiles,                                 │
       │  subscriptions)                                 │
       │                                            (Persist)
       ▼
     NATS
    ┌────┐
    │Bus │
    └────┘
    ▲    ▲    ▲
    │    │    │
┌───┴────┴────┴───┐
│                 │
▼                 ▼
weather-        alert-
fetcher         evaluator
│               │
└─────┬─────────┘
      │
      ▼
notification-
dispatcher
      │
      ▼
   Redis
  (Cache)
```

## Service Responsibilities

### 1. **user-service** (Port 8001)
- Manages user profiles, authentication, subscriptions
- Stores user alert preferences (temperature ranges, event types)
- Provides APIs for user onboarding and preference management
- **Database:** PostgreSQL (users, subscriptions, alert rules)
- **Dependencies:** PostgreSQL, NATS (publishes user events)

### 2. **weather-fetcher** (Port 8002)
- Periodically fetches weather data from external API (OpenWeatherMap, etc.)
- Caches fetched data in Redis (1-hour TTL)
- Publishes raw weather events to NATS topic `weather.raw`
- **Database:** None (stateless)
- **Dependencies:** Redis, NATS, external weather API
- **Schedule:** Every 30 minutes per location

### 3. **alert-evaluator** (Port 8003)
- Subscribes to `weather.raw` events from NATS
- Evaluates weather data against user alert rules
- Matches conditions and publishes `alert.triggered` events
- Prevents alert spam (cooldown: 1 hour per user per location)
- **Database:** Redis (for cooldown tracking)
- **Dependencies:** PostgreSQL (read-only user rules), Redis, NATS

### 4. **notification-dispatcher** (Port 8004)
- Subscribes to `alert.triggered` events from NATS
- Sends APNs push notifications to user devices
- Handles delivery retries and failure logging
- **Database:** PostgreSQL (device tokens, notification history)
- **Dependencies:** PostgreSQL, NATS, APNs HTTP/2 API

### 5. **config-service** (Port 8005) - *Optional*
- Centralized configuration management
- Environment-specific settings (API keys, endpoints, thresholds)
- Injected via environment variables or ConfigMaps in K8s

## Data Flow

1. **User Setup Phase**
   - User registers via user-service
   - User sets alert preferences (e.g., "notify if temp > 30°C")
   - Stored in PostgreSQL

2. **Weather Monitoring Phase**
   - weather-fetcher polls external API every 30 min
   - Caches result in Redis
   - Publishes event: `weather.raw` → NATS

3. **Alert Evaluation Phase**
   - alert-evaluator consumes `weather.raw` from NATS
   - Queries PostgreSQL for matching user rules
   - Checks Redis cooldown cache
   - Publishes `alert.triggered` → NATS

4. **Notification Phase**
   - notification-dispatcher consumes `alert.triggered`
   - Fetches device tokens from PostgreSQL
   - Sends APNs push notifications
   - Logs result to PostgreSQL for audit

## Technology Stack Details

| Component | Role | Rationale |
|-----------|------|-----------|
| **Go** | All microservices | Fast, concurrent, minimal resource footprint |
| **PostgreSQL** | Persistent user & alert data | ACID transactions, complex queries, reliability |
| **Redis** | Caching & distributed state | Sub-ms latency, cooldown tracking, session state |
| **NATS** | Event bus | Lightweight, fast, pub-sub native, K8s-friendly |
| **APNs HTTP/2 API** | Push notifications | Apple ecosystem, TLS mutual auth, high throughput |

## Deployment Architecture

### Local Development (Docker Compose)
- 4 services + PostgreSQL + Redis + NATS
- Single-node, file-based volumes
- See `docker-compose.yml`

### Kubernetes (Production)
- Namespaced deployments with resource limits
- Services expose internal communication (NATS headless)
- ConfigMaps for environment config
- Secrets for API keys (APNs certificate, database password)
- StatefulSets for PostgreSQL (optional: use managed RDS instead)
- See `k8s/` manifests

## API Contracts

### user-service
```
POST   /api/v1/users              - Register user
GET    /api/v1/users/:id          - Get profile
PUT    /api/v1/users/:id/rules    - Update alert rules
DELETE /api/v1/users/:id          - Deregister
POST   /api/v1/devices            - Register device token
```

### weather-fetcher
```
GET /health                        - Health check
GET /api/v1/weather/:location     - Manual fetch (admin)
```

### alert-evaluator
```
GET /health                        - Health check
GET /api/v1/stats                  - Evaluation stats (admin)
```

### notification-dispatcher
```
GET /health                        - Health check
GET /api/v1/notifications/:user    - Notification history
```

## Scaling Considerations

1. **Horizontal Scaling**
   - All services are stateless (except alert-evaluator's Redis state)
   - Run multiple replicas per service
   - NATS handles message ordering guarantees per stream

2. **Database Bottleneck**
   - PostgreSQL: Use connection pooling (pgBouncer)
   - Read replicas for alert-evaluator queries
   - Archive old notifications to cold storage

3. **External API Rate Limits**
   - weather-fetcher: Batch location requests
   - APNs: Use certificate-based flow (supports 10k req/sec per cert)

## Observability

- **Logging:** Structured JSON logs to stdout (Kubernetes captures)
- **Metrics:** Prometheus-compatible `/metrics` endpoint per service
- **Tracing:** OpenTelemetry with Jaeger backend (optional)

## Security Considerations

1. **Service-to-Service Communication:** mTLS via Kubernetes service mesh (Istio) or NATS auth tokens
2. **External API Keys:** Kubernetes Secrets, rotated regularly
3. **User Data:** PII encrypted at rest in PostgreSQL
4. **Device Tokens:** Stored securely, never logged
5. **Rate Limiting:** Per-user alert caps (prevent spam)

## 12-Factor Compliance

1. ✅ **Codebase:** Single git repo, mono-structure (separate build/deploy per service)
2. ✅ **Dependencies:** Go modules (go.mod/go.sum) per service
3. ✅ **Config:** Environment variables (NATS_URL, DB_HOST, APNS_KEY, etc.)
4. ✅ **Backing Services:** PostgreSQL, Redis, NATS as detachable resources
5. ✅ **Build/Run Separation:** Dockerfile per service
6. ✅ **Processes:** Stateless services, shared state in external stores
7. ✅ **Port Binding:** Each service exports HTTP (no app server dependency)
8. ✅ **Concurrency:** Scale via process replicas (K8s pods)
9. ✅ **Disposability:** Fast startup, graceful shutdown (signal handling)
10. ✅ **Dev/Prod Parity:** Same code, config varies (docker-compose ≈ K8s)
11. ✅ **Logs:** Stdout/stderr (Docker/K8s collects)
12. ✅ **Admin Tasks:** One-off scripts in separate `scripts/` directory

## Getting Started

See `CLAUDE.md` for local development setup and service interaction patterns.
