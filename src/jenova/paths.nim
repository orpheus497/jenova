## Script function and purpose: Path and layout resolution for the Nim core.
## Replaces the path-resolution half of `lib/jenova-conf.sh`. Every path Jenova
## uses at runtime is derived here, once, so no other module re-derives one from
## an environment variable that may be unset — the defect class that made
## `scripts/cleanup.sh` capable of deleting `/var/cache` (B-07).

import std/[algorithm, os, strutils, times]

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

  result.jcaHome = getEnv("JCA_HOME", home / "Jenova")

  # Action purpose: ruling D-AC — `~/JCA` is the USER's pre-existing working
  # deployment and nothing may write into it. The runtime home moved to
  # `~/Jenova`, but changing the default alone is not airtight: a shell that has
  # sourced the Jenova environment exports `JCA_HOME=~/JCA`, and an inherited
  # value overrides a default. This refuses that case outright rather than
  # relying on whoever runs the binary remembering — remembering is exactly what
  # failed. The override exists so N-S6 can address the real tree deliberately.
  if result.jcaHome.normalizedPath == (home / "JCA").normalizedPath and
     getEnv("JENOVA_ALLOW_DEPLOYED") != "1":
    raise newException(PathError,
      "refusing to operate on the legacy deployment at " & result.jcaHome &
      " (ruling D-AC). The runtime home is now " & home / "Jenova" &
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
  CachePrefix* = "attach-"
    ## The prefix `gui.attachmentPixbuf` gives every file it decodes into the
    ## cache directory. **The sweep matches on it and nothing else**, which is
    ## the whole safety property here: `cacheDir` is a path derived from an
    ## environment variable, and a sweep that deleted whatever it found would be
    ## `scripts/cleanup.sh` deleting `/var/cache` again — the defect (B-07) this
    ## module exists to make impossible. A file this program did not write is
    ## never a candidate.
  MaxCacheBytes* = 256 * 1024 * 1024
    ## M-02. The ceiling on the decoded-attachment cache.
    ##
    ## Every image ever attached, pasted or previewed is written here, named for
    ## the digest of its own bytes, and **nothing ever deleted one**. `nimble
    ## clean` removes `bin/` and `nimcache` only. So the directory accumulated a
    ## copy of every image the user had ever put in a chat, for ever, with no
    ## way to reclaim it short of `rm -rf`.
    ##
    ## Generous, because the files are what make re-opening a conversation with
    ## images cheap: the digest name means a decode is written once and every
    ## later view is a hit. This bounds the growth without throwing away the
    ## working set.

## Function purpose: keep the decoded-attachment cache under `maxBytes`, oldest
## first (M-02). Returns how many files were removed and how many bytes that
## reclaimed.
##
## Action purpose: **oldest by modification time, and the ordering is the
## point.** The cache is content-addressed, so a file that is still being looked
## at is rewritten only if it was evicted — its mtime therefore tracks when it
## was last *created*, and dropping the oldest sheds the conversations nobody
## has opened in longest. Deleting by size would evict exactly the large
## photographs that are most expensive to decode again.
##
## It is called once at startup rather than on every write: this stats a
## directory, and doing that on the path that decodes a thumbnail would put
## filesystem work inside `view`, which is the rule G-40 exists to hold.
##
## A file that cannot be removed is skipped rather than raising. A cache is a
## cache: failing to prune it must never stop the application starting.
proc sweepCache*(dir: string, maxBytes: int64 = MaxCacheBytes):
    tuple[removed: int, freed: int64] =
  if not dirExists(dir): return (0, 0'i64)
  var entries: seq[tuple[mtime: Time, size: int64, path: string]]
  var total = 0'i64
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    if not path.extractFilename.startsWith(CachePrefix): continue
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
