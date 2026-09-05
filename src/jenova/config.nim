## Script function and purpose: the two conf files, evaluated under one
## precedence rule stated in exactly one place:
##
##     builtin default  <  profile conf  <  local conf  <  environment
##
## Order matters and is easy to invert: both files read their defaults through
## `${JENOVA_X:-...}`, so sourcing the local file first lets the profile
## reassign every value the user set.

import std/[os, osproc, strutils, tables]
import ./paths
import ./models

type
  Config* = object
    ## Values as resolved by the precedence rule. Kept as strings because that is
    ## what they are in the conf files and what llama-server receives on its
    ## command line; typed accessors below parse only what needs parsing.
    values*: Table[string, string]
    profileConf*: string
    localConf*: string

  ConfigError* = object of CatchableError

const
  ## The contract with the conf files: a key not listed here is invisible to
  ## this program, so adding a key to a profile without adding it here sets
  ## nothing.
  Keys* = [
    # paths
    "JCA_HOME", "JENOVA_STATE", "LOG_DIR", "CACHE_DIR", "PID_FILE", "LLAMA_SERVER",
    # models (resolved by ./models.nim after the conf is evaluated; the conf
    # files no longer source a shell helper for this — see load() below)
    "MODEL_PATH", "MODEL_DRAFT", "MODEL_EMBED",
    # network
    "HOST", "PORT", "LLAMA_PORT", "LLAMA_EMBED_PORT",
    "API_URL", "LLAMA_URL", "LLAMA_EMBED_URL",
    # hardware
    "DEVICES", "TENSOR_SPLIT", "FIT_TARGET", "NGL_AGENT",
    # context
    "CTX_SIZE", "NUM_SLOTS", "KV_CACHE_TYPE",
    # threads and batching
    "THREADS", "THREADS_BATCH", "BATCH_SIZE", "UBATCH_SIZE",
    # speculative decoding
    "JENOVA_DRAFT", "DRAFT_DEVICE",
    # llama-server performance flags
    "JENOVA_FLASH_ATTN", "JENOVA_MLOCK", "JENOVA_MMAP",
    # agent limits
    "MAX_TURNS", "MAX_ACTIONS", "TIMEOUT",
    # health
    "JENOVA_HEALTH_TIMEOUT",
  ]

## Function purpose: the conf files are evaluated by `/bin/sh` rather than
## parsed, because they are shell — they carry guard clauses and branch on the
## layout to pick a binary. A parser for a subset of shell would mishandle that
## silently and report a plausible wrong answer; the interpreter that owns the
## format is exact. This depends on `/bin/sh` only, not on any project script.
proc evalConfFiles(p: Paths, profileConf, localConf: string): Table[string, string] =
  var script = """
set -e
JENOVA_ROOT=$1; export JENOVA_ROOT
JENOVA_LAYOUT=$2; export JENOVA_LAYOUT
. "$3" >/dev/null 2>&1
if [ -n "$4" ] && [ -f "$4" ]; then
    . "$4" >/dev/null 2>&1
fi
for _k in """ & Keys.join(" ") & """; do
    eval "_v=\${$_k-}"
    printf '%s\0%s\0' "$_k" "$_v"
done
"""

  # Action purpose: `sh -c <script> <name> <args...>` sets $0 to <name> and $1..
  # to the rest, so paths reach the script as positional parameters and are
  # never quoted into its text.
  let outp = execProcess(
    "/bin/sh",
    args = ["-c", script, "jenova-core", p.root, $p.layout, profileConf, localConf],
    env = nil,
    options = {})

  let fields = outp.split('\0')
  var i = 0
  while i + 1 < fields.len:
    result[fields[i]] = fields[i + 1]
    i += 2

## Function purpose: applying a hardware profile writes it to `$JCA_HOME/etc`,
## which makes that copy authoritative over the one in the source tree — a host
## with a read-only checkout would otherwise run on a stale profile. The whole
## directory is chosen at once so the profile and its local override can never
## come from different trees.
proc configDir(p: Paths): string =
  let deployed = p.jcaHome / "etc"
  if fileExists(deployed / "jenova.conf"): deployed else: p.root / "etc"

## Function purpose: the profile conf is required rather than defaulted. With
## no tuning values at all, guessing them is worse than refusing to start.
proc load*(p: Paths): Config =
  let dir = configDir(p)
  result.profileConf = dir / "jenova.conf"
  result.localConf = dir / "jenova.local.conf"

  if not fileExists(result.profileConf):
    raise newException(ConfigError,
      "profile config not found: " & result.profileConf &
      " (apply one from the window's Hardware screen, or with" &
      " `jenova-core hardware apply --best`)")

  if not fileExists(result.localConf):
    result.localConf = ""

  result.values = evalConfFiles(p, result.profileConf, result.localConf)
  if result.values.len == 0:
    raise newException(ConfigError,
      "config evaluation produced nothing; check " & result.profileConf)

  # Action purpose: discovery fills only what the conf left empty. The local
  # conf is the user's machine file and may name a model explicitly; overriding
  # that with a directory scan would invert the precedence rule this module
  # exists to state.
  for key, kind in {"MODEL_PATH": mkAgent,
                    "MODEL_DRAFT": mkDraft,
                    "MODEL_EMBED": mkEmbed}.items:
    if result.values.getOrDefault(key, "").strip.len == 0:
      result.values[key] = discover(p.jcaHome, kind)

## Function purpose: an absent key answers with `default` rather than raising,
## because most keys are optional and only the accessors below care why.
proc get*(c: Config, key: string, default = ""): string =
  c.values.getOrDefault(key, default)

## Function purpose: raises rather than substituting `default` for a value the
## operator actually set. A silently-defaulted thread count or context size is
## wrong-but-plausible, which is the hardest kind of fault to trace.
proc getInt*(c: Config, key: string, default: int): int =
  let raw = c.get(key)
  if raw.len == 0:
    return default
  try:
    parseInt(raw.strip)
  except ValueError:
    raise newException(ConfigError,
      "config key " & key & " is not an integer: '" & raw & "'")

## Function purpose: the switch-shaped keys, which are spelled by hand in a
## shell file and therefore arrive in whatever spelling the operator reached
## for. `1`/`0` is what the shipped profiles write and every other common word
## for the same thing is accepted beside it.
##
## Action purpose: **falls back rather than raising, and that is the whole
## difference from `getInt`.** These were read through `getInt`, so
## `JENOVA_MLOCK=true` — a spelling nothing rejects and nothing documents
## against — raised a `ConfigError` out of `llamaArgs`, through `start`, and out
## of `startAll`: a typo in one optional performance flag refused to start the
## inference backend at all. `getInt`'s reasoning does not carry here. A
## silently-defaulted context size is wrong-but-plausible arithmetic; a
## defaulted `--mlock` is a tuning flag not passed, which is the state the key
## was absent in and is survivable by construction.
proc getBool*(c: Config, key: string, default: bool): bool =
  let raw = c.get(key).strip
  if raw.len == 0: return default
  # Any integer, not only 1: these were `getInt(...) != 0` and a profile writing
  # `2` must keep meaning what it meant.
  try: return parseInt(raw) != 0
  except ValueError: discard
  case raw.toLowerAscii
  of "true", "yes", "on", "enabled": true
  of "false", "no", "off", "disabled": false
  else: default

## Function purpose: the `config` subcommand's output. Iterates `Keys` rather
## than the table so a key the conf never set still shows, as empty.
proc render*(c: Config): string =
  var lines: seq[string]
  for k in Keys:
    lines.add k & "=" & c.get(k)
  lines.join("\n")
