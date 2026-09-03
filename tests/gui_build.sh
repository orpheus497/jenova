#!/bin/sh
# Build the window, run it, and prove it works.
#
# `tests/gui_check.sh` type-checks `gui.nim` and stops there, because `nim
# check` performs semantic analysis and never invokes a C compiler. That is what
# makes it cheap, and it is also the boundary of what it can see. Two defects
# have already crossed that boundary in this branch:
#
#   1. `shortcuts.nim` declared `gtk_callback_action_new` with a `header:`
#      pragma, which made Nim `#include <gtk/gtk.h>` in a translation unit that
#      also carried owlkettle's header-less `void*` prototypes for
#      `gtk_box_new`, `gtk_box_append` and `gtk_box_remove`. The C compiler
#      rejected the conflicting declarations and `bin/jenova` did not build.
#      `nim check` passed, because no C compiler ran.
#   2. `ShortcutHost` wrapped the window in a GtkBox without setting the child's
#      expand flags, so the whole content collapsed to its natural height — the
#      canvas gone, the composer a fifth of the way down an empty window. No
#      static check reaches that: it is a property of the allocation GTK
#      performs at runtime.
#
# So this script goes three steps further than a check, and each step catches a
# class the step before it cannot:
#
#   compile + link  ->  the C-level errors `nim check` is blind to
#   --check         ->  GTK init, the stylesheet, and every widget's build hook
#   run + type      ->  the layout, which only exists once a window is mapped
#
# The last step asserts the property defect (2) broke, in the form a user would
# check it: **the composer is at the bottom of the window and accepts typing.**
# It clicks near the bottom edge, types, and requires that strip of pixels to
# change. See `composer_reachable` for why it is that and not a measurement of
# the picture — the measurement was tried first and passed against the defect.
#
# Usage: sh tests/gui_build.sh
#   NIM       — compiler to use (default: nim; must be 2.x)
#   OWLKETTLE — path to an owlkettle checkout, if it is not on the nimble path
#   JENOVA_GUI_NO_RUN=1 — build and `--check` only, skipping the mapped-window
#                         step. For a host with the toolkit but no X server.
#
# Requirements beyond `gui_check.sh`: the GTK4, libadwaita, GtkSourceView, VTE
# and D-Bus **development** packages, because this one really does compile C.
# The mapped-window step additionally needs an X server (`Xvfb` is enough) and
# ImageMagick's `import`; without them it reports what is missing and stops
# short rather than passing silently.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NIM=${NIM:-nim}
# The same switches `jenova_core.nimble` compiles with. Kept in step with it by
# hand: a build harness that builds something other than the shipped
# configuration proves nothing about the shipped configuration.
FLAGS="-d:release -d:gtkminor=10 -d:gtk48 -d:adwminor=4 --hints:off"

case $("$NIM" --version | head -1) in
  *"Version 2."*) ;;
  *) echo "gui_build: needs Nim 2 (owlkettle's =destroy signatures)"; exit 1 ;;
esac

[ -n "${OWLKETTLE:-}" ] && FLAGS="$FLAGS --path:$OWLKETTLE"

# Every pkg-config module the two binaries link. Named individually so a missing
# one is reported by name — "gtk4 not found" sends the reader to the right
# package, and "the build failed" does not.
missing=
for m in gtk4 libadwaita-1 gtksourceview-5 vte-2.91-gtk4 dbus-1 sqlite3 zlib; do
  pkg-config --exists "$m" 2>/dev/null || missing="$missing $m"
done
if [ -n "$missing" ]; then
  echo "gui_build: missing development packages:$missing"
  echo "gui_build: FAIL"
  exit 1
fi

if [ "$(uname -s)" = "FreeBSD" ]; then
  SRC=$ROOT
else
  SRC=$(mktemp -d)
  trap 'rm -rf "$SRC"' EXIT
  cp -r "$ROOT/src" "$SRC/"
  # As in `gui_check.sh`: the guards refuse to compile off FreeBSD by design,
  # and off FreeBSD is exactly where this script earns its keep. They are
  # neutralised in the copy and never in the tree.
  grep -rl "when not defined(freebsd)" "$SRC/src" | while read -r f; do
    sed -i.bak 's/when not defined(freebsd):/when false:/' "$f" && rm -f "$f.bak"
  done
fi

OUT=$(mktemp -d)
trap 'rm -rf "$SRC" "$OUT"' EXIT

echo "gui_build: compiling jenova-core"
cd "$SRC"
"$NIM" c $FLAGS --path:src --out:"$OUT/jenova-core" src/jenova_core.nim

# `--mm:arc` on the GUI only, exactly as `jenova_core.nimble` does it, and for
# the reason recorded there: owlkettle's `EventObj.widget` is a strong reference
# back to the state that owns the event, so ORC's cycle collector can free a
# widget state GTK still holds. Building this with a different memory
# management than the shipped binary would test a program that is not shipped.
echo "gui_build: compiling jenova"
"$NIM" c $FLAGS --mm:arc --path:src --out:"$OUT/jenova" src/jenova_gui.nim

# A scratch root, so the run cannot touch the developer's own database, notes or
# settings. `etc/` is copied because `config.load` reads it; `png/` because the
# sidebar logo is read from there and a missing one is survivable but noisy.
RT="$OUT/root"
mkdir -p "$RT"
cp -R "$ROOT/etc" "$RT/" 2>/dev/null || true
cp -R "$ROOT/png" "$RT/" 2>/dev/null || true

echo "gui_build: jenova --check"
# `--check` initialises GTK, installs the stylesheet and builds the whole widget
# tree without showing a window — so every `beforeBuild`, `afterBuild` and
# `connectEvents` hook in the program runs. It needs a display to reach
# `gdk_display_manager_get`, which is why it is inside the display block below
# on a host with no X server of its own.
run_check() {
  # Redirected, not piped. A pipeline reports the *last* command's status, so
  # `| tee` discarded `jenova`'s: a `--check` that crashed after printing its
  # line still satisfied the `grep` below and the whole step passed. POSIX `sh`
  # has no `pipefail` to lean on, so the pipe is removed instead.
  rc=0
  JENOVA_ROOT="$RT" JENOVA_NO_BACKENDS=1 CANVAS=0 \
    "$OUT/jenova" --check >"$OUT/check.out" 2>"$OUT/check.err" || rc=$?
  cat "$OUT/check.out"
  if [ "$rc" -ne 0 ]; then
    echo "gui_build: jenova --check exited $rc"
    cat "$OUT/check.err"
    return 1
  fi
  # GTK writes its complaints to stderr and still exits 0, so the exit status is
  # not the whole answer. A CSS parse error is the one this catches most often:
  # owlkettle takes the stylesheet at `brew` and a bad property is a warning,
  # not a failure.
  if grep -Eq "CRITICAL|WARNING \*\*: .*css|Theme parser" "$OUT/check.err"; then
    echo "gui_build: GTK complained during --check:"
    grep -E "CRITICAL|WARNING|Theme parser" "$OUT/check.err"
    return 1
  fi
  grep -q "window tree built" "$OUT/check.out"
}

# ---------------------------------------------------------------------------
# The mapped-window step
# ---------------------------------------------------------------------------

W=1200
H=800
# The strip of the window the composer must occupy, as a fraction of the
# **window's** height — not the screen's. The window opens at 900x680 on a
# 1200x800 screen, so a band measured against the screen is mostly the black
# space beside the window.
BAND_FRACTION=6

have() { command -v "$1" >/dev/null 2>&1; }

## The application window's geometry, as `WIDTH HEIGHT X Y`.
##
## From `xwininfo -root -children` and not `xdotool search --name`: GTK4 sets
## `_NET_WM_NAME` and leaves `WM_NAME` unset, and with no window manager running
## there is nothing to reconcile the two — so a search by name finds nothing at
## all under Xvfb. The largest child of the root is the window; the other child
## is GTK's own 1x1 helper.
window_geometry() {
  xwininfo -root -children 2>/dev/null |
    sed -n 's/.*  \([0-9][0-9]*\)x\([0-9][0-9]*\)+\([0-9-][0-9]*\)+\([0-9-][0-9]*\)  .*/\1 \2 \3 \4/p' |
    sort -k1 -n -r | head -1
}

## Type into the bottom of the window and prove the characters landed there.
##
## **This is a behavioural assertion, not a picture comparison, and the
## difference matters.** The first version measured the greyscale standard
## deviation of the bottom band and called a flat band a collapsed window. Run
## against the defect it was written for, it passed: the collapsed window still
## leaves its own rounded border and shadow in that band, so the deviation was
## 0.009 rather than 0 — small, non-zero, and only distinguishable from the
## healthy 0.075 by a threshold picked after seeing both numbers. A test whose
## pass condition is tuned to the answer is not a test.
##
## What is actually being asserted is the property a user would check: **the
## composer is at the bottom of the window and accepts typing.** So the script
## clicks a point near the bottom edge, types, and requires that band of pixels
## to change. Both halves have to hold, and each fails for a real reason:
##
## * a collapsed window puts the canvas under that point, so the click moves
##   focus off the composer and the characters go nowhere;
## * a window that draws but cannot be typed into fails too, which is worth
##   catching for its own sake.
##
## The comparison is `maxima` of the pixel difference, not a mean or a
## deviation: any changed pixel at all is a pass, so there is no threshold to
## tune. `CANVAS=0` is set on the run, so nothing else in the window moves
## between the two photographs.
composer_reachable() {
  set -- $(window_geometry)
  [ $# -eq 4 ] || { echo "gui_build: no application window on $DISPLAY"; return 1; }
  ww=$1; wh=$2; wx=$3; wy=$4
  echo "gui_build: window is ${ww}x${wh}+${wx}+${wy}"
  # A window smaller than this has not been mapped at the size `view` asked for,
  # which is its own failure and would make the geometry below meaningless.
  [ "$ww" -ge 400 ] && [ "$wh" -ge 300 ] || {
    echo "gui_build: the window mapped at ${ww}x${wh} — too small to judge"
    return 1
  }

  band_h=$((wh / BAND_FRACTION))
  band_y=$((wy + wh - band_h - 8))          # 8px inside the rounded bottom edge
  crop="${ww}x${band_h}+${wx}+${band_y}"

  import -window root "$OUT/before.png"
  # The left third of the composer row: the draft area. Deliberately not the
  # centre — the Send button is there, and a probe that sends a message would be
  # testing the backend rather than the layout.
  xdotool mousemove $((wx + ww / 6)) $((wy + wh - 40)) click 1
  sleep 1
  xdotool type --delay 40 "gui_build probe"
  sleep 2
  import -window root "$OUT/after.png"

  convert "$OUT/before.png" -crop "$crop" +repage "$OUT/before-band.png"
  convert "$OUT/after.png"  -crop "$crop" +repage "$OUT/after-band.png"
  d=$(convert "$OUT/before-band.png" "$OUT/after-band.png" \
      -compose difference -composite -colorspace Gray \
      -format "%[fx:maxima]" info: 2>/dev/null)
  [ -n "$d" ] || return 1
  echo "gui_build: largest pixel change in the composer row = $d"
  awk -v v="$d" 'BEGIN { exit !(v > 0.05) }' || { PROBE_FAILED=typing; return 1; }

  # The shortcut, asserted the only way it can be: by its effect. `<Ctrl>n`
  # starts a new conversation, which empties the composer — so the same band
  # that just proved typing works now has to change back.
  #
  # This is the one property `gui_check.sh` explicitly could not reach.
  # `ShortcutHost` installs a controller at `GTK_SHORTCUT_SCOPE_MANAGED` and
  # whether GTK routes that to the window from a widget several levels down is a
  # runtime fact, not a type.
  # **A control shot first, and it is not optional.** The first version of this
  # measured the peak difference and passed with the binding deleted: a blinking
  # caret moves one pixel to maximum, which is indistinguishable from a cleared
  # line by that measure. So the noise is measured rather than assumed — two
  # shots with nothing happening between them — and the shortcut has to beat it.
  sleep 2
  import -window root "$OUT/idle.png"
  convert "$OUT/idle.png" -crop "$crop" +repage "$OUT/idle-band.png"
  noise=$(convert "$OUT/after-band.png" "$OUT/idle-band.png" \
          -compose difference -composite -colorspace Gray \
          -format "%[fx:mean]" info: 2>/dev/null)

  xdotool key ctrl+n
  sleep 2
  import -window root "$OUT/newchat.png"
  convert "$OUT/newchat.png" -crop "$crop" +repage "$OUT/newchat-band.png"
  n=$(convert "$OUT/idle-band.png" "$OUT/newchat-band.png" \
      -compose difference -composite -colorspace Gray \
      -format "%[fx:mean]" info: 2>/dev/null)
  [ -n "$n" ] && [ -n "$noise" ] || return 1
  echo "gui_build: composer mean change — idle $noise, after <Ctrl>n $n"
  # Mean, not peak: clearing a line of text moves hundreds of pixels and a caret
  # moves a handful, which only a mean can tell apart. Four times the measured
  # idle noise, and above a floor so a perfectly still window cannot divide by
  # nothing.
  awk -v v="$n" -v b="$noise" 'BEGIN { exit !(v > 0.0004 && v > b * 4) }' || {
    PROBE_FAILED=shortcut
    return 1
  }
  echo "gui_build: window-wide shortcuts fire"
}

if [ "${JENOVA_GUI_NO_RUN:-}" = "1" ]; then
  echo "gui_build: JENOVA_GUI_NO_RUN=1, skipping the mapped-window step"
  if [ -n "${DISPLAY:-}" ]; then run_check; fi
  echo "gui_build: PASS (build only)"
  exit 0
fi

if [ -z "${DISPLAY:-}" ]; then
  have Xvfb || {
    echo "gui_build: no DISPLAY and no Xvfb — cannot map a window."
    echo "gui_build: set JENOVA_GUI_NO_RUN=1 to accept the build-only result."
    echo "gui_build: FAIL"
    exit 1
  }
  # A display number unlikely to collide with a developer's own session.
  DISPLAY=:87
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 "${W}x${H}x24" >/dev/null 2>&1 &
  XPID=$!
  trap 'kill $XPID 2>/dev/null; rm -rf "$SRC" "$OUT"' EXIT
  # Xvfb answers before it is listening; a short settle is cheaper and more
  # reliable than racing the first connection.
  sleep 2
fi

have import && have convert && have xwininfo && have xdotool || {
  echo "gui_build: ImageMagick's import/convert, xwininfo and xdotool are needed to prove the window works"
  echo "gui_build: FAIL"
  exit 1
}

run_check || { echo "gui_build: FAIL (--check)"; exit 1; }

echo "gui_build: running the window"
# A port of its own, so the run cannot collide with a server the developer has
# up. `--no-tray` because a StatusNotifierWatcher is a desktop service and its
# absence is not this script's subject.
JENOVA_ROOT="$RT" JENOVA_NO_BACKENDS=1 CANVAS=0 PORT=18787 \
  "$OUT/jenova" --no-tray >"$OUT/run.log" 2>&1 &
GPID=$!
# Long enough for the window to map and paint its first frame. The three worker
# threads and the HTTP listener come up first; this is not a health wait, it is
# a paint wait.
sleep 6

rc=0
if ! kill -0 "$GPID" 2>/dev/null; then
  echo "gui_build: the window exited before it could be photographed:"
  cat "$OUT/run.log"
  rc=1
elif composer_reachable; then
  echo "gui_build: the composer is at the bottom of the window and takes typing"
elif [ "${PROBE_FAILED:-}" = "shortcut" ]; then
  echo "gui_build: <Ctrl>n did not reach the window. The composer takes typing,"
  echo "gui_build: so the window is laid out — what failed is the shortcut"
  echo "gui_build: controller in shortcuts.nim reaching it from where it is"
  echo "gui_build: installed. $OUT is kept for inspection."
  KEEP=1
  rc=1
else
  echo "gui_build: typing at the bottom of the window changed nothing there."
  echo "gui_build: either the content did not fill the window — the shape of the"
  echo "gui_build: GtkBox-without-expand defect — or the composer does not accept"
  echo "gui_build: input. $OUT is kept for inspection."
  KEEP=1
  rc=1
fi

kill "$GPID" 2>/dev/null || true
sleep 1
kill -9 "$GPID" 2>/dev/null || true

# Reported whatever the outcome: a GTK criticality during the run is worth
# seeing even when the picture came out right.
if grep -Eq "CRITICAL|assertion" "$OUT/run.log"; then
  echo "gui_build: GTK complained during the run:"
  grep -E "CRITICAL|assertion" "$OUT/run.log"
  rc=1
fi

if [ "$rc" -ne 0 ]; then
  if [ "${KEEP:-}" = "1" ]; then
    # The two photographs are the whole evidence for the failure, and a trap
    # that deletes them leaves the reader with nothing to look at.
    EV=${TMPDIR:-/tmp}/gui_build-evidence.$$
    mkdir -p "$EV"
    cp "$OUT/before.png" "$OUT/after.png" "$EV/" 2>/dev/null || true
    cp "$OUT/run.log" "$EV/" 2>/dev/null || true
    echo "gui_build: before/after photographs written to $EV"
  fi
  echo "gui_build: FAIL"
  exit 1
fi
echo "gui_build: PASS"
