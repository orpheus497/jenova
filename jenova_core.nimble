import std/[os, tables]

version       = "0.1.0"
author        = "orpheus497"
description   = "Jenova Cognitive Architecture - native FreeBSD desktop application"
license       = "AGPL-3.0-or-later"
srcDir        = "src"
binDir        = "bin"
bin           = @["jenova_core", "jenova_gui"]
namedBin      = {"jenova_core": "jenova-core", "jenova_gui": "jenova"}.toTable

requires "nim >= 2.2.10"
requires "owlkettle >= 3.0.0"

# Which GTK4 API level owlkettle may compile against. The installed toolkit is
# 4.20.4 (D-AK); 10 is a deliberate floor rather than a match, unlocking what the
# GUI actually uses — `contentFit` on Picture (4.8) and `placeholderText` on
# SearchEntry (4.10) — without opting into every newer path owlkettle guards.
#
# **`-d:gtk48` is required alongside it and is not redundant.** owlkettle 3.0.0
# gates the *widget* on `GtkMinor >= 8` but its *binding* on `defined(gtk48)`
# (`bindings/gtk.nim:836`), so raising only `gtkminor` fails to compile with an
# undeclared `gtk_picture_set_content_fit`. Both switches, or neither.
const NimFlags = "-d:release -d:gtkminor=10 -d:gtk48 --hints:off --path:src"

task core, "Build the headless server (bin/jenova-core)":
  exec "nim c " & NimFlags & " --out:bin/jenova-core src/jenova_core.nim"

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
  exec "nim c " & GuiFlags & " --out:bin/jenova src/jenova_gui.nim"

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
  "nvim-env", "models", "fs", "hardware", "composer", "convmd", "lifecycle",
  "pipeline", "rag",
  "serve",
]

task suites, "Build both binaries and run the test suites":
  coreTask()
  guiTask()
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
  # without it. **That skip is the one exception to A-2's rule** that a suite
  # which cannot run must fail — nvim is not a build dependency of either
  # binary, so requiring it would make a green run impossible on a host that can
  # legitimately build and ship Jenova. The other five guards all fail.
  for f in ["test_api_db.sh", "test_api_fs.sh", "test_routes.sh",
            "test_lifecycle.sh", "test_models.sh", "test_nvimctl.sh"]:
    exec "sh tests/" & f

task llama, "Build the llama.cpp backend into external/ext_bin":
  let build = "external" / "llama.cpp" / "build"
  exec "cmake -S external/llama.cpp -B " & build &
       " -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DLLAMA_CURL=OFF"
  exec "cmake --build " & build & " --config Release -j"
  mkDir "external" / "ext_bin" / "bin"
  for f in listFiles(build / "bin"):
    if f.endsWith("llama-server") or f.contains(".so"):
      cpFile(f, "external" / "ext_bin" / "bin" / f.extractFilename)

task web, "Build the Web UI into public/":
  withDir "jca_web":
    exec "npm install"
    exec "npm run build"

task clean, "Remove build artifacts":
  rmFile "bin/jenova-core"
  rmFile "bin/jenova"
  rmDir "nimcache"
