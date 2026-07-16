# Weather Alert Microservices

A cloud-native microservices application for sending real-time weather push notifications. Built with Go, Kubernetes-ready, and following the Twelve-Factor App methodology.

## Quick Start

### Prerequisites
- Docker & Docker Compose
- Go 1.21+ (for local development)

### Run Locally

```bash
# Start all services
docker-compose up -d

# Verify services are healthy
curl http://localhost:8001/health
curl http://localhost:8002/health
curl http://localhost:8003/health
curl http://localhost:8004/health

# View logs
docker-compose logs -f

# Stop all services
docker-compose down
```

### Example API Usage

**Register a user:**
```bash
curl -X POST http://localhost:8001/api/v1/users \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","name":"John Doe"}'
```

**Create an alert rule:**
```bash
curl -X PUT http://localhost:8001/api/v1/users/1/rules \
  -H "Content-Type: application/json" \
  -d '{"location":"London","alert_type":"high_temp","threshold_value":30}'
```

**Register a device:**
```bash
curl -X POST http://localhost:8001/api/v1/devices \
  -H "Content-Type: application/json" \
  -d '{"user_id":1,"token":"apns-device-token-here","platform":"ios"}'
```

**Get weather:**
```bash
curl http://localhost:8002/api/v1/weather/London
```

**View notifications:**
```bash
curl http://localhost:8004/api/v1/notifications/1
```

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed system design.

**4 Microservices:**
- **user-service** (8001) — User management, subscriptions, device tokens
- **weather-fetcher** (8002) — Periodically fetches weather data (cached in Redis)
- **alert-evaluator** (8003) — Evaluates weather against user rules, publishes alerts
- **notification-dispatcher** (8004) — Sends APNs push notifications

**Tech Stack:**
- Go 1.21
- PostgreSQL (users, subscriptions, audit logs)
- Redis (weather cache, cooldown tracking)
- NATS (event bus)
- APNs HTTP/2 API (push notifications)

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development setup, testing, and troubleshooting.

### Project Structure
```
weather-alert/
├── user-service/             # User management microservice
├── weather-fetcher/          # Weather data fetcher
├── alert-evaluator/          # Alert evaluation engine
├── notification-dispatcher/  # APNs notification sender
├── db/
│   ├── schema.sql            # PostgreSQL schema
│   └── migrations/           # (Future: database migrations)
├── docker-compose.yml        # Local development stack
├── ARCHITECTURE.md           # System design
├── CLAUDE.md                 # Development guide
└── README.md                 # This file
```

## Event Flow

1. **weather-fetcher** polls external API every 30 min → publishes `weather.raw` to NATS
2. **alert-evaluator** subscribes to `weather.raw` → evaluates against user rules → publishes `alert.triggered`
3. **notification-dispatcher** subscribes to `alert.triggered` → sends APNs notifications → logs result

## 12-Factor Compliance

✅ Codebase  
✅ Dependencies (go.mod)  
✅ Config (environment variables)  
✅ Backing Services (PostgreSQL, Redis, NATS as detachables)  
✅ Build/Run Separation (Dockerfile)  
✅ Processes (stateless services)  
✅ Port Binding (self-contained HTTP servers)  
✅ Concurrency (horizontal scaling via K8s replicas)  
✅ Disposability (fast startup, graceful shutdown)  
✅ Dev/Prod Parity (same code, config varies)  
✅ Logs (stdout/stderr collection)  
✅ Admin Tasks (one-off scripts in future)

## API Endpoints

### user-service
- `POST /api/v1/users` — Register user
- `GET /api/v1/users/:id` — Get user profile
- `PUT /api/v1/users/:id/rules` — Create/update alert rules
- `DELETE /api/v1/users/:id` — Delete user
- `POST /api/v1/devices` — Register device token
- `GET /health` — Health check

### weather-fetcher
- `GET /api/v1/weather/:location` — Get cached weather
- `GET /health` — Health check

### alert-evaluator
- `GET /api/v1/stats` — Evaluation statistics
- `GET /health` — Health check

### notification-dispatcher
- `GET /api/v1/notifications/:user_id` — Notification history
- `GET /health` — Health check

## Testing

```bash
# Unit tests
cd user-service && go test ./...

# Integration tests (requires running services)
docker-compose up -d
cd user-service && go test -tags=integration ./...
```

## Deployment

### Local Kubernetes (minikube)

The `k8s/` manifests are set up for minikube out of the box: images are built directly
into minikube's Docker daemon and Deployments use `imagePullPolicy: Never`, so no
registry push is needed.

**1. Start minikube (if not already running):**
```powershell
minikube start
```

**2. Point your shell's Docker client at minikube's daemon, then build the 4 images:**
```powershell
minikube docker-env | Invoke-Expression

docker build -t weather-alert/user-service:latest -f user-service/Dockerfile .
docker build -t weather-alert/weather-fetcher:latest -f weather-fetcher/Dockerfile .
docker build -t weather-alert/alert-evaluator:latest -f alert-evaluator/Dockerfile .
docker build -t weather-alert/notification-dispatcher:latest -f notification-dispatcher/Dockerfile .
```
This shell now talks to minikube's Docker, so the images land where the cluster can see them — no push required. Run this again any time you rebuild.

**3. Apply the manifests in order** (namespace → config/secrets → backing services → app deployments):
```powershell
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmaps/
kubectl apply -f k8s/secrets/
kubectl apply -f k8s/backing-services/

kubectl -n weather-alert rollout status deployment/postgres
kubectl -n weather-alert rollout status deployment/redis
kubectl -n weather-alert rollout status deployment/nats

kubectl apply -f k8s/deployments/
kubectl -n weather-alert rollout status deployment/user-service
kubectl -n weather-alert rollout status deployment/weather-fetcher
kubectl -n weather-alert rollout status deployment/alert-evaluator
kubectl -n weather-alert rollout status deployment/notification-dispatcher
```

**4. Check everything is up:**
```powershell
kubectl -n weather-alert get pods,svc
```

**5. Reach the services from your machine** (pick one):

- Port-forward (simplest, one service at a time):
  ```powershell
  kubectl -n weather-alert port-forward svc/user-service 8001:8001
  ```
  Then `curl http://localhost:8001/health` in another terminal. Repeat for `weather-fetcher` (8002), `alert-evaluator` (8003), `notification-dispatcher` (8004).

- Or via Ingress (`k8s/ingress.yaml`) — requires the ingress addon and a tunnel:
  ```powershell
  minikube addons enable ingress
  kubectl apply -f k8s/ingress.yaml
  minikube tunnel   # keep this running in its own terminal
  ```
  Add `127.0.0.1 weather-alert.local` to your hosts file, then hit `http://weather-alert.local/users/health` etc.

**Rebuilding after a code change:**
```powershell
minikube docker-env | Invoke-Expression
docker build -t weather-alert/user-service:latest -f user-service/Dockerfile .
kubectl -n weather-alert rollout restart deployment/user-service
```

**Tear down:**
```powershell
kubectl delete namespace weather-alert
```
This deletes every object in one shot, including the Postgres PVC — data is not preserved.

> On macOS/Linux with `make` installed, the equivalents are `make k8s-build`, `make k8s-deploy`, `make k8s-status`, `make k8s-port-forward`, and `make k8s-clean` (see [Makefile](Makefile)).

### Remote Kubernetes (registry-based)
```bash
# Build and tag for your registry
docker build -t registry.example.com/weather-alert/user-service:latest user-service/
docker push registry.example.com/weather-alert/user-service:latest
# ...repeat for the other 3 services

# Then in k8s/deployments/*.yaml, change `image:` to the registry path
# and `imagePullPolicy: Never` to `imagePullPolicy: IfNotPresent` (or remove it)
kubectl apply -f k8s/
```

## Contributing

- Follow Go code conventions
- Use descriptive commit messages
- Add tests for new features
- Update documentation

## License

MIT
