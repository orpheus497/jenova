## Script function and purpose: Model discovery and model switching in Nim,
## replacing `lib/jenova-model.sh` and `bin/jenova-model-switch` — the last two
## shell scripts the running product relied on (D-AI's total-conversion gate).
##
## Discovery was previously reached the long way round: `etc/jenova.conf:27`
## sourced `jenova-model.sh`, `config.nim` evaluated that conf through `/bin/sh`,
## and `MODEL_PATH`/`MODEL_DRAFT`/`MODEL_EMBED` came back out as strings. The conf
## files keep their shell format — they are configs, and configs are exempt — but
## the *script* leaves the chain: `config.load` now fills those three keys from
## here whenever the conf did not already supply them.
##
## Switching was `bin/jenova-model-switch`, invoked by the GTK3 tray
## (`lib/ui.lua:125`). The GUI (N-S7) calls `switchModel` directly instead, so the
## desktop application spawns no shell to change models.

import std/[algorithm, os, strutils]

type
  ModelKind* = enum
    ## The three roles a GGUF can play. Each maps to a subdirectory of
    ## `$JCA_HOME/models` and to one `llama-server` argument.
    mkAgent = "agent"
    mkDraft = "draft"
    mkEmbed = "embed"

  ModelError* = object of CatchableError

  SwitchResult* = object
    ## What `switchModel` did, so a caller can report it without re-deriving it.
    ## The GUI shows `message`; the tests assert on the individual fields.
    target*: string      ## the .gguf now active in models/agent
    preserved*: seq[string]  ## active entries renamed to .old
    removed*: seq[string]    ## active entries that already pointed at the target
    message*: string

## Action purpose: `.old` and `.old.N` are the backups `jenova-model-switch`
## leaves behind on every switch. They live in the same directory and end in
## `.gguf.old`, so any scan that wants *active* models must skip them — the shell
## did this with `case "$_f" in *.old|*.old.*)` at three separate sites.
proc isBackup*(path: string): bool =
  let name = path.extractFilename
  name.endsWith(".old") or name.contains(".old.")

## Function purpose: the first `*.gguf` in a directory in collation order,
## reproducing `_find_model()` in `lib/jenova-model.sh:23-29`.
##
## Two details of the original are contract, not incidental. It matched files
## **and symlinks** (`\( -type f -o -type l \)`), because `switchModel` makes the
## active model a symlink — a files-only scan would find nothing after a switch.
## And it sorted before taking the first, so the choice is deterministic when a
## directory holds several; `walkDir` has no defined order, so the sort is
## explicit here rather than inherited from the filesystem.
proc findModel*(dir: string): string =
  if not dirExists(dir):
    return ""
  var found: seq[string]
  for kind, path in walkDir(dir):
    if kind notin {pcFile, pcLinkToFile}:
      continue
    if not path.endsWith(".gguf"):
      continue
    found.add path
  if found.len == 0:
    return ""
  found.sort()
  found[0]

## Function purpose: resolve all three model paths the way the shell did, so the
## values `lifecycle.nim` builds its argument vectors from are unchanged.
##
## The agent falls back to a flat `models/` directory when `models/agent` yields
## nothing (`jenova-model.sh:41-45`); draft and embed do not, and adding a
## fallback they never had would silently start passing `-md`/`-m` paths the
## shell would have left empty. Environment overrides are applied here for draft
## and embed, matching `:48,51`; the agent's `JENOVA_MODEL` override is applied by
## `etc/jenova.conf:33` as `MODEL_PATH`, so it is honoured here too rather than
## depending on which file got there first.
proc discover*(jcaHome: string, kind: ModelKind): string =
  let modelsDir = jcaHome / "models"
  case kind
  of mkAgent:
    result = getEnv("JENOVA_MODEL")
    if result.len > 0:
      return
    result = findModel(modelsDir / "agent")
    if result.len == 0:
      result = findModel(modelsDir)
  of mkDraft:
    result = getEnv("JENOVA_DRAFT_MODEL")
    if result.len == 0:
      result = findModel(modelsDir / "draft")
  of mkEmbed:
    result = getEnv("JENOVA_EMBED_MODEL")
    if result.len == 0:
      result = findModel(modelsDir / "embed")

## Function purpose: count comma-separated devices, replacing `count_devices()`
## in `jenova-model.sh:59-65`. `lifecycle.nim` needs it to decide whether `-ts`
## is meaningful, since a tensor split across one device is not.
proc countDevices*(devices: string): int =
  let trimmed = devices.strip
  if trimmed.len == 0:
    return 0
  trimmed.split(',').len

## Function purpose: pick the model a switch target offers — the first non-backup
## `*.gguf` in `models/<target>`, reproducing the glob at
## `bin/jenova-model-switch:42-47`.
proc targetModel*(jcaHome, target: string): string =
  let dir = jcaHome / "models" / target
  if not dirExists(dir):
    raise newException(ModelError, "target directory does not exist: " & dir)
  var found: seq[string]
  for kind, path in walkDir(dir):
    if kind notin {pcFile, pcLinkToFile}: continue
    if not path.endsWith(".gguf"): continue
    if path.isBackup: continue
    found.add path
  if found.len == 0:
    raise newException(ModelError, "no .gguf model found in " & dir)
  found.sort()
  found[0]

## Function purpose: make `models/<target>`'s model the active agent model,
## replacing `bin/jenova-model-switch` in full.
##
## The shell's ordering is reproduced deliberately, because it is what makes the
## operation safe rather than merely working:
##
## 1. **Build and validate the replacement before touching anything active.** The
##    new symlink is created under a temporary name and its resolved target
##    checked against the intended one. A switch that fails half way leaves the
##    old model in place rather than an empty `models/agent`.
## 2. **Relative link target.** `../<target>/<name>`, not an absolute path, so the
##    tree survives being moved or deployed elsewhere.
## 3. **Existing entries are renamed to `.old`, not deleted** — unless they already
##    resolve to the same real file, in which case keeping a second name for one
##    file is pointless. `.old.N` disambiguates when `.old` is taken.
## 4. **The swap is a rename**, which is atomic, so no reader ever sees the
##    directory without an active model.
proc switchToPath*(jcaHome, modelPath: string): SwitchResult =
  ## The generalised half of `switchModel`, added for the model selector (8a):
  ## the safety below is what is worth keeping, and the two-literal target
  ## vocabulary was the only thing standing between it and an arbitrary model.
  if not modelPath.endsWith(".gguf"):
    raise newException(ModelError, "not a .gguf: " & modelPath)
  if not (fileExists(modelPath) or symlinkExists(modelPath)):
    raise newException(ModelError, "model does not exist: " & modelPath)

  let modelsDir = jcaHome / "models"
  # Action purpose: the selector takes a path from a list this program built, but
  # `switchToPath` is exported and a caller could hand it anything. Activating a
  # file from outside the model tree would put a symlink into `models/agent`
  # pointing anywhere on the disk, so containment is checked here rather than
  # trusted at the call site.
  if not modelPath.isRelativeTo(modelsDir):
    raise newException(ModelError,
      "model is outside " & modelsDir & ": " & modelPath)

  let
    agentDir = modelsDir / "agent"
    targetName = modelPath.extractFilename
    targetReal = try: modelPath.expandFilename except OSError: modelPath

  createDir(agentDir)
  let linkTarget = relativePath(modelPath, agentDir)

  # Action purpose: a dotted temporary name ending in `.tmp.<pid>` cannot match
  # the `*.gguf` scan below, so the clearing loop can never mistake the
  # replacement for an entry to preserve. The shell relied on the same property.
  let tmpLink = agentDir / ("." & targetName & ".tmp." & $getCurrentProcessId())

  removeFile(tmpLink)
  createSymlink(linkTarget, tmpLink)

  let tmpReal = try: tmpLink.expandFilename except OSError: ""
  if tmpReal.len == 0 or tmpReal != targetReal:
    removeFile(tmpLink)
    raise newException(ModelError,
      "failed to validate replacement symlink for " & targetName &
      " (resolved to '" & tmpReal & "', expected '" & targetReal & "')")

  var existing: seq[string]
  for kind, path in walkDir(agentDir):
    if kind notin {pcFile, pcLinkToFile}: continue
    if not path.endsWith(".gguf"): continue
    if path.isBackup: continue
    existing.add path
  existing.sort()

  for entry in existing:
    let entryReal = try: entry.expandFilename except OSError: ""
    if entryReal.len > 0 and entryReal == targetReal:
      removeFile(entry)
      result.removed.add entry
    else:
      var dest = entry & ".old"
      if fileExists(dest) or symlinkExists(dest):
        var counter = 1
        while fileExists(entry & ".old." & $counter) or
              symlinkExists(entry & ".old." & $counter):
          counter += 1
        dest = entry & ".old." & $counter
      moveFile(entry, dest)
      result.preserved.add dest

  moveFile(tmpLink, agentDir / targetName)

  result.target = targetName
  result.message = "switched to model: " & targetName

## Function purpose: the two named targets the tray and the model menu have
## always offered. **Kept as its own entry point rather than folded into
## `switchToPath`** — Directive 3: `jenova-core models switch instruct` is a
## shipped surface and must keep working unchanged.
proc switchModel*(jcaHome, target: string): SwitchResult =
  if target notin ["instruct", "thinking"]:
    raise newException(ModelError,
      "target must be 'instruct' or 'thinking', got: " & target)
  result = switchToPath(jcaHome, targetModel(jcaHome, target))
  result.message = "switched to " & target & " model: " & result.target

type
  InstalledModel* = object
    ## One `.gguf` the tree holds, as a model list needs it.
    path*: string    ## absolute
    name*: string    ## file name
    role*: string    ## the `models/` subdirectory it sits in; "" for a flat one
    bytes*: int64
    active*: bool    ## resolves to the same file as the live `models/agent` link

## Function purpose: the real file the active agent model points at, or "" when
## there is none. Every row's `active` flag is this compared against.
proc activeAgentPath*(jcaHome: string): string =
  let cur = findModel(jcaHome / "models" / "agent")
  if cur.len == 0: return ""
  try: cur.expandFilename except OSError: cur

## Function purpose: every model on disk, which is what a selector draws.
##
## **`discover` cannot answer this and that is why this exists** (8a): it
## resolves *one* path for one of three fixed roles and throws the rest of the
## directory away. Backups are skipped for the reason `isBackup` records — a
## `.old` is a previous model, not an installed one — and `models/agent` is
## skipped because its entries are symlinks to rows already listed under their
## own role, which would otherwise appear twice.
proc available*(jcaHome: string): seq[InstalledModel] =
  let
    modelsDir = jcaHome / "models"
    activeReal = activeAgentPath(jcaHome)
  if not dirExists(modelsDir): return

  # The flat directory first, then each role beneath it. `agent` is deliberately
  # not scanned; see the note above.
  var dirs = @[(modelsDir, "")]
  for kind, path in walkDir(modelsDir):
    if kind notin {pcDir, pcLinkToDir}: continue
    let role = path.extractFilename
    if role == "agent": continue
    dirs.add (path, role)

  for (dir, role) in dirs:
    if not dirExists(dir): continue
    for kind, path in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile}: continue
      if not path.endsWith(".gguf"): continue
      if path.isBackup: continue
      var size = 0'i64
      try: size = getFileSize(path) except CatchableError: discard
      let real = try: path.expandFilename except OSError: path
      result.add InstalledModel(path: path, name: path.extractFilename,
                                role: role, bytes: size,
                                active: activeReal.len > 0 and real == activeReal)

  result.sort(proc (a, b: InstalledModel): int =
    if a.role != b.role: cmp(a.role, b.role) else: cmp(a.name, b.name))
