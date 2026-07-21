#!/usr/bin/env bash
# Build the 4 weather-alert images into minikube's Docker daemon and deploy
# the full stack. Safe to re-run: rebuilds images and re-applies manifests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SERVICES=(user-service weather-fetcher alert-evaluator notification-dispatcher)

echo "==> Checking minikube status"
if ! minikube status >/dev/null 2>&1; then
  echo "==> Starting minikube"
  minikube start
fi

echo "==> Pointing Docker client at minikube's daemon"
eval "$(minikube docker-env)"

echo "==> Building images"
for svc in "${SERVICES[@]}"; do
  echo "  - $svc"
  docker build -t "weather-alert/${svc}:latest" -f "${svc}/Dockerfile" .
done

echo "==> Applying namespace, config, secrets"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmaps/
kubectl apply -f k8s/secrets/

echo "==> Applying backing services (postgres, redis, nats)"
kubectl apply -f k8s/backing-services/
kubectl -n weather-alert rollout status deployment/postgres --timeout=90s
kubectl -n weather-alert rollout status deployment/redis --timeout=60s
kubectl -n weather-alert rollout status deployment/nats --timeout=60s

echo "==> Applying application deployments"
kubectl apply -f k8s/deployments/
for svc in "${SERVICES[@]}"; do
  kubectl -n weather-alert rollout status "deployment/${svc}" --timeout=90s
done

echo "==> Done"
kubectl -n weather-alert get pods,svc
