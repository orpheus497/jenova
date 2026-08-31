#!/bin/sh
# Run every proxy regression check. See README.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RC=0

echo "== FFI flag assertions =="
JENOVA_ROOT="$ROOT" luajit "$HERE/test_ffi_flags.lua" || RC=1

echo
echo "== proxy acceptance suite =="
sh "$HERE/run.sh" || RC=1

echo
echo "== connection reaper (takes ~50s) =="
sh "$HERE/test_reaper.sh" || RC=1

echo
[ "$RC" -eq 0 ] && echo "PROXY CHECKS: PASS" || echo "PROXY CHECKS: FAIL"
exit $RC
