#!/bin/sh

# test_bin_jenova.sh: Validate bin/jenova launcher against a running jenova-ca backend
# Tests: config loading, health check, cleanup guard
#
# Prerequisites:
#   - jenova.conf must exist
#   - jenova-ca must be reachable (either already running or startable)

SCRIPT_DIR=$(dirname "$(realpath "$0")")
if [ ! -f "$SCRIPT_DIR/../etc/jenova.conf" ]; then
    echo "Error: jenova.conf not found at $SCRIPT_DIR/../etc/jenova.conf" >&2
    exit 1
fi
. "$SCRIPT_DIR/../etc/jenova.conf"

EXIT_CODE=0

# Preflight checks
if [ -z "$JENOVA_ROOT" ]; then
    echo "FAIL: JENOVA_ROOT is not set" >&2
    exit 1
fi

JENOVA_BIN="$SCRIPT_DIR/../bin/jenova"
JENOVA_CA="$SCRIPT_DIR/../bin/jenova-ca"

if [ ! -x "$JENOVA_BIN" ]; then
    echo "SKIP: bin/jenova not found or not executable at $JENOVA_BIN (run setup first)" >&2
    exit 0
fi
if [ ! -x "$JENOVA_CA" ]; then
    echo "FAIL: bin/jenova-ca not found or not executable at $JENOVA_CA" >&2
    exit 1
fi

echo "=== test_bin_jenova.sh ==="
echo ""

# Test 1: Config loading
echo "[test 1] Config loading..."
if [ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$LLAMA_PORT" ]; then
    echo "  PASS: HOST=$HOST PORT=$PORT LLAMA_PORT=$LLAMA_PORT"
else
    echo "  FAIL: Missing HOST, PORT, or LLAMA_PORT in jenova.conf"
    EXIT_CODE=1
fi

# Test 2: Health check module exists
echo "[test 2] Health check module..."
if [ -f "$SCRIPT_DIR/../lib/healthcheck.lua" ]; then
    echo "  PASS: lib/healthcheck.lua exists"
else
    echo "  FAIL: lib/healthcheck.lua not found"
    EXIT_CODE=1
fi

# Test 3: Agent module exists
echo "[test 3] Agent module..."
if [ -f "$SCRIPT_DIR/../jenova-cli/legacy-agent/agent.lua" ]; then
    echo "  PASS: jenova-cli/legacy-agent/agent.lua exists"
else
    echo "  SKIP: jenova-cli/legacy-agent/agent.lua not found (jenova-cli may not be populated)"
fi

# Test 4: Check jenova-ca status verb
echo "[test 4] jenova-ca status verb..."
"$JENOVA_CA" status >/dev/null 2>&1
STATUS_EXIT=$?
if [ "$STATUS_EXIT" -eq 0 ]; then
    echo "  PASS: jenova-ca status returned exit 0"
else
    echo "  WARN: jenova-ca status returned exit $STATUS_EXIT (backend may not be running)"
fi

# Test 5: Health check against running server (if available)
CONNECT_HOST="${JENOVA_CONNECT_HOST:-127.0.0.1}"
echo "[test 5] Health check (${CONNECT_HOST}:${PORT})..."
if luajit "$SCRIPT_DIR/../lib/healthcheck.lua" "$CONNECT_HOST" "$PORT" 3 2>/dev/null; then
    echo "  PASS: Proxy health check returned 200"
else
    echo "  SKIP: Proxy not reachable (backend may not be running)"
fi

# Test 6: Verify PID file format (if exists)
echo "[test 6] PID file format..."
PID_FILE="${PID_FILE:-${JENOVA_ROOT:+$JENOVA_ROOT/.jenova/jenova-ca.pid}}"
if [ -z "$PID_FILE" ]; then
    echo "  SKIP: PID_FILE not set and JENOVA_ROOT unavailable"
elif [ -f "$PID_FILE" ]; then
    PID_CONTENT=$(tr -d '\n' < "$PID_FILE" | tr -s ' ')
    # PID file must be non-empty, all tokens must be non-zero positive integers, no "0" anywhere.
    if [ -n "$PID_CONTENT" ] && \
       echo "$PID_CONTENT" | grep -qE '^[1-9][0-9]*( [1-9][0-9]*)*$' && \
       ! echo "$PID_CONTENT" | grep -qwE '(^| )0( |$)'; then
        echo "  PASS: PID file format valid: $PID_CONTENT"
    else
        echo "  FAIL: PID file contains invalid content: $PID_CONTENT"
        EXIT_CODE=1
    fi
else
    echo "  SKIP: No PID file at ${PID_FILE} (backend not running)"
fi

# Test 7: Verify cleanup guard variable
echo "[test 7] Cleanup guard (STARTED_BY_THIS_INVOCATION)..."
if grep -q "STARTED_BY_THIS_INVOCATION" "$JENOVA_BIN"; then
    echo "  PASS: Cleanup guard present in bin/jenova"
else
    echo "  FAIL: STARTED_BY_THIS_INVOCATION guard missing from bin/jenova"
    EXIT_CODE=1
fi

# Test 8: Verify trap is set
echo "[test 8] EXIT/INT/TERM trap..."
if grep -q "trap cleanup_agent EXIT INT TERM" "$JENOVA_BIN"; then
    echo "  PASS: trap cleanup_agent EXIT INT TERM found"
else
    echo "  FAIL: Missing trap in bin/jenova"
    EXIT_CODE=1
fi

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests failed (exit code $EXIT_CODE)."
fi
exit $EXIT_CODE
