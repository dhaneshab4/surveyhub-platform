#!/usr/bin/env bash
# Post-deploy smoke test. Exits non-zero on the first real failure so CD can roll back.
#
# Deliberately narrow: this proves the deployment is serving and wired to its database,
# not that every feature works. That is what the test suite is for.
set -euo pipefail

BASE="${1:?usage: smoke.sh <base-url>}"
RETRIES="${RETRIES:-30}"
SLEEP="${SLEEP:-4}"

log()  { printf '  %s\n' "$*"; }
fail() { printf '::error::%s\n' "$*"; exit 1; }

# Fly machines auto-stop when idle, so the first request after a quiet period pays a
# cold start. Wait for liveness before asserting anything else.
log "waiting for ${BASE}/healthz"
for i in $(seq 1 "$RETRIES"); do
    if curl -fsS --max-time 20 "${BASE}/healthz" >/dev/null 2>&1; then
        log "up after ${i} attempt(s)"
        break
    fi
    [ "$i" -eq "$RETRIES" ] && fail "never became healthy after $((RETRIES * SLEEP))s"
    sleep "$SLEEP"
done

log "checking liveness payload"
HEALTH=$(curl -fsS --max-time 20 "${BASE}/healthz")
echo "$HEALTH" | grep -q '"status": *"ok"' || fail "unexpected /healthz body: $HEALTH"
log "$HEALTH"

log "checking readiness (database reachable)"
READY=$(curl -fsS --max-time 30 "${BASE}/readyz") \
    || fail "/readyz returned non-2xx — database unreachable"
echo "$READY" | grep -q '"database": *"up"' || fail "unexpected /readyz body: $READY"

log "checking the API answers"
# SECURE_SSL_REDIRECT sends a 301 to plain-HTTP callers. Behind Fly the proxy supplies
# X-Forwarded-Proto, so send it here too and get the real response rather than the
# redirect — otherwise this check passes on a 301 and proves nothing.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
       -H 'X-Forwarded-Proto: https' "${BASE}/api/surveys/")
# 401 is the correct answer for an unauthenticated caller; 5xx is not.
case "$CODE" in
    200|401|403) log "/api/surveys/ -> $CODE" ;;
    *)           fail "/api/surveys/ returned $CODE (expected 200, 401 or 403)" ;;
esac

log "checking metrics are being exported"
curl -fsS --max-time 20 "${BASE}/metrics" | grep -q 'surveyhub_http_requests_total' \
    || fail "/metrics missing surveyhub_http_requests_total"

log "checking HTTPS is enforced"
REDIRECT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
           "${BASE/https:/http:}/healthz" || echo 000)
case "$REDIRECT" in
    301|302|308) log "http -> https redirect: $REDIRECT" ;;
    *)           log "warning: expected an http->https redirect, got $REDIRECT" ;;
esac

printf '\nsmoke test passed against %s\n' "$BASE"
