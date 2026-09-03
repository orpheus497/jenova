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
    target*: string      ## the source .gguf now behind models/agent/active.gguf
    preserved*: seq[string]  ## real files renamed to .old — never symlinks
    removed*: seq[string]    ## displaced links, and entries already on the target
    failures*: seq[string]   ## entries the cleanup could not clear, by name
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

const ActiveLink* = "active.gguf"
  ## The one name a switch writes into `models/agent`. Fixed rather than the
  ## model's own filename so that reading the slot is a lookup and not a guess:
  ## anything else in the directory — a hand-dropped `.gguf`, an entry a failed
  ## cleanup could not clear — used to win on collation order and silently run a
  ## model nobody selected.

## Function purpose: the active agent model, by name where a switch has set one
## and by collation order where it has not. The fallback is for directories no
## switch has touched: an install predating `ActiveLink`, or one the operator
## fills by hand.
proc agentModel*(agentDir: string): string =
  let active = agentDir / ActiveLink
  if symlinkExists(active) or fileExists(active):
    return active
  findModel(agentDir)

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
    result = agentModel(modelsDir / "agent")
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

## Function purpose: the one place the cleanup warning is worded, so the two
## entry points cannot disagree about whether a switch that could not tidy up
## says so.
proc withCleanup*(msg: string, failures: seq[string]): string =
  if failures.len == 0: msg
  else: msg & " (could not clear: " & failures.join(", ") & ")"

## Function purpose: activates any model in the tree. The ordering below is what
## makes the operation safe rather than merely working, and each step exists for
## a failure the previous one does not cover:
##
## 1. The replacement is built and validated under a temporary name, then moved
##    into place before any old entry is touched — so the slot holds a working
##    model from the first mutation onward, and a later failure is untidiness
##    rather than an empty `models/agent`.
## 2. The link target is relative, so the tree survives being moved.
## 3. A displaced entry is preserved only when it is the user's only copy. A
##    symlink is removed, because the file it points at is still in its source
##    folder; a real file dropped in by hand is renamed to `.old`.
## 4. The swap is a rename, which is atomic, so no reader sees the directory
##    without an active model, and the source may not itself be in the slot.
## 5. The link is always named `ActiveLink`, never after the model. That is what
##    makes the slot readable by lookup: a second `.gguf` in the directory is
##    then untidiness, where before it decided which model ran.
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

  # Action purpose: the active slot cannot be its own source. `isRelativeTo`
  # above admits anything under `models/`, and `models/agent` is under `models/`
  # — so activating an entry already in the slot made `linkTarget` resolve to the
  # entry itself, and the clearing loop below removed the very file being
  # activated. The result was a symlink pointing at its own name.
  #
  # **The resolved path is checked as well as the given one**, because the given
  # one can reach the slot through an indirection the first test cannot see: a
  # `models/instruct/aaa.gguf` that is itself a link to `models/agent/active.gguf`
  # is not under `agentDir` by name. It passed, and the `tmpReal == targetReal`
  # validation below passed too — both resolve to the same real model while the
  # old link is still in place — and then the rename replaced that link with one
  # pointing back through `aaa.gguf` to itself. The switch reported success and
  # left an `ELOOP` where the model had been.
  let agentReal = try: agentDir.expandFilename except OSError: agentDir
  if modelPath.isRelativeTo(agentDir) or targetReal.isRelativeTo(agentReal):
    raise newException(ModelError,
      "model is already in the active slot: " & modelPath)

  createDir(agentDir)
  # Action purpose: the link is built from the RESOLVED source, so a chain of
  # symlinks is collapsed to one hop at switch time. Built from `modelPath`, a
  # source that was itself a link into the slot pointed the slot back through
  # that source at itself — an `ELOOP` reported as a successful switch. One hop
  # cannot form a cycle, and the slot naming the real file is what the reader of
  # `models list` wants anyway.
  let linkTarget = relativePath(targetReal, agentDir)

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

  # Declared before the swap because preserving a real file already in the slot
  # can fail, and that is reported through the same list as every other entry
  # the cleanup could not clear rather than through a second channel.
  var failuresPreActive: seq[string]

  var existing: seq[string]
  for kind, path in walkDir(agentDir):
    if kind notin {pcFile, pcLinkToFile}: continue
    if not path.endsWith(".gguf"): continue
    if path.isBackup: continue
    existing.add path
  existing.sort()

  # Action purpose: the swap happens before the clearing, not after it. The
  # header's promise — that a switch failing half way leaves the old model in
  # place rather than an empty `models/agent` — was not kept by the old order:
  # the loop below removed and renamed entries one at a time and the rename into
  # place came last, so an `OSError` in the middle left the directory with no
  # active model at all.
  #
  # `moveFile` is a rename, which replaces any existing entry of that name
  # atomically. Doing it first means the slot holds the right model from this
  # point on, and anything that fails afterwards is untidiness rather than an
  # unusable installation.
  let active = agentDir / ActiveLink
  # Action purpose: `moveFile` is a rename, which replaces the destination
  # silently — and the destination is skipped by the clearing loop below on the
  # grounds that it is the entry just put there. So a REAL `active.gguf`, one an
  # operator dropped in by hand or an install predating `ActiveLink` left, was
  # neither preserved nor removed: it was destroyed by the rename, with a
  # success message and a `preserved` list that did not mention it. A symlink is
  # still simply replaced — the file it names has not moved and is still in its
  # source folder, which is the same reasoning the clearing loop uses.
  if fileExists(active) and not symlinkExists(active):
    var dest = active & ".old"
    if fileExists(dest) or symlinkExists(dest):
      var counter = 1
      while fileExists(active & ".old." & $counter) or
            symlinkExists(active & ".old." & $counter):
        counter += 1
      dest = active & ".old." & $counter
    try:
      moveFile(active, dest)
      result.preserved.add dest
    except OSError, IOError:
      # Reported like any other entry the cleanup could not clear. Raising here
      # would abort a switch whose replacement is already validated and ready,
      # and the rename below still leaves the slot correct.
      failuresPreActive.add active.extractFilename
  moveFile(tmpLink, active)
  result.target = targetName

  var failures = failuresPreActive
  for entry in existing:
    # The entry just moved into place is the answer, not a leftover.
    if entry == active: continue
    try:
      let entryReal = try: entry.expandFilename except OSError: ""
      if (entryReal.len > 0 and entryReal == targetReal) or symlinkExists(entry):
        # Action purpose: every entry this proc writes is a symlink into a source
        # folder, so removing one drops a second name for a file that has not
        # moved. `symlinkExists` is an lstat, which is what distinguishes the
        # link from a real `.gguf` dropped in by hand.
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
    except OSError, IOError:
      # One entry that could not be cleared does not undo a switch that already
      # happened. Reported rather than raised, because raising here would tell
      # the caller the switch failed when the active model is correct.
      failures.add entry.extractFilename

  result.failures = failures
  result.message = withCleanup("switched to model: " & targetName, failures)

## Function purpose: the two named targets the tray and the model menu offer.
## Kept as its own entry point rather than folded into `switchToPath`, because
## `jenova-core models switch instruct` is a shipped surface.
proc switchModel*(jcaHome, target: string): SwitchResult =
  if target notin ["instruct", "thinking"]:
    raise newException(ModelError,
      "target must be 'instruct' or 'thinking', got: " & target)
  result = switchToPath(jcaHome, targetModel(jcaHome, target))
  # Through `withCleanup` and not a plain assignment: this rewrites the message
  # `switchToPath` composed, and a plain one dropped its cleanup warning — so a
  # named switch, which is what the tray and the model menu both call, reported
  # an unqualified success over a directory it had failed to clear.
  result.message = withCleanup(
    "switched to " & target & " model: " & result.target, result.failures)

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
  let cur = agentModel(jcaHome / "models" / "agent")
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
