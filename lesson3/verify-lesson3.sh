#!/usr/bin/env bash
# verify-lesson3.sh — checks labs 3.1-3.4's requirements against the REAL
# weather-alert deployment/namespace. No lab namespace is created.
#
# Every lab creates its own standalone objects and deletes them at the end:
#   - Lab 3.1: a standalone Secret/ConfigMap/Pod (config-secret-demo) - the
#     real app-config/app-secrets objects are never touched.
#   - Lab 3.2: two standalone Pods proving a real security-context gotcha
#     (user-service's image has no non-root user) and its real fix (an init
#     container staging the binary into a shared, world-executable emptyDir).
#   - Lab 3.3: a standalone ServiceAccount/Role/RoleBinding/Pod
#     (pod-lister-sa / rbac-demo-pod) that calls the REAL Kubernetes API
#     server with its own token to list the REAL Pods in the namespace.
#   - Lab 3.4: a real ResourceQuota/LimitRange applied directly to the
#     weather-alert namespace (generous limits - see lab_3.4.yaml's SAFETY
#     NOTE for why this never risks the already-running project), plus two
#     throwaway test Pods proving admission-time rejection/defaulting.
#
# Run from WSL (or any shell with kubectl pointed at your minikube cluster):
#   bash lesson3/verify-lesson3.sh
#
# Flags:
#   --skip-config-sync-wait   Skip lab 3.1's ~65s wait for a mounted
#                             ConfigMap volume to pick up a live edit
#
# Prints PASS/FAIL lines plus an indented "Means:" explanation of what that
# result tells you. A final summary counts PASS / FAIL / SKIP.
#
# PREREQUISITE: the weather-alert namespace and the full stack (postgres,
# redis, nats, user-service, weather-fetcher, alert-evaluator,
# notification-dispatcher) must already be deployed and Running.
# See weather-alert/README.md "Deploy to Minikube".

set -uo pipefail

REAL_NS="weather-alert"
SKIP_CONFIG_SYNC_WAIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-config-sync-wait) SKIP_CONFIG_SYNC_WAIT=1; shift ;;
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
}

# ---------------------------------------------------------------------------
# Lab 3.1 — ConfigMap & Secret Injection, using a standalone Secret/
# ConfigMap/Pod in REAL_NS. Deletes everything it creates at the end.
# ---------------------------------------------------------------------------
verify_3_1() {
  section "Lab 3.1 — ConfigMap & Secret Injection (standalone Pod, in $REAL_NS)"

  # Clean slate in case a previous run didn't finish cleanup
  kubectl -n "$REAL_NS" delete pod config-secret-demo --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete configmap demo-app-config --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete secret demo-apns-secret --ignore-not-found >/dev/null 2>&1

  # STEP 1: Secret from a file
  local tmpfile
  tmpfile=$(mktemp)
  echo "LAB-3.1-DEMO-APNS-KEY-CONTENT" > "$tmpfile"
  kubectl -n "$REAL_NS" create secret generic demo-apns-secret --from-file="apns-key.p8=$tmpfile" >/dev/null 2>&1
  rm -f "$tmpfile"
  local secret_value
  secret_value=$(kubectl -n "$REAL_NS" get secret demo-apns-secret -o jsonpath='{.data.apns-key\.p8}' 2>/dev/null | base64 -d 2>/dev/null)
  if [[ "$secret_value" == "LAB-3.1-DEMO-APNS-KEY-CONTENT" ]]; then
    pass "Secret demo-apns-secret must be created --from-file" "decoded value matches"
    explain "The Secret stores the FILE'S CONTENTS as the value of key 'apns-key.p8' — base64-encoded, not encrypted."
  else
    fail "Secret demo-apns-secret must be created --from-file" "decoded='$secret_value'"
  fi

  # STEP 2: ConfigMap from literals
  kubectl -n "$REAL_NS" create configmap demo-app-config \
    --from-literal=LOG_LEVEL=debug --from-literal=FEATURE_FLAG=new-ui-enabled >/dev/null 2>&1
  local cm_log_level cm_feature_flag
  cm_log_level=$(kubectl -n "$REAL_NS" get configmap demo-app-config -o jsonpath='{.data.LOG_LEVEL}' 2>/dev/null)
  cm_feature_flag=$(kubectl -n "$REAL_NS" get configmap demo-app-config -o jsonpath='{.data.FEATURE_FLAG}' 2>/dev/null)
  if [[ "$cm_log_level" == "debug" && "$cm_feature_flag" == "new-ui-enabled" ]]; then
    pass "ConfigMap demo-app-config must be created --from-literal" "LOG_LEVEL=$cm_log_level, FEATURE_FLAG=$cm_feature_flag"
  else
    fail "ConfigMap demo-app-config must be created --from-literal" "LOG_LEVEL=$cm_log_level, FEATURE_FLAG=$cm_feature_flag"
  fi

  # STEP 3: one Pod, Secret as env var + ConfigMap as mounted volume
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: config-secret-demo
  namespace: $REAL_NS
  labels: {app: config-secret-demo}
spec:
  containers:
  - name: user-service
    image: weather-alert/user-service:latest
    imagePullPolicy: Never
    env:
    - {name: PORT, value: "8001"}
    - name: DB_USER
      valueFrom: {secretKeyRef: {name: app-secrets, key: DB_USER}}
    - name: DB_PASSWORD
      valueFrom: {secretKeyRef: {name: app-secrets, key: DB_PASSWORD}}
    - name: APNS_KEY_CONTENT
      valueFrom:
        secretKeyRef: {name: demo-apns-secret, key: apns-key.p8}
    envFrom:
    - configMapRef: {name: app-config}
    volumeMounts:
    - {name: config-vol, mountPath: /etc/demo-config, readOnly: true}
    resources:
      requests: {cpu: 50m, memory: 64Mi}
      limits: {cpu: 250m, memory: 128Mi}
  volumes:
  - name: config-vol
    configMap: {name: demo-app-config}
EOF
  kubectl -n "$REAL_NS" wait --for=condition=Ready pod/config-secret-demo --timeout=60s >/dev/null 2>&1

  local env_value
  env_value=$(kubectl -n "$REAL_NS" exec config-secret-demo -- printenv APNS_KEY_CONTENT 2>/dev/null)
  if [[ "$env_value" == "LAB-3.1-DEMO-APNS-KEY-CONTENT" ]]; then
    pass "Secret must be injected as an env var" "APNS_KEY_CONTENT=$env_value"
  else
    fail "Secret must be injected as an env var" "APNS_KEY_CONTENT=$env_value"
  fi

  local file_log_level file_feature_flag
  file_log_level=$(kubectl -n "$REAL_NS" exec config-secret-demo -- cat /etc/demo-config/LOG_LEVEL 2>/dev/null)
  file_feature_flag=$(kubectl -n "$REAL_NS" exec config-secret-demo -- cat /etc/demo-config/FEATURE_FLAG 2>/dev/null)
  if [[ "$file_log_level" == "debug" && "$file_feature_flag" == "new-ui-enabled" ]]; then
    pass "ConfigMap must be mounted as one file per key" "LOG_LEVEL=$file_log_level, FEATURE_FLAG=$file_feature_flag"
    explain "envFrom/env give you variables; a volume mount gives you FILES — same data, different consumption shape."
  else
    fail "ConfigMap must be mounted as one file per key" "LOG_LEVEL=$file_log_level, FEATURE_FLAG=$file_feature_flag"
  fi

  # STEP: prove volume-mounted config auto-updates without a Pod restart
  if [[ "$SKIP_CONFIG_SYNC_WAIT" -eq 1 ]]; then
    skip "Mounted ConfigMap file must update live, no Pod restart" "wait disabled (--skip-config-sync-wait)"
  else
    local restarts_before
    restarts_before=$(kubectl -n "$REAL_NS" get pod config-secret-demo -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
    kubectl -n "$REAL_NS" patch configmap demo-app-config --type merge -p '{"data":{"LOG_LEVEL":"trace"}}' >/dev/null 2>&1
    echo "        Waiting up to 150s for kubelet to sync the mounted ConfigMap volume (cache TTL + sync period can add up to ~2 min)..."
    local waited=0
    local file_log_level_after=""
    while [[ $waited -lt 150 ]]; do
      file_log_level_after=$(kubectl -n "$REAL_NS" exec config-secret-demo -- cat /etc/demo-config/LOG_LEVEL 2>/dev/null)
      [[ "$file_log_level_after" == "trace" ]] && break
      sleep 10
      waited=$((waited + 10))
    done
    local restarts_after
    restarts_after=$(kubectl -n "$REAL_NS" get pod config-secret-demo -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
    if [[ "$file_log_level_after" == "trace" && "$restarts_after" == "$restarts_before" ]]; then
      pass "Mounted ConfigMap file must update live, no Pod restart" "LOG_LEVEL=$file_log_level_after, restarts unchanged ($restarts_after)"
      explain "The kubelet re-syncs projected ConfigMap/Secret volumes periodically — env vars could never do this without a rollout."
    else
      fail "Mounted ConfigMap file must update live, no Pod restart" "LOG_LEVEL=$file_log_level_after (restarts $restarts_before->$restarts_after)"
    fi
  fi

  kubectl -n "$REAL_NS" delete pod config-secret-demo --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete configmap demo-app-config --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete secret demo-apns-secret --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up config-secret-demo, demo-app-config, and demo-apns-secret from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Lab 3.2 — Security Context Lockdown, using two standalone Pods in REAL_NS.
# Deletes both at the end.
# ---------------------------------------------------------------------------
verify_3_2() {
  section "Lab 3.2 — Security Context Lockdown (standalone Pods, in $REAL_NS)"

  kubectl -n "$REAL_NS" delete pod user-service-naive-lockdown user-service-locked-down --ignore-not-found >/dev/null 2>&1

  # STEP 1: naive attempt must fail for real
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: user-service-naive-lockdown
  namespace: $REAL_NS
  labels: {app: user-service-naive-lockdown}
spec:
  containers:
  - name: user-service
    image: weather-alert/user-service:latest
    imagePullPolicy: Never
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
    env:
    - {name: PORT, value: "8001"}
    - name: DB_USER
      valueFrom: {secretKeyRef: {name: app-secrets, key: DB_USER}}
    - name: DB_PASSWORD
      valueFrom: {secretKeyRef: {name: app-secrets, key: DB_PASSWORD}}
    envFrom:
    - configMapRef: {name: app-config}
    resources:
      requests: {cpu: 50m, memory: 64Mi}
      limits: {cpu: 250m, memory: 128Mi}
EOF

  echo "        Waiting up to 30s to confirm the naive lockdown fails for real..."
  local waited=0
  local naive_ready="false"
  while [[ $waited -lt 30 ]]; do
    naive_ready=$(kubectl -n "$REAL_NS" get pod user-service-naive-lockdown -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    [[ "$naive_ready" == "true" ]] && break
    sleep 5
    waited=$((waited + 5))
  done
  local naive_restarts
  naive_restarts=$(kubectl -n "$REAL_NS" get pod user-service-naive-lockdown -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  if [[ "$naive_ready" != "true" && "${naive_restarts:-0}" -ge 1 ]] 2>/dev/null; then
    pass "Naive lockdown on the real image must fail (never Ready)" "ready=$naive_ready, restarts=$naive_restarts"
    explain "user-service's Dockerfile has no non-root user and WORKDIR /root/ — the binary itself isn't reachable by UID 1000. Not a Kubernetes bug, an image limitation."
  else
    fail "Naive lockdown on the real image must fail (never Ready)" "ready=$naive_ready, restarts=${naive_restarts:-0}"
  fi

  # STEP 3: the real fix - init container stages the binary into a shared,
  # world-executable emptyDir
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: user-service-locked-down
  namespace: $REAL_NS
  labels: {app: user-service-locked-down}
spec:
  volumes:
  - {name: app-bin, emptyDir: {}}
  initContainers:
  - name: stage-binary
    image: weather-alert/user-service:latest
    imagePullPolicy: Never
    command: ["/bin/sh", "-c", "cp /root/app /staged/app && chmod 755 /staged/app"]
    volumeMounts:
    - {name: app-bin, mountPath: /staged}
  containers:
  - name: user-service
    image: weather-alert/user-service:latest
    imagePullPolicy: Never
    command: ["/app/app"]
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
    ports: [{containerPort: 8001}]
    env:
    - {name: PORT, value: "8001"}
    - name: DB_USER
      valueFrom: {secretKeyRef: {name: app-secrets, key: DB_USER}}
    - name: DB_PASSWORD
      valueFrom: {secretKeyRef: {name: app-secrets, key: DB_PASSWORD}}
    envFrom:
    - configMapRef: {name: app-config}
    volumeMounts:
    - {name: app-bin, mountPath: /app, readOnly: true}
    readinessProbe:
      httpGet: {path: /health, port: 8001}
      initialDelaySeconds: 5
      periodSeconds: 10
    resources:
      requests: {cpu: 50m, memory: 64Mi}
      limits: {cpu: 250m, memory: 128Mi}
EOF
  kubectl -n "$REAL_NS" wait --for=condition=Ready pod/user-service-locked-down --timeout=60s >/dev/null 2>&1

  local phase
  phase=$(kubectl -n "$REAL_NS" get pod user-service-locked-down -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$phase" == "Running" ]]; then
    pass "Init-container fix must make the locked-down Pod Running" "phase=$phase"
    explain "The main container now execs a copy of the binary from a world-executable emptyDir instead of the root-owned /root/ directory."
  else
    fail "Init-container fix must make the locked-down Pod Running" "phase=$phase"
  fi

  local uid_output
  uid_output=$(kubectl -n "$REAL_NS" exec user-service-locked-down -- id 2>/dev/null)
  if [[ "$uid_output" == *"uid=1000"* && "$uid_output" != *"uid=0"* ]]; then
    pass "Process must run as non-root (uid=1000)" "$uid_output"
  else
    fail "Process must run as non-root (uid=1000)" "$uid_output"
  fi

  local write_attempt
  write_attempt=$(kubectl -n "$REAL_NS" exec user-service-locked-down -- sh -c "touch /test-write 2>&1" 2>/dev/null)
  if [[ "$write_attempt" == *"Read-only"* || "$write_attempt" == *"read-only"* ]]; then
    pass "Root filesystem must genuinely be read-only" "$write_attempt"
  else
    fail "Root filesystem must genuinely be read-only" "$write_attempt"
  fi

  local health
  health=$(kubectl -n "$REAL_NS" exec user-service-locked-down -- wget -qO- http://localhost:8001/health 2>/dev/null)
  if [[ "$health" == *'"status":"ok"'* ]]; then
    pass "App must still serve traffic despite full lockdown" "$health"
  else
    fail "App must still serve traffic despite full lockdown" "$health"
  fi

  local dropped_caps
  dropped_caps=$(kubectl -n "$REAL_NS" get pod user-service-locked-down -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop}' 2>/dev/null)
  if [[ "$dropped_caps" == *"ALL"* ]]; then
    pass "Capabilities must be fully dropped" "drop=$dropped_caps"
  else
    fail "Capabilities must be fully dropped" "drop=$dropped_caps"
  fi

  kubectl -n "$REAL_NS" delete pod user-service-naive-lockdown user-service-locked-down --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up user-service-naive-lockdown and user-service-locked-down from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Lab 3.3 — ServiceAccount & RBAC, using a standalone ServiceAccount/Role/
# RoleBinding/Pod in REAL_NS. Deletes everything it creates at the end.
# ---------------------------------------------------------------------------
verify_3_3() {
  section "Lab 3.3 — ServiceAccount & RBAC (standalone SA/Role/Pod, in $REAL_NS)"

  kubectl -n "$REAL_NS" delete pod rbac-demo-pod --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete rolebinding pod-lister-binding --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete role pod-lister-role --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete serviceaccount pod-lister-sa --ignore-not-found >/dev/null 2>&1

  kubectl -n "$REAL_NS" create serviceaccount pod-lister-sa >/dev/null 2>&1
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-lister-role
  namespace: $REAL_NS
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-lister-binding
  namespace: $REAL_NS
subjects:
- kind: ServiceAccount
  name: pod-lister-sa
  namespace: $REAL_NS
roleRef:
  kind: Role
  name: pod-lister-role
  apiGroup: rbac.authorization.k8s.io
EOF

  local can_list_granted can_list_default can_delete_granted
  can_list_granted=$(kubectl auth can-i list pods --as="system:serviceaccount:${REAL_NS}:pod-lister-sa" -n "$REAL_NS" 2>/dev/null)
  can_list_default=$(kubectl auth can-i list pods --as="system:serviceaccount:${REAL_NS}:default" -n "$REAL_NS" 2>/dev/null)
  can_delete_granted=$(kubectl auth can-i delete pods --as="system:serviceaccount:${REAL_NS}:pod-lister-sa" -n "$REAL_NS" 2>/dev/null)

  if [[ "$can_list_granted" == "yes" ]]; then
    pass "pod-lister-sa must be allowed to list pods" "can-i=$can_list_granted"
  else
    fail "pod-lister-sa must be allowed to list pods" "can-i=$can_list_granted"
  fi

  if [[ "$can_list_default" == "no" ]]; then
    pass "default ServiceAccount must NOT be allowed to list pods" "can-i=$can_list_default"
    explain "No Role is bound to 'default' — least-privilege by default is the whole point of RBAC."
  else
    fail "default ServiceAccount must NOT be allowed to list pods" "can-i=$can_list_default"
  fi

  if [[ "$can_delete_granted" == "no" ]]; then
    pass "pod-lister-sa must NOT be allowed to delete pods" "can-i=$can_delete_granted"
    explain "The Role only grants verbs: [get, list] — RBAC is deny-by-default per verb, not just per resource."
  else
    fail "pod-lister-sa must NOT be allowed to delete pods" "can-i=$can_delete_granted"
  fi

  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: rbac-demo-pod
  namespace: $REAL_NS
  labels: {app: rbac-demo-pod}
spec:
  serviceAccountName: pod-lister-sa
  containers:
  - name: api-client
    image: postgres:15-alpine
    imagePullPolicy: IfNotPresent
    command: ["sleep", "3600"]
    resources:
      requests: {cpu: 25m, memory: 32Mi}
      limits: {cpu: 100m, memory: 64Mi}
EOF
  kubectl -n "$REAL_NS" wait --for=condition=Ready pod/rbac-demo-pod --timeout=60s >/dev/null 2>&1

  local api_response
  api_response=$(kubectl -n "$REAL_NS" exec rbac-demo-pod -- /bin/sh -c \
    'TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); wget --no-check-certificate --header="Authorization: Bearer $TOKEN" -qO- https://kubernetes.default.svc/api/v1/namespaces/'"$REAL_NS"'/pods' 2>/dev/null)
  if [[ "$api_response" == *"PodList"* && "$api_response" == *"user-service"* ]]; then
    pass "Pod must list REAL Pods via its own SA token against the live API" "response contains PodList + real Pod names"
    explain "The token at /var/run/secrets/kubernetes.io/serviceaccount/token authenticated AS pod-lister-sa; RBAC then authorized the call."
  else
    fail "Pod must list REAL Pods via its own SA token against the live API" "response did not contain expected PodList content"
  fi

  local secrets_response
  secrets_response=$(kubectl -n "$REAL_NS" exec rbac-demo-pod -- /bin/sh -c \
    'TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); wget --no-check-certificate --header="Authorization: Bearer $TOKEN" -qO- https://kubernetes.default.svc/api/v1/namespaces/'"$REAL_NS"'/secrets 2>&1' 2>/dev/null)
  if [[ "$secrets_response" == *"Forbidden"* || "$secrets_response" == *"403"* ]]; then
    pass "Same token must be denied access to secrets (never granted)" "response contains Forbidden/403"
  else
    fail "Same token must be denied access to secrets (never granted)" "response='$secrets_response'"
  fi

  kubectl -n "$REAL_NS" delete pod rbac-demo-pod --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete rolebinding pod-lister-binding --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete role pod-lister-role --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete serviceaccount pod-lister-sa --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up rbac-demo-pod, pod-lister-binding, pod-lister-role, and pod-lister-sa from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Lab 3.4 — Namespace Quotas, applies a real ResourceQuota/LimitRange
# directly to REAL_NS (generous limits, see lab_3.4.yaml's SAFETY NOTE),
# plus two throwaway test Pods. Deletes everything at the end.
# ---------------------------------------------------------------------------
verify_3_4() {
  section "Lab 3.4 — Namespace Quotas (real ResourceQuota/LimitRange, in $REAL_NS)"

  kubectl -n "$REAL_NS" delete pod quota-test-ok quota-test-toobig --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete resourcequota weather-alert-quota --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete limitrange weather-alert-limits --ignore-not-found >/dev/null 2>&1

  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: weather-alert-quota
  namespace: $REAL_NS
spec:
  hard:
    pods: "50"
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
EOF

  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: weather-alert-limits
  namespace: $REAL_NS
spec:
  limits:
  - type: Container
    default: {cpu: 200m, memory: 128Mi}
    defaultRequest: {cpu: 50m, memory: 64Mi}
    min: {cpu: 10m, memory: 16Mi}
    max: {cpu: "1", memory: 1Gi}
EOF

  local quota_hard_pods
  quota_hard_pods=$(kubectl -n "$REAL_NS" get resourcequota weather-alert-quota -o jsonpath='{.spec.hard.pods}' 2>/dev/null)
  local limitrange_max_cpu
  limitrange_max_cpu=$(kubectl -n "$REAL_NS" get limitrange weather-alert-limits -o jsonpath='{.spec.limits[0].max.cpu}' 2>/dev/null)
  if [[ "$quota_hard_pods" == "50" && "$limitrange_max_cpu" == "1" ]]; then
    pass "ResourceQuota and LimitRange must both be applied" "quota.hard.pods=$quota_hard_pods, limitrange.max.cpu=$limitrange_max_cpu"
  else
    fail "ResourceQuota and LimitRange must both be applied" "quota.hard.pods=$quota_hard_pods, limitrange.max.cpu=$limitrange_max_cpu"
  fi

  # Oversized Pod must be rejected at admission time
  local apply_stderr
  apply_stderr=$(kubectl -n "$REAL_NS" apply -f - 2>&1 >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: quota-test-toobig
  namespace: $REAL_NS
spec:
  containers:
  - name: oversized
    image: postgres:15-alpine
    command: ["sleep", "3600"]
    resources:
      requests: {cpu: "10", memory: 8Gi}
      limits: {cpu: "10", memory: 8Gi}
EOF
)
  local toobig_exists
  toobig_exists=$(kubectl -n "$REAL_NS" get pod quota-test-toobig --no-headers 2>/dev/null | wc -l)
  if [[ "$toobig_exists" -eq 0 && ( "$apply_stderr" == *"exceeded"* || "$apply_stderr" == *"maximum"* || "$apply_stderr" == *"forbidden"* || "$apply_stderr" == *"Forbidden"* ) ]]; then
    pass "Oversized Pod must be rejected at admission time" "not created; API server refused it"
    explain "Neither ResourceQuota nor LimitRange evict running Pods — they only gate NEW object admission, which is exactly what just happened."
  else
    fail "Oversized Pod must be rejected at admission time" "pod_exists=$toobig_exists, stderr='$apply_stderr'"
  fi

  # Normal Pod must succeed and pick up LimitRange defaults
  kubectl -n "$REAL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: quota-test-ok
  namespace: $REAL_NS
spec:
  containers:
  - name: fits
    image: postgres:15-alpine
    command: ["sleep", "3600"]
EOF
  kubectl -n "$REAL_NS" wait --for=condition=Ready pod/quota-test-ok --timeout=30s >/dev/null 2>&1

  local defaulted_req_cpu defaulted_req_mem defaulted_lim_cpu defaulted_lim_mem
  defaulted_req_cpu=$(kubectl -n "$REAL_NS" get pod quota-test-ok -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
  defaulted_req_mem=$(kubectl -n "$REAL_NS" get pod quota-test-ok -o jsonpath='{.spec.containers[0].resources.requests.memory}' 2>/dev/null)
  defaulted_lim_cpu=$(kubectl -n "$REAL_NS" get pod quota-test-ok -o jsonpath='{.spec.containers[0].resources.limits.cpu}' 2>/dev/null)
  defaulted_lim_mem=$(kubectl -n "$REAL_NS" get pod quota-test-ok -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)
  if [[ "$defaulted_req_cpu" == "50m" && "$defaulted_req_mem" == "64Mi" && "$defaulted_lim_cpu" == "200m" && "$defaulted_lim_mem" == "128Mi" ]]; then
    pass "Pod with no resources block must get LimitRange defaults injected" "requests=$defaulted_req_cpu/$defaulted_req_mem, limits=$defaulted_lim_cpu/$defaulted_lim_mem"
  else
    fail "Pod with no resources block must get LimitRange defaults injected" "requests=$defaulted_req_cpu/$defaulted_req_mem, limits=$defaulted_lim_cpu/$defaulted_lim_mem"
  fi

  # Confirm the real Deployments are all still fine — nothing was disrupted
  local all_deployments_ready=1
  for dep in postgres redis nats user-service weather-fetcher alert-evaluator notification-dispatcher; do
    local ready
    ready=$(kubectl -n "$REAL_NS" get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${ready:-0}" -ge 1 ]] 2>/dev/null || all_deployments_ready=0
  done
  if [[ "$all_deployments_ready" -eq 1 ]]; then
    pass "All real Deployments must remain Ready throughout this lab" "unaffected"
  else
    fail "All real Deployments must remain Ready throughout this lab" "at least one Deployment lost its Ready replica(s)"
  fi

  kubectl -n "$REAL_NS" delete pod quota-test-ok quota-test-toobig --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete resourcequota weather-alert-quota --ignore-not-found >/dev/null 2>&1
  kubectl -n "$REAL_NS" delete limitrange weather-alert-limits --ignore-not-found >/dev/null 2>&1
  echo "        (Cleaned up quota-test-ok, the ResourceQuota, and the LimitRange from $REAL_NS.)"
}

# ---------------------------------------------------------------------------
# Run everything
# ---------------------------------------------------------------------------
preflight
if [[ "$PREFLIGHT_OK" -eq 1 ]]; then
  verify_3_1
  verify_3_2
  verify_3_3
  verify_3_4
else
  echo ""
  echo "${C_RED}Preflight failed — skipping labs 3.1-3.4. Fix the issues above and re-run.${C_RESET}"
fi

echo ""
echo "${C_BOLD}=== Summary ===${C_RESET}"
echo "${C_GREEN}PASS: $PASS_COUNT${C_RESET}  ${C_RED}FAIL: $FAIL_COUNT${C_RESET}  ${C_YELLOW}SKIP: $SKIP_COUNT${C_RESET}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
