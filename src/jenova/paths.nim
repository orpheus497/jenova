## Script function and purpose: Path and layout resolution for the Nim core.
## Replaces the path-resolution half of `lib/jenova-conf.sh`. Every path Jenova
## uses at runtime is derived here, once, so no other module re-derives one from
## an environment variable that may be unset — the defect class that made
## `scripts/cleanup.sh` capable of deleting `/var/cache` (B-07).

import std/[os, strutils]

type
  Layout* = enum
    ## Which tree Jenova is running from. `lib/jenova-conf.sh:25` distinguishes
    ## these by the presence of a deployed llama-server without a source
    ## checkout beside it; the same test is reproduced here.
    lyInstalled = "installed"
    lySource = "source"

  Paths* = object
    root*: string
    layout*: Layout
    jcaHome*: string
    state*: string
    workspaces*: string
    logDir*: string
    cacheDir*: string
    pidFile*: string
    llamaServer*: string
    llamaLibDir*: string

  PathError* = object of CatchableError

## Function purpose: locate the project root without trusting the caller's cwd.
## `JENOVA_ROOT` wins when exported, because the shell launchers still set it
## during the transition and both trees must agree. Otherwise the root is derived
## from the running binary, matching how `jenova-ui/src/main.c` resolves it via
## KERN_PROC_PATHNAME: the executable lives in <root>/bin, so the root is two
## levels up.
proc findRoot*(): string =
  let fromEnv = getEnv("JENOVA_ROOT")
  if fromEnv.len > 0:
    return fromEnv.absolutePath.normalizedPath
  let exe = getAppFilename()
  result = exe.parentDir.parentDir.normalizedPath
  if result.len == 0:
    raise newException(PathError, "cannot resolve JENOVA_ROOT from " & exe)

## Function purpose: distinguish a deployed install from a source checkout, which
## decides where llama-server and its shared libraries live.
proc detectLayout*(root: string): Layout =
  if fileExists(root / "bin" / "llama-server") and
     not dirExists(root / "external" / "llama.cpp"):
    lyInstalled
  else:
    lySource

## Function purpose: resolve every runtime path from the root in one place.
## Values already present in the environment are honoured, so an operator can
## still relocate a directory, but nothing is left undefined: each field has a
## default derived from JCA_HOME rather than from an empty string.
proc resolve*(root = ""): Paths =
  let r = if root.len > 0: root.normalizedPath else: findRoot()
  if not dirExists(r):
    raise newException(PathError, "JENOVA_ROOT does not exist: " & r)

  result.root = r
  result.layout = detectLayout(r)

  let home = getEnv("HOME")
  if home.len == 0:
    raise newException(PathError, "HOME is not set; cannot derive JCA_HOME")

  result.jcaHome = getEnv("JCA_HOME", home / "JCA")
  result.state = getEnv("JENOVA_STATE", result.jcaHome / ".system")
  result.workspaces = getEnv("JENOVA_WORKSPACES", result.jcaHome / "Workspaces")
  result.logDir = getEnv("LOG_DIR", result.jcaHome / "var" / "log")
  result.cacheDir = getEnv("CACHE_DIR", result.jcaHome / "var" / "cache")
  result.pidFile = getEnv("PID_FILE", result.state / "jenova-ca.pid")

  case result.layout
  of lyInstalled:
    result.llamaServer = getEnv("LLAMA_SERVER", r / "bin" / "llama-server")
    result.llamaLibDir = r / "bin"
  of lySource:
    result.llamaServer = getEnv("LLAMA_SERVER",
                                r / "external" / "ext_bin" / "bin" / "llama-server")
    result.llamaLibDir = r / "external" / "ext_bin" / "bin"

## Function purpose: render the resolved paths for the `config` subcommand and
## for diffing against what the shell path currently produces.
proc render*(p: Paths): string =
  var lines: seq[string]
  lines.add "JENOVA_ROOT=" & p.root
  lines.add "JENOVA_LAYOUT=" & $p.layout
  lines.add "JCA_HOME=" & p.jcaHome
  lines.add "JENOVA_STATE=" & p.state
  lines.add "JENOVA_WORKSPACES=" & p.workspaces
  lines.add "LOG_DIR=" & p.logDir
  lines.add "CACHE_DIR=" & p.cacheDir
  lines.add "PID_FILE=" & p.pidFile
  lines.add "LLAMA_SERVER=" & p.llamaServer
  lines.add "LLAMA_LIB_DIR=" & p.llamaLibDir
  lines.join("\n")
