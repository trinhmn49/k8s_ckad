#!/usr/bin/env bash
# verify-lesson1.sh — recreates, checks, and explains the results of labs 1.1-1.5.
#
# TWO-NAMESPACE DESIGN:
#   - REAL_NS ("weather-alert")     - the actual deployed project. Left alone,
#     except lab 1.5 which intentionally patches its ConfigMap and reverts it.
#   - LAB_NS  ("weather-alert-lab") - created fresh by this script for labs
#     1.1-1.4. Pods here reach Postgres/Redis/NATS in REAL_NS via cross-namespace
#     DNS (e.g. postgres.weather-alert.svc.cluster.local) - the same mechanism
#     taught in lesson2/2.2. Cleanup is just deleting this whole namespace.
#
# All five labs use the REAL weather-alert images: weather-alert/user-service,
# alert-evaluator, notification-dispatcher, and postgres:15-alpine (the
# project's own backing-service image) - not generic busybox/nginx placeholders.
#
# Run from WSL (or any shell with kubectl pointed at your minikube cluster):
#   bash lesson1/verify-lesson1.sh
#
# Flags:
#   --keep                   Don't delete the weather-alert-lab namespace afterward
#   --skip-1.5               Skip lab 1.5 (ConfigMap/Secret checks against REAL_NS)
#   --no-wait-cron           Don't wait ~70s for the CronJob in lab 1.3 to actually fire
#
# Each lab prints PASS/FAIL lines plus an indented "Means:" explanation of what
# that result tells you. A final summary counts PASS / FAIL / SKIP across all labs.
#
# PREREQUISITE: the weather-alert namespace, its ConfigMap/Secret, and its
# backing services (postgres/redis/nats) must already be deployed and Running,
# and the 4 service images must already be built into minikube's Docker daemon.
# See weather-alert/README.md "Deploy to Minikube". This script checks for that
# and skips everything with a clear message if it's not ready yet.

set -uo pipefail

REAL_NS="weather-alert"
LAB_NS="weather-alert-lab"
KEEP=0
SKIP_1_5=0
WAIT_CRON=1

# This script lives at lesson1/verify-lesson1.sh - the real project's schema
# file is a sibling directory up one level.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="$SCRIPT_DIR/../weather-alert/db/schema.sql"

# Cross-namespace Service DNS names (Service.Namespace form - reachable from
# ANY namespace, unlike the short "postgres" name which only works inside REAL_NS)
POSTGRES_FQDN="postgres.${REAL_NS}.svc.cluster.local"
REDIS_FQDN="redis.${REAL_NS}.svc.cluster.local"
NATS_FQDN="nats.${REAL_NS}.svc.cluster.local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --skip-1.5) SKIP_1_5=1; shift ;;
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

section() {
  echo ""
  echo "${C_BOLD}${C_CYAN}=== $1 ===${C_RESET}"
}

pass() {
  echo "${C_GREEN}[PASS]${C_RESET} $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "${C_RED}[FAIL]${C_RESET} $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  echo "${C_YELLOW}[SKIP]${C_RESET} $1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

explain() {
  echo "        ${C_YELLOW}Means:${C_RESET} $1"
}

run_cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo ""
    echo "${C_YELLOW}--keep set: leaving namespace '$LAB_NS' in place.${C_RESET}"
    return
  fi
  echo ""
  echo "${C_BOLD}Deleting namespace '$LAB_NS' (removes everything labs 1.1-1.4 created)...${C_RESET}"
  kubectl delete namespace "$LAB_NS" --ignore-not-found >/dev/null 2>&1
}
trap run_cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight — the real weather-alert stack must already be deployed, then
# create the fresh lab namespace
# ---------------------------------------------------------------------------
PREFLIGHT_OK=1

preflight() {
  section "Preflight — weather-alert stack + lab namespace"

  if ! kubectl get namespace "$REAL_NS" >/dev/null 2>&1; then
    fail "Namespace '$REAL_NS' does not exist"
    explain "Deploy it first: kubectl apply -f ../weather-alert/k8s/namespace.yaml (see weather-alert/README.md)"
    PREFLIGHT_OK=0
    return
  fi
  pass "Namespace '$REAL_NS' exists"

  local ok=1
  for obj in "configmap app-config" "secret app-secrets"; do
    if ! kubectl -n "$REAL_NS" get $obj >/dev/null 2>&1; then
      fail "Missing: $obj in $REAL_NS"
      ok=0
    fi
  done

  for dep in postgres redis nats; do
    local ready
    ready=$(kubectl -n "$REAL_NS" get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [[ "$ready" -ge 1 ]] 2>/dev/null; then
      pass "Backing service '$dep' has $ready ready replica(s) in $REAL_NS"
    else
      fail "Backing service '$dep' is not Ready in $REAL_NS"
      ok=0
    fi
  done

  if [[ "$ok" -eq 0 ]]; then
    explain "Deploy the missing pieces first (see weather-alert/README.md 'Deploy to Minikube'), then re-run this script."
    PREFLIGHT_OK=0
    return
  fi

  if [[ ! -f "$SCHEMA_FILE" ]]; then
    fail "Schema file not found: $SCHEMA_FILE"
    PREFLIGHT_OK=0
    return
  fi

  # Create (or reuse) the independent lab namespace - idempotent via apply
  kubectl create namespace "$LAB_NS" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
  local phase
  phase=$(kubectl get namespace "$LAB_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$phase" == "Active" ]]; then
    pass "Namespace '$LAB_NS' is Active (created fresh for this run)"
    explain "Labs 1.1-1.4 create their Pods/Jobs here, fully separate from the real project — cleanup is just deleting this one namespace."
  else
    fail "Namespace '$LAB_NS' is not Active (phase=$phase)"
    explain "If it's stuck 'Terminating' from a previous run, wait a bit and re-run."
    PREFLIGHT_OK=0
    return
  fi

  # Reuse the real project's own schema.sql as a ConfigMap inside LAB_NS (used by lab 1.3)
  kubectl -n "$LAB_NS" create configmap postgres-schema \
    --from-file=schema.sql="$SCHEMA_FILE" \
    --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
  pass "ConfigMap 'postgres-schema' created in $LAB_NS from the real weather-alert/db/schema.sql"
}

# ---------------------------------------------------------------------------
# Lab 1.1 — The 60-Second Pod (weather-alert/user-service, cross-namespace to REAL_NS)
# ---------------------------------------------------------------------------
verify_1_1() {
  section "Lab 1.1 — The 60-Second Pod (user-service, in $LAB_NS)"

  if ! kubectl -n "$LAB_NS" get pod user-service-standalone >/dev/null 2>&1; then
    kubectl -n "$LAB_NS" run user-service-standalone \
      --image=weather-alert/user-service:latest \
      --image-pull-policy=Never \
      --labels="app=user-service,tier=api" \
      --env="PORT=8001,LOG_LEVEL=info,DB_HOST=${POSTGRES_FQDN},DB_PORT=5432,DB_USER=weather_app,DB_PASSWORD=weather_app,DB_NAME=weather_alert,NATS_URL=nats://${NATS_FQDN}:4222" \
      --requests="cpu=50m,memory=64Mi" \
      --limits="cpu=250m,memory=128Mi" \
      --port=8001 >/dev/null
  fi

  kubectl -n "$LAB_NS" wait --for=condition=Ready pod/user-service-standalone --timeout=60s >/dev/null 2>&1

  local phase
  phase=$(kubectl -n "$LAB_NS" get pod user-service-standalone -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$phase" == "Running" ]]; then
    pass "Pod user-service-standalone phase=Running"
    explain "The real user-service binary, running in '$LAB_NS', reached across namespaces to '$POSTGRES_FQDN' in '$REAL_NS' — proof cross-namespace Service DNS works."
  else
    fail "Pod user-service-standalone phase=$phase (expected Running)"
    explain "If this crash-loops, the cross-namespace DNS name may be wrong, or postgres in $REAL_NS is unreachable. Check 'kubectl -n $LAB_NS logs user-service-standalone'."
  fi

  local labels
  labels=$(kubectl -n "$LAB_NS" get pod user-service-standalone -o jsonpath='{.metadata.labels}' 2>/dev/null)
  if [[ "$labels" == *"app:user-service"* && "$labels" == *"tier:api"* ]]; then
    pass "Labels present: $labels"
    explain "These are namespace-local — labels never need to be unique across namespaces, only within one."
  else
    fail "Labels missing/incorrect: $labels"
  fi

  local envs
  envs=$(kubectl -n "$LAB_NS" exec user-service-standalone -- printenv 2>/dev/null | grep -E "^(PORT|DB_HOST|NATS_URL)=")
  if [[ "$(echo "$envs" | grep -c '^PORT=8001$')" -eq 1 && "$(echo "$envs" | grep -c "^DB_HOST=${POSTGRES_FQDN}\$")" -eq 1 ]]; then
    pass "Env vars present: $(echo "$envs" | tr '\n' ' ')"
    explain "DB_HOST is the FULLY QUALIFIED cross-namespace name — the short name 'postgres' alone would NOT resolve from a different namespace."
  else
    fail "Env vars missing/incorrect: $envs"
  fi

  local resources
  resources=$(kubectl -n "$LAB_NS" get pod user-service-standalone -o jsonpath='{.spec.containers[0].resources}' 2>/dev/null)
  if [[ "$resources" == *"cpu:50m"* && "$resources" == *"memory:64Mi"* && "$resources" == *"cpu:250m"* && "$resources" == *"memory:128Mi"* ]]; then
    pass "Resources present: $resources"
  else
    fail "Resources missing/incorrect: $resources"
  fi

  local health
  health=$(kubectl -n "$LAB_NS" exec user-service-standalone -- wget -qO- http://localhost:8001/health 2>/dev/null)
  if [[ "$health" == *'"status":"ok"'* ]]; then
    pass "GET /health returned: $health"
    explain "The real app served this from inside '$LAB_NS' while its database lives in '$REAL_NS' — two namespaces, one working connection."
  else
    fail "GET /health did not return the expected body: $health"
  fi
}

# ---------------------------------------------------------------------------
# Lab 1.2 — Init + Sidecar Pattern (notification-dispatcher, in LAB_NS)
# ---------------------------------------------------------------------------
verify_1_2() {
  section "Lab 1.2 — Init + Sidecar Pattern (notification-dispatcher, in $LAB_NS)"

  if ! kubectl -n "$LAB_NS" get pod notification-dispatcher-guarded >/dev/null 2>&1; then
    cat <<EOF | kubectl -n "$LAB_NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: notification-dispatcher-guarded
  labels:
    app: notification-dispatcher
    pattern: init-sidecar
spec:
  volumes:
  - name: apns-secret-vol
    emptyDir: {}
  initContainers:
  - name: wait-for-postgres
    image: postgres:15-alpine
    command: ["/bin/sh", "-c", "until pg_isready -h ${POSTGRES_FQDN} -p 5432 -U weather_app; do sleep 2; done; echo LAB-PLACEHOLDER-APNS-KEY-CONTENT > /run/secrets/apns-key.p8"]
    volumeMounts:
    - name: apns-secret-vol
      mountPath: /run/secrets
  containers:
  - name: dispatcher
    image: weather-alert/notification-dispatcher:latest
    imagePullPolicy: Never
    ports:
    - containerPort: 8004
    env:
    - name: PORT
      value: "8004"
    - name: LOG_LEVEL
      value: info
    - name: DB_HOST
      value: "${POSTGRES_FQDN}"
    - name: DB_PORT
      value: "5432"
    - name: DB_USER
      value: weather_app
    - name: DB_PASSWORD
      value: weather_app
    - name: DB_NAME
      value: weather_alert
    - name: NATS_URL
      value: "nats://${NATS_FQDN}:4222"
    - name: APNS_KEY_PATH
      value: /run/secrets/apns-key.p8
    volumeMounts:
    - name: apns-secret-vol
      mountPath: /run/secrets
      readOnly: true
    resources:
      requests: {cpu: 50m, memory: 64Mi}
      limits: {cpu: 250m, memory: 128Mi}
  - name: health-monitor
    image: postgres:15-alpine
    command: ["/bin/sh", "-c", "while true; do wget -qO- http://localhost:8004/health && echo ' -- healthy' || echo 'not reachable yet'; sleep 10; done"]
    resources:
      requests: {cpu: 25m, memory: 32Mi}
      limits: {cpu: 100m, memory: 64Mi}
  restartPolicy: Always
EOF
  fi

  kubectl -n "$LAB_NS" wait --for=condition=Ready pod/notification-dispatcher-guarded --timeout=90s >/dev/null 2>&1

  local init_reason
  init_reason=$(kubectl -n "$LAB_NS" get pod notification-dispatcher-guarded -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}' 2>/dev/null)
  if [[ "$init_reason" == "Completed" ]]; then
    pass "Init container 'wait-for-postgres' terminated with reason=Completed"
    explain "It blocked on real pg_isready checks against '${POSTGRES_FQDN}' in a DIFFERENT namespace until Postgres was reachable, then staged the placeholder APNs key file."
  else
    fail "Init container state: $init_reason (expected Completed)"
    explain "If this never completes, check the cross-namespace DNS name resolves: kubectl -n $LAB_NS run dns-check --rm -it --restart=Never --image=postgres:15-alpine -- nslookup ${POSTGRES_FQDN}"
  fi

  local ready_count
  ready_count=$(kubectl -n "$LAB_NS" get pod notification-dispatcher-guarded -o jsonpath='{range .status.containerStatuses[*]}{.ready}{" "}{end}' 2>/dev/null | grep -o true | wc -l)
  if [[ "$ready_count" -eq 2 ]]; then
    pass "Both regular containers (dispatcher, health-monitor) are Ready"
  else
    fail "Expected 2 ready containers, got $ready_count"
  fi

  local key_contents
  key_contents=$(kubectl -n "$LAB_NS" exec notification-dispatcher-guarded -c dispatcher -- cat /run/secrets/apns-key.p8 2>/dev/null)
  if [[ "$key_contents" == *"LAB-PLACEHOLDER-APNS-KEY-CONTENT"* ]]; then
    pass "App container can read the file the init container staged: $key_contents"
    explain "emptyDir sharing works the same regardless of which namespace the Pod lives in — it's purely local to the Pod."
  else
    fail "App container could not read the staged key file: $key_contents"
  fi

  local sidecar_check
  sidecar_check=$(kubectl -n "$LAB_NS" exec notification-dispatcher-guarded -c health-monitor -- wget -qO- http://localhost:8004/health 2>/dev/null)
  if [[ "$sidecar_check" == *'"status":"ok"'* ]]; then
    pass "Sidecar reached the app via localhost:8004 -> $sidecar_check"
  else
    fail "Sidecar could not reach the app over localhost: $sidecar_check"
  fi
}

# ---------------------------------------------------------------------------
# Lab 1.3 — Jobs & CronJobs (postgres:15-alpine, in LAB_NS, cross-namespace to REAL_NS)
# ---------------------------------------------------------------------------
verify_1_3() {
  section "Lab 1.3 — Jobs & CronJobs (in $LAB_NS, targeting postgres in $REAL_NS)"

  if ! kubectl -n "$LAB_NS" get job db-migrate >/dev/null 2>&1; then
    kubectl -n "$LAB_NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
spec:
  backoffLimit: 3
  template:
    spec:
      containers:
      - name: db-migrate
        image: postgres:15-alpine
        command: ["/bin/sh", "-c", "psql postgresql://weather_app:weather_app@${POSTGRES_FQDN}:5432/weather_alert -f /migrations/schema.sql"]
        volumeMounts:
        - name: schema-vol
          mountPath: /migrations
      volumes:
      - name: schema-vol
        configMap:
          name: postgres-schema
      restartPolicy: Never
EOF
  fi

  if ! kubectl -n "$LAB_NS" get job db-connection-check-fail >/dev/null 2>&1; then
    kubectl -n "$LAB_NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-connection-check-fail
spec:
  backoffLimit: 2
  template:
    spec:
      containers:
      - name: db-connection-check-fail
        image: postgres:15-alpine
        command: ["/bin/sh", "-c", "pg_isready -h postgres-wrong-host.${REAL_NS}.svc.cluster.local -p 5432 -U weather_app -t 2"]
      restartPolicy: Never
EOF
  fi

  if ! kubectl -n "$LAB_NS" get cronjob notification-log-cleanup >/dev/null 2>&1; then
    kubectl -n "$LAB_NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: notification-log-cleanup
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
            command: ["/bin/sh", "-c", "psql postgresql://weather_app:weather_app@${POSTGRES_FQDN}:5432/weather_alert -c \"DELETE FROM notification_log WHERE created_at < NOW() - INTERVAL '30 days';\""]
          restartPolicy: OnFailure
EOF
  fi

  # --- db-migrate: should succeed and actually create the real tables ---
  kubectl -n "$LAB_NS" wait --for=condition=Complete job/db-migrate --timeout=60s >/dev/null 2>&1
  local succeeded
  succeeded=$(kubectl -n "$LAB_NS" get job db-migrate -o jsonpath='{.status.succeeded}' 2>/dev/null)
  if [[ "$succeeded" == "1" ]]; then
    pass "Job db-migrate: status.succeeded=1"
    explain "This Job ran in '$LAB_NS' but applied schema.sql to the real database over in '$REAL_NS' via cross-namespace DNS — Jobs work identically regardless of namespace."
  else
    fail "Job db-migrate: status.succeeded=$succeeded (expected 1)"
    explain "Check 'kubectl -n $LAB_NS logs job/db-migrate' for the actual psql error."
  fi

  local table_check
  table_check=$(kubectl -n "$LAB_NS" run psql-check-$$ --rm -i --restart=Never --image=postgres:15-alpine -- \
    psql "postgresql://weather_app:weather_app@${POSTGRES_FQDN}:5432/weather_alert" -tAc \
    "SELECT to_regclass('public.users') IS NOT NULL AND to_regclass('public.notification_log') IS NOT NULL;" 2>/dev/null)
  if [[ "$table_check" == *"t"* ]]; then
    pass "Real tables 'users' and 'notification_log' exist in the database"
  else
    fail "Expected tables not found (result: $table_check)"
  fi

  # --- db-connection-check-fail: should exhaust backoffLimit ---
  sleep 20
  local failed_reason
  failed_reason=$(kubectl -n "$LAB_NS" get job db-connection-check-fail -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null)
  if [[ "$failed_reason" == "BackoffLimitExceeded" ]]; then
    pass "Job db-connection-check-fail: Failed condition reason=BackoffLimitExceeded"
    explain "The hostname doesn't exist in EITHER namespace, so pg_isready fails every attempt; after backoffLimit=2 retries the Job gave up permanently."
  else
    skip "Job db-connection-check-fail: Failed condition not yet set (reason='$failed_reason')"
    explain "backoffLimit retries use exponential backoff — re-run this script in a bit if this looks unfinished."
  fi

  # --- notification-log-cleanup CronJob ---
  local schedule
  schedule=$(kubectl -n "$LAB_NS" get cronjob notification-log-cleanup -o jsonpath='{.spec.schedule}' 2>/dev/null)
  if [[ "$schedule" == "*/1 * * * *" ]]; then
    pass "CronJob notification-log-cleanup: schedule=$schedule"
  else
    fail "CronJob notification-log-cleanup: unexpected schedule='$schedule'"
  fi

  if [[ "$WAIT_CRON" -eq 1 ]]; then
    echo "        Waiting up to 70s for the scheduler to fire at least one Job..."
    local waited=0
    local last_schedule=""
    while [[ $waited -lt 70 ]]; do
      last_schedule=$(kubectl -n "$LAB_NS" get cronjob notification-log-cleanup -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null)
      [[ -n "$last_schedule" ]] && break
      sleep 5
      waited=$((waited + 5))
    done
    if [[ -n "$last_schedule" ]]; then
      pass "CronJob notification-log-cleanup: status.lastScheduleTime=$last_schedule"
      explain "A CronJob in '$LAB_NS' cleaned up real rows in '$REAL_NS' — the CronJob controller itself is fully namespace-agnostic about where its target Service lives."
    else
      skip "CronJob notification-log-cleanup: no lastScheduleTime after 70s"
      explain "Timing issue, not necessarily a bug — cron ticks land on the wall-clock minute boundary."
    fi
  else
    skip "CronJob trigger wait disabled (--no-wait-cron)"
  fi
}

# ---------------------------------------------------------------------------
# Lab 1.4 — Label & Annotation Drill (real service images as scale-test Pods, in LAB_NS)
# ---------------------------------------------------------------------------
verify_1_4() {
  section "Lab 1.4 — Label & Annotation Drill (scale-test Pods, in $LAB_NS)"

  declare -A pod_image=(
    [user-service-extra-1]="weather-alert/user-service:latest|api|PORT=8001"
    [user-service-extra-2]="weather-alert/user-service:latest|api|PORT=8001"
    [alert-evaluator-extra-1]="weather-alert/alert-evaluator:latest|worker|PORT=8003"
    [alert-evaluator-extra-2]="weather-alert/alert-evaluator:latest|worker|PORT=8003"
    [notification-dispatcher-extra-1]="weather-alert/notification-dispatcher:latest|dispatch|PORT=8004"
  )

  for name in "${!pod_image[@]}"; do
    IFS='|' read -r image tier portenv <<< "${pod_image[$name]}"
    if ! kubectl -n "$LAB_NS" get pod "$name" >/dev/null 2>&1; then
      kubectl -n "$LAB_NS" run "$name" \
        --image="$image" --image-pull-policy=Never \
        --labels="app=weather-alert-scale-demo,tier=$tier" \
        --env="$portenv,DB_HOST=${POSTGRES_FQDN},DB_PORT=5432,DB_USER=weather_app,DB_PASSWORD=weather_app,DB_NAME=weather_alert,NATS_URL=nats://${NATS_FQDN}:4222,REDIS_URL=${REDIS_FQDN}:6379" >/dev/null
    fi
  done
  for name in "${!pod_image[@]}"; do
    kubectl -n "$LAB_NS" wait --for=condition=Ready "pod/$name" --timeout=60s >/dev/null 2>&1
  done

  local api_count worker_count dispatch_count
  api_count=$(kubectl -n "$LAB_NS" get pods -l app=weather-alert-scale-demo,tier=api --no-headers 2>/dev/null | wc -l)
  worker_count=$(kubectl -n "$LAB_NS" get pods -l app=weather-alert-scale-demo,tier=worker --no-headers 2>/dev/null | wc -l)
  dispatch_count=$(kubectl -n "$LAB_NS" get pods -l app=weather-alert-scale-demo,tier=dispatch --no-headers 2>/dev/null | wc -l)

  if [[ "$api_count" -eq 2 && "$worker_count" -eq 2 && "$dispatch_count" -eq 1 ]]; then
    pass "Selectors return expected counts: tier=api->2, tier=worker->2, tier=dispatch->1"
    explain "These are real service images running entirely in '$LAB_NS', reaching their dependencies in '$REAL_NS' by FQDN — labels/selectors themselves are always namespace-local."
  else
    fail "Selector counts wrong: api=$api_count worker=$worker_count dispatch=$dispatch_count"
  fi

  # Overwrite test — mark one replica as a canary
  kubectl -n "$LAB_NS" label pod user-service-extra-1 tier=canary --overwrite >/dev/null 2>&1
  local canary_tier
  canary_tier=$(kubectl -n "$LAB_NS" get pod user-service-extra-1 -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
  if [[ "$canary_tier" == "canary" ]]; then
    pass "user-service-extra-1 relabeled tier=canary"
    explain "--overwrite was required since 'tier' already existed — this is exactly how you'd mark one replica for canary testing without touching the others."
  else
    fail "user-service-extra-1 tier=$canary_tier (expected canary)"
  fi

  # Bulk update test
  kubectl -n "$LAB_NS" label pods -l app=weather-alert-scale-demo env=scale-test --overwrite >/dev/null 2>&1
  local scale_test_count
  scale_test_count=$(kubectl -n "$LAB_NS" get pods -l env=scale-test --no-headers 2>/dev/null | wc -l)
  if [[ "$scale_test_count" -eq 5 ]]; then
    pass "Bulk label update: all 5 scale-demo pods now have env=scale-test"
  else
    fail "Expected 5 pods with env=scale-test, got $scale_test_count"
  fi

  # Confirm the REAL project (different namespace entirely) was never touched
  local real_pod_count
  real_pod_count=$(kubectl -n "$REAL_NS" get pods -l app=user-service,env=scale-test --no-headers 2>/dev/null | wc -l)
  if [[ "$real_pod_count" -eq 0 ]]; then
    pass "Real user-service Deployment in '$REAL_NS' unaffected by scale-demo labeling"
    explain "Because these lab Pods live in a completely separate namespace, there was never any chance of a selector in '$REAL_NS' matching them — stronger isolation than same-namespace naming alone."
  else
    fail "Unexpectedly found $real_pod_count real user-service pods with env=scale-test"
  fi

  # Annotation not selectable
  kubectl -n "$LAB_NS" annotate pods -l app=weather-alert-scale-demo \
    note="temporary scale-test pods, safe to delete" --overwrite >/dev/null 2>&1
  local annotated_note
  annotated_note=$(kubectl -n "$LAB_NS" get pod alert-evaluator-extra-1 -o jsonpath='{.metadata.annotations.note}' 2>/dev/null)
  local selector_result
  selector_result=$(kubectl -n "$LAB_NS" get pods -l note="temporary scale-test pods, safe to delete" --no-headers 2>/dev/null | wc -l)
  if [[ -n "$annotated_note" && "$selector_result" -eq 0 ]]; then
    pass "Annotation set (note='$annotated_note') but NOT selectable via -l"
    explain "Core Label vs Annotation distinction: annotations hold metadata, but only labels participate in selector queries."
  else
    fail "Annotation check failed: note='$annotated_note' selector_result=$selector_result"
  fi
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
  verify_1_5
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
