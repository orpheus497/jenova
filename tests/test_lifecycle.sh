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

# Action purpose: a prerequisite this suite cannot supply makes the run FAIL,
# never PASS (TODOS.md A-2). This used to `exit 0`, which reported success
# having asserted nothing.
[ -x "$CORE" ] || { echo "FAIL: $CORE not built (run: nimble core)"; exit 1; }

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

# The profiles set JENOVA_FLASH_ATTN, JENOVA_MLOCK and JENOVA_MMAP and nothing
# read them: -fa auto ran even where a profile said off, and MLOCK=1 locked
# nothing. These pin the defaults, so the wiring cannot silently regress to a
# hardcoded flag again.
hasnt "mlock is off unless a profile asks"  '\-\-mlock'   "$LLAMA_LINE"
hasnt "mmap stays on unless a profile asks" '\-\-no-mmap' "$LLAMA_LINE"

# In a subshell: `VAR=x FOO=$(cmd)` applies VAR to the assignment, not to the
# command substitution, so the override would not reach the child.
TUNED_LLAMA=$(
    JENOVA_FLASH_ATTN=off JENOVA_MLOCK=1 JENOVA_MMAP=0
    export JENOVA_FLASH_ATTN JENOVA_MLOCK JENOVA_MMAP
    "$CORE" backends args 2>/dev/null | head -1
)
has "a profile can turn flash attention off" '\-fa off'   "$TUNED_LLAMA"
has "a profile can request mlock"            '\-\-mlock'   "$TUNED_LLAMA"
has "a profile can disable mmap"             '\-\-no-mmap' "$TUNED_LLAMA"

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

# --- --lan moves ONLY the client-facing port (S-0, D-E) ----------------------
# This is a security property, not a default. Publishing the backends would put
# two unauthenticated inference endpoints on the network; jenova-ca:568-575 is
# explicit about it. Asserted in both directions.
LAN=$(JENOVA_NO_BACKENDS=1 JENOVA_PORT=18771 timeout 3 "$CORE" serve --lan 2>&1 | head -6)
has   "--lan binds the client port to 0.0.0.0"      'serving on 0.0.0.0'    "$LAN"
has   "--lan leaves llama on loopback"              'llama 127.0.0.1'       "$LAN"
has   "--lan leaves embed on loopback"              'embed 127.0.0.1'       "$LAN"
hasnt "--lan does not publish a backend"            'llama 0.0.0.0'         "$LAN"

DEF=$(JENOVA_NO_BACKENDS=1 JENOVA_PORT=18772 timeout 3 "$CORE" serve 2>&1 | head -6)
has "without --lan the client port stays loopback" 'serving on 127.0.0.1' "$DEF"

# --- port overrides ----------------------------------------------------------
PORTS=$(JENOVA_NO_BACKENDS=1 timeout 3 "$CORE" serve --port 18773 --llama-port 19001 --embed-port 19002 2>&1 | head -6)
has "--port overrides the client port"  'serving on 127.0.0.1:18773' "$PORTS"
has "--llama-port reaches the upstream" 'llama 127.0.0.1:19001'      "$PORTS"
has "--embed-port reaches the upstream" 'embed 127.0.0.1:19002'      "$PORTS"

# Guarded like the other serve checks: if the flag were ever accepted instead of
# refused, an unguarded invocation would start a real server on the default port
# and hang the suite there.
out=$(JENOVA_NO_BACKENDS=1 JENOVA_PORT=18774 timeout 3 "$CORE" serve --nonsense 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "unknown option"; then
    pass "an unknown serve flag is refused, not ignored"
else
    fail "an unknown serve flag is refused, not ignored" "exit=$rc" "$out"
fi

# --- health is not liveness --------------------------------------------------
# A wedged llama-server keeps its pid; only the port tells the truth. This is
# what the watchdog acts on, and the distinction B-13 got wrong.
#
# Action purpose: T-12, and the override is scoped to THIS command rather than
# exported. The assertion is that health goes red when nothing is listening, so
# it has to probe ports nothing holds — unoverridden it probed the machine's
# real 8081/8082 and passed only while the USER's backends were down. It is not
# exported because the argument-vector assertions above read back the DEFAULT
# ports (`--port 8081`, `--port 8082`); a global override turns those two red.
JENOVA_LLAMA_PORT=18775 JENOVA_LLAMA_EMBED_PORT=18776 \
    "$CORE" backends health >/dev/null 2>&1
if [ $? -ne 0 ]; then pass "health reports failure when nothing is listening"
else fail "health reports failure when nothing is listening" "expected non-zero exit"; fi

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
