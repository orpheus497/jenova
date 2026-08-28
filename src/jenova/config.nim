## Script function and purpose: Configuration loading for the Nim core, with one
## precedence rule stated once. Replaces the tuning half of `etc/jenova.conf` +
## `etc/jenova.local.conf` as consumed by `bin/jenova-ca`.
##
## The precedence defect this fixes (TODOS.md B-12): `bin/jenova-ca:44-48` sources
## the local conf *before* the profile conf, and the profile conf then reassigns
## every tuning variable from `${JENOVA_X:-default}`. A user's local override is
## therefore discarded — `etc/jenova.local.conf` sets THREADS=8 and the profile
## resets it to 4. This module sources them the other way round.
##
## Scope note: the shell path keeps that bug until `bin/jenova-ca` is deleted at
## stage N-S6. B-12 is fixed *here*, not repo-wide, and is recorded as such.

import std/[os, osproc, strutils, tables]
import ./paths

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
  ## Every key the launchers read out of the two conf files. Anything not listed
  ## here is invisible to the Nim core by design — an unlisted key is a key
  ## nothing consumes.
  Keys* = [
    # paths
    "JCA_HOME", "JENOVA_STATE", "LOG_DIR", "CACHE_DIR", "PID_FILE", "LLAMA_SERVER",
    # models (discovered by lib/jenova-model.sh, which jenova.conf sources)
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
    # agent limits
    "MAX_TURNS", "MAX_ACTIONS", "TIMEOUT",
    # health
    "JENOVA_HEALTH_TIMEOUT",
  ]

## Action purpose: evaluate the conf files with /bin/sh rather than parsing them.
##
## They ARE shell — `etc/jenova.conf` opens with a guard clause, branches on
## JENOVA_LAYOUT to pick LLAMA_SERVER (`:17-21`), and sources
## `lib/jenova-model.sh` for model discovery (`:27`). A hand-written parser for a
## subset of shell would silently mishandle all three and report a plausible
## wrong answer. Handing them to the interpreter that owns the format is exact.
##
## The two files are sourced profile-then-local, which is the corrected order.
## Exported JENOVA_* variables still win, because both files read their defaults
## through `${JENOVA_X:-...}` — giving the full rule:
##
##     builtin default  <  profile conf  <  local conf  <  environment
##
## This shell dependency is deliberate and temporary: it lasts until the conf
## format itself changes, which is a separate decision touching all six shipped
## hardware profiles.
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

  # `sh -c <script> <name> <args...>` sets $0 to <name> and $1.. to the rest, so
  # the script's positional parameters line up without quoting paths into it.
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

## Function purpose: load configuration under the corrected precedence. The
## profile conf is required — without it there are no tuning values at all and
## guessing them would be worse than failing.
proc load*(p: Paths): Config =
  result.profileConf = p.root / "etc" / "jenova.conf"
  result.localConf = p.root / "etc" / "jenova.local.conf"

  if not fileExists(result.profileConf):
    raise newException(ConfigError,
      "profile config not found: " & result.profileConf &
      " (apply one with hardware-profiles/detect-hardware.sh --apply-profile)")

  if not fileExists(result.localConf):
    result.localConf = ""

  result.values = evalConfFiles(p, result.profileConf, result.localConf)
  if result.values.len == 0:
    raise newException(ConfigError,
      "config evaluation produced nothing; check " & result.profileConf)

proc get*(c: Config, key: string, default = ""): string =
  c.values.getOrDefault(key, default)

## Function purpose: integer accessor that fails loudly rather than substituting
## a default for a value the operator actually set. A silently-defaulted thread
## count or context size is the kind of wrong-but-plausible behaviour that is
## hard to notice and hard to trace.
proc getInt*(c: Config, key: string, default: int): int =
  let raw = c.get(key)
  if raw.len == 0:
    return default
  try:
    parseInt(raw.strip)
  except ValueError:
    raise newException(ConfigError,
      "config key " & key & " is not an integer: '" & raw & "'")

proc render*(c: Config): string =
  var lines: seq[string]
  for k in Keys:
    lines.add k & "=" & c.get(k)
  lines.join("\n")
