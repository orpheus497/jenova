#!/bin/sh
# Type-check the GUI without building it.
#
# `gui.nim` links owlkettle, which needs GTK4 and libadwaita, which need
# FreeBSD — so on any other host the window went unchecked and its errors were
# found by the next FreeBSD build. It does not have to be that way: `nim check`
# performs semantic analysis only and never invokes a C compiler, so `importc`
# declarations carrying `header:` never need the header to be present. The only
# real requirements are Nim 2 (Nim 1.6 rejects owlkettle's `=destroy`
# signatures) and owlkettle's own source.
#
# On FreeBSD this checks the tree as it stands. Elsewhere it copies `src/` to a
# scratch directory and neutralises the two `when not defined(freebsd)` guards,
# because those are the only thing that stops the module set from resolving.
#
# **This is not a build, and the difference has already cost one.** No C
# compiler runs, so nothing here sees a conflict between an `importc` carrying a
# `header:` and owlkettle's own header-less prototypes for the same function —
# which is a hard build failure that passes this check silently. It also sees no
# owlkettle runtime invariant: the `Button.shortcut` update assert, `Paned`
# refusing a child that changes type, or a container that hands its child the
# wrong size. `nimble gui` on FreeBSD remains the only thing that proves those.
#
# Usage: sh tests/gui_check.sh
#   NIM       — compiler to use (default: nim; must be 2.x)
#   OWLKETTLE — path to an owlkettle checkout, if it is not on the nimble path
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NIM=${NIM:-nim}
set -- -d:gtkminor=10 -d:gtk48 -d:adwminor=4 --mm:arc --hints:off

case $("$NIM" --version | head -1) in
  *"Version 2."*) ;;
  *) echo "gui_check: needs Nim 2 (owlkettle's =destroy signatures)"; exit 1 ;;
esac

[ -n "${OWLKETTLE:-}" ] && set -- "$@" "--path:$OWLKETTLE"

# Asked before the real check, because owlkettle being unreachable does not
# produce one honest error — it produces a wall of them. Every module that
# imports it fails, every type it declares becomes undeclared, and the first
# thing printed is a cascade several hundred lines down in `gui.nim` that reads
# like a defect in this repository. Two lines here name the actual cause.
PRE=$(mktemp -d)
echo "import owlkettle" > "$PRE/owlprobe.nim"
if ! "$NIM" check "$@" --hints:off "$PRE/owlprobe.nim" >/dev/null 2>&1; then
  rm -rf "$PRE"
  echo "gui_check: owlkettle is not on the compiler's path."
  echo "gui_check: install it (\`nimble install\`, which reads the revision"
  echo "gui_check: jenova_core.nimble pins) or point OWLKETTLE at a checkout:"
  echo "gui_check:   OWLKETTLE=/path/to/owlkettle sh tests/gui_check.sh"
  exit 1
fi
rm -rf "$PRE"

if [ "$(uname -s)" = "FreeBSD" ]; then
  SRC=$ROOT
else
  SRC=$(mktemp -d)
  trap 'rm -rf "$SRC"' EXIT
  cp -r "$ROOT/src" "$SRC/"
  # The guards refuse to compile off FreeBSD by design. Off FreeBSD is exactly
  # where this script is useful, so they are disabled in the copy and never in
  # the tree.
  grep -rl "when not defined(freebsd)" "$SRC/src" | while read -r f; do
    sed -i.bak 's/when not defined(freebsd):/when false:/' "$f" && rm -f "$f.bak"
  done
fi

cd "$SRC"
# The status is captured, not discarded. `|| true` threw it away and the verdict
# rested entirely on finding the string `Error:` in the output — so a check that
# died without printing one (killed, out of memory, a compiler crash, a future
# Nim wording its diagnostics differently) was reported as a PASS. The status is
# the compiler's own answer to the question this script asks; the grep stays as
# a second gate, not the only one.
rc=0
out=$("$NIM" check "$@" --path:src src/jenova_gui.nim 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "$out"
  echo
  echo "gui_check: nim check exited $rc"
  echo "gui_check: FAIL"
  exit 1
fi
echo "$out" | grep -vE "^Hint|UnusedImport" || true

if echo "$out" | grep -q "Error:"; then
  echo
  echo "gui_check: nim check exited 0 but reported an error — treating it as one."
  echo "gui_check: FAIL"
  exit 1
fi
echo "gui_check: PASS"
