import std/[os, strutils, tables]

version       = "0.1.0"
author        = "orpheus497"
description   = "Jenova Cognitive Architecture - native FreeBSD desktop application"
license       = "AGPL-3.0-or-later"
srcDir        = "src"
binDir        = "bin"
bin           = @["jenova_core", "jenova_gui"]
namedBin      = {"jenova_core": "jenova-core", "jenova_gui": "jenova"}.toTable

requires "nim >= 2.2.10"
# **Pinned to a commit, and `>= 3.0.0` could not do this job.** owlkettle's
# `main` still declares `version = "3.0.0"` in its own nimble file, so the tag
# and everything after it satisfy the same constraint while offering different
# widgets — `ToastOverlay`, `Toast`/`ToastQueue` and `ToolbarView` exist only
# after the tag. Which of the two a machine happened to have decided whether
# this window compiled, silently.
#
# `ac61ecf` is the revision report 06 audited and the one this window is written
# against: `gui.nim` uses `ToastOverlay` for its confirmations, and report 05's
# Phase 3 plans `ToolbarView` for the header/content/footer. Raise the pin
# deliberately, having read what moved; do not relax it back to a range.
requires "https://github.com/can-lehmann/owlkettle#ac61ecf"

# Which GTK4 API level owlkettle may compile against. The installed toolkit is
# 4.20.4 (D-AK); 10 is a deliberate floor rather than a match, unlocking what the
# GUI actually uses — `contentFit` on Picture (4.8) and `placeholderText` on
# SearchEntry (4.10) — without opting into every newer path owlkettle guards.
#
# No `-d:gtk48` beside it, and that is a property of the pin rather than an
# omission. At `ac61ecf` the Picture binding is gated on `when GtkMinor >= 8`
# (`bindings/gtk.nim:864-867`) and `defined(gtk48)` is read nowhere in the
# dependency, so `-d:gtkminor=10` reaches `gtk_picture_set_content_fit` on its
# own. The `v3.0.0` tag gates the widget on `GtkMinor` but its binding on
# `defined(gtk48)`, where raising only `gtkminor` fails to compile with that
# call undeclared — so relaxing the pin back to the tag means putting
# `-d:gtk48` back with it.
#
# `-d:adwminor` gates libadwaita the same way, and owlkettle defaults it to 0
# (`bindings/adw.nim:29`) — which compiled `OverlaySplitView`, `ToolbarView`,
# `SwitchRow`, `EntryRow`, `PasswordEntryRow`, `Banner` and `AboutWindow` out of
# the binary entirely, along with 13 widget properties. The window used the
# deprecated `Flap` because its replacement was not built. 4 is the level the
# planned widgets need; the host's libadwaita must be at least 1.4.
const NimFlags = "-d:release -d:gtkminor=10 -d:adwminor=4 " &
                 "--hints:off --path:src"

# Action purpose: a cache under the working tree, one directory per task, rather
# than Nim's default. That default is keyed on the project *name*, so every
# checkout of Jenova on the machine shares `~/.cache/nim/jenova_core_r` — and a
# cache holding objects built from a different copy of these sources links with
# a wall of `undefined reference to` errors for generic instantiations, naming
# modules that are not wrong. Incremental rebuilds are kept, because each task
# still has one stable directory of its own; what is given up is sharing a cache
# between trees, which is the thing that breaks. It also makes `clean` true:
# `nimcache/` is what this project actually writes.
const CoreCache = " --nimcache:nimcache/core"
const GuiCache = " --nimcache:nimcache/gui"

task core, "Build the headless server (bin/jenova-core)":
  exec "nim c " & NimFlags & CoreCache &
       " --out:bin/jenova-core src/jenova_core.nim"

# `--mm:arc`, and only here. owlkettle's `EventObj[T].widget` is a strong ref back
# to the state that owns the event (`widgetdef.nim:44-50`), so every widget with a
# callback is a `state -> event -> state` reference cycle. Under Nim 2's default
# ORC those cycles are collected, and the collector can take a widget state while
# GTK still holds the widget and its connected handler — the next `updateState`
# then disconnects a signal from a wild pointer. That is the SIGBUS in the five
# `jenova` cores of 2026-08-31: `g_signal_handler_disconnect` ->
# `g_type_check_instance`, reached from the header bar's children.
#
# ARC has no cycle collector, so those cycles leak instead. The leak is bounded:
# GTK owns the widgets, and what is left behind is a small state object per
# discarded widget in a fixed-size tree.
#
# `jenova-core` keeps ORC. It links no owlkettle and has none of these cycles,
# and it is a long-lived threaded server where an uncollected cycle would matter.
const GuiFlags = NimFlags & " --mm:arc"

task gui, "Build the desktop application (bin/jenova)":
  exec "nim c " & GuiFlags & GuiCache & " --out:bin/jenova src/jenova_gui.nim"

# Every `X-selftest` subcommand `jenova-core` dispatches. Read this list against
# the `of "…-selftest"` cases in `src/jenova_core.nim` when one is added — there
# is no reflection to enumerate them, and a new self-test that is not added here
# is a self-test nothing runs.
#
# Ordered cheapest-first so a broken fundamental fails the run before the slow
# ones start. `serve-selftest` is last: it binds a port (18642) and measures
# stream cadence under load, so it is the only one whose result depends on what
# else the machine is doing.
const SelfTests = [
  "db", "sha256", "markdown", "error", "tree", "attach", "workspace",
  "nvim-env", "models", "fs", "hardware", "composer", "convmd", "asset",
  "lifecycle", "relay", "inspect", "math", "pipeline", "rag",
  "serve",
]

# Declared BEFORE `suites`, which calls `webTask()`. NimScript generates a
# task's proc where the task is written and resolves calls in source order, so
# with this further down the file `nimble` refused to read the package at all —
# "undeclared identifier: 'webTask'" — and every task, `core` and `gui`
# included, failed before running a line.
task web, "Build the Web UI into public/":
  withDir "jca_web":
    exec "npm install"
    exec "npm run build"

task suites, "Build both binaries and run the test suites":
  coreTask()
  guiTask()
  # Action purpose: `serve-selftest`'s third phase asks `/` for a body while the
  # debug class is saturated, and `serveStatic` answers that out of
  # `public/index.html`. Nothing but this task builds that directory, so on a
  # clean checkout the request returned 404 and the run reported a saturation
  # failure that had not happened.
  #
  # Depended on rather than skipped, because a skip would have to meet the bar
  # below and cannot: `node` and `npm` are in `docs/install.md`'s dependency
  # list, which says in as many words that there is no optional tier, and
  # `nimble web` is step 2 of the documented install. A host that can build and
  # ship Jenova can build the Web UI.
  webTask()
  # Action purpose: the self-tests are this project's entire assertion base and
  # until now no build task, no suite and no CI executed any of them — they were
  # reachable only by typing the subcommand by hand (`TODOS.md` A-1). Every one
  # exits 0 on PASS and 1 on FAIL, and `exec` raises on a non-zero exit, so
  # running them here is the whole fix: `nimble suites` now fails when an
  # assertion fails.
  #
  # They run before the shell suites because they are the faster signal and
  # need no scratch server.
  for t in SelfTests:
    exec "bin/jenova-core " & t & "-selftest"
  # `test_nvimctl.sh` compiles its own driver and spawns a headless `nvim`; it
  # skips cleanly when nvim is not installed, so it costs nothing on a host
  # without it. That skip is one of exactly two exceptions to the rule that a
  # suite which cannot run must fail — nvim is not a build dependency of either
  # binary, so requiring it would make a green run impossible on a host that can
  # legitimately build and ship Jenova. The other five guards all fail. The
  # second exception is the mapped-window tier below, on the same argument.
  for f in ["test_api_db.sh", "test_api_fs.sh", "test_routes.sh",
            "test_lifecycle.sh", "test_models.sh", "test_nvimctl.sh"]:
    exec "sh tests/" & f

  # Action purpose: the two GUI harnesses run last, because they are the
  # slowest and because they are the only things in this repository that have
  # ever compiled, linked, mapped and driven the window. `gui_check.sh` needs
  # nothing `nimble gui` did not already need, and `gui_build.sh` links the same
  # toolkit `bin/jenova` was just linked against, so neither can legitimately be
  # unavailable on a host that reached this line. Both run, and both fail.
  exec "sh tests/gui_check.sh"
  # The mapped-window step is the one part that can be legitimately absent, and
  # it is the `test_nvimctl.sh` case exactly: an X server, ImageMagick,
  # `xwininfo`, `xdotool`, `xclip` and `nc` are in no dependency list in
  # `docs/install.md` and are not needed to build or run Jenova, so requiring
  # them would make a green run impossible on a headless FreeBSD build host.
  # When they are absent the harness is asked for its build-only tier, which it
  # names on stdout — and the tools that were missing are named here, so the
  # reduced run is a reported result rather than a silent one.
  var needed = @["import", "convert", "xwininfo", "xdotool", "xclip", "nc"]
  # A display already open is as good as being able to start one, which is why
  # `Xvfb` is asked for only when there is none.
  if not existsEnv("DISPLAY"): needed.add "Xvfb"
  var missing: seq[string]
  for tool in needed:
    if findExe(tool).len == 0: missing.add tool
  if missing.len == 0:
    exec "sh tests/gui_build.sh"
  else:
    echo "suites: no mapped-window step — missing " & missing.join(", ")
    exec "JENOVA_GUI_NO_RUN=1 sh tests/gui_build.sh"

task llama, "Build the llama.cpp backend into external/ext_bin":
  let build = "external" / "llama.cpp" / "build"
  exec "cmake -S external/llama.cpp -B " & build &
       " -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DLLAMA_CURL=OFF"
  exec "cmake --build " & build & " --config Release -j"
  mkDir "external" / "ext_bin" / "bin"
  for f in listFiles(build / "bin"):
    if f.endsWith("llama-server") or f.contains(".so"):
      cpFile(f, "external" / "ext_bin" / "bin" / f.extractFilename)

task clean, "Remove build artifacts":
  rmFile "bin/jenova-core"
  rmFile "bin/jenova"
  rmDir "nimcache"
