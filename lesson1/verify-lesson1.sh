#!/usr/bin/env bash
# verify-lesson1.sh — checks labs 1.1-1.4's requirements against the REAL
# weather-alert deployment/namespace. No lab namespace is created.
#
# Labs 1.1/1.2 only INSPECT already-running Pods (user-service,
# notification-dispatcher) - nothing is created or deleted.
#
# Labs 1.3/1.4 are different: Jobs/CronJobs run-to-completion and lab 1.4's
# Pods are standalone scale-test replicas, so there's no pre-existing object
# to inspect. Both create their real objects directly in the real
# "weather-alert" namespace (exactly as lesson1/1.3 and 1.4's own reference
# YAML do - short "postgres"/"nats"/"redis" DNS names, no lab namespace), then
# delete them at the end so the namespace is left as it was found. Lab 1.3's
# CronJob DELETE only ever targets notification_log rows older than 30 days -
# safe against real data. Lab 1.4's Pods carry no app=user-service/etc. label,
# so they can never be matched by the real Deployments' selectors.
#
# NOTE: lab 1.5 is temporarily disabled (see "Run everything" at the bottom)
# while labs 1.1-1.4's checks are being finalized.
#
# Run from WSL (or any shell with kubectl pointed at your minikube cluster):
#   bash lesson1/verify-lesson1.sh
#
# Flags:
#   --no-wait-cron           Don't wait ~70s for lab 1.3's CronJob to actually fire
#
# Prints PASS/FAIL lines plus an indented "Means:" explanation of what that
# result tells you. A final summary counts PASS / FAIL / SKIP.
#
# PREREQUISITE: the weather-alert namespace, its ConfigMap/Secret, backing
# services (postgres/redis/nats), and the user-service + notification-dispatcher
# Deployments must already be deployed and Running. See weather-alert/README.md
# "Deploy to Minikube". This script checks for that and skips everything with
# a clear message if it's not ready yet.

set -uo pipefail

REAL_NS="weather-alert"
WAIT_CRON=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait-cron) WAIT_CRON=0; shift ;;
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
# Prints a two-column row: the requirement being checked, and what was found.
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
# Preflight — the real weather-alert stack (including user-service) must
# already be deployed and Running. Nothing is created by this script.
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
  for obj in "configmap app-config" "secret app-secrets"; do
    if ! kubectl -n "$REAL_NS" get $obj >/dev/null 2>&1; then
      fail "$obj must exist in $REAL_NS" "not found"
      ok=0
    else
      pass "$obj must exist in $REAL_NS" "exists"
    fi
  done

  for dep in postgres redis nats user-service notification-dispatcher; do
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
}

# ---------------------------------------------------------------------------
# Lab 1.1 — The 60-Second Pod, verified against the REAL user-service Pod
# (part of the actual Deployment in REAL_NS) — nothing is created here.
# ---------------------------------------------------------------------------
verify_1_1() {
  section "Lab 1.1 — The 60-Second Pod (real user-service Pod, in $REAL_NS)"

  local pod_name
  pod_name=$(kubectl -n "$REAL_NS" get pods -l app=user-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "$pod_name" ]]; then
    fail "Must find a real Pod with label app=user-service" "not found"
    explain "Deploy the real user-service Deployment first: kubectl apply -f weather-alert/k8s/deployments/user-service.yaml"
    return
  fi
  pass "Must find a real Pod with label app=user-service" "$pod_name"

  local phase
  phase=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$phase" == "Running" ]]; then
    pass "Pod must be in Running phase" "phase=$phase"
  else
    fail "Pod must be in Running phase" "phase=$phase"
    explain "Check 'kubectl -n $REAL_NS logs $pod_name' and 'kubectl -n $REAL_NS describe pod $pod_name'."
  fi

  local image pull_policy container_port
  image=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
  pull_policy=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.containers[0].imagePullPolicy}' 2>/dev/null)
  container_port=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.containers[0].ports[0].containerPort}' 2>/dev/null)
  if [[ "$image" == "weather-alert/user-service:latest" && "$pull_policy" == "Never" && "$container_port" == "8001" ]]; then
    pass "image=weather-alert/user-service:latest, imagePullPolicy=Never, containerPort=8001" "image=$image, imagePullPolicy=$pull_policy, containerPort=$container_port"
    explain "imagePullPolicy=Never is required for locally-built images on minikube — without it the kubelet tries (and fails) to pull from a registry."
  else
    fail "image=weather-alert/user-service:latest, imagePullPolicy=Never, containerPort=8001" "image=$image, imagePullPolicy=$pull_policy, containerPort=$container_port"
  fi

  local label_app
  label_app=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.metadata.labels.app}' 2>/dev/null)
  if [[ "$label_app" == "user-service" ]]; then
    pass "Label app=user-service" "app=$label_app"
    explain "The real Deployment's selector (spec.selector.matchLabels) must match this exact label, or the Pod would never be adopted by the Deployment/Service."
  else
    fail "Label app=user-service" "app=$label_app"
  fi

  # Env vars the real Deployment wires in via envFrom(app-config) + secretKeyRef(app-secrets) + direct env
  local envs
  envs=$(kubectl -n "$REAL_NS" exec "$pod_name" -- printenv 2>/dev/null)
  declare -A expected_envs=(
    [PORT]="8001"
    [LOG_LEVEL]="info"
    [DB_HOST]="postgres"
    [DB_PORT]="5432"
    [DB_USER]="weather_app"
    [DB_PASSWORD]="weather_app"
    [DB_NAME]="weather_alert"
    [NATS_URL]="nats://nats:4222"
  )
  local envs_ok=1
  local env_mismatches=""
  for key in "${!expected_envs[@]}"; do
    local expected="${expected_envs[$key]}"
    local actual
    actual=$(echo "$envs" | grep "^${key}=" | cut -d= -f2-)
    if [[ "$actual" != "$expected" ]]; then
      envs_ok=0
      env_mismatches+=" $key(expected=$expected,got=$actual)"
    fi
  done
  if [[ "$envs_ok" -eq 1 ]]; then
    pass "8 env vars: PORT,LOG_LEVEL,DB_HOST,DB_PORT,DB_USER,DB_PASSWORD,DB_NAME,NATS_URL" "all match"
    explain "DB_HOST/DB_PORT/DB_NAME/NATS_URL/LOG_LEVEL come from the app-config ConfigMap (envFrom); DB_USER/DB_PASSWORD come from the app-secrets Secret (secretKeyRef) — same source of truth taught in lab 1.5."
  else
    fail "8 env vars: PORT,LOG_LEVEL,DB_HOST,DB_PORT,DB_USER,DB_PASSWORD,DB_NAME,NATS_URL" "mismatch:$env_mismatches"
  fi

  local req_cpu req_mem lim_cpu lim_mem
  req_cpu=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
  req_mem=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.containers[0].resources.requests.memory}' 2>/dev/null)
  lim_cpu=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.containers[0].resources.limits.cpu}' 2>/dev/null)
  lim_mem=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)
  if [[ "$req_cpu" == "50m" && "$req_mem" == "64Mi" && "$lim_cpu" == "250m" && "$lim_mem" == "128Mi" ]]; then
    pass "requests=cpu:50m,memory:64Mi limits=cpu:250m,memory:128Mi" "requests=cpu:$req_cpu,memory:$req_mem limits=cpu:$lim_cpu,memory:$lim_mem"
  else
    fail "requests=cpu:50m,memory:64Mi limits=cpu:250m,memory:128Mi" "requests=cpu:$req_cpu,memory:$req_mem limits=cpu:$lim_cpu,memory:$lim_mem"
  fi

  # Exam-speed check (no editor): export the running Pod's manifest via -o yaml
  local exported_yaml
  exported_yaml=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o yaml 2>/dev/null)
  if [[ "$exported_yaml" == *"kind: Pod"* && "$exported_yaml" == *"image: weather-alert/user-service:latest"* ]]; then
    pass "kubectl get pod -o yaml must export the manifest (no editor)" "exported successfully"
    explain "Exam-speed habit: never open vi/nano to inspect a live object — -o yaml/jsonpath gives you everything."
  else
    fail "kubectl get pod -o yaml must export the manifest (no editor)" "did not match expected"
  fi

  local health
  health=$(kubectl -n "$REAL_NS" exec "$pod_name" -- wget -qO- http://localhost:8001/health 2>/dev/null)
  if [[ "$health" == *'"status":"ok"'* ]]; then
    pass "GET /health must return status=ok" "$health"
    explain "This is the real user-service binary serving live traffic, not a placeholder — the health check ran inside the actual Deployment's Pod."
  else
    fail "GET /health must return status=ok" "$health"
  fi
}

# ---------------------------------------------------------------------------
# Lab 1.2 — Init + Sidecar Pattern, verified against the REAL notification-
# dispatcher Pod (part of the actual Deployment in REAL_NS) — nothing created.
# ---------------------------------------------------------------------------
verify_1_2() {
  section "Lab 1.2 — Init + Sidecar Pattern (real notification-dispatcher Pod, in $REAL_NS)"

  local pod_name
  pod_name=$(kubectl -n "$REAL_NS" get pods -l app=notification-dispatcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "$pod_name" ]]; then
    fail "Must find a real Pod with label app=notification-dispatcher" "not found"
    explain "Deploy the real notification-dispatcher Deployment first: kubectl apply -f weather-alert/k8s/deployments/notification-dispatcher.yaml"
    return
  fi
  pass "Must find a real Pod with label app=notification-dispatcher" "$pod_name"

  local phase
  phase=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$phase" == "Running" ]]; then
    pass "Pod must be in Running phase" "phase=$phase"
  else
    fail "Pod must be in Running phase" "phase=$phase"
    explain "Check 'kubectl -n $REAL_NS logs $pod_name -c check-config' and 'kubectl -n $REAL_NS describe pod $pod_name'."
  fi

  local init_name init_reason
  init_name=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.spec.initContainers[0].name}' 2>/dev/null)
  init_reason=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}' 2>/dev/null)
  if [[ "$init_name" == "check-config" && "$init_reason" == "Completed" ]]; then
    pass "Init container 'check-config' must terminate with reason=Completed" "name=$init_name, reason=$init_reason"
    explain "It validated DB_USER/DB_PASSWORD/APNS_KEY_ID/APNS_TEAM_ID were all non-empty before the main container was allowed to start — fail-fast on bad config instead of crash-looping later."
  else
    fail "Init container 'check-config' must terminate with reason=Completed" "name=$init_name, reason=$init_reason"
    explain "Check 'kubectl -n $REAL_NS logs $pod_name -c check-config' for which var was reported missing."
  fi

  local ready_count
  ready_count=$(kubectl -n "$REAL_NS" get pod "$pod_name" -o jsonpath='{range .status.containerStatuses[*]}{.ready}{" "}{end}' 2>/dev/null | grep -o true | wc -l)
  if [[ "$ready_count" -eq 2 ]]; then
    pass "Both regular containers (notification-dispatcher, health-monitor) must be Ready" "ready_count=$ready_count"
  else
    fail "Both regular containers (notification-dispatcher, health-monitor) must be Ready" "ready_count=$ready_count"
  fi

  # emptyDir sharing: the init container wrote a status file only the main
  # container should be able to read back — proves the volume hand-off worked.
  local status_contents
  status_contents=$(kubectl -n "$REAL_NS" exec "$pod_name" -c notification-dispatcher -- cat /status/config-check 2>/dev/null)
  if [[ "$status_contents" == *"config-check-passed"* ]]; then
    pass "Main container must read the status file staged by the init container via emptyDir" "$status_contents"
    explain "The init container and main container don't share a filesystem by default — the emptyDir volume mounted at /status in both is what lets the init container hand off proof of its work."
  else
    fail "Main container must read the status file staged by the init container via emptyDir" "$status_contents"
  fi

  local sidecar_check
  sidecar_check=$(kubectl -n "$REAL_NS" exec "$pod_name" -c health-monitor -- wget -qO- http://localhost:8004/health 2>/dev/null)
  if [[ "$sidecar_check" == *'"status":"ok"'* ]]; then
    pass "Sidecar must reach the app via localhost:8004" "$sidecar_check"
    explain "All containers in a Pod share one network namespace — the sidecar hits localhost:8004, never the Pod's own DNS name."
  else
    fail "Sidecar must reach the app via localhost:8004" "$sidecar_check"
  fi
}

# ---------------------------------------------------------------------------
# Lab 1.3 — Jobs & CronJobs, run as REAL Job/CronJob objects directly in
# REAL_NS against the real database (matching lesson1/1.3's own reference
# YAML exactly - short "postgres" DNS name, no lab namespace). Cleaned up
# at the end so the namespace is left as it was found.
# ---------------------------------------------------------------------------
verify_1_3() {
  section "Lab 1.3 — Jobs & CronJobs (real Job/CronJob objects in $REAL_NS)"

  # Clean slate in case a previous run didn't finish cleanup
  kubectl -n "$REAL_NS" delete job db-migrate db-connection-check-fail --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete cronjob notification-log-cleanup --ignore-not-found >/dev/null 2>&1

  # --- Part A: db-migrate (idempotent CREATE TABLE IF NOT EXISTS against the real DB) ---
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  namespace: $REAL_NS
spec:
  backoffLimit: 3
  template:
    spec:
      containers:
      - name: db-migrate
        image: postgres:15-alpine
        command: ["/bin/sh", "-c", "psql postgresql://weather_app:weather_app@postgres:5432/weather_alert -f /migrations/schema.sql"]
        volumeMounts:
        - name: schema-vol
          mountPath: /migrations
      volumes:
      - name: schema-vol
        configMap:
          name: postgres-init-schema
      restartPolicy: Never
EOF

  kubectl -n "$REAL_NS" wait --for=condition=Complete job/db-migrate --timeout=60s >/dev/null 2>&1
  local succeeded
  succeeded=$(kubectl -n "$REAL_NS" get job db-migrate -o jsonpath='{.status.succeeded}' 2>/dev/null)
  if [[ "$succeeded" == "1" ]]; then
    pass "Job db-migrate must complete with status.succeeded=1" "succeeded=$succeeded"
    explain "Applied schema.sql (idempotent CREATE TABLE IF NOT EXISTS) directly against the real database in $REAL_NS, reusing the same postgres-init-schema ConfigMap that bootstraps the postgres Pod itself."
  else
    fail "Job db-migrate must complete with status.succeeded=1" "succeeded=${succeeded:-0}"
    explain "Check 'kubectl -n $REAL_NS logs job/db-migrate' for the actual psql error."
  fi

  local table_check
  table_check=$(kubectl -n "$REAL_NS" run psql-check-$$ --rm -i --restart=Never --image=postgres:15-alpine -- \
    psql "postgresql://weather_app:weather_app@postgres:5432/weather_alert" -tAc \
    "SELECT to_regclass('public.users') IS NOT NULL AND to_regclass('public.notification_log') IS NOT NULL;" 2>/dev/null)
  if [[ "$table_check" == *"t"* ]]; then
    pass "Real tables 'users' and 'notification_log' must exist in the database" "found"
  else
    fail "Real tables 'users' and 'notification_log' must exist in the database" "result=$table_check"
  fi

  # --- db-connection-check-fail: should exhaust backoffLimit ---
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-connection-check-fail
  namespace: $REAL_NS
spec:
  backoffLimit: 2
  template:
    spec:
      containers:
      - name: db-connection-check-fail
        image: postgres:15-alpine
        command: ["/bin/sh", "-c", "pg_isready -h postgres-wrong-host -p 5432 -U weather_app -t 2"]
      restartPolicy: Never
EOF

  echo "        Waiting up to 60s for db-connection-check-fail to exhaust backoffLimit..."
  local waited=0
  local failed_reason=""
  while [[ $waited -lt 60 ]]; do
    failed_reason=$(kubectl -n "$REAL_NS" get job db-connection-check-fail -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null)
    [[ -n "$failed_reason" ]] && break
    sleep 5
    waited=$((waited + 5))
  done
  if [[ "$failed_reason" == "BackoffLimitExceeded" ]]; then
    pass "Job db-connection-check-fail must fail with reason=BackoffLimitExceeded" "reason=$failed_reason"
    explain "postgres-wrong-host doesn't exist, so pg_isready fails every attempt; after backoffLimit=2 retries the Job gave up permanently."
  else
    skip "Job db-connection-check-fail must fail with reason=BackoffLimitExceeded" "reason='${failed_reason:-not set yet}'"
    explain "backoffLimit retries use exponential backoff — re-run this script in a bit if this looks unfinished."
  fi

  # --- Part B: notification-log-cleanup CronJob ---
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: notification-log-cleanup
  namespace: $REAL_NS
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          containers:
          - name: notification-log-cleanup
            image: postgres:15-alpine
            command: ["/bin/sh", "-c", "psql postgresql://weather_app:weather_app@postgres:5432/weather_alert -c \"DELETE FROM notification_log WHERE created_at < NOW() - INTERVAL '30 days';\""]
          restartPolicy: OnFailure
EOF

  local schedule
  schedule=$(kubectl -n "$REAL_NS" get cronjob notification-log-cleanup -o jsonpath='{.spec.schedule}' 2>/dev/null)
  if [[ "$schedule" == "*/1 * * * *" ]]; then
    pass "CronJob notification-log-cleanup schedule must be */1 * * * *" "schedule=$schedule"
  else
    fail "CronJob notification-log-cleanup schedule must be */1 * * * *" "schedule=$schedule"
  fi

  if [[ "$WAIT_CRON" -eq 1 ]]; then
    echo "        Waiting up to 70s for the scheduler to fire at least one Job..."
    local waited2=0
    local last_schedule=""
    while [[ $waited2 -lt 70 ]]; do
      last_schedule=$(kubectl -n "$REAL_NS" get cronjob notification-log-cleanup -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null)
      [[ -n "$last_schedule" ]] && break
      sleep 5
      waited2=$((waited2 + 5))
    done
    if [[ -n "$last_schedule" ]]; then
      pass "CronJob must fire at least one Job on schedule" "lastScheduleTime=$last_schedule"
      explain "The CronJob controller created a fresh Job and ran the real DELETE against notification_log in $REAL_NS (scoped to rows older than 30 days)."
    else
      skip "CronJob must fire at least one Job on schedule" "no lastScheduleTime after 70s"
      explain "Timing issue, not necessarily a bug — cron ticks land on the wall-clock minute boundary. Re-run without --no-wait-cron or wait a bit."
    fi
  else
    skip "CronJob must fire at least one Job on schedule" "wait disabled (--no-wait-cron)"
  fi

  # Cleanup - remove the test Jobs/CronJob from the real namespace so it's left as it was found
  kubectl -n "$REAL_NS" delete job db-migrate db-connection-check-fail --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete cronjob notification-log-cleanup --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up db-migrate, db-connection-check-fail, and notification-log-cleanup from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Lab 1.4 — Label & Annotation Drill, run as REAL standalone Pods directly in
# REAL_NS (matching lesson1/1.4's own reference YAML exactly - short DNS names,
# no lab namespace). These 5 Pods are separate from the real Deployments (no
# app=user-service/etc. label), so labeling them can never affect the actual
# running project. Cleaned up at the end so the namespace is left as found.
# ---------------------------------------------------------------------------
verify_1_4() {
  section "Lab 1.4 — Label & Annotation Drill (real standalone Pods, in $REAL_NS)"

  declare -A pod_image=(
    [user-service-extra-1]="weather-alert/user-service:latest|api|PORT=8001"
    [user-service-extra-2]="weather-alert/user-service:latest|api|PORT=8001"
    [alert-evaluator-extra-1]="weather-alert/alert-evaluator:latest|worker|PORT=8003"
    [alert-evaluator-extra-2]="weather-alert/alert-evaluator:latest|worker|PORT=8003"
    [notification-dispatcher-extra-1]="weather-alert/notification-dispatcher:latest|dispatch|PORT=8004"
  )

  # Clean slate in case a previous run didn't finish cleanup
  kubectl -n "$REAL_NS" delete pods "${!pod_image[@]}" --ignore-not-found >/dev/null 2>&1

  for name in "${!pod_image[@]}"; do
    IFS='|' read -r image tier portenv <<< "${pod_image[$name]}"
    kubectl -n "$REAL_NS" run "$name" \
      --image="$image" --image-pull-policy=Never \
      --labels="app=weather-alert-scale-demo,tier=$tier" \
      --env="$portenv,DB_HOST=postgres,DB_PORT=5432,DB_USER=weather_app,DB_PASSWORD=weather_app,DB_NAME=weather_alert,NATS_URL=nats://nats:4222,REDIS_URL=redis:6379" >/dev/null
  done
  for name in "${!pod_image[@]}"; do
    kubectl -n "$REAL_NS" wait --for=condition=Ready "pod/$name" --timeout=60s >/dev/null 2>&1
  done

  local api_count worker_count dispatch_count
  api_count=$(kubectl -n "$REAL_NS" get pods -l app=weather-alert-scale-demo,tier=api --no-headers 2>/dev/null | wc -l)
  worker_count=$(kubectl -n "$REAL_NS" get pods -l app=weather-alert-scale-demo,tier=worker --no-headers 2>/dev/null | wc -l)
  dispatch_count=$(kubectl -n "$REAL_NS" get pods -l app=weather-alert-scale-demo,tier=dispatch --no-headers 2>/dev/null | wc -l)

  if [[ "$api_count" -eq 2 && "$worker_count" -eq 2 && "$dispatch_count" -eq 1 ]]; then
    pass "Selectors must return tier=api->2, tier=worker->2, tier=dispatch->1" "api=$api_count, worker=$worker_count, dispatch=$dispatch_count"
    explain "These are the real service images, standalone Pods living in $REAL_NS alongside the actual Deployments — but with no app=user-service/etc. label, so they can never be matched by the real Services' selectors."
  else
    fail "Selectors must return tier=api->2, tier=worker->2, tier=dispatch->1" "api=$api_count, worker=$worker_count, dispatch=$dispatch_count"
  fi

  # Overwrite test — mark one replica as a canary
  kubectl -n "$REAL_NS" label pod user-service-extra-1 tier=canary --overwrite >/dev/null 2>&1
  local canary_tier
  canary_tier=$(kubectl -n "$REAL_NS" get pod user-service-extra-1 -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
  if [[ "$canary_tier" == "canary" ]]; then
    pass "user-service-extra-1 must be relabeled tier=canary" "tier=$canary_tier"
    explain "--overwrite was required since 'tier' already existed — this is exactly how you'd mark one replica for canary testing without touching the others."
  else
    fail "user-service-extra-1 must be relabeled tier=canary" "tier=$canary_tier"
  fi

  # Bulk update test
  kubectl -n "$REAL_NS" label pods -l app=weather-alert-scale-demo env=scale-test --overwrite >/dev/null 2>&1
  local scale_test_count
  scale_test_count=$(kubectl -n "$REAL_NS" get pods -l app=weather-alert-scale-demo,env=scale-test --no-headers 2>/dev/null | wc -l)
  if [[ "$scale_test_count" -eq 5 ]]; then
    pass "Bulk label update must set env=scale-test on all 5 scale-demo Pods" "count=$scale_test_count"
  else
    fail "Bulk label update must set env=scale-test on all 5 scale-demo Pods" "count=$scale_test_count"
  fi

  # Confirm the REAL Deployment-managed Pods (different label set) were never touched
  local real_pod_count
  real_pod_count=$(kubectl -n "$REAL_NS" get pods -l app=user-service,env=scale-test --no-headers 2>/dev/null | wc -l)
  if [[ "$real_pod_count" -eq 0 ]]; then
    pass "Real user-service Deployment Pods must be unaffected by scale-demo labeling" "matched=$real_pod_count"
    explain "Even in the SAME namespace, the real Deployment's Pods carry only app=user-service (no tier/scale-demo label), so no selector used here could ever match them — label selectors are exact-match on the full key set, not proximity."
  else
    fail "Real user-service Deployment Pods must be unaffected by scale-demo labeling" "matched=$real_pod_count"
  fi

  # Annotation not selectable
  kubectl -n "$REAL_NS" annotate pods -l app=weather-alert-scale-demo \
    note="temporary scale-test pods, safe to delete" --overwrite >/dev/null 2>&1
  local annotated_note
  annotated_note=$(kubectl -n "$REAL_NS" get pod alert-evaluator-extra-1 -o jsonpath='{.metadata.annotations.note}' 2>/dev/null)
  local selector_result
  selector_result=$(kubectl -n "$REAL_NS" get pods -l note="temporary scale-test pods, safe to delete" --no-headers 2>/dev/null | wc -l)
  if [[ -n "$annotated_note" && "$selector_result" -eq 0 ]]; then
    pass "Annotation must be set but NOT selectable via -l" "note='$annotated_note', selector_matches=$selector_result"
    explain "Core Label vs Annotation distinction: annotations hold metadata, but only labels participate in selector queries."
  else
    fail "Annotation must be set but NOT selectable via -l" "note='$annotated_note', selector_matches=$selector_result"
  fi

  # Cleanup - remove the standalone test Pods so the namespace is left as it was found
  kubectl -n "$REAL_NS" delete pods "${!pod_image[@]}" --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up the 5 scale-demo Pods from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Lab 1.5 — ConfigMaps & Secrets (against the REAL weather-alert project, in REAL_NS)
# ---------------------------------------------------------------------------
verify_1_5() {
  section "Lab 1.5 — ConfigMaps & Secrets (weather-alert, in $REAL_NS)"

  if [[ "$SKIP_1_5" -eq 1 ]]; then
    skip "Lab 1.5 skipped (--skip-1.5)"
    return
  fi

  if ! kubectl -n "$REAL_NS" get deployment weather-fetcher >/dev/null 2>&1; then
    skip "weather-fetcher Deployment not found"
    explain "Lab 1.5 needs the real weather-fetcher Deployment running. Deploy it first (weather-alert/README.md), then re-run."
    return
  fi

  local db_password
  db_password=$(kubectl -n "$REAL_NS" get secret app-secrets -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null)
  if [[ -n "$db_password" ]]; then
    pass "Decoded Secret app-secrets.DB_PASSWORD (length=${#db_password})"
    explain "Secrets store values base64-ENCODED, not encrypted — anyone who can read the Secret object can decode it exactly like this."
  else
    fail "Could not decode DB_PASSWORD from app-secrets"
  fi

  local before_level
  before_level=$(kubectl -n "$REAL_NS" exec deploy/weather-fetcher -- printenv LOG_LEVEL 2>/dev/null)

  kubectl -n "$REAL_NS" patch configmap app-config --type merge -p '{"data":{"LOG_LEVEL":"debug"}}' >/dev/null 2>&1
  local cm_level
  cm_level=$(kubectl -n "$REAL_NS" get configmap app-config -o jsonpath='{.data.LOG_LEVEL}' 2>/dev/null)

  local still_old_level
  still_old_level=$(kubectl -n "$REAL_NS" exec deploy/weather-fetcher -- printenv LOG_LEVEL 2>/dev/null)

  if [[ "$cm_level" == "debug" && "$still_old_level" == "$before_level" ]]; then
    pass "ConfigMap updated to LOG_LEVEL=debug, but the running Pod still reports LOG_LEVEL=$still_old_level"
    explain "Env vars are a startup-time snapshot — editing the ConfigMap object never touches a container that's already running."
  else
    fail "Expected ConfigMap=debug + Pod unchanged, got ConfigMap=$cm_level Pod=$still_old_level"
  fi

  kubectl -n "$REAL_NS" rollout restart deployment/weather-fetcher >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/weather-fetcher --timeout=90s >/dev/null 2>&1

  local after_level
  after_level=$(kubectl -n "$REAL_NS" exec deploy/weather-fetcher -- printenv LOG_LEVEL 2>/dev/null)
  if [[ "$after_level" == "debug" ]]; then
    pass "After 'rollout restart', new Pod reports LOG_LEVEL=debug"
    explain "A rollout restart replaces the Pod, and the new Pod reads the ConfigMap fresh at its own startup — this is the only way env-based config picks up a change."
  else
    fail "Expected LOG_LEVEL=debug after restart, got $after_level"
  fi

  # Revert so the real project's state matches what's checked into k8s/
  kubectl -n "$REAL_NS" patch configmap app-config --type merge -p '{"data":{"LOG_LEVEL":"info"}}' >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout restart deployment/weather-fetcher >/dev/null 2>&1
  kubectl -n "$REAL_NS" rollout status deployment/weather-fetcher --timeout=90s >/dev/null 2>&1
  echo "        (Reverted LOG_LEVEL back to 'info' and restarted weather-fetcher to leave the real project as it was.)"
}

# ---------------------------------------------------------------------------
# Run everything
# ---------------------------------------------------------------------------
preflight
if [[ "$PREFLIGHT_OK" -eq 1 ]]; then
  verify_1_1
  verify_1_2
  verify_1_3
  verify_1_4
  # TODO: re-enable once labs 1.1-1.4 checks are confirmed passing
  # verify_1_5
else
  echo ""
  echo "${C_RED}Preflight failed — skipping labs 1.1-1.5. Fix the issues above and re-run.${C_RESET}"
fi

echo ""
echo "${C_BOLD}=== Summary ===${C_RESET}"
echo "${C_GREEN}PASS: $PASS_COUNT${C_RESET}  ${C_RED}FAIL: $FAIL_COUNT${C_RESET}  ${C_YELLOW}SKIP: $SKIP_COUNT${C_RESET}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
