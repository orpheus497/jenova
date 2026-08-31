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

task gui, "Build the desktop application (bin/jenova)":
  exec "nim c " & NimFlags & " --out:bin/jenova src/jenova_gui.nim"

task suites, "Build both binaries and run the test suites":
  coreTask()
  guiTask()
  for f in ["test_api_db.sh", "test_api_fs.sh", "test_routes.sh",
            "test_lifecycle.sh", "test_models.sh"]:
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
