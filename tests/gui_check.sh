#!/bin/sh
# Type-check the GUI without building it.
#
# `nim check` performs semantic analysis only and never invokes a C compiler, so
# `importc` declarations carrying a `header:` pragma are checked without the
# header being present anywhere. The only real requirements are Nim 2 — Nim 1.6
# rejects owlkettle's `=destroy` signatures — and owlkettle's own source, which
# makes this the one check in the repository that runs on a host with no GTK.
#
# **This is not a build, and the difference has already cost one.** No C compiler
# runs, so nothing here sees a conflict between an `importc` carrying a `header:`
# and owlkettle's own header-less prototypes for the same function — which is a
# hard build failure that passes this check silently. It also sees no owlkettle
# runtime invariant: the `Button.shortcut` update assert, `Paned` refusing a
# child that changes type, or a container that hands its child the wrong size.
# `tests/gui_build.sh` is what compiles, links and maps the window, and only it
# can prove those.
#
# Usage: sh tests/gui_check.sh
#   NIM       — compiler to use (default: nim; must be 2.x)
#   OWLKETTLE — path to an owlkettle checkout, if it is not on the nimble path
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NIM=${NIM:-nim}
NIMBLE=$ROOT/jenova_core.nimble

# The switches `jenova_core.nimble` compiles `bin/jenova` with. Restated here
# rather than read out of that file, because it assembles them by Nim string
# concatenation across two constants and a shell parser of that is a second
# implementation of the build that can be quietly wrong. Restating alone is what
# left a dead `-d:gtk48` in this line for two sessions after the pin stopped
# defining it — so the two lists are compared below, and a check that mirrors
# the wrong flags now fails instead of claiming to mirror them.
FLAGS="-d:release -d:gtkminor=10 -d:adwminor=4 --mm:arc --hints:off"

## Every `-d:` and `--mm:` switch in the `.nimble`'s flag constants.
##
## Read out of the `const NimFlags`/`const GuiFlags` definitions and nowhere
## else: that file's prose says "No `-d:gtk48` beside it" in as many words, so a
## scrape of the whole file would compare this script against a comment about
## the build rather than against the build.
nimble_switches() {
  awk '
    /^const (NimFlags|GuiFlags)/ { grab = 1 }
    grab {
      sub(/#.*/, "")
      n = split($0, t, /[ \t"&]+/)
      for (i = 1; i <= n; i++)
        if (t[i] ~ /^-d:/ || t[i] ~ /^--mm:/) print t[i]
      if ($0 !~ /&[ \t]*$/) grab = 0
    }
  ' "$1" | sort -u
}

want=$(nimble_switches "$NIMBLE")
mine=$(for f in $FLAGS; do
         case $f in -d:*|--mm:*) echo "$f" ;; esac
       done | sort -u)
# An empty answer is a broken scrape, not agreement. Without this the comparison
# would pass by finding nothing on both sides the day the `.nimble` renames its
# constants, which is the same silent drift this exists to stop.
if [ -z "$want" ]; then
  echo "gui_check: no -d:/--mm: switches found in $NIMBLE."
  echo "gui_check: the flag constants were renamed or reshaped, so this script"
  echo "gui_check: can no longer tell whether it mirrors them. Fix the reader"
  echo "gui_check: in nimble_switches(), not this message."
  echo "gui_check: FAIL"
  exit 1
fi
if [ "$want" != "$mine" ]; then
  echo "gui_check: this script does not compile what jenova_core.nimble does."
  echo "gui_check: nimble: $(echo "$want" | tr '\n' ' ')"
  echo "gui_check: here:   $(echo "$mine" | tr '\n' ' ')"
  echo "gui_check: FAIL"
  exit 1
fi

set -- $FLAGS

case $("$NIM" --version | sed -n 1p) in
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

# The tree as it stands, on every host, so what this reports on is what a reader
# can go and look at. Nothing in `src/` is guarded by platform any more, so
# there is nothing a scratch copy could usefully differ in.
cd "$ROOT"
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
