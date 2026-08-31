#!/bin/sh
# Script function and purpose: the route inventory, as a standing test.
#
# TESTS.md §5d mandates this. It exists because N-29 was missed: the audit
# enumerated the route families it happened to notice, /api/storage/* was not
# among them, and N-S5a was recorded complete with five routes unserved. Reading
# the handler list is not a substitute for asking the running binary.
#
# What each status means here:
#   200/4xx from the core  — the core owns the route
#   502                    — correctly classified to a proxied class; llama-server
#                            is simply not running, which is the honest answer
#   404/405                — NOT served. If proxy.lua serves it, that is a defect
#
# Usage: sh tests/test_routes.sh [port]
# Runs inside a scratch JCA_HOME (D-AE: never touch ~/JCA) and removes it on exit.

set -u

PORT=${1:-18743}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CORE="$ROOT/bin/jenova-core"
FAILED=0

[ -x "$CORE" ] || { echo "SKIP: $CORE not built (run: make core)"; exit 0; }
command -v nc >/dev/null 2>&1 || { echo "SKIP: nc not available"; exit 0; }

JCA_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jenova-routes.XXXXXX") || exit 1
export JCA_HOME
mkdir -p "$JCA_HOME/.system" "$JCA_HOME/Workspaces"

JENOVA_NO_BACKENDS=1 JENOVA_PORT="$PORT" "$CORE" serve >/dev/null 2>&1 &
SRV=$!
cleanup() {
    kill $SRV 2>/dev/null
    case "$JCA_HOME" in
        */jenova-routes.*) rm -rf "$JCA_HOME" ;;
    esac
}
trap cleanup EXIT INT TERM
sleep 1

probe() { # method path
    printf '%s %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' "$1" "$2" \
        | nc 127.0.0.1 "$PORT" | head -1 | sed 's/^HTTP\/1.1 \([0-9]*\).*/\1/'
}

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; shift; for l in "$@"; do echo "       $l"; done
         FAILED=$((FAILED + 1)); }

expect() { # method path expected-code label
    got=$(probe "$1" "$2")
    if [ "$got" = "$3" ]; then
        pass "$4 ($1 $2 -> $3)"
    else
        fail "$4" "$1 $2 expected $3, got ${got:-<no response>}"
    fi
}

echo "test_routes: port $PORT"

if [ "$(probe GET /health)" != "200" ]; then
    echo "  FAIL server did not answer /health — aborting"
    echo "test_routes: FAIL (unreachable)"
    exit 1
fi

# --- owned by the core ------------------------------------------------------
expect GET /health              200 "health"
expect GET /api/db/workspaces   200 "database surface"
expect GET /api/fs/trash        200 "filesystem surface"
expect GET /api/db/nope         404 "unknown collection is an honest 404"
expect GET /api/storage/        200 "storage listing"
expect GET /api/storage/../../etc/passwd 403 "storage traversal refused"

# --- classified to a proxied class (D-AF) -----------------------------------
# 502 proves classification reached upstream.forward and found no llama-server.
# A 404 or 405 would mean the route was never classified at all — the N-29 bug.
expect POST /v1/chat/completions 502 "chat completions proxied"
expect POST /completion          502 "completion proxied"
expect POST /infill              502 "FIM proxied — the USER's Neovim dependency"
expect GET  /v1/health           200 "/v1/health is health, not completion"

# --- the completion pipeline runs in the serving path (N-30) -----------------
# A chat POST goes through pipeline.prepare — intent detection, RAG retrieval,
# persona injection — before reaching the upstream. A 500 here means the
# pipeline threw; a 502 means it completed and llama-server is simply absent.
# This distinction is the whole check: the pipeline self-test calls
# rag.initSchema() itself and so could not catch `serve` failing to.
postcode() { # path body
    printf 'POST %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$1" "${#2}" "$2" | nc 127.0.0.1 "$PORT" | head -1 \
        | sed 's/^HTTP\/1.1 \([0-9]*\).*/\1/'
}
got=$(postcode /v1/chat/completions '{"messages":[{"role":"user","content":"hi"}]}')
if [ "$got" = "502" ]; then
    pass "chat request survives the pipeline and reaches the upstream"
else
    fail "chat request survives the pipeline and reaches the upstream" \
         "expected 502 (pipeline ok, no llama-server), got ${got:-<none>} — 500 means the pipeline threw"
fi
got=$(postcode /infill '{"input_prefix":"def f(","input_suffix":"):"}')
if [ "$got" = "502" ]; then
    pass "FIM body passes through the pipeline untouched"
else
    fail "FIM body passes through the pipeline untouched" \
         "expected 502, got ${got:-<none>}"
fi

# --- containment ------------------------------------------------------------
expect GET /../etc/jenova.conf   403 "path traversal refused"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "test_routes: PASS"
    exit 0
fi
echo "test_routes: FAIL ($FAILED)"
exit 1
