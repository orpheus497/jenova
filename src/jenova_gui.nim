## Script function and purpose: entry point for `bin/jenova`, the native FreeBSD
## desktop application (N-S7). Replaces the shell launcher of the same name, plus
## `jenova-ui/src/main.c` (C, GTK3, embedded LuaJIT, ncurses) and `lib/ui.lua`.
##
## ## Why this is a second binary and not another `jenova-core` subcommand
##
## `jenova-core` is the headless server and must stay buildable on a machine with
## no GTK at all — N-7 requires LAN mode to serve whether or not the GUI is
## running, and folding owlkettle into it would make a graphical toolkit a
## build-time requirement for a server. Splitting the *binaries* is not splitting
## the *program*: both link the same core modules, and the GUI drives
## `lifecycle` in-process exactly as `jenova-core serve` does.
##
## This is the distinction D-N's "single binary" ruling was actually about — one
## program rather than a daemon plus a detached client talking over a socket —
## and it is preserved here. What is *not* reproduced is `bin/jenova-ca`'s split,
## where the tray owned the client-facing proxy as a child process: that is
## defect B-13, and `gui.nim` documents why it disappears.

when not defined(freebsd):
  {.error: "Jenova targets FreeBSD only. " &
           "This carries forward the #error guard that jenova-ui/src/main.c held " &
           "before N-S7 archived it, and matches the guard in jenova_core.nim.".}

import std/os
import jenova/gui

const
  Version = "0.1.0"
  Stage = "N-S7 desktop application"

proc usage() =
  echo "jenova ", Version, " (", Stage, ")"
  echo ""
  echo "Usage: jenova [--no-tray] [--check] [--help]"
  echo ""
  echo "  The Jenova desktop application: chat window, backend control,"
  echo "  model switching, LAN toggle, and a StatusNotifierItem tray."
  echo ""
  echo "  --no-tray   run the window without registering a tray item"
  echo "  --check     start-up smoke test: initialise GTK and build the whole"
  echo "              window, then exit. Shows no window, starts no backend,"
  echo "              binds no port. Exit 0 means the application reaches its"
  echo "              first frame — which a successful compile does not tell you"
  echo ""
  echo "  The headless server is a separate binary: jenova-core serve"

proc main() =
  var withTray = true
  var checkOnly = false
  for arg in commandLineParams():
    case arg
    of "--no-tray": withTray = false
    of "--check": checkOnly = true
    of "-h", "--help", "help":
      usage()
      quit(0)
    else:
      # Action purpose: refuse an unknown flag rather than ignoring it. The same
      # rule is asserted for `jenova-core serve` in tests/test_lifecycle.sh —
      # silently swallowing a mistyped flag is how a run does the wrong thing
      # while looking correct.
      echo "unknown option: ", arg
      echo ""
      usage()
      quit(2)

  try:
    gui.run(withTray = withTray, checkOnly = checkOnly)
  except CatchableError as e:
    # A configuration or path error must reach the terminal. Reporting it inside
    # a window the error may have prevented from opening is how a startup
    # failure becomes a silent one.
    stderr.writeLine "jenova: ", e.msg
    quit(1)

when isMainModule:
  main()
