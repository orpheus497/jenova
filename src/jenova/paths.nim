## Script function and purpose: every path Jenova uses at runtime, derived once.
## Nothing else may re-derive one from an environment variable: an unset
## variable makes a path expand to a prefix of itself, which is how a cleanup
## routine ends up walking a system directory rather than its own cache.

import std/[algorithm, os, strutils, times]

type
  Layout* = enum
    ## Which tree Jenova is running from, which decides where llama-server and
    ## its shared libraries are looked for.
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

## Function purpose: locates the root without trusting the caller's working
## directory. `JENOVA_ROOT` wins when exported so a launcher and the binary
## cannot disagree; otherwise the running executable's own location answers it,
## since it lives in `<root>/bin`.
proc findRoot*(): string =
  let fromEnv = getEnv("JENOVA_ROOT")
  if fromEnv.len > 0:
    return fromEnv.absolutePath.normalizedPath
  let exe = getAppFilename()
  result = exe.parentDir.parentDir.normalizedPath
  if result.len == 0:
    raise newException(PathError, "cannot resolve JENOVA_ROOT from " & exe)

## Function purpose: a deployed llama-server with no checkout beside it is what
## distinguishes an install from a source tree; nothing else is reliable.
proc detectLayout*(root: string): Layout =
  if fileExists(root / "bin" / "llama-server") and
     not dirExists(root / "external" / "llama.cpp"):
    lyInstalled
  else:
    lySource

## Function purpose: an environment value is honoured so an operator can
## relocate a directory, but every field falls back to a value derived from
## `JCA_HOME` rather than to an empty string.
proc resolve*(root = ""): Paths =
  let r = if root.len > 0: root.normalizedPath else: findRoot()
  if not dirExists(r):
    raise newException(PathError, "JENOVA_ROOT does not exist: " & r)

  result.root = r
  result.layout = detectLayout(r)

  let home = getEnv("HOME")
  if home.len == 0:
    raise newException(PathError, "HOME is not set; cannot derive JCA_HOME")

  result.jcaHome = getEnv("JCA_HOME", home / "Jenova")

  # Action purpose: `~/JCA` is a pre-existing working deployment that nothing
  # here may write into. Moving the default to `~/Jenova` is not enough on its
  # own, because a shell that has sourced the Jenova environment exports
  # `JCA_HOME=~/JCA` and an inherited value beats a default. Refused outright
  # rather than left to whoever runs the binary to remember.
  if result.jcaHome.normalizedPath == (home / "JCA").normalizedPath and
     getEnv("JENOVA_ALLOW_DEPLOYED") != "1":
    raise newException(PathError,
      "refusing to operate on the legacy deployment at " & result.jcaHome &
      ". The runtime home is now " & home / "Jenova" &
      ". Set JENOVA_ALLOW_DEPLOYED=1 only if targeting the old tree is intended.")
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

const
  AttachCacheDir* = "attachments"
    ## The only directory the sweep will ever delete from. `CACHE_DIR` is
    ## operator-configurable, so matching on filename alone could delete an
    ## unrelated file that happened to be named `attach-…` in whatever directory
    ## the operator pointed it at. A name is not ownership; a directory this
    ## program creates for itself is. The prefixes below stay as defence in
    ## depth.
  CachePrefixes* = ["attach-", "pasted-"]
    ## Both writers into the attachment cache: decoded images are named for
    ## their digest, clipboard images for the epoch. A prefix missing from this
    ## list is a file that grows without bound in a directory being swept.
  MaxCacheBytes* = 256 * 1024 * 1024
    ## The ceiling on the decoded-attachment cache, which nothing else bounds —
    ## every image ever attached, pasted or previewed is written here and no
    ## build target removes them. Deliberately generous: the digest naming means
    ## a decode is written once and every later view is a hit, so a tight cap
    ## would throw away the working set to reclaim little.

## Function purpose: derived here rather than in the window, so the writer and
## the sweeper cannot disagree about where the cache is.
proc attachCacheDir*(p: Paths): string = p.cacheDir / AttachCacheDir

## Function purpose: `dir` must come from `attachCacheDir` and never be
## `cacheDir` itself — the subdirectory is what establishes these files are ours
## to delete. Called once at startup, not per write, so that statting a
## directory never lands on the path that decodes a thumbnail.
##
## Action purpose: eviction is oldest-mtime-first, and the ordering is the
## point. The cache is content-addressed, so an mtime tracks when a file was
## last created rather than last read, and dropping the oldest sheds the
## conversations nobody has opened in longest. Evicting by size instead would
## drop exactly the large images that cost most to decode again.
##
## A file that cannot be removed is skipped rather than raising: failing to
## prune a cache must never stop the application starting.
proc sweepCache*(dir: string, maxBytes: int64 = MaxCacheBytes):
    tuple[removed: int, freed: int64] =
  if not dirExists(dir): return (0, 0'i64)
  var entries: seq[tuple[mtime: Time, size: int64, path: string]]
  var total = 0'i64
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    var owned = false
    for prefix in CachePrefixes:
      if path.extractFilename.startsWith(prefix):
        owned = true
        break
    if not owned: continue
    var size = 0'i64
    var mtime: Time
    try:
      size = getFileSize(path)
      mtime = getLastModificationTime(path)
    except CatchableError:
      continue
    entries.add (mtime, size, path)
    total += size
  if total <= maxBytes: return (0, 0'i64)

  entries.sort(proc (a, b: tuple[mtime: Time, size: int64, path: string]): int =
    cmp(a.mtime, b.mtime))
  for e in entries:
    if total <= maxBytes: break
    if tryRemoveFile(e.path):
      total -= e.size
      result.removed.inc
      result.freed += e.size

## Function purpose: the `paths` subcommand's output, in `KEY=value` form so it
## can be diffed against what a launcher's environment actually holds.
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
