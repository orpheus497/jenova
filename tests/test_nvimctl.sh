#!/bin/sh
# Script function and purpose: regression test for src/jenova/nvimctl.nim, the
# reader behind G-18 — "the ai able to read the active document" (D-AT).
#
# Unlike the other five suites this one has no jenova-core subcommand to curl, so
# it compiles tests/nvimctl_check.nim and drives that. The script owns the
# editor's lifecycle; the Nim file owns the assertions.
#
# Why the assertions are what they are: nvimctl does not fail by crashing. It
# fails by returning the file *on disk* instead of the buffer, which looks
# correct in every test where nothing has been edited — and is precisely wrong
# for the feature, whose whole purpose is reading unsaved work. So this runs
# twice: once clean, then again after editing the buffer WITHOUT saving. The
# second pass is also what proves these checks can go red (BRIEFING: a suite that
# passes while asserting nothing has shipped here twice).
#
# Action purpose: the listen socket lives in /tmp with a short name because
# `nvim --listen` rejects a path near 104 bytes — FreeBSD's sun_path limit,
# measured 2026-08-31, not read. A scratch dir deep under /tmp/… will fail.

set -u

JENOVA_ROOT="${JENOVA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export JENOVA_ROOT

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }

echo "== test_nvimctl =="

if ! command -v nvim >/dev/null 2>&1; then
    echo "  SKIP no nvim on PATH - nvimctl has nothing to talk to"
    exit 0
fi

WORK=$(mktemp -d) || exit 1
SOCK=/tmp/jenova-test-nvim.$$.sock
SAMPLE="$WORK/sample.txt"
DRIVER="$WORK/nvimctl_check"

cleanup() {
    [ -n "${NVIM_PID:-}" ] && kill "$NVIM_PID" 2>/dev/null
    rm -f "$SOCK"
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

printf 'line one\nline two\nline three\n' > "$SAMPLE"

if ! nim c --path:"$JENOVA_ROOT/src" --hints:off --mm:arc \
        -o:"$DRIVER" "$JENOVA_ROOT/tests/nvimctl_check.nim" >"$WORK/build.log" 2>&1; then
    fail "compile nvimctl_check" "$(tail -3 "$WORK/build.log")"
    echo "  $PASSED passed, $FAILED failed"
    exit 1
fi
pass "compile nvimctl_check"

rm -f "$SOCK"
nvim --headless --listen "$SOCK" "$SAMPLE" </dev/null >"$WORK/nvim.log" 2>&1 &
NVIM_PID=$!

# Action purpose: wait for the socket rather than sleeping a fixed interval — a
# fixed sleep is either flaky on a loaded machine or wasted time on an idle one.
i=0
while [ ! -S "$SOCK" ] && [ $i -lt 100 ]; do
    i=$((i + 1))
    command -v usleep >/dev/null 2>&1 && usleep 50000 || sleep 1
done

if [ ! -S "$SOCK" ]; then
    fail "nvim --listen created a socket" "$(cat "$WORK/nvim.log" 2>/dev/null)"
    echo "  $PASSED passed, $FAILED failed"
    exit 1
fi
pass "nvim --listen created a socket"

echo "  -- clean buffer --"
if "$DRIVER" "$SOCK" sample.txt; then
    pass "clean-buffer assertions"
else
    fail "clean-buffer assertions"
fi

# Action purpose: edit the buffer and never write it. This is the case the
# feature exists for, and the case a disk-reading implementation gets wrong.
nvim --server "$SOCK" --remote-expr 'setline(2,"EDITED IN BUFFER, NEVER SAVED")' \
    >/dev/null 2>&1

if grep -q "EDITED IN BUFFER" "$SAMPLE"; then
    fail "the edit stayed out of the file" "it was written to disk; the test proves nothing"
else
    pass "the edit stayed out of the file"
fi

echo "  -- dirty buffer, unsaved --"
if "$DRIVER" "$SOCK" sample.txt --expect-dirty; then
    pass "unsaved-buffer assertions"
else
    fail "unsaved-buffer assertions"
fi

echo "  $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
