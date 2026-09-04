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
#   seed + copy     ->  the transcript, which drew nothing in any earlier run
#   seed markdown   ->  the code-block and table widgets, which nothing had ever
#                       built, and the Pango markup a reply's emphasis becomes,
#                       which is refused whole and drawn as an empty label
#
# The composer step asserts the property defect (2) broke, in the form a user
# would check it: **the composer is at the bottom of the window and accepts typing.**
# It clicks near the bottom edge, types, and requires that strip of pixels to
# change. See `composer_reachable` for why it is that and not a measurement of
# the picture — the measurement was tried first and passed against the defect.
#
# Usage: sh tests/gui_build.sh
#   NIM       — compiler to use (default: nim; must be 2.x)
#   OWLKETTLE — path to an owlkettle checkout, if it is not on the nimble path.
#               It must be the revision `jenova_core.nimble` pins: the `v3.0.0`
#               tag and `main` both call themselves 3.0.0 and differ in what
#               they offer, and `gui.nim` uses `ToastOverlay`, which is only on
#               the latter. The guard below says so rather than letting it
#               surface as an undeclared identifier.
#   JENOVA_GUI_NO_RUN=1 — build and `--check` only, skipping the mapped-window
#                         step. For a host with the toolkit but no X server.
#
# Requirements beyond `gui_check.sh`: the GTK4, libadwaita, GtkSourceView, VTE
# and D-Bus **development** packages, because this one really does compile C.
# The mapped-window step additionally needs an X server (`Xvfb` is enough),
# ImageMagick's `import`, `xdotool`, `nc` to seed the conversation and `xclip`
# to read back what the transcript's Copy button wrote; without them it reports
# what is missing and stops short rather than passing silently.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NIM=${NIM:-nim}
# The same switches `jenova_core.nimble` compiles with. Kept in step with it by
# hand: a build harness that builds something other than the shipped
# configuration proves nothing about the shipped configuration.
FLAGS="-d:release -d:gtkminor=10 -d:adwminor=4 --hints:off"

# `sed -n 1p` and not `head -1`: head closes the pipe as soon as it has its
# line, `nim` takes SIGPIPE mid-write, and Nim's `syncio` turns that into
# `Error: unhandled exception: errno: 32 'Broken pipe'` printed above this
# script's own first line. It is a race on how fast the compiler writes, so it
# appears on some runs and not others — and a gate that prints an unhandled
# exception on a passing run teaches its reader to skim the one line that will
# eventually matter. `sed` consumes its input to the end.
case $("$NIM" --version | sed -n 1p) in
  *"Version 2."*) ;;
  *) echo "gui_build: needs Nim 2 (owlkettle's =destroy signatures)"; exit 1 ;;
esac

if [ -n "${OWLKETTLE:-}" ]; then
  FLAGS="$FLAGS --path:$OWLKETTLE"
  # One grep, and it names the symptom. Without it a checkout of the tag fails
  # with `undeclared identifier: 'ToastOverlay'` from inside a `gui:` block,
  # which reads as a defect in this repository rather than in the dependency.
  if ! grep -q "renderable ToastOverlay" "$OWLKETTLE/owlkettle/adw.nim" 2>/dev/null
  then
    echo "gui_build: $OWLKETTLE has no ToastOverlay — that is the v3.0.0 tag."
    echo "gui_build: jenova_core.nimble pins a later commit; check out that one."
    echo "gui_build: FAIL"
    exit 1
  fi
fi

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

# `SCRATCH` is what the trap is allowed to delete, and it is set only where a
# directory was actually created here. On FreeBSD `SRC` is the working tree
# itself, so `SRC` must never reach an `rm -rf` — the two are kept as separate
# variables for exactly that reason and not merged back.
SCRATCH=
if [ "$(uname -s)" = "FreeBSD" ]; then
  SRC=$ROOT
else
  SRC=$(mktemp -d)
  SCRATCH=$SRC
  trap 'rm -rf "$SCRATCH"' EXIT
  cp -r "$ROOT/src" "$SRC/"
  # As in `gui_check.sh`: the guards refuse to compile off FreeBSD by design,
  # and off FreeBSD is exactly where this script earns its keep. They are
  # neutralised in the copy and never in the tree.
  grep -rl "when not defined(freebsd)" "$SRC/src" | while read -r f; do
    sed -i.bak 's/when not defined(freebsd):/when false:/' "$f" && rm -f "$f.bak"
  done
fi

OUT=$(mktemp -d)
trap 'rm -rf $SCRATCH "$OUT"' EXIT

# Action purpose: a cache inside this run's own temp directory, thrown away
# with it. Nim's default cache is keyed on the *project name*, not the project
# path, so `~/.cache/nim/jenova_core_r` is shared by every copy of this tree on
# the machine — and the copy above is a fresh `mktemp -d` on every run. A cache
# holding objects from a different copy of these sources links with ~20
# `undefined reference to` errors for generic instantiations
# (`hasKey__jenovaZmarkdown_u2147` and its like), ending in `final link failed:
# bad value`. That reads as a defect in `markdown.nim`, names a file nothing is
# wrong with, and is why this gate cannot share a cache with anything.
NIMCACHE="$OUT/nimcache"

echo "gui_build: compiling jenova-core"
cd "$SRC"
"$NIM" c $FLAGS --nimcache:"$NIMCACHE/core" --path:src \
  --out:"$OUT/jenova-core" src/jenova_core.nim

# `--mm:arc` on the GUI only, exactly as `jenova_core.nimble` does it, and for
# the reason recorded there: owlkettle's `EventObj.widget` is a strong reference
# back to the state that owns the event, so ORC's cycle collector can free a
# widget state GTK still holds. Building this with a different memory
# management than the shipped binary would test a program that is not shipped.
#
# Its own cache directory beside the first: these are two separate programs
# built with different memory management, and one directory cannot hold both.
echo "gui_build: compiling jenova"
"$NIM" c $FLAGS --mm:arc --nimcache:"$NIMCACHE/gui" --path:src \
  --out:"$OUT/jenova" src/jenova_gui.nim

# Two roots, because `paths.resolve` reads two variables and they mean
# different things. `JENOVA_ROOT` is the install tree — `etc/` because
# `config.load` reads it, `png/` because the sidebar logo is read from there and
# a missing one is survivable but noisy.
RT="$OUT/root"
mkdir -p "$RT"
cp -R "$ROOT/etc" "$RT/" 2>/dev/null || true
cp -R "$ROOT/png" "$RT/" 2>/dev/null || true

# `JCA_HOME` is the DATA tree, and it has to be set explicitly: it does not
# derive from `JENOVA_ROOT`, it defaults to `$HOME/Jenova`
# (`paths.nim:66`). Setting only `JENOVA_ROOT` therefore ran both the `--check`
# and the mapped window against the developer's live database, notes,
# workspaces, logs and cache — `--check` builds the whole widget tree, so it
# opens the database and migrates it. That is the defect `test_api_db.sh`
# records having destroyed a real conversation database, and this is its fix.
JH="$OUT/jcahome"
mkdir -p "$JH/.system" "$JH/Workspaces"

# ---------------------------------------------------------------------------
# A conversation to look at
# ---------------------------------------------------------------------------
# Until this existed, nothing in the repository had ever displayed a chat
# message. The window starts on `latestConversation()`, which on an empty
# database is a new empty one — so every check here passed against a transcript
# that was drawing nothing, and a change that broke message rendering entirely
# would have gone through green.
#
# Seeded over the same `/api/db/*` routes `test_api_db.sh` uses, rather than by
# writing SQL, so the schema has one owner and this cannot drift from it.
SEED_PORT=18788
SEED_MSGS=6
seed_text() {
  # Message 4 is the assistant turn that is actually *markdown*, and until it
  # existed every message in this conversation was one plain sentence — so the
  # code-block, table and emphasis branches of `mdBlock` had never been built
  # by anything, in any test, on any host. Their `beforeBuild` hooks construct
  # a GtkSourceView and a GtkPopover, which is the class of work `--check`
  # exists to run.
  #
  # It also carries `***bold italic***`, which is the one thing here aimed at
  # the *renderer* rather than the widgets: the emphasis passes used to close
  # bold before italic and hand Pango `<b><i>x</b></i>`, and Pango answers
  # malformed markup by refusing the whole string and drawing an empty label.
  # That is invisible to a compile and to a screenshot; it is visible in the
  # log, which is why `run_check` and the run both grep for it now.
  #
  # Deliberately short. The transcript follows to the bottom, so every line
  # added here pushes message 1 — the one the clipboard assertion reads —
  # closer to the top edge of the viewport.
  #
  # The line breaks are emitted as the two characters `\` and `n`, not as real
  # newlines: this is substituted straight into a JSON body, and a raw newline
  # inside a JSON string is a parse error rather than a line break.
  if [ "$1" = 4 ]; then
    printf 'Seeded message 4 is ***markdown***:\\n\\n```sh\\necho one\\n```\\n\\n| a | b |\\n|---|---|\\n| 1 | 2 |'
  else
    printf 'Seeded message %s: the transcript has to render this line.' "$1"
  fi
}

seed_post() { # path body
  printf 'POST %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
    "$1" "${#2}" "$2" | nc 127.0.0.1 "$SEED_PORT" >/dev/null
}

echo "gui_build: seeding a conversation"
JENOVA_ROOT="$RT" JCA_HOME="$JH" JENOVA_NO_BACKENDS=1 JENOVA_PORT="$SEED_PORT" \
  "$OUT/jenova-core" serve >"$OUT/seed.log" 2>&1 &
SEEDPID=$!

# Waited on, not slept through. A fixed `sleep 2` is a guess about how long the
# process takes to bind, and it is wrong in both directions: too short on a
# loaded runner, so the first `seed_post` writes into a closed socket and the
# transcript is silently short; too long everywhere else. The socket answers or
# it does not, so that is what is asked. Any status line counts — the question
# is whether the listener is up, not what it thinks of the path.
seed_ready=0
i=0
while [ "$i" -lt 40 ]; do
  if printf 'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' \
     | nc 127.0.0.1 "$SEED_PORT" 2>/dev/null | grep -q "^HTTP/"; then
    seed_ready=1
    break
  fi
  # The server dying is not something to keep waiting for.
  kill -0 "$SEEDPID" 2>/dev/null || break
  sleep 0.25 2>/dev/null || sleep 1
  i=$((i + 1))
done
[ "$seed_ready" -eq 1 ] || {
  echo "gui_build: the seeding server never answered on 127.0.0.1:$SEED_PORT"
  cat "$OUT/seed.log" 2>/dev/null
  kill "$SEEDPID" 2>/dev/null || true
  exit 1
}

seed_post /api/db/workspaces '{"id":"w1","name":"Work"}'
seed_post /api/db/conversations \
  '{"id":"seeded","name":"Seeded chat","lastModified":1730000000,"workspaceId":"w1"}'
# `parent` and not `parentId`: the window does not show every row of a
# conversation, it shows one path through the reply tree (`pathOf`), so messages
# with no parent chain are not a short transcript — they are one message.
i=1
prev=""
while [ "$i" -le "$SEED_MSGS" ]; do
  # An `&&` chain here and not an `if` would be fatal: this runs at the top
  # level under `set -e`, and the chain evaluates to 1 on every odd `i`.
  if [ $((i % 2)) -eq 0 ]; then role=assistant; else role=user; fi
  seed_post /api/db/messages \
    "{\"id\":\"m$i\",\"convId\":\"seeded\",\"role\":\"$role\",\"content\":\"$(seed_text "$i")\",\"timestamp\":$((1730000000 + i)),\"parent\":\"$prev\"}"
  prev="m$i"
  i=$((i + 1))
done
kill $SEEDPID 2>/dev/null || true
wait $SEEDPID 2>/dev/null || true

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
  JENOVA_ROOT="$RT" JCA_HOME="$JH" JENOVA_NO_BACKENDS=1 CANVAS=0 \
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
  #
  # `error parsing markup` is the second, and it is the only report there is
  # that a message rendered as an **empty label**. Pango's markup parser is
  # XML-shaped: one crossed tag and it refuses the whole string, the label draws
  # nothing, and every other check here — the exit status, the picture, the
  # clipboard read on a different card — passes. Message 4 exists to put
  # emphasis through that parser.
  if grep -Eq "CRITICAL|WARNING \*\*: .*css|Theme parser|error parsing markup" \
     "$OUT/check.err"; then
    echo "gui_build: GTK complained during --check:"
    grep -E "CRITICAL|WARNING|Theme parser|markup" "$OUT/check.err"
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
    sort -k1 -n -r | sed -n 1p
}

## Prove the transcript rendered the seeded conversation.
##
## **The assertion is the message's own text, not a picture of it.** Every pixel
## measure tried first failed to separate the two states: the empty transcript
## draws a large icon and a bold heading over the same canvas artwork the cards
## sit on, so its greyscale mean (0.971) and deviation (0.130) bracket the
## seeded one (0.982 / 0.103) from the wrong side. A threshold there would have
## been a number picked after seeing both answers, which is the defect this file
## already records for the composer test.
##
## So it clicks Copy on the first card and reads the clipboard back. The text
## either is message 1's or it is not, and no blank card, missing card or
## transposed order can produce a match.
##
## **Nothing here is a measured screen coordinate.** The first version pinned
## the button at 50,195 and was broken within the hour by a `Clamp` and an
## `Avatar` — ordinary work on the very widget being tested. Instead the card's
## left edge is found from the image (it is the only strongly saturated column
## in the transcript: the role-coloured accent border), and the row is found by
## clicking down the column until something lands on the clipboard.
##
## `CARD_COPY_DX` is the one offset left, and it is measured from the card's own
## edge rather than the window's, so it survives anything that moves the card.
## It is deliberately small: the action row runs copy, fork, edit, delete at
## roughly +29, +67, +105 and +143 from that edge, so **staying near the left
## keeps the scan away from Delete**, which a search for a button must never
## reach.
CARD_COPY_DX=29
SCAN_STEP=10

## The screen x of the leftmost card edge, or nothing if no card is drawn.
##
## Two different empty answers, and they are separated here rather than at the
## call site: `convert` failing measured nothing, while `convert` succeeding and
## finding no saturated column means no card drew. The first exits non-zero, the
## second exits zero with no output. Piping straight into `sed` would lose the
## distinction — a pipeline reports its *last* command's status, and `awk`
## succeeds on empty input — so the scan is written to a file first.
card_accent_x() { # image wx wy ww wh
  convert "$1" -crop "$(($4 - 40))x$(($5 / 2))+$(($2 + 20))+$(($3 + $5 / 8))" +repage \
    -colorspace HSL -channel G -separate -resize "$(($4 - 40))x1!" -depth 8 \
    txt:- >"$OUT/accent.txt" 2>/dev/null || return 1
  sed -n 's/^\([0-9]*\),0: .*gray(\([0-9]*\)).*/\1 \2/p' "$OUT/accent.txt" |
    awk -v ox=$(($2 + 20)) '$2 > 40 { print $1 + ox; exit }'
}

transcript_renders() {
  set -- $(window_geometry)
  [ $# -eq 4 ] || { echo "gui_build: no window to read the transcript from"; return 1; }
  ww=$1; wh=$2; wx=$3; wy=$4

  import -window root "$OUT/transcript.png" 2>/dev/null || {
    TRANSCRIPT_FAILED=measure
    return 1
  }
  ax=$(card_accent_x "$OUT/transcript.png" "$wx" "$wy" "$ww" "$wh") || {
    TRANSCRIPT_FAILED=measure
    return 1
  }
  if [ -z "$ax" ]; then
    TRANSCRIPT_FAILED=nocards
    return 1
  fi

  cx=$((ax + CARD_COPY_DX))
  want=$(seed_text 1)
  y=$((wy + wh / 7))
  ylast=$((wy + wh / 2))
  while [ "$y" -le "$ylast" ]; do
    # Cleared before every click, so a value left by an earlier one cannot be
    # mistaken for this one's.
    printf '' | xclip -i -selection clipboard >/dev/null 2>&1 || true
    xdotool mousemove "$cx" "$y" click 1 ||
      { TRANSCRIPT_FAILED=measure; return 1; }
    sleep 0.4
    got=$(xclip -o -selection clipboard 2>/dev/null || true)
    if [ -n "$got" ]; then
      [ "$got" = "$want" ] && return 0
      TRANSCRIPT_FAILED=wrongtext
      echo "gui_build:   wanted: $want"
      echo "gui_build:   got:    $got"
      return 1
    fi
    y=$((y + SCAN_STEP))
  done
  TRANSCRIPT_FAILED=nobutton
  return 1
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
## deviation — one changed pixel anywhere in the band is enough, so the measure
## does not dilute with the size of the band the way a mean does.
##
## **There is still a threshold, and the comment used to deny it.** The test is
## `> 0.05`, not `> 0`, because the band is captured from a live X server: PNG
## quantisation and the software renderer's dithering move the odd pixel by a
## least-significant bit between two shots of an unchanged window, so a literal
## `> 0` passes against a composer that took no input at all. 0.05 is ~13 levels
## out of 255 — far above that noise and far below the change a line of typed
## text makes, which saturates the measure at 1.0. It is a floor on noise, not a
## tuned separation between two observed answers: the failing case here measures
## 0, and the note above about a threshold picked after seeing both numbers is
## about the mean-based version this replaced.
##
## `CANVAS=0` is set on the run, so nothing else in the window moves between the
## two photographs.
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

  # **Every capture and conversion is guarded, and that is not decoration.**
  # This runs under `set -e`, so a bare `import` or `convert` that failed — no
  # X server left, ImageMagick's policy refusing the format, a full disk — aborted
  # the whole script at that line. `PROBE_FAILED=measure` was then never set, the
  # harness-versus-GUI distinction below never printed, and `kill "$GPID"` never
  # ran, so the window was left behind. A failure here has to `return 1` like any
  # other, which is what puts it back on the reporting and cleanup path.
  import -window root "$OUT/before.png" || { PROBE_FAILED=measure; return 1; }
  # The left third of the composer row: the draft area. Deliberately not the
  # centre — the Send button is there, and a probe that sends a message would be
  # testing the backend rather than the layout.
  xdotool mousemove $((wx + ww / 6)) $((wy + wh - 40)) click 1 ||
    { PROBE_FAILED=measure; return 1; }
  sleep 1
  xdotool type --delay 40 "gui_build probe" ||
    { PROBE_FAILED=measure; return 1; }
  sleep 2
  import -window root "$OUT/after.png" || { PROBE_FAILED=measure; return 1; }

  convert "$OUT/before.png" -crop "$crop" +repage "$OUT/before-band.png" ||
    { PROBE_FAILED=measure; return 1; }
  convert "$OUT/after.png"  -crop "$crop" +repage "$OUT/after-band.png" ||
    { PROBE_FAILED=measure; return 1; }
  # `|| true` on the substitution and the emptiness test right after it: a
  # failing `$(...)` on the right of an assignment is itself a failing command
  # under `set -e`, so without this the guard below could never be reached.
  d=$(convert "$OUT/before-band.png" "$OUT/after-band.png" \
      -compose difference -composite -colorspace Gray \
      -format "%[fx:maxima]" info: 2>/dev/null || true)
  [ -n "$d" ] || { PROBE_FAILED=measure; return 1; }
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
  import -window root "$OUT/idle.png" || { PROBE_FAILED=measure; return 1; }
  convert "$OUT/idle.png" -crop "$crop" +repage "$OUT/idle-band.png" ||
    { PROBE_FAILED=measure; return 1; }
  noise=$(convert "$OUT/after-band.png" "$OUT/idle-band.png" \
          -compose difference -composite -colorspace Gray \
          -format "%[fx:mean]" info: 2>/dev/null || true)

  xdotool key ctrl+n || { PROBE_FAILED=measure; return 1; }
  # **Sampled over time, not photographed once after a fixed sleep.** A single
  # `sleep 2` was enough while the transcript was a plain list of widgets and
  # became marginal when it became a `ListView` over a `Clamp` — the software
  # renderer under Xvfb had not finished the frame, so the shot caught the
  # window mid-redraw and the change measured 0.0123 against a 0.0089 threshold
  # on one run and failed outright on another. Waiting for the window to go
  # perfectly still is not available either: the composer's caret blinks, which
  # is the idle noise measured just above.
  #
  # So the largest change **across several frames** is taken. This is still a
  # mean over pixels — the defect this file warns about is a peak over *pixels*,
  # where one blinking caret reaches the maximum. A maximum over *time* of that
  # mean cannot be reached by a caret: it moves the same handful of pixels in
  # every frame.
  n=0
  i=0
  while [ "$i" -lt 8 ]; do
    sleep 1
    import -window root "$OUT/newchat.png" || { PROBE_FAILED=measure; return 1; }
    convert "$OUT/newchat.png" -crop "$crop" +repage "$OUT/newchat-band.png" ||
      { PROBE_FAILED=measure; return 1; }
    d=$(convert "$OUT/idle-band.png" "$OUT/newchat-band.png" \
        -compose difference -composite -colorspace Gray \
        -format "%[fx:mean]" info: 2>/dev/null || true)
    # A `convert` that produced nothing measured nothing. Breaking here would
    # leave `n` at 0, which is non-empty, passes the emptiness check below and
    # then fails the threshold — reporting a broken ImageMagick as a missing
    # `<Ctrl>n` binding. The two are not the same failure, so they do not share
    # an exit path.
    [ -n "$d" ] || { PROBE_FAILED=measure; return 1; }
    n=$(awk -v a="$n" -v b="$d" 'BEGIN { print (b > a ? b : a) }')
    # Once it is clearly past the bar there is nothing to gain by watching
    # longer, and the run is eight seconds shorter.
    awk -v v="$n" -v b="$noise" 'BEGIN { exit !(v > 0.0004 && v > b * 4) }' && break
    i=$((i + 1))
  done
  [ -n "$n" ] && [ -n "$noise" ] || { PROBE_FAILED=measure; return 1; }
  echo "gui_build: composer mean change — idle $noise, after <Ctrl>n $n"
  # Four times the measured idle noise, and above a floor so a perfectly still
  # window cannot divide by nothing.
  awk -v v="$n" -v b="$noise" 'BEGIN { exit !(v > 0.0004 && v > b * 4) }' || {
    PROBE_FAILED=shortcut
    return 1
  }
  echo "gui_build: window-wide shortcuts fire"
}

if [ "${JENOVA_GUI_NO_RUN:-}" = "1" ]; then
  echo "gui_build: JENOVA_GUI_NO_RUN=1, skipping the mapped-window step"
  # The status is propagated, not swallowed by the `if`. As a condition,
  # `run_check`'s answer was discarded — so on a host with a display but a
  # `--check` that crashed, or one GTK filled with criticals, this printed PASS
  # and exited 0. That is the one path a CI runner without an X server takes, so
  # the build-only mode was the mode least able to report a failure.
  if [ -n "${DISPLAY:-}" ]; then
    run_check || { echo "gui_build: FAIL (--check)"; exit 1; }
  fi
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
  # `$SCRATCH` and never `$SRC`, for the reason given where it is set: on
  # FreeBSD `SRC` is the working tree, and this trap would have deleted the
  # repository. Empty there, so this reduces to removing the output directory.
  trap 'kill $XPID 2>/dev/null; rm -rf $SCRATCH "$OUT"' EXIT
  # Xvfb answers before it is listening; a short settle is cheaper and more
  # reliable than racing the first connection.
  sleep 2
fi

have import && have convert && have xwininfo && have xdotool && have xclip && have nc || {
  echo "gui_build: ImageMagick's import/convert, xwininfo, xdotool, xclip and nc"
  echo "gui_build: are needed to prove the window works. xclip reads back what the"
  echo "gui_build: transcript's Copy button put on the clipboard; nc seeds the"
  echo "gui_build: conversation it copies from."
  echo "gui_build: FAIL"
  exit 1
}

run_check || { echo "gui_build: FAIL (--check)"; exit 1; }

echo "gui_build: running the window"
# `JENOVA_PORT` and not `PORT`, which is the name the configuration file
# *writes*: `etc/jenova.conf:39` is `PORT="${JENOVA_PORT:-8080}"`, so a bare
# `PORT` in the environment is unconditionally replaced by 8080 the moment the
# conf is read. A run set that way bound the developer's real port while a
# comment here claimed it had one of its own — and two gates run at once, or a
# gate run beside a live `jenova`, then fought over 8080. The seeding server
# above already uses the working name; this is the same spelling.
RUN_PORT=18787
# Asserted rather than assumed, because the failure above was silent: the window
# came up, bound the wrong port and passed. `jenova-core config` resolves the
# same file the window does, so a future divergence between the conf's variable
# names and this script's fails here instead of in the developer's live server.
CONF_PORT=$(JENOVA_ROOT="$RT" JCA_HOME="$JH" JENOVA_PORT="$RUN_PORT" \
  "$OUT/jenova-core" config 2>/dev/null | sed -n 's/^PORT=//p')
if [ "$CONF_PORT" != "$RUN_PORT" ]; then
  echo "gui_build: asked for port $RUN_PORT and the configuration resolves" \
       "$CONF_PORT — the window would bind a port this run does not own."
  echo "gui_build: check etc/jenova.conf against the variables set here."
  echo "gui_build: FAIL"
  exit 1
fi
# `--no-tray` because a StatusNotifierWatcher is a desktop service and its
# absence is not this script's subject.
JENOVA_ROOT="$RT" JCA_HOME="$JH" JENOVA_NO_BACKENDS=1 CANVAS=0 \
  JENOVA_PORT="$RUN_PORT" \
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
elif ! transcript_renders; then
  case "${TRANSCRIPT_FAILED:-}" in
    wrongtext)
      echo "gui_build: a Copy button answered, but with something other than the"
      echo "gui_build: seeded conversation's first message." ;;
    measure)
      echo "gui_build: a measurement did not produce a number. ImageMagick's"
      echo "gui_build: \`convert\` or \`import\` failed while reading the transcript,"
      echo "gui_build: so nothing was proved either way about what drew. This is"
      echo "gui_build: a harness failure, not a GUI failure." ;;
    nocards)
      echo "gui_build: no card edge in the transcript — the accent border every"
      echo "gui_build: message card carries is not there, so no message drew." ;;
    *)
      echo "gui_build: cards are drawn but no Copy button answered anywhere down"
      echo "gui_build: the column. Either the action row is gone or CARD_COPY_DX"
      echo "gui_build: no longer lands on it." ;;
  esac
  echo "gui_build: $OUT is kept for inspection."
  KEEP=1
  rc=1
elif composer_reachable; then
  echo "gui_build: the transcript renders the seeded conversation"
  echo "gui_build: the composer is at the bottom of the window and takes typing"
elif [ "${PROBE_FAILED:-}" = "measure" ]; then
  echo "gui_build: a measurement did not produce a number. ImageMagick's"
  echo "gui_build: \`convert\` returned nothing for one of the band crops or"
  echo "gui_build: differences, so nothing was proved either way about the"
  echo "gui_build: window. This is a harness failure, not a GUI failure."
  echo "gui_build: $OUT is kept for inspection."
  KEEP=1
  rc=1
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
if grep -Eq "CRITICAL|assertion|error parsing markup" "$OUT/run.log"; then
  echo "gui_build: GTK complained during the run:"
  grep -E "CRITICAL|assertion|markup" "$OUT/run.log"
  rc=1
fi

if [ "$rc" -ne 0 ]; then
  if [ "${KEEP:-}" = "1" ]; then
    # The photographs are the whole evidence for the failure, and a trap that
    # deletes them leaves the reader with nothing to look at. Which ones exist
    # depends on how far the run got: a `transcript_renders` failure produces
    # `transcript.png` and never reaches the before/after pair, so copying only
    # that pair left the earliest failure with no picture at all. Everything the
    # run captured is copied, and the message names what actually landed rather
    # than a fixed pair.
    EV=${TMPDIR:-/tmp}/gui_build-evidence.$$
    mkdir -p "$EV"
    for f in "$OUT"/*.png "$OUT/run.log"; do
      if [ -f "$f" ]; then cp "$f" "$EV/"; fi
    done
    echo "gui_build: evidence written to $EV:"
    ls -1 "$EV"
  fi
  echo "gui_build: FAIL"
  exit 1
fi
echo "gui_build: PASS"
