#!/bin/sh
# Tests: config loading, module existence, jenova-ca verbs, health check, cleanup guard
# Does NOT start real daemons — all checks are static/unit-level.
set -e

SCRIPT_DIR=$(dirname "$(realpath "$0")")
ROOT=$(dirname "$SCRIPT_DIR")

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s\n" "$1"
}

# --- T1: etc/jenova.conf loads without error ---
if . "$ROOT/etc/jenova.conf" 2>/dev/null && [ -n "$JENOVA_ROOT" ]; then
    ok "T1: etc/jenova.conf loads and sets JENOVA_ROOT"
else
    fail "T1: etc/jenova.conf failed to load or JENOVA_ROOT not set"
fi

# --- T2: Required Lua modules exist ---
for _mod in proxy search embed http json ffi_defs daemon; do
    if [ -f "$ROOT/lib/${_mod}.lua" ]; then
        ok "T2: lib/${_mod}.lua exists"
    else
        fail "T2: lib/${_mod}.lua MISSING"
    fi
done

# New locations for agent and memory
if [ -d "$ROOT/jvim-config/lua/jenova/agent" ]; then
    ok "T2: jvim-config/lua/jenova/agent/ exists"
else
    fail "T2: jvim-config/lua/jenova/agent/ MISSING"
fi

if [ -f "$ROOT/jvim-config/lua/jenova/agent/memory.lua" ]; then
    ok "T2: jvim-config/lua/jenova/agent/memory.lua exists"
else
    fail "T2: jvim-config/lua/jenova/agent/memory.lua MISSING"
fi

# --- T3: jenova-ca is executable ---
if [ -x "$ROOT/bin/jenova-ca" ]; then
    ok "T3: bin/jenova-ca is executable"
else
    fail "T3: bin/jenova-ca not executable"
fi

# --- T4: jenova-ca status verb exits 0 ---
# jenova-ca performs mandatory checks for LLAMA_SERVER and the model file before
# reaching the status case; skip on a fresh clone where build artifacts are absent.
_T4_SERVER="${LLAMA_SERVER:-$ROOT/external/ext_bin/bin/llama-server}"
_T4_MODEL="${JENOVA_MODEL:-${MODEL_AGENT:-}}"
if [ ! -f "$_T4_SERVER" ] || [ -z "$_T4_MODEL" ] || [ ! -f "$_T4_MODEL" ]; then
    ok "T4: jenova-ca status (SKIPPED — build artifacts not present)"
elif "$ROOT/bin/jenova-ca" status >/dev/null 2>&1; then
    ok "T4: jenova-ca status exits 0"
else
    fail "T4: jenova-ca status did not exit 0"
fi

# --- T5: lib/healthcheck.lua exists ---
if [ -f "$ROOT/lib/healthcheck.lua" ]; then
    ok "T5: lib/healthcheck.lua exists"
else
    fail "T5: lib/healthcheck.lua MISSING"
fi

# --- T6: PID file format — must contain only non-zero positive integers if present ---
# Validate format only; does not require the file to exist.
JENOVA_STATE="${JENOVA_STATE:-$ROOT/.jenova}"
PID_FILE="${PID_FILE:-$JENOVA_STATE/jenova-ca.pid}"
if [ -f "$PID_FILE" ]; then
    PID_CONTENT=$(tr -d '\n' < "$PID_FILE" | tr -s ' ')
    # Require at least one PID, each token must be a non-zero positive integer.
    if [ -n "$PID_CONTENT" ] && \
       echo "$PID_CONTENT" | grep -qE '^[1-9][0-9]*( [1-9][0-9]*)*$' && \
       ! echo "$PID_CONTENT" | grep -qwE '(^| )0( |$)'; then
        ok "T6: PID file format is valid (no zeros, all positive integers)"
    else
        fail "T6: PID file exists but contains invalid entries: '$PID_CONTENT'"
    fi
else
    ok "T6: PID file absent (daemons not running — format check skipped)"
fi

# --- T7: cleanup trap is present in bin/jenova ---
if grep -q "trap.*cleanup" "$ROOT/bin/jenova" 2>/dev/null; then
    ok "T7: cleanup trap present in bin/jenova"
else
    fail "T7: cleanup trap NOT found in bin/jenova"
fi

# --- T8: proxy.lua has /health endpoint ---
if grep -q 'GET /health' "$ROOT/lib/proxy.lua" 2>/dev/null; then
    ok "T8: /health endpoint present in lib/proxy.lua"
else
    fail "T8: /health endpoint NOT found in lib/proxy.lua"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
