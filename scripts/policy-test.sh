#!/usr/bin/env bash
# =============================================================================
# Network-level zero-trust tests, from INSIDE the cluster:
#   - an "attacker" pod in another namespace cannot reach the API or the DB
#   - the API pod cannot reach the internet, the Kubernetes API, or resolve
#     external DNS names (egress lockdown)
#
# Usage: scripts/policy-test.sh [namespace]   (default: taskapi-dev)
# =============================================================================
set -euo pipefail

NS="${1:-taskapi-dev}"
ATTACKER_NS="policy-test"
CURL_IMAGE="curlimages/curl:8.17.0"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

cleanup() { kubectl delete namespace "$ATTACKER_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl create namespace "$ATTACKER_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$ATTACKER_NS" run attacker --image="$CURL_IMAGE" --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"attacker","image":"'"$CURL_IMAGE"'","command":["sleep","600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  >/dev/null 2>&1 || true
kubectl -n "$ATTACKER_NS" wait --for=condition=Ready pod/attacker --timeout=120s >/dev/null

# blocked_from_attacker DESCRIPTION URL  -> PASS if the connection times out
blocked_from_attacker() {
  if kubectl -n "$ATTACKER_NS" exec attacker -- curl -sS -m 4 -o /dev/null "$2" >/dev/null 2>&1; then
    fail "$1: connection SUCCEEDED (should be blocked)"
  else
    pass "$1: blocked"
  fi
}

echo "== Lateral movement from another namespace (${ATTACKER_NS} -> ${NS})"
blocked_from_attacker "attacker -> API service :80"        "http://taskapi.${NS}.svc.cluster.local/api/info"
blocked_from_attacker "attacker -> API metrics :9090"      "http://taskapi.${NS}.svc.cluster.local:9090/metrics"
blocked_from_attacker "attacker -> PostgreSQL :5432"       "telnet://taskapi-postgresql.${NS}.svc.cluster.local:5432"

echo; echo "== Egress lockdown of the API pod (${NS})"
API_POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.name}')"
KUBE_API_IP="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')"

# api_try DESCRIPTION PYTHON_SNIPPET EXPECT(ok|blocked)
api_try() {
  local out
  if out="$(kubectl -n "$NS" exec "$API_POD" -c api -- python -c "$2" 2>&1)"; then
    if [[ "$3" == "ok" ]]; then pass "$1"; else fail "$1: SUCCEEDED (should be blocked) $out"; fi
  else
    if [[ "$3" == "blocked" ]]; then pass "$1: blocked"; else fail "$1: $out"; fi
  fi
}

api_try "API -> its own PostgreSQL :5432 (allowed)" \
  "import socket; socket.create_connection(('taskapi-postgresql', 5432), 3)" ok
api_try "API -> internet 1.1.1.1:443" \
  "import socket; socket.create_connection(('1.1.1.1', 443), 3)" blocked
api_try "API -> Kubernetes API ${KUBE_API_IP}:443" \
  "import socket; socket.create_connection(('${KUBE_API_IP}', 443), 3)" blocked
api_try "API -> DNS lookup of github.com (DNS policy)" \
  "import socket; socket.getaddrinfo('github.com', 443)" blocked

echo; echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
