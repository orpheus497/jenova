## Script function and purpose: finding the GGUF files under `$JCA_HOME/models`
## and making one of them the active agent model. `config.load` fills the three
## model keys from here when the conf files leave them empty, and the window
## calls `switchModel` directly, so changing models spawns nothing.

import std/[algorithm, os, strutils]

type
  ModelKind* = enum
    ## Each maps to one subdirectory of `$JCA_HOME/models` and to one
    ## `llama-server` argument.
    mkAgent = "agent"
    mkDraft = "draft"
    mkEmbed = "embed"

  ModelError* = object of CatchableError

  SwitchResult* = object
    ## What the switch did, so a caller reports it without re-deriving it. The
    ## window shows `message`; the tests assert on the individual fields.
    target*: string      ## the .gguf now active in models/agent
    preserved*: seq[string]  ## real files renamed to .old — never symlinks
    removed*: seq[string]    ## displaced links, and entries already on the target
    message*: string

## Function purpose: `.old` and `.old.N` backups sit in the same directory and
## still end in `.gguf`, so every scan that wants active models must skip them.
## One test rather than three, because three would drift.
proc isBackup*(path: string): bool =
  let name = path.extractFilename
  name.endsWith(".old") or name.contains(".old.")

## Function purpose: the first `*.gguf` in collation order. Symlinks count,
## because a switch makes the active model a symlink and a files-only scan finds
## nothing after one. The sort is explicit because `walkDir` has no defined
## order, and the choice has to be the same on every call.
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

## Function purpose: the three paths `lifecycle` builds its argument vectors
## from, resolved in one place so a caller cannot get a different answer.
##
## Action purpose: only the agent falls back to a flat `models/` directory. Draft
## and embed answer empty instead, because giving them a fallback would start
## passing `-md` and `-m` paths where the intent was to run without them.
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

## Function purpose: the first non-backup `*.gguf` a named target offers. Raises
## rather than answering empty, because a named target that holds no model is a
## mistake the caller made and not a state to carry on from.
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

## Function purpose: activates any model in the tree. The ordering below is what
## makes the operation safe rather than merely working, and each step exists for
## a failure the previous one does not cover:
##
## 1. The replacement is built and validated under a temporary name before
##    anything active is touched, so a switch that fails half way leaves the old
##    model in place rather than an empty `models/agent`.
## 2. The link target is relative, so the tree survives being moved.
## 3. A displaced entry is preserved only when it is the user's only copy. A
##    symlink is removed, because the file it points at is still in its source
##    folder; a real file dropped in by hand is renamed to `.old`.
## 4. The swap is a rename, which is atomic, so no reader sees the directory
##    without an active model.
proc switchToPath*(jcaHome, modelPath: string): SwitchResult =
  if not modelPath.endsWith(".gguf"):
    raise newException(ModelError, "not a .gguf: " & modelPath)
  if not (fileExists(modelPath) or symlinkExists(modelPath)):
    raise newException(ModelError, "model does not exist: " & modelPath)

  let modelsDir = jcaHome / "models"
  # Action purpose: exported, so a caller can hand it any path. Activating a
  # file from outside the model tree would put a symlink into `models/agent`
  # pointing anywhere on disk, so containment is checked here and not trusted.
  if not modelPath.isRelativeTo(modelsDir):
    raise newException(ModelError,
      "model is outside " & modelsDir & ": " & modelPath)

  let
    agentDir = modelsDir / "agent"
    targetName = modelPath.extractFilename
    targetReal = try: modelPath.expandFilename except OSError: modelPath

  createDir(agentDir)
  let linkTarget = relativePath(modelPath, agentDir)

  # Action purpose: a name ending in `.tmp.<pid>` cannot match the `*.gguf` scan
  # below, so the clearing loop can never mistake the replacement for an entry
  # to preserve, and two concurrent switches cannot collide.
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
    elif symlinkExists(entry):
      # Action purpose: every entry this proc writes is a symlink into a source
      # folder, so renaming one to `.old` only adds a second name for a file that
      # has not moved. `symlinkExists` is an lstat, which is what distinguishes
      # the link from a real `.gguf` dropped in by hand.
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

## Function purpose: the two named targets the tray and the model menu offer.
## Kept as its own entry point rather than folded into `switchToPath`, because
## `jenova-core models switch instruct` is a shipped surface.
proc switchModel*(jcaHome, target: string): SwitchResult =
  if target notin ["instruct", "thinking"]:
    raise newException(ModelError,
      "target must be 'instruct' or 'thinking', got: " & target)
  result = switchToPath(jcaHome, targetModel(jcaHome, target))
  result.message = "switched to " & target & " model: " & result.target

type
  InstalledModel* = object
    ## One `.gguf` the tree holds, as a selector needs it.
    path*: string    ## absolute
    name*: string    ## file name
    role*: string    ## the `models/` subdirectory it sits in; "" for a flat one
    bytes*: int64
    active*: bool    ## resolves to the same file as the live `models/agent` link

## Function purpose: the real file behind the active symlink, which is what an
## `active` flag has to be compared against — the link's own path never matches.
proc activeAgentPath*(jcaHome: string): string =
  let cur = findModel(jcaHome / "models" / "agent")
  if cur.len == 0: return ""
  try: cur.expandFilename except OSError: cur

const SourceRoles* = ["instruct", "thinking"]
  ## The only two directories a switch may draw from. The user owns them and
  ## this module reads them without managing them.

## Function purpose: what the selector draws. `discover` cannot answer it — that
## resolves one path per role and discards the rest of the directory.
##
## Action purpose: only the two source roles are scanned. Walking every
## subdirectory would offer embed and drafter models as the agent model, which
## `lifecycle` never launches and which fails as a model behaving oddly rather
## than as a list that lied. `models/agent` is the slot being swapped, not a
## source.
proc available*(jcaHome: string): seq[InstalledModel] =
  let
    modelsDir = jcaHome / "models"
    activeReal = activeAgentPath(jcaHome)

  for role in SourceRoles:
    let dir = modelsDir / role
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
