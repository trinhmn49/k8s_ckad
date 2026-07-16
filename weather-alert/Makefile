.PHONY: help up down logs test build clean reset-db k8s-build k8s-deploy k8s-status k8s-logs k8s-port-forward k8s-clean

help:
	@echo "Weather Alert Microservices - Available Commands"
	@echo ""
	@echo "  make up              - Start all services (docker-compose)"
	@echo "  make down            - Stop all services"
	@echo "  make logs            - View real-time logs from all services"
	@echo "  make logs-service    - View logs from specific service (usage: make logs-service SERVICE=user-service)"
	@echo "  make ps              - Show running containers"
	@echo "  make test            - Run all unit tests"
	@echo "  make test-service    - Run tests for specific service (usage: make test-service SERVICE=user-service)"
	@echo "  make build           - Build all service Docker images"
	@echo "  make health          - Check health of all services"
	@echo "  make reset-db        - Reset database (drops and recreates)"
	@echo "  make clean           - Stop services and remove volumes"
	@echo ""
	@echo "  Kubernetes / minikube:"
	@echo "  make k8s-build       - Build images into minikube's Docker daemon"
	@echo "  make k8s-deploy      - Apply all k8s manifests"
	@echo "  make k8s-status      - Show pods/services in weather-alert namespace"
	@echo "  make k8s-logs        - Tail logs for a deployment (usage: make k8s-logs SERVICE=user-service)"
	@echo "  make k8s-port-forward - Port-forward all 4 services to localhost:8001-8004"
	@echo "  make k8s-clean       - Delete the weather-alert namespace"

up:
	docker-compose up -d
	@echo "✓ All services started. Waiting for startup..."
	sleep 5
	@make health

down:
	docker-compose down

logs:
	docker-compose logs -f

logs-service:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Usage: make logs-service SERVICE=user-service"; \
	else \
		docker-compose logs -f $(SERVICE); \
	fi

ps:
	docker-compose ps

test:
	cd user-service && go test ./... && cd ..
	cd weather-fetcher && go test ./... && cd ..
	cd alert-evaluator && go test ./... && cd ..
	cd notification-dispatcher && go test ./... && cd ..

test-service:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Usage: make test-service SERVICE=user-service"; \
	else \
		cd $(SERVICE) && go test ./... && cd ..; \
	fi

build:
	docker build -t weather-alert/user-service:latest user-service/
	docker build -t weather-alert/weather-fetcher:latest weather-fetcher/
	docker build -t weather-alert/alert-evaluator:latest alert-evaluator/
	docker build -t weather-alert/notification-dispatcher:latest notification-dispatcher/

health:
	@echo "Checking service health..."
	@curl -s http://localhost:8001/health | jq '.' && echo "✓ user-service" || echo "✗ user-service"
	@curl -s http://localhost:8002/health | jq '.' && echo "✓ weather-fetcher" || echo "✗ weather-fetcher"
	@curl -s http://localhost:8003/health | jq '.' && echo "✓ alert-evaluator" || echo "✗ alert-evaluator"
	@curl -s http://localhost:8004/health | jq '.' && echo "✓ notification-dispatcher" || echo "✗ notification-dispatcher"

reset-db:
	docker-compose down -v
	docker-compose up -d postgres redis nats
	@echo "Waiting for database to be ready..."
	sleep 5
	docker-compose up -d

clean:
	docker-compose down -v
	@echo "✓ All services stopped and volumes removed"

k8s-build:
	eval $$(minikube docker-env) && \
	docker build -t weather-alert/user-service:latest user-service/ && \
	docker build -t weather-alert/weather-fetcher:latest weather-fetcher/ && \
	docker build -t weather-alert/alert-evaluator:latest alert-evaluator/ && \
	docker build -t weather-alert/notification-dispatcher:latest notification-dispatcher/

k8s-deploy:
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/configmaps/
	kubectl apply -f k8s/secrets/
	kubectl apply -f k8s/backing-services/
	kubectl -n weather-alert rollout status deployment/postgres --timeout=90s
	kubectl -n weather-alert rollout status deployment/redis --timeout=60s
	kubectl -n weather-alert rollout status deployment/nats --timeout=60s
	kubectl apply -f k8s/deployments/
	kubectl -n weather-alert rollout status deployment/user-service --timeout=90s
	kubectl -n weather-alert rollout status deployment/weather-fetcher --timeout=90s
	kubectl -n weather-alert rollout status deployment/alert-evaluator --timeout=90s
	kubectl -n weather-alert rollout status deployment/notification-dispatcher --timeout=90s

k8s-status:
	kubectl -n weather-alert get pods,svc,deployments

k8s-logs:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Usage: make k8s-logs SERVICE=user-service"; \
	else \
		kubectl -n weather-alert logs -f deployment/$(SERVICE); \
	fi

k8s-port-forward:
	@echo "Forwarding ports 8001-8004 to weather-alert services. Ctrl+C to stop."
	kubectl -n weather-alert port-forward svc/user-service 8001:8001 & \
	kubectl -n weather-alert port-forward svc/weather-fetcher 8002:8002 & \
	kubectl -n weather-alert port-forward svc/alert-evaluator 8003:8003 & \
	kubectl -n weather-alert port-forward svc/notification-dispatcher 8004:8004 & \
	wait

k8s-clean:
	kubectl delete namespace weather-alert --ignore-not-found
