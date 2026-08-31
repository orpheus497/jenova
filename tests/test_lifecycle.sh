#!/bin/sh
# Script function and purpose: lifecycle checks for the backend supervisor
# (N-S6) — the argument vector it builds and its refusal paths.
#
# Under D-AF llama-server is the inference engine, so the argument vector this
# core produces IS the tuning. Its flags are the accumulated result of work
# against real hardware; a silently dropped or reordered one changes generation
# behaviour without failing anything. These assertions pin the flags that carry
# intent, and the two branches that are easy to conflate.
#
# It does not start llama-server: that needs a model, and the models live under
# ~/JCA which ruling D-AE places permanently out of bounds.
#
# Usage: sh tests/test_lifecycle.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CORE="$ROOT/bin/jenova-core"
FAILED=0

[ -x "$CORE" ] || { echo "SKIP: $CORE not built (run: make core)"; exit 0; }

JCA_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jenova-lifecycle.XXXXXX") || exit 1
export JCA_HOME
mkdir -p "$JCA_HOME/.system" "$JCA_HOME/var/log"
cleanup() {
    case "$JCA_HOME" in
        */jenova-lifecycle.*) rm -rf "$JCA_HOME" ;;
    esac
}
trap cleanup EXIT INT TERM

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; shift; for l in "$@"; do echo "       $l"; done
         FAILED=$((FAILED + 1)); }

echo "test_lifecycle: scratch $JCA_HOME"

ARGS=$("$CORE" backends args 2>/dev/null)
LLAMA_LINE=$(printf '%s\n' "$ARGS" | head -1)
EMBED_LINE=$(printf '%s\n' "$ARGS" | tail -1)

has() { # label needle line
    if printf '%s' "$3" | grep -q -- "$2"; then pass "$1"
    else fail "$1" "expected to contain: $2" "in: $3"; fi
}
hasnt() { # label needle line
    if printf '%s' "$3" | grep -q -- "$2"; then
        fail "$1" "expected NOT to contain: $2" "in: $3"
    else pass "$1"; fi
}

# --- flags that carry tuning intent ------------------------------------------
has "FIM enabled (--spm-infill) — the Neovim dependency" '\-\-spm-infill' "$LLAMA_LINE"
has "prompt cache enabled"        '\-\-cache-prompt'  "$LLAMA_LINE"
has "offline mode (no telemetry)" '\-\-offline'       "$LLAMA_LINE"
has "continuous batching"         '\-cb'              "$LLAMA_LINE"
has "flash attention auto"        '\-fa auto'         "$LLAMA_LINE"
has "split mode layer"            '\-sm layer'        "$LLAMA_LINE"

# --- ports and binding -------------------------------------------------------
# S-0 and D-E: backends are loopback-only regardless of --lan, so LAN mode
# cannot publish two unauthenticated inference endpoints to the network.
has "llama binds loopback"  '\-\-host 127.0.0.1' "$LLAMA_LINE"
has "llama on :8081"        '\-\-port 8081'      "$LLAMA_LINE"
has "embed binds loopback"  '\-\-host 127.0.0.1' "$EMBED_LINE"
has "embed on :8082"        '\-\-port 8082'      "$EMBED_LINE"

# --- the embed server runs on CPU by design ----------------------------------
# It must not compete for VRAM with the agent model; on a 4GB card that is the
# difference between both loading and neither.
has   "embed offloads nothing" '\-ngl 0'   "$EMBED_LINE"
has   "embed uses no device"   '\-dev none' "$EMBED_LINE"
has   "embed is an embedding server" '\-\-embedding' "$EMBED_LINE"
hasnt "embed does not request flash attention" '\-fa' "$EMBED_LINE"

# --- the -fitt / -ngl branch, which is easy to conflate ----------------------
# jenova-ca:162-172: NGL_AGENT=all uses auto-fit; an explicit count uses -ngl
# and must skip -fitt entirely, because the two conflict.
FITT_LINE=$(JENOVA_NGL_AGENT=all "$CORE" backends args 2>/dev/null | head -1)
NGL_LINE=$(JENOVA_NGL_AGENT=18 "$CORE" backends args 2>/dev/null | head -1)
has   "NGL_AGENT=all uses auto-fit"        '\-fitt' "$FITT_LINE"
hasnt "NGL_AGENT=all does not pass -ngl"   '\-ngl ' "$FITT_LINE"
has   "explicit NGL_AGENT passes -ngl 18"  '\-ngl 18' "$NGL_LINE"
hasnt "explicit NGL_AGENT skips -fitt"     '\-fitt' "$NGL_LINE"

# --- refusal paths -----------------------------------------------------------
out=$("$CORE" backends start 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "MODEL_PATH\|model not found\|not found at"; then
    pass "start refuses with no model and says why"
else
    fail "start refuses with no model and says why" "exit=$rc" "output: $out"
fi

"$CORE" backends stop >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "stop is idempotent when nothing is running"
else fail "stop is idempotent when nothing is running"; fi

if "$CORE" backends status 2>&1 | grep -q "not running"; then
    pass "status reports each backend separately"
else
    fail "status reports each backend separately"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "test_lifecycle: PASS"
    exit 0
fi
echo "test_lifecycle: FAIL ($FAILED)"
exit 1
