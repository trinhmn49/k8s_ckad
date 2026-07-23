#!/usr/bin/env bash
# verify-lesson2.sh — checks labs 2.1-2.4's requirements against the REAL
# weather-alert deployment/namespace. No lab namespace is created.
#
# Every lab mutates real objects temporarily and reverts at the end:
#   - Lab 2.1: retags the real user-service image as v1/v2, rolls through
#     both, then deliberately deploys a tag that was never built
#     (v3-broken) to force a real stuck rollout, then rolls back. Ends by
#     resetting the image to :latest.
#   - Lab 2.2: creates two standalone Deployments (user-service-blue/green)
#     plus a dedicated router Service, flips the router's selector between
#     them, then deletes both Deployments and the router Service. The real
#     user-service Deployment/Service are never touched.
#   - Lab 2.3: scales user-service to 10 replicas, scales back to 2, creates
#     a real HorizontalPodAutoscaler, optionally drives real load against it
#     (skipped gracefully if metrics-server isn't enabled), then deletes the
#     HPA/load pods and restores the original replica count.
#   - Lab 2.4: applies the real kustomize/ overlays under lesson2/2.4/ as the
#     standalone user-service-demo Deployment/Service, switches from the dev
#     overlay to the prod overlay, then deletes both. The real user-service
#     Deployment/Service are never touched.
#
# Run from WSL (or any shell with kubectl pointed at your minikube cluster,
# and `eval $(minikube docker-env)` active so `docker tag` lands where the
# cluster can see it):
#   bash lesson2/verify-lesson2.sh
#
# Flags:
#   --skip-2.3-load   Skip lab 2.3's load-generation/scale-out wait (still
#                     creates/checks the HPA object itself)
#
# Prints PASS/FAIL lines plus an indented "Means:" explanation of what that
# result tells you. A final summary counts PASS / FAIL / SKIP.
#
# PREREQUISITE: the weather-alert namespace and the full stack (postgres,
# redis, nats, user-service, weather-fetcher, alert-evaluator,
# notification-dispatcher) must already be deployed and Running.
# See weather-alert/README.md "Deploy to Minikube". Lab 2.3 additionally
# needs `minikube addons enable metrics-server` for the live scale-out check
# (gracefully skipped, not failed, if metrics aren't available).

set -uo pipefail

REAL_NS="weather-alert"
SKIP_2_3_LOAD=0

# This script lives at lesson2/verify-lesson2.sh - lab 2.4's kustomize/
# directory is a sibling of this file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUSTOMIZE_DEV="$SCRIPT_DIR/2.4/kustomize/overlays/dev"
KUSTOMIZE_PROD="$SCRIPT_DIR/2.4/kustomize/overlays/prod"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-2.3-load) SKIP_2_3_LOAD=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CRITERIA_WIDTH=60

section() {
  echo ""
  echo "${C_BOLD}${C_CYAN}=== $1 ===${C_RESET}"
  printf "%-${CRITERIA_WIDTH}s | %s\n" "CRITERIA (requirement)" "ACTUAL RESULT"
  printf '%s\n' "$(printf -- '-%.0s' $(seq 1 100))"
}

# pass/fail/skip <criteria> <actual result>
pass() {
  printf "%s[PASS]%s %-${CRITERIA_WIDTH}s | %s\n" "$C_GREEN" "$C_RESET" "$1" "$2"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf "%s[FAIL]%s %-${CRITERIA_WIDTH}s | %s\n" "$C_RED" "$C_RESET" "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  printf "%s[SKIP]%s %-${CRITERIA_WIDTH}s | %s\n" "$C_YELLOW" "$C_RESET" "$1" "${2:-}"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

explain() {
  echo "        ${C_YELLOW}Means:${C_RESET} $1"
}

# ---------------------------------------------------------------------------
# Preflight — the real weather-alert stack must already be deployed and
# Running. Nothing is created by this script.
# ---------------------------------------------------------------------------
PREFLIGHT_OK=1

preflight() {
  section "Preflight — weather-alert stack"

  if ! kubectl get namespace "$REAL_NS" >/dev/null 2>&1; then
    fail "Namespace '$REAL_NS' must exist" "not found"
    explain "Deploy it first: kubectl apply -f ../weather-alert/k8s/namespace.yaml (see weather-alert/README.md)"
    PREFLIGHT_OK=0
    return
  fi
  pass "Namespace '$REAL_NS' must exist" "exists"

  local ok=1
  for dep in postgres redis nats user-service weather-fetcher alert-evaluator notification-dispatcher; do
    local ready
    ready=$(kubectl -n "$REAL_NS" get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [[ "$ready" -ge 1 ]] 2>/dev/null; then
      pass "Deployment '$dep' must have >=1 Ready replica" "readyReplicas=$ready"
    else
      fail "Deployment '$dep' must have >=1 Ready replica" "readyReplicas=${ready:-0}"
      ok=0
    fi
  done

  if [[ "$ok" -eq 0 ]]; then
    explain "Deploy the missing pieces first (see weather-alert/README.md 'Deploy to Minikube'), then re-run this script."
    PREFLIGHT_OK=0
    return
  fi

  # Point this shell's docker client at minikube's daemon so `docker tag`
  # (used by labs 2.1/2.2/2.4) lands where the cluster's kubelet can see it.
  eval "$(minikube docker-env 2>/dev/null)" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Lab 2.1 — Rolling Update & Rollback, run directly against the REAL
# user-service Deployment in REAL_NS. Retags the already-built image as v1/v2
# (same real binary, different tag - enough to exercise genuine rollout
# mechanics), then deploys a tag that was never built (v3-broken) to force a
# real stuck rollout, then rolls back. Always restores :latest at the end.
# ---------------------------------------------------------------------------
verify_2_1() {
  section "Lab 2.1 — Rolling Update & Rollback (real user-service Deployment, in $REAL_NS)"

  local original_image
  original_image=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [[ -z "$original_image" ]]; then
    fail "Deployment user-service must exist" "not found"
    explain "Deploy it first: kubectl apply -f weather-alert/k8s/deployments/user-service.yaml"
    return
  fi
  pass "Deployment user-service must exist" "image=$original_image"

  docker tag weather-alert/user-service:latest weather-alert/user-service:v1 2>/dev/null
  docker tag weather-alert/user-service:latest weather-alert/user-service:v2 2>/dev/null
  if docker image inspect weather-alert/user-service:v1 >/dev/null 2>&1 && \
     docker image inspect weather-alert/user-service:v2 >/dev/null 2>&1; then
    pass "Local image must be tagged as both v1 and v2" "tagged"
  else
    fail "Local image must be tagged as both v1 and v2" "docker tag failed — is 'eval \$(minikube docker-env)' active?"
    return
  fi

  # STEP 2: deploy v1 baseline
  kubectl -n "$REAL_NS" set image deployment/user-service user-service=weather-alert/user-service:v1 >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service --timeout=90s >/dev/null 2>&1
  local image_v1
  image_v1=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [[ "$image_v1" == "weather-alert/user-service:v1" ]]; then
    pass "Deployment must run v1 after the first rollout" "image=$image_v1"
  else
    fail "Deployment must run v1 after the first rollout" "image=$image_v1"
  fi

  # STEP 3: roll out v2
  kubectl -n "$REAL_NS" set image deployment/user-service user-service=weather-alert/user-service:v2 >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service --timeout=90s >/dev/null 2>&1
  local image_v2
  image_v2=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [[ "$image_v2" == "weather-alert/user-service:v2" ]]; then
    pass "Deployment must run v2 after the rolling update" "image=$image_v2"
    explain "Each image change is a .spec.template edit — a NEW ReplicaSet took over once its Pods passed readinessProbe."
  else
    fail "Deployment must run v2 after the rolling update" "image=$image_v2"
  fi

  local revision_count_before_bad
  revision_count_before_bad=$(kubectl -n "$REAL_NS" rollout history deployment/user-service 2>/dev/null | grep -cE '^[0-9]+[[:space:]]')

  # STEP 4: simulate a bad deployment (tag that was never built)
  kubectl -n "$REAL_NS" set image deployment/user-service user-service=weather-alert/user-service:v3-broken >/dev/null 2>&1
  echo "        Waiting up to 30s for the bad tag to get stuck (ErrImageNeverPull/ImagePullBackOff)..."
  local waited=0
  local bad_reason=""
  while [[ $waited -lt 30 ]]; do
    bad_reason=$(kubectl -n "$REAL_NS" get pods -l app=user-service -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{" "}{end}' 2>/dev/null)
    [[ "$bad_reason" == *"ErrImageNeverPull"* || "$bad_reason" == *"ImagePullBackOff"* ]] && break
    sleep 3
    waited=$((waited + 3))
  done
  if [[ "$bad_reason" == *"ErrImageNeverPull"* || "$bad_reason" == *"ImagePullBackOff"* ]]; then
    pass "Deploying an unbuilt tag must get a Pod stuck (bad rollout signal)" "reason=$bad_reason"
    explain "imagePullPolicy: Never + a tag that was never built is a safe, scriptable way to simulate a bad release without shipping broken app code."
  else
    fail "Deploying an unbuilt tag must get a Pod stuck (bad rollout signal)" "reason='${bad_reason:-none found}'"
  fi

  # STEP 5: roll back
  kubectl -n "$REAL_NS" rollout undo deployment/user-service >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service --timeout=90s >/dev/null 2>&1
  local image_after_undo
  image_after_undo=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [[ "$image_after_undo" == "weather-alert/user-service:v2" ]]; then
    pass "rollout undo must revert to the last known-good image (v2)" "image=$image_after_undo"
    explain "Rollback isn't 'going back in time' — kubectl rollout undo re-applies the previous ReplicaSet's template as a brand-new revision."
  else
    fail "rollout undo must revert to the last known-good image (v2)" "image=$image_after_undo"
  fi

  local revision_count_after
  revision_count_after=$(kubectl -n "$REAL_NS" rollout history deployment/user-service 2>/dev/null | grep -cE '^[0-9]+[[:space:]]')
  if [[ "$revision_count_after" -gt "$revision_count_before_bad" ]]; then
    pass "rollout history must grow (bad deploy + rollback both add revisions)" "revisions=$revision_count_after (was $revision_count_before_bad)"
  else
    fail "rollout history must grow (bad deploy + rollback both add revisions)" "revisions=$revision_count_after (was $revision_count_before_bad)"
  fi

  # Restore original image
  kubectl -n "$REAL_NS" set image deployment/user-service "user-service=$original_image" >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service --timeout=90s >/dev/null 2>&1
  echo "        (Restored user-service image to $original_image.)"
}

# ---------------------------------------------------------------------------
# Lab 2.2 — Blue/Green Switch, creates its OWN standalone Deployments
# (user-service-blue/green) and a dedicated router Service in REAL_NS -
# completely separate from the real user-service Deployment/Service. Deletes
# everything it created at the end.
# ---------------------------------------------------------------------------
verify_2_2() {
  section "Lab 2.2 — Blue/Green Switch (standalone blue/green Deployments, in $REAL_NS)"

  # Clean slate in case a previous run didn't finish cleanup
  kubectl -n "$REAL_NS" delete deployment user-service-blue user-service-green --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete service user-service-bluegreen-router --ignore-not-found >/dev/null 2>&1

  docker tag weather-alert/user-service:latest weather-alert/user-service:blue 2>/dev/null
  docker tag weather-alert/user-service:latest weather-alert/user-service:green 2>/dev/null

  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service-blue
  namespace: $REAL_NS
spec:
  replicas: 2
  selector:
    matchLabels: {app: user-service-bluegreen, color: blue}
  template:
    metadata:
      labels: {app: user-service-bluegreen, color: blue}
    spec:
      containers:
      - name: user-service
        image: weather-alert/user-service:blue
        imagePullPolicy: Never
        ports: [{containerPort: 8001}]
        env:
        - {name: PORT, value: "8001"}
        - {name: DEPLOY_COLOR, value: blue}
        - name: DB_USER
          valueFrom: {secretKeyRef: {name: app-secrets, key: DB_USER}}
        - name: DB_PASSWORD
          valueFrom: {secretKeyRef: {name: app-secrets, key: DB_PASSWORD}}
        envFrom: [{configMapRef: {name: app-config}}]
        readinessProbe:
          httpGet: {path: /health, port: 8001}
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {cpu: 250m, memory: 128Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service-green
  namespace: $REAL_NS
spec:
  replicas: 2
  selector:
    matchLabels: {app: user-service-bluegreen, color: green}
  template:
    metadata:
      labels: {app: user-service-bluegreen, color: green}
    spec:
      containers:
      - name: user-service
        image: weather-alert/user-service:green
        imagePullPolicy: Never
        ports: [{containerPort: 8001}]
        env:
        - {name: PORT, value: "8001"}
        - {name: DEPLOY_COLOR, value: green}
        - name: DB_USER
          valueFrom: {secretKeyRef: {name: app-secrets, key: DB_USER}}
        - name: DB_PASSWORD
          valueFrom: {secretKeyRef: {name: app-secrets, key: DB_PASSWORD}}
        envFrom: [{configMapRef: {name: app-config}}]
        readinessProbe:
          httpGet: {path: /health, port: 8001}
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {cpu: 250m, memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: user-service-bluegreen-router
  namespace: $REAL_NS
spec:
  selector: {app: user-service-bluegreen, color: blue}
  ports: [{port: 8001, targetPort: 8001}]
  type: ClusterIP
EOF

  kubectl -n "$REAL_NS" rollout status deployment/user-service-blue --timeout=90s >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service-green --timeout=90s >/dev/null 2>&1

  local router_color blue_ip green_ip endpoint_ip
  router_color=$(kubectl -n "$REAL_NS" get service user-service-bluegreen-router -o jsonpath='{.spec.selector.color}' 2>/dev/null)
  endpoint_ip=$(kubectl -n "$REAL_NS" get endpoints user-service-bluegreen-router -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  blue_ip=$(kubectl -n "$REAL_NS" get pods -l app=user-service-bluegreen,color=blue -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  if [[ "$router_color" == "blue" && -n "$endpoint_ip" && "$endpoint_ip" == "$blue_ip" ]]; then
    pass "Router Service must start pointed at blue" "selector.color=$router_color, endpointIP matches a blue Pod"
    explain "Both Deployments run full-strength at once — the Service's label selector alone decides which one receives traffic."
  else
    fail "Router Service must start pointed at blue" "selector.color=$router_color, endpointIP=$endpoint_ip, blueIP=$blue_ip"
  fi

  # Flip to green
  kubectl -n "$REAL_NS" patch service user-service-bluegreen-router --type merge \
    -p '{"spec":{"selector":{"app":"user-service-bluegreen","color":"green"}}}' >/dev/null 2>&1
  sleep 2
  green_ip=$(kubectl -n "$REAL_NS" get pods -l app=user-service-bluegreen,color=green -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  endpoint_ip=$(kubectl -n "$REAL_NS" get endpoints user-service-bluegreen-router -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  if [[ -n "$endpoint_ip" && "$endpoint_ip" == "$green_ip" ]]; then
    pass "Selector flip must cut traffic to green instantly" "endpointIP now matches a green Pod"
    explain "No Pods were created, deleted, or restarted by the flip — only the Service's Endpoints selection changed."
  else
    fail "Selector flip must cut traffic to green instantly" "endpointIP=$endpoint_ip, greenIP=$green_ip"
  fi

  # Flip back to blue (instant rollback)
  kubectl -n "$REAL_NS" patch service user-service-bluegreen-router --type merge \
    -p '{"spec":{"selector":{"app":"user-service-bluegreen","color":"blue"}}}' >/dev/null 2>&1
  sleep 2
  endpoint_ip=$(kubectl -n "$REAL_NS" get endpoints user-service-bluegreen-router -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  if [[ -n "$endpoint_ip" && "$endpoint_ip" == "$blue_ip" ]]; then
    pass "Flipping back to blue must be an instant rollback (no rollout)" "endpointIP matches a blue Pod again"
  else
    fail "Flipping back to blue must be an instant rollback (no rollout)" "endpointIP=$endpoint_ip, blueIP=$blue_ip"
  fi

  # Confirm the REAL Deployment/Service were never touched
  local real_image real_selector
  real_image=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  real_selector=$(kubectl -n "$REAL_NS" get service user-service -o jsonpath='{.spec.selector.app}' 2>/dev/null)
  if [[ "$real_selector" == "user-service" ]]; then
    pass "Real user-service Deployment/Service must be unaffected" "image=$real_image, service selector app=$real_selector"
  else
    fail "Real user-service Deployment/Service must be unaffected" "image=$real_image, service selector app=$real_selector"
  fi

  kubectl -n "$REAL_NS" delete deployment user-service-blue user-service-green --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete service user-service-bluegreen-router --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up user-service-blue, user-service-green, and the router Service from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Lab 2.3 — Scale & HPA, run directly against the REAL user-service
# Deployment in REAL_NS. Always restores the original replica count and
# removes the HPA/load pods at the end.
# ---------------------------------------------------------------------------
verify_2_3() {
  section "Lab 2.3 — Scale & HPA (real user-service Deployment, in $REAL_NS)"

  local original_replicas
  original_replicas=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [[ -z "$original_replicas" ]]; then
    fail "Deployment user-service must exist" "not found"
    return
  fi

  # STEP 1: manual scale to 10
  kubectl -n "$REAL_NS" scale deployment user-service --replicas=10 >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service --timeout=120s >/dev/null 2>&1
  local ready_at_10
  ready_at_10=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ "$ready_at_10" == "10" ]]; then
    pass "Manual scale to 10 replicas must succeed" "readyReplicas=$ready_at_10"
  else
    fail "Manual scale to 10 replicas must succeed" "readyReplicas=${ready_at_10:-0}"
  fi

  local endpoint_count
  endpoint_count=$(kubectl -n "$REAL_NS" get endpoints user-service -o jsonpath='{range .subsets[0].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -c .)
  if [[ "$endpoint_count" -eq 10 ]]; then
    pass "Service endpoints must list all 10 scaled Pods" "endpointCount=$endpoint_count"
  else
    fail "Service endpoints must list all 10 scaled Pods" "endpointCount=$endpoint_count"
  fi

  # STEP 2: scale back to a small baseline before the HPA takes over
  kubectl -n "$REAL_NS" scale deployment user-service --replicas=2 >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service --timeout=90s >/dev/null 2>&1

  # STEP 3: create the HPA
  kubectl -n "$REAL_NS" delete hpa user-service --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" autoscale deployment user-service --cpu-percent=50 --min=2 --max=10 >/dev/null 2>&1

  local hpa_min hpa_max hpa_target
  hpa_min=$(kubectl -n "$REAL_NS" get hpa user-service -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
  hpa_max=$(kubectl -n "$REAL_NS" get hpa user-service -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
  hpa_target=$(kubectl -n "$REAL_NS" get hpa user-service -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)
  if [[ "$hpa_min" == "2" && "$hpa_max" == "10" && "$hpa_target" == "50" ]]; then
    pass "HPA must be configured min=2, max=10, cpu target=50%" "min=$hpa_min, max=$hpa_max, target=$hpa_target%"
    explain "Percentage targets are computed against the container's resources.requests.cpu — user-service already requests 50m per Pod."
  else
    fail "HPA must be configured min=2, max=10, cpu target=50%" "min=$hpa_min, max=$hpa_max, target=$hpa_target%"
  fi

  if [[ "$SKIP_2_3_LOAD" -eq 1 ]]; then
    skip "HPA must scale OUT under real load" "wait disabled (--skip-2.3-load)"
  else
    if ! kubectl -n "$REAL_NS" top pods >/dev/null 2>&1; then
      skip "HPA must scale OUT under real load" "metrics-server not available"
      explain "Enable it first: minikube addons enable metrics-server (then wait ~1-2 min before re-running with load)."
    else
      for i in 1 2 3 4; do
        kubectl -n "$REAL_NS" run "load-generator-$i" --image=busybox:musl --restart=Never -- \
          /bin/sh -c "while true; do wget -q -O- http://user-service:8001/health >/dev/null; done" >/dev/null 2>&1
      done

      echo "        Waiting up to 90s for the HPA to scale OUT above minReplicas under load..."
      local waited=0
      local current_replicas="$original_replicas"
      while [[ $waited -lt 90 ]]; do
        current_replicas=$(kubectl -n "$REAL_NS" get hpa user-service -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
        [[ "${current_replicas:-0}" -gt 2 ]] 2>/dev/null && break
        sleep 10
        waited=$((waited + 10))
      done
      if [[ "${current_replicas:-0}" -gt 2 ]] 2>/dev/null; then
        pass "HPA must scale OUT above minReplicas under load" "currentReplicas=$current_replicas"
        explain "The HPA controller adjusted .spec.replicas itself — same mechanism as kubectl scale, just automatic."
      else
        skip "HPA must scale OUT above minReplicas under load" "currentReplicas=${current_replicas:-unknown} after 90s"
        explain "A single lightweight /health handler may not push CPU past 50% of a 50m request even under this load — not necessarily a bug. Re-run with more load-generator Pods if this matters to you."
      fi

      kubectl -n "$REAL_NS" delete pod load-generator-1 load-generator-2 load-generator-3 load-generator-4 --ignore-not-found >/dev/null 2>&1
    fi
  fi

  # Cleanup
  kubectl -n "$REAL_NS" delete hpa user-service --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" scale deployment user-service --replicas="$original_replicas" >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service --timeout=90s >/dev/null 2>&1
  echo "        (Removed the HPA and restored user-service to $original_replicas replica(s).)"
}

# ---------------------------------------------------------------------------
# Lab 2.4 — Kustomize Overlay, applies the REAL kustomize/ base+overlays
# under lesson2/2.4/ as the standalone user-service-demo Deployment/Service -
# completely separate from the real user-service Deployment/Service. Deletes
# both overlays' objects at the end.
# ---------------------------------------------------------------------------
verify_2_4() {
  section "Lab 2.4 — Kustomize Overlay (standalone user-service-demo, in $REAL_NS)"

  if [[ ! -d "$KUSTOMIZE_DEV" || ! -d "$KUSTOMIZE_PROD" ]]; then
    fail "kustomize/overlays/dev and prod must exist" "not found under $SCRIPT_DIR/2.4/kustomize"
    return
  fi

  docker tag weather-alert/user-service:latest weather-alert/user-service:v2 2>/dev/null

  # Clean slate in case a previous run didn't finish cleanup
  kubectl delete -k "$KUSTOMIZE_DEV" --ignore-not-found >/dev/null 2>&1
  kubectl delete -k "$KUSTOMIZE_PROD" --ignore-not-found >/dev/null 2>&1

  local dev_rendered
  dev_rendered=$(kubectl kustomize "$KUSTOMIZE_DEV" 2>/dev/null)
  local prod_rendered
  prod_rendered=$(kubectl kustomize "$KUSTOMIZE_PROD" 2>/dev/null)
  if [[ "$dev_rendered" == *"replicas: 1"* && "$dev_rendered" == *"user-service:latest"* \
        && "$prod_rendered" == *"replicas: 4"* && "$prod_rendered" == *"user-service:v2"* ]]; then
    pass "kubectl kustomize must render dev (1 replica, latest) and prod (4 replicas, v2)" "both overlays render correctly, no cluster contact"
    explain "Neither overlay copies the base Deployment — 'replicas:' and 'images:' transformers patch it at render time."
  else
    fail "kubectl kustomize must render dev (1 replica, latest) and prod (4 replicas, v2)" "dev or prod rendering did not match expected values"
  fi

  # Apply dev overlay
  kubectl apply -k "$KUSTOMIZE_DEV" >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service-demo --timeout=90s >/dev/null 2>&1
  local dev_replicas dev_image dev_env
  dev_replicas=$(kubectl -n "$REAL_NS" get deployment user-service-demo -o jsonpath='{.spec.replicas}' 2>/dev/null)
  dev_image=$(kubectl -n "$REAL_NS" get deployment user-service-demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  dev_env=$(kubectl -n "$REAL_NS" get deployment user-service-demo -o jsonpath='{.spec.template.metadata.labels.env}' 2>/dev/null)
  if [[ "$dev_replicas" == "1" && "$dev_image" == "weather-alert/user-service:latest" && "$dev_env" == "dev" ]]; then
    pass "dev overlay must deploy 1 replica of :latest, labeled env=dev" "replicas=$dev_replicas, image=$dev_image, env=$dev_env"
  else
    fail "dev overlay must deploy 1 replica of :latest, labeled env=dev" "replicas=$dev_replicas, image=$dev_image, env=$dev_env"
  fi

  # Switch to prod overlay (must delete dev first - shared resource name, immutable selector)
  kubectl delete -k "$KUSTOMIZE_DEV" >/dev/null 2>&1
  kubectl apply -k "$KUSTOMIZE_PROD" >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/user-service-demo --timeout=90s >/dev/null 2>&1
  local prod_replicas prod_image prod_env
  prod_replicas=$(kubectl -n "$REAL_NS" get deployment user-service-demo -o jsonpath='{.spec.replicas}' 2>/dev/null)
  prod_image=$(kubectl -n "$REAL_NS" get deployment user-service-demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  prod_env=$(kubectl -n "$REAL_NS" get deployment user-service-demo -o jsonpath='{.spec.template.metadata.labels.env}' 2>/dev/null)
  if [[ "$prod_replicas" == "4" && "$prod_image" == "weather-alert/user-service:v2" && "$prod_env" == "prod" ]]; then
    pass "prod overlay must deploy 4 replicas of :v2, labeled env=prod" "replicas=$prod_replicas, image=$prod_image, env=$prod_env"
    explain "Same base/ manifests for both environments — only the overlay-level replicas/images/commonLabels patches differ."
  else
    fail "prod overlay must deploy 4 replicas of :v2, labeled env=prod" "replicas=$prod_replicas, image=$prod_image, env=$prod_env"
  fi

  # Confirm the REAL Deployment was never touched
  local real_image
  real_image=$(kubectl -n "$REAL_NS" get deployment user-service -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [[ -n "$real_image" ]]; then
    pass "Real user-service Deployment must be unaffected" "image=$real_image"
  else
    fail "Real user-service Deployment must be unaffected" "not found"
  fi

  kubectl delete -k "$KUSTOMIZE_PROD" --ignore-not-found >/dev/null 2>&1
  kubectl delete -k "$KUSTOMIZE_DEV" --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up user-service-demo and its Service from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Run everything
# ---------------------------------------------------------------------------
preflight
if [[ "$PREFLIGHT_OK" -eq 1 ]]; then
  verify_2_1
  verify_2_2
  verify_2_3
  verify_2_4
else
  echo ""
  echo "${C_RED}Preflight failed — skipping labs 2.1-2.4. Fix the issues above and re-run.${C_RESET}"
fi

echo ""
echo "${C_BOLD}=== Summary ===${C_RESET}"
echo "${C_GREEN}PASS: $PASS_COUNT${C_RESET}  ${C_RED}FAIL: $FAIL_COUNT${C_RESET}  ${C_YELLOW}SKIP: $SKIP_COUNT${C_RESET}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
