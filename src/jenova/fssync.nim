## Script function and purpose: the filesystem mirror behind `/api/db/*` and the
## `/api/fs/*` routes, replacing `lib/fs_sync.lua`.
##
## Every workspace, project, folder, note and file asset in the database has a
## real counterpart on disk under `$JENOVA_WORKSPACES`. Deleting one moves it into
## a trash tree beside a `.metadata.json` sidecar rather than unlinking it, which
## is what makes restore possible. **This is the half of the `/api/db/*` contract
## `src/jenova/api.nim` was missing** — recorded as N-27, and it matters beyond
## fidelity: the RAG layer at N-S5b indexes these files, so a core that never
## writes them would index an empty tree.
##
## The path layout, trash naming and metadata shape are reproduced from
## `lib/fs_sync.lua` exactly, because `jca_web` is frozen (D-Z) and reads them.
##
## **Three deliberate deviations, all removals of forks rather than behaviour:**
## `fs_sync.lua` shells out to `find` for every listing, runs `test -d` once per
## entry in `get_fs_tree`, and `rm -rf` for emptying trash (B-16, B-17). Those
## existed because LuaJIT on a single event loop had no better option. Here the
## walk is native `os` code on a worker thread, so the fork storm simply does not
## arise. The observable results are identical; only the process count changes.

import std/[os, json, strutils, times, base64, osproc, algorithm, streams, random]
import ./db
import ./paths

type
  TrashKind* = enum
    tkGlobal = "global"
    tkWorkspace = "workspace"

  TrashEntry* = object
    path*: string
    kind*: TrashKind
    workspace*: string
    name*: string

  FsResult* = object
    ok*: bool
    path*: string      ## where the item now lives (trash path), when relevant
    original*: string  ## where it came from
    msg*: string

var wsRoot {.threadvar.}: string
var trashRoot {.threadvar.}: string

## Function purpose: resolve the two roots once per thread. `paths.resolve` reads
## the environment, and doing that per call would make every mirroring write pay
## for it. Deliberately threadvar rather than a global: a shared string is
## refcounted memory that every worker thread would touch, which is neither
## GC-safe nor necessary — the same reasoning that made `api.nim`'s entity table
## `const` and `db.nim`'s connection per-thread.
proc roots(): tuple[workspaces, trash: string] =
  if wsRoot.len == 0:
    let p = paths.resolve()
    wsRoot = p.workspaces
    trashRoot = p.jcaHome / ".trash"
  (wsRoot, trashRoot)

## Function purpose: make a database-supplied name safe to use as one path
## component. Reproduces `fs_sync.lua:29` exactly — separators become
## underscores and leading dots are stripped, so a name can neither escape its
## directory nor create a hidden entry.
proc sanitize*(s: string): string =
  if s.len == 0: return ""
  result = newStringOfCap(s.len)
  for ch in s:
    result.add (if ch == '/' or ch == '\\': '_' else: ch)
  var start = 0
  while start < result.len and result[start] == '.':
    inc start
  result = result[start .. ^1]

## Function purpose: the original only mirrors rows whose id is a real UUID
## (`fs_sync.lua:70`). It is a guard against a malformed id becoming a filename,
## and dropping it would widen what can be written to disk.
proc isValidUuid*(id: string): bool =
  if id.len != 36: return false
  const dashes = [8, 13, 18, 23]
  for i, ch in id:
    if i in dashes:
      if ch != '-': return false
    elif ch notin HexDigits:
      return false
  true

## Seeded per thread: the default global RNG is deterministic, which would make
## two runs mint the same "unique" ids — and a single shared `Rand` is mutable
## state every worker thread would advance concurrently, which is the same race
## the roots above are threadvar to avoid. The thread id joins the seed so two
## threads starting inside the same microsecond do not mint the same stream.
var uuidRng {.threadvar.}: Rand
var uuidRngSeeded {.threadvar.}: bool

proc seedUuidRng() =
  if not uuidRngSeeded:
    uuidRng = initRand(int(epochTime() * 1_000_000) xor
                       getCurrentProcessId() xor getThreadId())
    uuidRngSeeded = true

## Function purpose: the counterpart to `isValidUuid`, and the reason it has to
## exist is `physicalPath` — it refuses any note or file-asset id that is not a
## UUID, and `upsert` then deletes the row it just wrote. A caller minting one of
## those ids needs this; `genOid` produces 24 hex characters and is rejected.
proc newUuid*(): string =
  seedUuidRng()
  var bytes: array[16, uint8]
  for b in bytes.mitems: b = uint8(uuidRng.rand(255))
  bytes[6] = (bytes[6] and 0x0f'u8) or 0x40'u8   # version 4
  bytes[8] = (bytes[8] and 0x3f'u8) or 0x80'u8   # RFC 4122 variant
  const hex = "0123456789abcdef"
  result = newStringOfCap(36)
  for i, b in bytes:
    if i in [4, 6, 8, 10]: result.add '-'
    result.add hex[int(b shr 4)]
    result.add hex[int(b and 0x0f)]

proc epochPrefix(): string = $int(epochTime())

proc ensureDir(path: string) =
  if path.len > 0:
    createDir(path)

## Function purpose: run one git command in a workspace, replacing `lib/git.lua`'s
## `io.popen` wrapper. Arguments are passed as a vector, never interpolated into a
## shell string — `git.lua` hand-quoted every path into `sh -c`, and a workspace
## name is user data.
proc gitRun(cwd: string, args: openArray[string]): bool =
  if not dirExists(cwd): return false
  try:
    let p = startProcess("git", workingDir = cwd, args = @args,
                         options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    discard p.outputStream.readAll()
    p.waitForExit() == 0
  except OSError, IOError:
    false

proc gitInit(workspacePath: string): bool =
  if not gitRun(workspacePath, ["init"]): return false
  discard gitRun(workspacePath, ["config", "user.email", "jenova@local"])
  discard gitRun(workspacePath, ["config", "user.name", "Jenova"])
  true

proc gitAdd(workspacePath, filePath: string) =
  discard gitRun(workspacePath, ["add", filePath])

# ---------------------------------------------------------------------------
# Physical path resolution
# ---------------------------------------------------------------------------

proc lookupName(table, id: string): tuple[found: bool, name, parent: string] =
  ## Returns the row's name and its parent id, for walking note -> folder ->
  ## project -> workspace. The parent column differs per table, so it is named
  ## here rather than inferred.
  let parentCol =
    case table
    of "folders": "projectId"
    of "projects": "workspaceId"
    else: ""
  let sql =
    if parentCol.len > 0:
      "SELECT name, " & parentCol & " FROM " & table & " WHERE id=?"
    else:
      "SELECT name FROM " & table & " WHERE id=?"
  let rows = db.query(sql, id)
  if rows.len == 0: return (false, "", "")
  (true, rows[0][0], (if parentCol.len > 0 and rows[0].len > 1: rows[0][1] else: ""))

proc isSet(v: string): bool =
  v.len > 0 and v != "null"

## Function purpose: build the on-disk path for a note or asset by walking its
## ancestry, reproducing `fs_sync.lua:76-128`. The three placements — under a
## folder, under a project, or directly under a workspace — are the client's
## contract, and an item with no resolvable ancestry lands in `unassigned/`
## rather than being dropped.
proc physicalPath(id, displayName, folderId, projectId, workspaceId,
                  suffix: string): tuple[path, workspace: string] =
  let (workspaces, _) = roots()
  if not isValidUuid(id):
    return ("", "")
  let safeName = sanitize(displayName)

  if isSet(folderId):
    let f = lookupName("folders", folderId)
    if f.found:
      let p = lookupName("projects", f.parent)
      if p.found:
        let w = lookupName("workspaces", p.parent)
        if w.found:
          let ws = sanitize(w.name)
          return (workspaces / ws / sanitize(p.name) / sanitize(f.name) &
                  "/" & safeName & "_" & id & suffix, ws)
  elif isSet(projectId):
    let p = lookupName("projects", projectId)
    if p.found:
      let w = lookupName("workspaces", p.parent)
      if w.found:
        let ws = sanitize(w.name)
        return (workspaces / ws / sanitize(p.name) & "/" & safeName & "_" &
                id & suffix, ws)
  elif isSet(workspaceId):
    let w = lookupName("workspaces", workspaceId)
    if w.found:
      let ws = sanitize(w.name)
      return (workspaces / ws & "/" & safeName & "_" & id & suffix, ws)

  (workspaces / "unassigned" & "/" & safeName & "_" & id & suffix, "unassigned")

## Function purpose: the directory an item with this ancestry lives in — the same
## walk `physicalPath` does, stopping at the directory instead of naming a file.
##
## The GUI's document panel (G-25) needs it: a chat's documents are plain files
## beside that chat's notes, so the panel has to resolve the same folder →
## project → workspace chain from ids to sanitized names. Reproducing that walk
## in `gui.nim` would be two definitions of one layout, and they would drift the
## first time a name is sanitized differently.
proc scopeDir*(folderId, projectId, workspaceId: string): string =
  let (workspaces, _) = roots()
  if isSet(folderId):
    let f = lookupName("folders", folderId)
    if f.found:
      let p = lookupName("projects", f.parent)
      if p.found:
        let w = lookupName("workspaces", p.parent)
        if w.found:
          return workspaces / sanitize(w.name) / sanitize(p.name) / sanitize(f.name)
  elif isSet(projectId):
    let p = lookupName("projects", projectId)
    if p.found:
      let w = lookupName("workspaces", p.parent)
      if w.found:
        return workspaces / sanitize(w.name) / sanitize(p.name)
  elif isSet(workspaceId):
    let w = lookupName("workspaces", workspaceId)
    if w.found:
      return workspaces / sanitize(w.name)
  workspaces / "unassigned"

## Function purpose: the directory a container occupies, resolved from an explicit
## name and parent id rather than from its own row. `api.upsert` overwrites the
## row before the mirror runs, so a container's *previous* location can only be
## rebuilt from the values captured beforehand — which is what makes moving the
## directory possible at all. The layout is the same one `trashProject` and
## `trashFolder` build, so a container that has been moved is still found when it
## is later deleted.
proc containerDir*(kind, name, parentId: string): string =
  let (workspaces, _) = roots()
  let safe = sanitize(name)
  if safe.len == 0: return ""
  case kind
  of "workspaces":
    workspaces / safe
  of "projects":
    let w = lookupName("workspaces", parentId)
    if not w.found: "" else: workspaces / sanitize(w.name) / safe
  of "folders":
    let p = lookupName("projects", parentId)
    if not p.found: return ""
    let w = lookupName("workspaces", p.parent)
    if not w.found: ""
    else: workspaces / sanitize(w.name) / sanitize(p.name) / safe
  else:
    ""

## Function purpose: move a container's directory when its name or its parent
## changes. Without this a rename strands everything underneath it: every note and
## asset path is built from ancestor *names* (`physicalPath`), so the row moved and
## the directory did not, leaving the old tree orphaned and the next write landing
## in a fresh empty directory beside it (T-14).
##
## Returns false only when the move itself could not be done, so `api.upsert` rolls
## the row back — a database claiming a name the disk does not carry is the state
## this mirror exists to prevent. **A container with no directory yet is not a
## failure:** directories are created by the first note or asset written into them,
## so there is simply nothing to move.
proc renameContainer*(kind, priorName, priorParent, newName,
                      newParent: string): bool =
  let dst = containerDir(kind, newName, newParent)
  if dst.len == 0: return false
  let src = containerDir(kind, priorName, priorParent)
  if src.len == 0 or src == dst: return true
  if not dirExists(src): return true
  # Action purpose: a sibling already standing at the new path would be merged
  # into by `moveDir`, silently mixing two containers' files together. Refusing
  # hands the caller a rollback instead, which is recoverable; a merge is not.
  if dirExists(dst) or fileExists(dst): return false
  try:
    ensureDir(dst.parentDir)
    moveDir(src, dst)
    true
  except OSError:
    false

proc notePath(id, title, folderId, projectId, workspaceId: string):
    tuple[path, workspace: string] =
  physicalPath(id, title, folderId, projectId, workspaceId, ".md")

proc assetPath(id, name, folderId, projectId, workspaceId: string):
    tuple[path, workspace: string] =
  physicalPath(id, name, folderId, projectId, workspaceId, "")

proc workspaceTrash(workspaceName: string): string =
  let (workspaces, _) = roots()
  result = workspaces / workspaceName / ".trash"
  ensureDir(result)

## Function purpose: the sidecar that makes restore possible. `restore_trash`
## reads it back to recover both the original path and the database row to
## un-delete, so a trashed item that loses this file can only be restored by
## hand.
proc writeTrashMetadata(trashPath, table, id, originalPath: string) =
  try:
    writeFile(trashPath & ".metadata.json",
              $(%*{"type": table, "id": id, "original_path": originalPath}))
  except IOError, OSError:
    discard

proc moveToTrash(source, trashPath, table, id: string): bool =
  try:
    ensureDir(trashPath.parentDir)
    moveFile(source, trashPath)
    writeTrashMetadata(trashPath, table, id, source)
    true
  except OSError, IOError:
    false

# ---------------------------------------------------------------------------
# Sync — database row to disk
# ---------------------------------------------------------------------------

## Function purpose: a workspace is a git repository, created on first sync.
## `fs_sync.lua:141` removes the directory again if `git init` fails, so a
## half-made workspace is not left behind; that is reproduced.
##
## `priorName` is the name the row carried before this upsert, empty on insert.
## A rename **moves** the repository instead of leaving it behind under the old
## name with every file still in it (T-14).
proc syncWorkspace*(name: string, priorName = ""): bool =
  let (workspaces, _) = roots()
  let path = workspaces / sanitize(name)
  # `priorName != name` is checked first so the common case — a re-sync of an
  # unchanged workspace — costs one string compare instead of two `sanitize`
  # allocations.
  if priorName.len > 0 and priorName != name and
     sanitize(priorName) != sanitize(name):
    if not renameContainer("workspaces", priorName, "", name, ""):
      return false
  # Action purpose: whether this call created the directory decides whether it may
  # unmake it below. Removing one that was already there — or that a rename has
  # just moved here — would delete the user's files, which the original could not
  # do because it only ever created.
  let created = not dirExists(path)
  try:
    ensureDir(path)
  except OSError:
    return false
  if not gitInit(path):
    if created:
      try: removeDir(path)
      except OSError: discard
    return false
  true

proc syncNote*(id, title, content, folderId, projectId, workspaceId: string): bool =
  let (path, ws) = notePath(id, title, folderId, projectId, workspaceId)
  if path.len == 0: return false
  let (workspaces, _) = roots()
  try:
    ensureDir(path.parentDir)
    writeFile(path, content)
  except IOError, OSError:
    return false
  gitAdd(workspaces / ws, path)
  true

## Function purpose: read a note's mirror file back off disk — the half of this
## module that did not exist (`PLANS.md` Step 13b).
##
## **Every `sync*` proc above writes one way, database to disk.** Nothing read a
## `.md` back, so an edit made outside the note editor — in the embedded Neovim,
## in another editor, over `/api/storage` — was written to a file the database
## then ignored for ever, and the next save silently overwrote it. That is the
## `SyncService.pull` gap.
##
## The path is `notePath`'s, not a second construction of it: a reader that
## built the path itself would drift from the writer the first time `sanitize`
## changed, and then quietly reconcile nothing.
proc readNoteMirror*(id, title, folderId, projectId, workspaceId: string):
    tuple[found: bool, content: string] =
  let (path, _) = notePath(id, title, folderId, projectId, workspaceId)
  if path.len == 0 or not fileExists(path): return (false, "")
  try:
    (true, readFile(path))
  except IOError, OSError:
    (false, "")

## Function purpose: file assets arrive from the Web UI as `data:` URIs, so the
## base64 payload is decoded back to bytes before writing — otherwise every
## uploaded image is stored as its own text encoding. Reproduces
## `fs_sync.lua:172-180`, including the rejection of a payload whose length is
## not a multiple of four rather than writing truncated bytes.
proc syncFileAsset*(id, name, content, folderId, projectId,
                    workspaceId: string): bool =
  let (path, ws) = assetPath(id, name, folderId, projectId, workspaceId)
  if path.len == 0: return false
  let (workspaces, _) = roots()

  var payload = content
  let marker = "base64,"
  if content.startsWith("data:"):
    let idx = content.find(marker)
    if idx >= 0:
      var clean = newStringOfCap(content.len)
      for ch in content[(idx + marker.len) .. ^1]:
        if ch in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}:
          clean.add ch
      if clean.len mod 4 != 0: return false
      try:
        payload = base64.decode(clean)
      except ValueError:
        return false

  try:
    ensureDir(path.parentDir)
    writeFile(path, payload)
  except IOError, OSError:
    return false
  gitAdd(workspaces / ws, path)
  true

# ---------------------------------------------------------------------------
# Trash — move to trash rather than unlink
# ---------------------------------------------------------------------------

proc trashNote*(id, title, folderId, projectId, workspaceId: string): bool =
  let (path, ws) = notePath(id, title, folderId, projectId, workspaceId)
  if path.len == 0:
    # `fs_sync.lua:206`: an unassigned item with no resolvable path is not an
    # error — there was nothing on disk to move.
    return ws == "unassigned"
  if not fileExists(path): return true
  let dest = workspaceTrash(ws) / epochPrefix() & "_" & path.extractFilename
  moveToTrash(path, dest, "notes", id)

proc trashFileAsset*(id, name, folderId, projectId, workspaceId: string): bool =
  let (path, ws) = assetPath(id, name, folderId, projectId, workspaceId)
  if path.len == 0:
    return ws == "unassigned"
  if not fileExists(path): return true
  let dest = workspaceTrash(ws) / epochPrefix() & "_" & path.extractFilename
  moveToTrash(path, dest, "fileAssets", id)

proc trashWorkspace*(id, name: string): bool =
  let (workspaces, trash) = roots()
  let safe = sanitize(name)
  let path = workspaces / safe
  if not dirExists(path): return true
  ensureDir(trash)
  let dest = trash / epochPrefix() & "_" & safe
  try:
    moveDir(path, dest)
    writeTrashMetadata(dest, "workspaces", id, path)
    true
  except OSError:
    false

## Function purpose: project and folder trashing must resolve their ancestry
## through the database first, because the on-disk path is built from ancestor
## *names*. `fs_sync.lua:248` treats an already-absent directory as success
## (ENOENT) and anything else as failure — that distinction is kept, since a
## delete of something that was never mirrored is not an error.
proc trashProject*(id, workspaceId, name: string): FsResult =
  let (workspaces, _) = roots()
  let w = lookupName("workspaces", workspaceId)
  if not w.found:
    return FsResult(ok: false, msg: "workspace not found")
  let safeWs = sanitize(w.name)
  let path = workspaces / safeWs / sanitize(name)
  if not dirExists(path):
    return FsResult(ok: true, original: path)
  let dest = workspaceTrash(safeWs) / epochPrefix() & "_" & sanitize(name)
  try:
    moveDir(path, dest)
    writeTrashMetadata(dest, "projects", id, path)
    FsResult(ok: true, path: dest, original: path)
  except OSError:
    FsResult(ok: false, path: dest, original: path, msg: "rename failed")

proc trashFolder*(id, projectId, name: string): FsResult =
  let (workspaces, _) = roots()
  let p = lookupName("projects", projectId)
  if not p.found:
    return FsResult(ok: false, msg: "project not found")
  let w = lookupName("workspaces", p.parent)
  if not w.found:
    return FsResult(ok: false, msg: "workspace not found")
  let safeWs = sanitize(w.name)
  let path = workspaces / safeWs / sanitize(p.name) / sanitize(name)
  if not dirExists(path):
    return FsResult(ok: true, original: path)
  let dest = workspaceTrash(safeWs) / epochPrefix() & "_" & sanitize(name)
  try:
    moveDir(path, dest)
    writeTrashMetadata(dest, "folders", id, path)
    FsResult(ok: true, path: dest, original: path)
  except OSError:
    FsResult(ok: false, path: dest, original: path, msg: "rename failed")

# ---------------------------------------------------------------------------
# Trash listing, restore, empty — the /api/fs/* surface (N-20)
# ---------------------------------------------------------------------------

proc collectTrash(dir: string, kind: TrashKind, workspace: string,
                  acc: var seq[TrashEntry]) =
  if not dirExists(dir): return
  for path in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile}):
    let base = path.extractFilename
    if base == ".git" or path.contains("/.git/"): continue
    if path.endsWith(".metadata.json"): continue
    acc.add TrashEntry(path: path, kind: kind, workspace: workspace, name: base)

## Function purpose: list everything in the global trash and in every workspace's
## own `.trash`, which is what `GET /api/fs/trash` returns. `fs_sync.lua:314`
## does this with two `find` subprocesses; the walk here is native.
proc getTrash*(): seq[TrashEntry] =
  let (workspaces, trash) = roots()
  collectTrash(trash, tkGlobal, "", result)
  # A-17. `storageTrash` files a deleted storage path under `<workspaces>/.trash`
  # so its relative structure survives the move, and this walk never looked
  # there: it enumerated `<workspaces>` as a list of workspaces, met `.trash`
  # among them, and went looking for `<workspaces>/.trash/.trash`, which cannot
  # exist. So every `/api/storage` deletion was invisible here and to
  # `emptyTrash`, and accumulated for ever with no way to list or clear it.
  #
  # They are `tkGlobal` because they belong to no one workspace — which also
  # leaves the JSON `toJson` emits byte-identical, since `workspace` is only
  # added for `tkWorkspace` and `jca_web` is frozen against that shape (D-Z).
  collectTrash(workspaces / ".trash", tkGlobal, "", result)
  if dirExists(workspaces):
    for kind, wsPath in walkDir(workspaces):
      if kind != pcDir: continue
      # Collected above, and it is not a workspace.
      if wsPath.extractFilename == ".trash": continue
      let wsTrash = wsPath / ".trash"
      if dirExists(wsTrash):
        collectTrash(wsTrash, tkWorkspace, wsPath.extractFilename, result)

## Function purpose: move an item back out of the trash and un-delete its
## database row. The sidecar's `original_path` wins over the caller-supplied one
## — `fs_sync.lua:356` does the same, because the client sends back what it was
## shown while the sidecar is what was actually recorded at deletion.
## Function purpose: is `path` the root itself or something beneath it? A bare
## prefix test accepts `<root>-evil` as being inside `<root>`, which is the same
## directory-boundary rule `resolveStoragePath` applies.
proc underRoot(path, root: string): bool =
  if root.len == 0: return false
  let r = root.normalizedPath
  path == r or path.startsWith(r & "/")

## Action purpose: the tables `writeTrashMetadata` is ever called with. The
## sidecar is a file on disk, so its `type` field is untrusted input that was
## being concatenated straight into an UPDATE statement; only these five names
## may reach the SQL.
const RestorableTables = ["notes", "fileAssets", "workspaces", "projects", "folders"]

proc restoreTrash*(trashPath, originalPath: string): bool =
  if trashPath.len == 0 or originalPath.len == 0: return false
  let (workspaces, trash) = roots()

  # Containment: only paths inside a known trash directory may be restored, so a
  # crafted request cannot move an arbitrary file. fs_sync.lua had no such check;
  # it is added here rather than reproduced, and is the one behavioural addition
  # in this module.
  let normalized = trashPath.normalizedPath
  if not (underRoot(normalized, trash) or
          (underRoot(normalized, workspaces) and
           normalized.contains("/.trash/"))):
    return false

  var target = originalPath
  var metaType, metaId: string
  let metaFile = trashPath & ".metadata.json"
  if fileExists(metaFile):
    try:
      let meta = parseJson(readFile(metaFile))
      if meta.kind == JObject:
        if meta.hasKey("original_path"): target = meta["original_path"].getStr
        if meta.hasKey("type"): metaType = meta["type"].getStr
        if meta.hasKey("id"): metaId = meta["id"].getStr
    except CatchableError:
      discard

  # The destination is as much a filesystem write as the source is a read, and
  # it comes from the same two untrusted places — the caller's `original_path`
  # and the sidecar. Without this a crafted pair moved a trashed file anywhere
  # the process could write.
  let normalizedTarget = target.normalizedPath
  if not (underRoot(normalizedTarget, workspaces) or
          underRoot(normalizedTarget, trash)):
    return false

  try:
    ensureDir(target.parentDir)
    if dirExists(trashPath):
      moveDir(trashPath, target)
    else:
      moveFile(trashPath, target)
  except OSError, IOError:
    return false

  if metaType.len > 0 and metaId.len > 0 and metaType in RestorableTables:
    try:
      db.exec("UPDATE " & metaType & " SET is_deleted=0 WHERE id=?", metaId)
    except CatchableError:
      discard
  try: removeFile(metaFile)
  except OSError: discard
  true

## Function purpose: put back the file or directory a delete filed in the trash,
## found by its sidecar rather than by recomputing where it used to live.
##
## **A-16: restoring from the window restored the row and never the file.**
## `api.restoreItem` contained no call into this module at all, while deletion
## mirrors with care — the item is moved into a trash tree and
## `writeTrashMetadata` writes `{type, id, original_path}` beside it *for the
## express purpose of putting it back*. Nothing ever read that sidecar from the
## desktop path. A restored note's `.md` stayed in the trash until the note
## happened to be saved again; **a restored file asset's file never came back at
## all**, having no re-save path; and a restored workspace, project or folder
## left its whole directory behind for ever. The delete confirmation the user
## is shown says "It can be restored from the trash."
##
## **The id is the key, not the path.** A path would have to be recomputed from
## the row, and the row's name may have changed since the delete — the sidecar
## records where the item actually came from, which is why it exists.
##
## **All three trash roots are walked**, and that is not one root too many: the
## global `<jcaHome>/.trash`, the storage root `<workspaces>/.trash`, and each
## workspace's own. Walking only the first two is precisely A-17, and the
## workspace loop must skip an entry named `.trash` or it enumerates the storage
## root as though it were a workspace — the mechanism behind that defect.
##
## `collectTrash` is deliberately not reused: it filters `*.metadata.json` out,
## which is the only thing being looked for here.
##
## The move itself is `restoreTrash`, so containment is enforced once, in one
## place. A second check here would be a third standard in a module that already
## has two, which is A-19's warning.
proc restoreMirror*(table, id: string): bool =
  if table notin RestorableTables or id.len == 0: return false
  let (workspaces, trash) = roots()

  var trashRoots = @[trash, workspaces / ".trash"]
  if dirExists(workspaces):
    for kind, wsPath in walkDir(workspaces):
      if kind != pcDir: continue
      if wsPath.extractFilename == ".trash": continue
      trashRoots.add wsPath / ".trash"

  const Suffix = ".metadata.json"
  for root in trashRoots:
    if not dirExists(root): continue
    for path in walkDirRec(root, yieldFilter = {pcFile}):
      if not path.endsWith(Suffix): continue
      var meta: JsonNode
      try: meta = parseJson(readFile(path))
      except CatchableError: continue
      if meta.kind != JObject: continue
      if meta{"type"}.getStr != table or meta{"id"}.getStr != id: continue
      return restoreTrash(path[0 ..< path.len - Suffix.len],
                          meta{"original_path"}.getStr)
  false

## Function purpose: empty the global trash and every workspace trash.
## `fs_sync.lua:378` shells out to `rm -rf "$dir"/*`; this removes entries
## directly, so there is no shell to quote against and no fork per workspace.
proc emptyTrash*(): bool =
  let (workspaces, trash) = roots()
  var allOk = true

  proc clear(dir: string): bool =
    result = true
    if not dirExists(dir): return
    for kind, path in walkDir(dir):
      try:
        if kind == pcDir: removeDir(path)
        else: removeFile(path)
      except OSError:
        result = false

  allOk = clear(trash)
  # A-17's other half — the storage trash root was never emptied either, for the
  # same reason `getTrash` never listed it.
  if not clear(workspaces / ".trash"): allOk = false
  if dirExists(workspaces):
    for kind, wsPath in walkDir(workspaces):
      if kind == pcDir:
        if wsPath.extractFilename == ".trash": continue
        if not clear(wsPath / ".trash"): allOk = false
  allOk

type FsNode* = object
  path*: string
  fullPath*: string
  isDir*: bool

## Function purpose: the tree `GET /api/fs/tree` returns, optionally scoped to a
## workspace, project or folder. `.trash` and `.git` are excluded, matching the
## original's `find` predicates.
##
## `fs_sync.lua:445` ran `test -d` as a **separate subprocess for every entry**
## (B-17). `walkDir` already reports the kind, so the whole fork storm
## disappears without changing a single result.
proc getFsTree*(scopeWorkspace, scopeProject, scopeFolder: string): seq[FsNode] =
  let (workspaces, _) = roots()

  proc rejected(s: string): bool =
    s.contains("..") or s.contains('/') or s.contains('\r') or s.contains('\n')

  if rejected(scopeWorkspace) or rejected(scopeProject) or rejected(scopeFolder):
    return @[]

  var searchRoot = workspaces
  if scopeWorkspace.len > 0:
    searchRoot = searchRoot / scopeWorkspace
    if scopeProject.len > 0:
      searchRoot = searchRoot / scopeProject
      if scopeFolder.len > 0:
        searchRoot = searchRoot / scopeFolder

  if not dirExists(searchRoot): return @[]

  let prefixLen = workspaces.len + 1
  for path in walkDirRec(searchRoot, yieldFilter = {pcFile, pcDir}):
    if path.contains("/.trash") or path.contains("/.git"): continue
    if path.len <= prefixLen: continue
    result.add FsNode(path: path[prefixLen .. ^1], fullPath: path,
                      isDir: dirExists(path))
  result.sort(proc (a, b: FsNode): int = cmp(a.path, b.path))

# ---------------------------------------------------------------------------
# /api/storage/* — raw file access under the workspaces root (N-29)
# ---------------------------------------------------------------------------

## Function purpose: lexical path normalisation, reproducing
## `lib/proxy.lua:normalize_path`. Collapses `//`, drops `.`, resolves `..`, and
## **returns empty when an absolute path tries to escape its own root** rather
## than clamping at `/` — the distinction matters, because clamping would turn
## an escape attempt into a valid path.
proc normalizePathLexical(path: string): string =
  var p = path
  while p.contains("//"):
    p = p.replace("//", "/")
  if p.len > 1 and p.endsWith("/"):
    p = p[0 ..< ^1]
  let isAbsolute = p.startsWith("/")
  var segments: seq[string]
  for segment in p.split('/'):
    if segment.len == 0 or segment == ".":
      continue
    elif segment == "..":
      if segments.len > 0 and segments[^1] != "..":
        discard segments.pop()
      elif isAbsolute:
        return ""            # escape attempted on an absolute path
      else:
        segments.add ".."
    else:
      segments.add segment
  result = (if isAbsolute: "/" else: "") & segments.join("/")

## Function purpose: resolve a client-supplied relative path against the
## workspaces root and refuse anything that lands outside it. Reproduces
## `proxy.lua:resolve_safe_path`, including **the directory-boundary check** —
## a prefix match alone would accept `/Workspaces-evil` for the root
## `/Workspaces`, so the character after the prefix must be `/` or the paths must
## be equal. Returns an empty string on refusal.
##
## Two guards the original does not have are added, and are asserted:
## a literal `..` rejection before normalisation (the original does this at the
## call site, so it is centralised here instead of repeated four times), and a
## symlink check — lexical normalisation cannot see that a component is a link
## pointing out of the tree, which is the one way the original's containment can
## still be walked past.
proc resolveStoragePath*(relative: string): string =
  if relative.len == 0 or relative.contains(".."):
    return ""
  if relative.contains('\0') or relative.contains('\r') or relative.contains('\n'):
    return ""
  let (workspaces, _) = roots()
  let normBase = normalizePathLexical(workspaces)
  if normBase.len == 0:
    return ""
  let candidate = normalizePathLexical(workspaces & "/" & relative)
  if candidate.len == 0:
    return ""
  if not candidate.startsWith(normBase):
    return ""
  if candidate.len != normBase.len and candidate[normBase.len] != '/':
    return ""

  # Action purpose: **T-4 — the symlink check had a hole at each end, and both
  # close the same way: resolve, then compare resolved against resolved.**
  #
  # 1. It ran only `if fileExists(candidate) or dirExists(candidate)`, so it saw
  #    an existing file through a symlink and **missed a new one written through
  #    a symlinked parent** — the create path, which is the one that matters,
  #    because that is how a file gets outside the tree in the first place.
  # 2. It compared against `normBase`, the *lexical* root. If the workspaces
  #    root is itself a symlink, `expandFilename` returns the real location and
  #    the prefix test fails for **every legitimate path**, refusing the whole
  #    tree.
  #
  # So: resolve the base, walk up to the deepest ancestor that actually exists,
  # resolve that, and require it inside the resolved base. The unresolved tail
  # below that ancestor cannot smuggle anything — it does not exist, so it holds
  # no symlink, and `..` was rejected lexically at the top of this proc.
  var realBase = normBase
  if dirExists(normBase):
    try:
      realBase = expandFilename(normBase)
    except OSError:
      return ""

  var probe = candidate
  while not (fileExists(probe) or dirExists(probe)):
    let up = probe.parentDir
    # `parentDir` of a root returns itself or empty; either way there is nothing
    # further up and nothing existing was found.
    if up.len == 0 or up == probe: return ""
    probe = up

  try:
    let realProbe = expandFilename(probe)
    if not (realProbe == realBase or realProbe.startsWith(realBase & "/")):
      return ""
  except OSError:
    return ""
  candidate

## Function purpose: `POST /api/storage/<path>` — write a file verbatim,
## creating parent directories. The body is written as bytes, not text: the Web
## UI stores binary assets through this route.
proc storageSave*(relative, content: string): bool =
  let path = resolveStoragePath(relative)
  if path.len == 0: return false
  try:
    ensureDir(path.parentDir)
    writeFile(path, content)
    true
  except IOError, OSError:
    false

## Function purpose: `GET /api/storage/<path>` — read a file. Empty result and a
## false flag distinguish "not found" from "found but empty", which a bare string
## return could not.
proc storageGet*(relative: string): tuple[found: bool, content: string] =
  let path = resolveStoragePath(relative)
  if path.len == 0 or not fileExists(path):
    return (false, "")
  try:
    (true, readFile(path))
  except IOError, OSError:
    (false, "")

## Function purpose: `GET /api/storage/` — list every file under the workspaces
## root as paths relative to it. Reproduces the original's `find -maxdepth 4`
## with its three exclusions: dotfiles and dot-directories, `node_modules`, and
## `build`. Depth is counted from the root, matching `find`'s semantics.
proc storageList*(): seq[string] =
  let (workspaces, _) = roots()
  if not dirExists(workspaces): return @[]
  let baseLen = workspaces.len + 1

  proc walk(dir: string, depth: int, acc: var seq[string]) =
    if depth > 4: return
    for kind, path in walkDir(dir):
      let name = path.extractFilename
      if name.startsWith("."): continue
      if name == "node_modules" or name == "build": continue
      if path.len > baseLen:
        acc.add path[baseLen .. ^1]
      if kind == pcDir:
        walk(path, depth + 1, acc)

  walk(workspaces, 1, result)
  result.sort()

## Function purpose: `DELETE /api/storage/<path>` — move a file into the
## workspaces trash rather than unlinking it, reproducing `fs_sync.trash_path`
## (`fs_sync.lua:281`), the thirteenth function and the last one unported. The
## trash layout is `<root>/.trash/<epoch>/<original relative path>`, which
## preserves the directory structure so a restore has somewhere to put it back.
proc storageTrash*(relative: string): FsResult =
  let path = resolveStoragePath(relative)
  if path.len == 0:
    return FsResult(ok: false, msg: "path refused")
  if not (fileExists(path) or dirExists(path)):
    return FsResult(ok: false, msg: "not found")
  let (workspaces, _) = roots()
  let dest = workspaces / ".trash" / epochPrefix() / relative
  try:
    ensureDir(dest.parentDir)
    if dirExists(path): moveDir(path, dest)
    else: moveFile(path, dest)
    FsResult(ok: true, path: dest, original: path)
  except OSError, IOError:
    FsResult(ok: false, path: dest, original: path, msg: "rename failed")

proc toJson*(entries: seq[TrashEntry]): JsonNode =
  result = newJArray()
  for e in entries:
    var node = %*{"path": e.path, "type": $e.kind, "name": e.name}
    if e.kind == tkWorkspace:
      node["workspace"] = %e.workspace
    result.add node

proc toJson*(nodes: seq[FsNode]): JsonNode =
  result = newJArray()
  for n in nodes:
    result.add %*{"path": n.path, "full_path": n.fullPath, "isDir": n.isDir}
