## Script function and purpose: entry point for the desktop application.
##
## A second binary rather than another `jenova-core` subcommand, because the
## headless server must stay buildable on a machine with no GTK — LAN mode has to
## serve whether or not a window is running, and folding owlkettle in would make
## a graphical toolkit a build-time requirement for a server.
##
## Two binaries are not two programs: both link the same core modules and this
## one drives the backend lifecycle in-process, exactly as the server does. What
## is deliberately not reproduced is a tray that owns the client-facing port as a
## child process — see `gui.nim` for why that arrangement disappears.

when not defined(freebsd):
  {.error: "Jenova targets FreeBSD only — see docs/install.md. " &
           "This matches the guard in jenova_core.nim.".}

import std/os
import jenova/gui

const
  Version = "0.1.0"
  Stage = "desktop application"

## Function purpose: printed on `--help` and on an unknown flag, so a mistyped
## option shows what was expected rather than only that it was wrong.
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

## Function purpose: parses the three flags and hands everything else to the
## window, so argument handling stays out of the widget module.
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
      # Action purpose: refuse an unknown flag rather than ignore it. Silently
      # swallowing a mistyped one is how a run does the wrong thing while
      # looking correct.
      echo "unknown option: ", arg
      echo ""
      usage()
      quit(2)

  try:
    gui.run(withTray = withTray, checkOnly = checkOnly)
  except CatchableError as e:
    # Action purpose: a configuration or path error must reach the terminal.
    # Reporting it inside a window the error may have prevented from opening is
    # how a start-up failure becomes a silent one.
    stderr.writeLine "jenova: ", e.msg
    quit(1)

when isMainModule:
  main()
