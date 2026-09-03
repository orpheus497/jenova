#!/bin/sh
# Script function and purpose: regression test for src/jenova/models.nim, the Nim
# replacement for lib/jenova-model.sh and bin/jenova-model-switch (N-36, N-37).
#
# These two scripts were the last shell the running product relied on, so this is
# the test that guards the total-conversion gate (D-AI). It runs entirely inside
# a mktemp JCA_HOME and starts no server and no backend.
#
# Why the assertions are what they are: a reimplementation of a file-scanning
# helper does not fail by crashing, it fails by picking a *different plausible
# file* — a different sort order, a backup counted as active, a symlink skipped.
# Every check below pins one of those, because that is where a silent wrong
# answer would live.

set -u

JENOVA_ROOT="${JENOVA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export JENOVA_ROOT
CORE="$JENOVA_ROOT/bin/jenova-core"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

if [ ! -x "$CORE" ]; then
    echo "test_models: bin/jenova-core not built — run 'nimble core' first" >&2
    exit 1
fi

SCRATCH=$(mktemp -d /tmp/jenova-test-models-XXXXXX) || exit 1
# Action purpose: only ever remove a directory matching this suite's own prefix.
# test_api_db.sh once derived its path from ${JCA_HOME:-$HOME/JCA} and deleted
# the user's real database; the isolation is the lesson from that.
cleanup() {
    case "$SCRATCH" in
        /tmp/jenova-test-models-*) rm -rf "$SCRATCH" ;;
    esac
}
trap cleanup EXIT INT TERM

export JCA_HOME="$SCRATCH"
mkdir -p "$SCRATCH/models/agent" "$SCRATCH/models/draft" "$SCRATCH/models/embed" \
         "$SCRATCH/models/instruct" "$SCRATCH/models/thinking"

echo "test_models: discovery"

# Created out of collation order deliberately: walkDir has no defined order, so
# the sort has to be explicit in models.nim. Creating alpha second is what makes
# this assertion able to fail.
: > "$SCRATCH/models/agent/zeta-9b.gguf"
: > "$SCRATCH/models/agent/alpha-9b.gguf"
: > "$SCRATCH/models/draft/tiny-0.5b.gguf"
: > "$SCRATCH/models/embed/nomic.gguf"

out=$("$CORE" models list 2>&1)
assert_eq "agent picks first alphabetically, not first on disk" \
    "$(printf '%s\n' "$out" | awk '/^agent:/{print $2}')" \
    "$SCRATCH/models/agent/alpha-9b.gguf"
assert_eq "draft resolved" \
    "$(printf '%s\n' "$out" | awk '/^draft:/{print $2}')" \
    "$SCRATCH/models/draft/tiny-0.5b.gguf"
assert_eq "embed resolved" \
    "$(printf '%s\n' "$out" | awk '/^embed:/{print $2}')" \
    "$SCRATCH/models/embed/nomic.gguf"

# jenova-model.sh:48,51 honoured these; dropping them would silently ignore an
# operator's explicit choice.
out=$(JENOVA_DRAFT_MODEL=/custom/draft.gguf "$CORE" models list 2>&1)
assert_eq "JENOVA_DRAFT_MODEL overrides discovery" \
    "$(printf '%s\n' "$out" | awk '/^draft:/{print $2}')" "/custom/draft.gguf"

out=$(JENOVA_MODEL=/custom/agent.gguf "$CORE" models list 2>&1)
assert_eq "JENOVA_MODEL overrides discovery" \
    "$(printf '%s\n' "$out" | awk '/^agent:/{print $2}')" "/custom/agent.gguf"

# jenova-model.sh:42-45 — the agent, and only the agent, falls back to a flat
# models/ directory. Giving draft or embed the same fallback would start passing
# -md/-m paths the shell would have left empty.
FLAT=$(mktemp -d /tmp/jenova-test-models-XXXXXX)
mkdir -p "$FLAT/models"
: > "$FLAT/models/flat-9b.gguf"
out=$(JCA_HOME="$FLAT" "$CORE" models list 2>&1)
assert_eq "agent falls back to flat models/" \
    "$(printf '%s\n' "$out" | awk '/^agent:/{print $2}')" "$FLAT/models/flat-9b.gguf"
assert_eq "draft does NOT fall back to flat models/" \
    "$(printf '%s\n' "$out" | awk '/^draft:/{print $2}')" ""
case "$FLAT" in /tmp/jenova-test-models-*) rm -rf "$FLAT" ;; esac

echo "test_models: switching"

: > "$SCRATCH/models/instruct/qwen-instruct.gguf"
: > "$SCRATCH/models/thinking/qwen-thinking.gguf"
(cd "$SCRATCH/models/agent" && rm -f ./*.gguf && \
    ln -s ../thinking/qwen-thinking.gguf qwen-thinking.gguf)

"$CORE" models switch instruct >/dev/null 2>&1
assert_eq "switch installs the target as a symlink" \
    "$(readlink "$SCRATCH/models/agent/qwen-instruct.gguf" 2>/dev/null)" \
    "../instruct/qwen-instruct.gguf"

# The link target must be RELATIVE. An absolute one works until the tree is
# moved or deployed, and then silently points outside it.
case "$(readlink "$SCRATCH/models/agent/qwen-instruct.gguf" 2>/dev/null)" in
    /*) fail "link target is relative, not absolute" ;;
    ../*) pass "link target is relative, not absolute" ;;
    *) fail "link target is relative, not absolute" "unexpected form" ;;
esac

# Action purpose: D-CB. This asserted the opposite until 2026-09-03 — that a
# displaced SYMLINK survives as `.old` — which is the behaviour the ruling
# removed on 2026-09-02: the link named a `.gguf` that never moved, so `.old`
# kept a second name for the same file and the directory filled on every
# switch. `models-selftest` was updated with the code and this suite was not,
# so it has asserted a deleted behaviour ever since. Found by 12a, which is the
# point of 12a.
if [ -e "$SCRATCH/models/agent/qwen-thinking.gguf.old" ] ||
   [ -L "$SCRATCH/models/agent/qwen-thinking.gguf.old" ]; then
    fail "a displaced symlink is removed, not kept as .old" \
         "found $SCRATCH/models/agent/qwen-thinking.gguf.old"
else
    pass "a displaced symlink is removed, not kept as .old"
fi

# ...and the half D-CB kept, asserted here because removing the symlink case
# leaves nothing in this suite covering the branch that still preserves. A real
# `.gguf` the user dropped into `models/agent` by hand is their only copy of it.
: > "$SCRATCH/models/agent/manual.gguf"
"$CORE" models switch thinking >/dev/null 2>&1
if [ -f "$SCRATCH/models/agent/manual.gguf.old" ] &&
   [ ! -L "$SCRATCH/models/agent/manual.gguf.old" ]; then
    pass "a displaced real file is preserved as .old"
else
    fail "a displaced real file is preserved as .old" \
         "no plain file at $SCRATCH/models/agent/manual.gguf.old"
fi
rm -f "$SCRATCH/models/agent/manual.gguf.old"
"$CORE" models switch instruct >/dev/null 2>&1

# A .old backup must never be selected as the active model, or a switch would
# resurrect the model it just replaced.
out=$("$CORE" models list 2>&1)
assert_eq "a .old backup is not discovered as the agent model" \
    "$(printf '%s\n' "$out" | awk '/^agent:/{print $2}')" \
    "$SCRATCH/models/agent/qwen-instruct.gguf"

# Switching to the same target twice: the existing entry already resolves to the
# target, so it is removed rather than preserved. Without this the directory
# accumulates a .old per switch for a file that never changed.
"$CORE" models switch instruct >/dev/null 2>&1
n_old=$(find "$SCRATCH/models/agent" -name 'qwen-instruct.gguf.old*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "re-switching to the same model leaves no redundant .old" "$n_old" "0"
assert_eq "re-switching leaves the target active" \
    "$(readlink "$SCRATCH/models/agent/qwen-instruct.gguf" 2>/dev/null)" \
    "../instruct/qwen-instruct.gguf"

echo "test_models: refusals"

"$CORE" models switch banana >/dev/null 2>&1
assert_eq "an invalid target is refused" "$?" "1"

EMPTY=$(mktemp -d /tmp/jenova-test-models-XXXXXX)
mkdir -p "$EMPTY/models/instruct"
JCA_HOME="$EMPTY" "$CORE" models switch instruct >/dev/null 2>&1
assert_eq "switching with no .gguf in the target is refused" "$?" "1"
case "$EMPTY" in /tmp/jenova-test-models-*) rm -rf "$EMPTY" ;; esac

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "test_models: PASS ($PASSED assertions)"
    exit 0
else
    echo "test_models: FAIL ($FAILED failed, $PASSED passed)"
    exit 1
fi
