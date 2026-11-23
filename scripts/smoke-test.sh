#!/usr/bin/env bash
# =============================================================================
# End-to-end test THROUGH THE GATEWAY, like a real client:
#   1. the API works (CRUD)
#   2. the Cilium L7 policy blocks everything that is not explicitly allowed
#
# Usage: scripts/smoke-test.sh [dev|prod]
# =============================================================================
set -euo pipefail

ENVIRONMENT="${1:-dev}"
GATEWAY="${GATEWAY:-http://127.0.0.1:8080}"
case "$ENVIRONMENT" in
  dev)  HOST="taskapi-dev.localtest.me" ;;
  prod) HOST="taskapi.localtest.me" ;;
  *) echo "usage: $0 [dev|prod]" >&2; exit 2 ;;
esac

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# request METHOD PATH [JSON_BODY] -> prints "<status> <body>"
request() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -m 10 -o /tmp/smoke_body -w '%{http_code}' -X "$method" -H "Host: ${HOST}")
  [[ -n "$body" ]] && args+=(-H 'content-type: application/json' -d "$body")
  local code
  code="$(curl "${args[@]}" "${GATEWAY}${path}" || echo 000)"
  printf '%s %s' "$code" "$(cat /tmp/smoke_body 2>/dev/null || true)"
}

expect() {  # expect DESCRIPTION EXPECTED_STATUS METHOD PATH [BODY]
  local desc="$1" want="$2"; shift 2
  local out; out="$(request "$@")"
  local got="${out%% *}"
  if [[ "$got" == "$want" ]]; then pass "$desc ($got)"; else fail "$desc: expected $want, got $got: ${out#* }"; fi
  LAST_BODY="${out#* }"
}

echo "Waiting for ${HOST} to answer through the Gateway..."
for _ in $(seq 1 60); do
  [[ "$(request GET /api/info | cut -d' ' -f1)" == "200" ]] && break
  sleep 5
done

echo; echo "== Functional tests (${ENVIRONMENT})"
expect "GET  /api/info"                 200 GET /api/info
if [[ "$LAST_BODY" == *"\"env\":\"${ENVIRONMENT}\""* ]]; then pass "info reports env=${ENVIRONMENT}"; else fail "info env: ${LAST_BODY}"; fi

expect "POST /api/tasks"                201 POST /api/tasks '{"title":"smoke test"}'
TASK_ID="$(sed -E 's/.*"id":([0-9]+).*/\1/' <<<"$LAST_BODY")"
expect "GET  /api/tasks/${TASK_ID}"     200 GET "/api/tasks/${TASK_ID}"
expect "PATCH /api/tasks/${TASK_ID}"    200 PATCH "/api/tasks/${TASK_ID}" '{"done":true}'
expect "GET  /api/tasks"                200 GET /api/tasks
expect "DELETE /api/tasks/${TASK_ID}"   204 DELETE "/api/tasks/${TASK_ID}"
expect "GET deleted task -> 404 (app)"  404 GET "/api/tasks/${TASK_ID}"

echo; echo "== Zero-trust tests: denied by Cilium (Envoy) BEFORE reaching the app"
expect "PUT  /api/tasks/1 (method not allowed by policy)" 403 PUT /api/tasks/1 '{"title":"x"}'
if [[ "$LAST_BODY" == *"Access denied"* ]]; then pass "403 body comes from the Cilium proxy"; else fail "unexpected 403 body: ${LAST_BODY}"; fi
expect "GET  /api/admin  (path not allowed by policy)"   403 GET /api/admin
expect "GET  /healthz    (not routed by the HTTPRoute)"  404 GET /healthz
expect "GET  /metrics    (metrics port never exposed)"   404 GET /metrics

echo; echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
