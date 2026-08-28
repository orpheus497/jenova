# Package metadata and dependency declaration for jenova-core.
#
# The Makefile is this project's single build entry point (`make core`); this
# file exists so nimble can resolve dependencies and so the package carries its
# licence and version. namedBin keeps nimble's output path identical to the
# Makefile's, so the two never produce differently-named binaries.

import std/tables

version       = "0.1.0"
author        = "orpheus497"
description   = "Jenova Cognitive Architecture - native FreeBSD core"
license       = "AGPL-3.0-or-later"
srcDir        = "src"
bin           = @["jenova_core"]
binDir        = "bin"
namedBin      = {"jenova_core": "jenova-core"}.toTable

requires "nim >= 2.2.10"
