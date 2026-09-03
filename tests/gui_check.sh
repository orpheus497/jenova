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
out=$("$NIM" check "$@" --path:src src/jenova_gui.nim 2>&1) || true
echo "$out" | grep -vE "^Hint|UnusedImport" || true

if echo "$out" | grep -q "Error:"; then
  echo
  echo "gui_check: FAIL"
  exit 1
fi
echo "gui_check: PASS"
