## Script function and purpose: the filesystem mirror behind the database and
## storage routes. Every workspace, project, folder, note and file asset has a
## real counterpart on disk, and deleting one moves it into a trash tree beside
## a metadata sidecar rather than unlinking it, which is what makes restore
## possible at all.
##
## The path layout, trash naming and sidecar shape are a fixed contract: the Web
## UI is frozen and reads them, so changing any of the three breaks a client
## that cannot be changed back.
##
## Every walk here is native rather than a subprocess. The results are identical
## and only the process count differs, which matters because these run on worker
## threads and a listing is not worth a fork per entry.

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

## Function purpose: resolving the roots reads the environment, so it is done
## once per thread rather than on every mirroring write. A threadvar rather than
## a global because a shared string is refcounted memory every worker would
## touch, which is not GC-safe across them.
proc roots(): tuple[workspaces, trash: string] =
  if wsRoot.len == 0:
    let p = paths.resolve()
    wsRoot = p.workspaces
    trashRoot = p.jcaHome / ".trash"
  (wsRoot, trashRoot)

## Function purpose: a database-supplied name becomes one path component here.
## Separators become underscores and leading dots are stripped, so a name can
## neither escape its directory nor create a hidden entry.
proc sanitize*(s: string): string =
  if s.len == 0: return ""
  result = newStringOfCap(s.len)
  for ch in s:
    result.add (if ch == '/' or ch == '\\': '_' else: ch)
  var start = 0
  while start < result.len and result[start] == '.':
    inc start
  result = result[start .. ^1]

## Function purpose: only rows whose id is a real UUID are mirrored, which is
## what stops a malformed id becoming a filename. Dropping this widens what can
## be written to disk.
proc isValidUuid*(id: string): bool =
  if id.len != 36: return false
  const dashes = [8, 13, 18, 23]
  for i, ch in id:
    if i in dashes:
      if ch != '-': return false
    elif ch notin HexDigits:
      return false
  true

## Function purpose: seeded per thread, because the default generator is
## deterministic and would mint the same "unique" ids on every run, while a
## single shared one is mutable state every worker would advance concurrently.
## The thread id joins the seed so two threads starting in the same microsecond
## do not produce the same stream.
var uuidRng {.threadvar.}: Rand
var uuidRngSeeded {.threadvar.}: bool

## Function purpose: called before the first id is minted on each thread, since
## an unseeded generator repeats across runs.
proc seedUuidRng() =
  if not uuidRngSeeded:
    uuidRng = initRand(int(epochTime() * 1_000_000) xor
                       getCurrentProcessId() xor getThreadId())
    uuidRngSeeded = true

## Function purpose: the counterpart to the UUID test, needed because path
## resolution refuses any note or asset id that is not one — and the upsert then
## deletes the row it just wrote. A generic object id is 24 hex characters and
## is rejected, so a caller minting one of these ids has to use this.
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

## Function purpose: groups everything deleted in one second under one trash
## directory, so a bulk delete restores as a unit.
proc epochPrefix(): string = $int(epochTime())

## Function purpose: swallows the error, because a directory that already exists
## is the ordinary case and every caller creates before writing.
proc ensureDir(path: string) =
  if path.len > 0:
    createDir(path)

## Function purpose: arguments are passed as a vector and never interpolated
## into a shell string, because a workspace name is user data and hand-quoting
## it into `sh -c` is how that becomes a command.
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

## Function purpose: a workspace is a repository so the user can see and revert
## what the mirror wrote; failure is reported, not raised.
proc gitInit(workspacePath: string): bool =
  if not gitRun(workspacePath, ["init"]): return false
  discard gitRun(workspacePath, ["config", "user.email", "jenova@local"])
  discard gitRun(workspacePath, ["config", "user.name", "Jenova"])
  true

## Function purpose: stages without committing, so the history is the user's to
## write and the mirror only keeps it aware of new files.
proc gitAdd(workspacePath, filePath: string) =
  discard gitRun(workspacePath, ["add", filePath])

# ---------------------------------------------------------------------------
# Physical path resolution
# ---------------------------------------------------------------------------

## Function purpose: the row's name and its parent id, for walking a note up to
## its workspace. The parent column differs per table, so it is named here
## rather than inferred.
proc lookupName(table, id: string): tuple[found: bool, name, parent: string] =
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

## Function purpose: a container id is absent as either an empty string or the
## literal "null", depending on which client wrote the row.
proc isSet(v: string): bool =
  v.len > 0 and v != "null"

## Function purpose: walks a note or asset's ancestry to build its path. The
## three placements — under a folder, under a project, or directly under a
## workspace — are a client contract, and an item with no resolvable ancestry
## lands in `unassigned/` rather than being dropped.
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

## Function purpose: resolved from an explicit name and parent id rather than
## from the row, because the upsert overwrites the row before the mirror runs —
## so a container's previous location can only be rebuilt from values captured
## beforehand, which is what makes moving the directory possible at all. The
## layout matches what the trash paths build, so a moved container is still
## found when it is later deleted.
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

## Function purpose: without this a rename strands everything underneath it.
## Every note and asset path is built from ancestor *names*, so the row moves and
## the directory does not, leaving the old tree orphaned and the next write
## landing in a fresh empty directory beside it.
##
## Action purpose: false means only that the move could not be done, so the
## caller rolls the row back — a database claiming a name the disk does not carry
## is the state this mirror exists to prevent. A container with no directory yet
## is not a failure: directories are created by the first item written into them.
proc renameContainer*(kind, priorName, priorParent, newName,
                      newParent: string): bool =
  let dst = containerDir(kind, newName, newParent)
  if dst.len == 0: return false
  let src = containerDir(kind, priorName, priorParent)
  if src.len == 0 or src == dst: return true
  if not dirExists(src): return true
  # Action purpose: a sibling already standing at the new path would be merged
  # into, silently mixing two containers' files. Refusing hands the caller a
  # rollback, which is recoverable; a merge is not.
  if dirExists(dst) or fileExists(dst): return false
  try:
    ensureDir(dst.parentDir)
    moveDir(src, dst)
    true
  except OSError:
    false

## Function purpose: a note is mirrored as markdown, so the extension is fixed
## here rather than taken from the title.
proc notePath(id, title, folderId, projectId, workspaceId: string):
    tuple[path, workspace: string] =
  physicalPath(id, title, folderId, projectId, workspaceId, ".md")

## Function purpose: an asset keeps the name it was uploaded under, so its
## extension comes from that rather than being imposed.
proc assetPath(id, name, folderId, projectId, workspaceId: string):
    tuple[path, workspace: string] =
  physicalPath(id, name, folderId, projectId, workspaceId, "")

## Function purpose: each workspace has its own trash, so deleting one takes its
## deleted items with it rather than orphaning them globally.
proc workspaceTrash(workspaceName: string): string =
  let (workspaces, _) = roots()
  result = workspaces / workspaceName / ".trash"
  ensureDir(result)

## Function purpose: the sidecar that makes restore possible — it carries both
## the original path and which row to un-delete, so a trashed item that loses
## this file can only be put back by hand.
proc writeTrashMetadata(trashPath, table, id, originalPath: string) =
  try:
    writeFile(trashPath & ".metadata.json",
              $(%*{"type": table, "id": id, "original_path": originalPath}))
  except IOError, OSError:
    discard

## Function purpose: the one path a delete takes, so the sidecar is always
## written beside the item and never only sometimes.
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

## Function purpose: a workspace is a git repository, created on first sync. A
## failed `git init` removes the directory again, so a half-made workspace is
## not left behind.
##
## `priorName` is what the row carried before this upsert and is empty on
## insert. It is what lets a rename move the repository rather than leave it
## behind under the old name with every file still in it.
proc syncWorkspace*(name: string, priorName = ""): bool =
  let (workspaces, _) = roots()
  let path = workspaces / sanitize(name)
  # Checked first so the common case, a re-sync of an unchanged workspace, costs
  # one string compare rather than two sanitising allocations.
  if priorName.len > 0 and priorName != name and
     sanitize(priorName) != sanitize(name):
    if not renameContainer("workspaces", priorName, "", name, ""):
      return false
  # Action purpose: whether this call created the directory decides whether it
  # may unmake it below. Removing one that was already there, or that a rename
  # has just moved here, deletes the user's files.
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

## Function purpose: the write half for a note, staging the file in git so the
## user can see what the mirror did.
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

## Function purpose: every other sync proc writes one way, database to disk.
## This is the read back, without which an edit made outside the note editor —
## in the embedded Neovim, another editor, or over the storage route — goes to a
## file the database ignores for ever and the next save silently overwrites.
##
## Action purpose: the path comes from the writer's own resolution rather than
## being rebuilt here. A reader that constructed it itself would drift from the
## writer the first time sanitising changed, and then reconcile nothing.
proc readNoteMirror*(id, title, folderId, projectId, workspaceId: string):
    tuple[found: bool, content: string] =
  let (path, _) = notePath(id, title, folderId, projectId, workspaceId)
  if path.len == 0 or not fileExists(path): return (false, "")
  try:
    (true, readFile(path))
  except IOError, OSError:
    (false, "")

## Function purpose: the bytes a stored asset belongs on disk as. Assets arrive
## as `data:` URIs, so the payload is decoded here — otherwise every uploaded
## image is mirrored as its own text encoding. A payload whose length cannot be
## base64 at all is refused rather than written truncated, which is what the
## flag distinguishes from a payload that is legitimately empty.
proc assetPayload(content: string): tuple[ok: bool, bytes: string] =
  const marker = "base64,"
  if not content.startsWith("data:"): return (true, content)
  let idx = content.find(marker)
  if idx < 0: return (true, content)
  # Action purpose: **whitespace is skipped; anything else is a refusal.** The
  # filter exists because a stored URI can carry newlines — base64 is routinely
  # line-wrapped, and that is not a corruption. But dropping *every* character
  # outside the alphabet turned `QQ!` into `QQ` and wrote `A` to disk: bytes
  # that are not the bytes the caller supplied, filed under a success. A payload
  # carrying a character that is neither base64 nor layout is not a payload this
  # decoder was given, and guessing what it meant is worse than saying no.
  var clean = newStringOfCap(content.len)
  for ch in content[(idx + marker.len) .. ^1]:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}:
      clean.add ch
    elif ch notin {' ', '\t', '\n', '\r'}:
      return (false, "")
  # Padding is stripped before the length is measured, and then only a
  # remainder of 1 is refused. base64 encodes three bytes to four characters,
  # so an unpadded tail of 2 or 3 characters is one or two bytes and decodes
  # exactly; 1 is the only length base64 cannot produce. Measuring the padded
  # length instead refused every unpadded `data:` URI — and the cost of that is
  # not cosmetic, because `syncFileAsset` returns false and `api.upsert` then
  # deletes the row it has already written, so the upload is lost and the
  # client is told the save failed.
  clean = clean.strip(leading = false, chars = {'='})
  if clean.len mod 4 == 1: return (false, "")
  try:
    (true, base64.decode(clean))
  except ValueError:
    (false, "")

## Function purpose: whether an asset row has any bytes to have a file at all,
## which is what separates "its file is gone" from "it never had one". Read from
## the row and not from the filesystem, because an absent file is precisely the
## state being explained.
##
## Action purpose: a row that cannot be read answers yes, which keeps the louder
## of the two answers — the quiet one says there was nothing to lose, and an
## unanswerable question must not become that claim. Guarded at all because
## `restoreMirror` is reachable with no database open, which is how `fs-selftest`
## drives it; `restoreTrash` guards its own write against the same thing.
proc hasAssetBytes(id: string): bool =
  var rows: seq[Row]
  try:
    rows = db.query("SELECT content FROM fileAssets WHERE id=?", id)
  except CatchableError:
    return true
  if rows.len == 0 or rows[0].len == 0: return false
  assetPayload(rows[0][0]).bytes.len > 0

## Function purpose: the write half for a file asset, staging the file in git so
## the user can see what the mirror did.
##
## Action purpose: an asset with no bytes gets no file. The window files every
## chat image as a row whose `content` is deliberately empty — base64 must not
## enter a column `workspace.contextFor` renders into a prompt and
## `rag.indexFileAsset` embeds — and mirroring that row wrote a zero-byte file
## into the workspace and `git add`ed it, one for every image attached.
##
## Skipping is a success with nothing written, and that distinction is the whole
## of it: `api.upsert` deletes the row it has already written when the mirror
## answers false, which is what made every attachment report "could not file"
## once already.
##
## It closes the truncating half of the same trap from underneath. An update
## that carries no content can no longer shorten a real file to nothing, so the
## rename that blanked `content` and wrote a zero-byte file over the bytes now
## costs at worst a stale mirror. `api.putEntity` merging the stored row before
## it writes is what keeps the mirror current; this is the floor under that.
##
## Nothing sweeps up the zero-byte files already on disk. They are inert — the
## viewer reads the row when the mirror is zero-length, so it answers the same
## with or without one — and they sit in a repository whose history is the
## user's to write: `gitAdd` stages and never commits, so deleting them here
## would author a change into the user's own tree that the user did not make.
## Function purpose: carry an existing mirror across a rename or a move when the
## update itself brought no bytes to write.
##
## Action purpose: **the row's location and the file's location must not be
## allowed to disagree.** `putEntity` writes the new name and folder before the
## mirror is touched, so an update that changes them while carrying no payload
## left the row pointing at a path with no file and the real bytes stranded
## under the old name — which is what `readFileAssetMirror` then failed to find,
## falling back to a column the same update had blanked. Skipping the old file's
## cleanup avoids destroying it and does not fix that; moving it does.
##
## Answers `true` when there was nothing to move, because a row that never had a
## file is not a failed move — it is the ordinary case for an image, whose bytes
## deliberately never enter the column (report 07, V-10).
proc moveFileAssetMirror*(id, oldName, oldFolderId, oldProjectId, oldWorkspaceId,
                          newName, newFolderId, newProjectId,
                          newWorkspaceId: string): bool =
  let (src, srcWs) = assetPath(id, oldName, oldFolderId, oldProjectId,
                               oldWorkspaceId)
  let (dst, ws) = assetPath(id, newName, newFolderId, newProjectId, newWorkspaceId)
  if src.len == 0 or dst.len == 0: return false
  if src == dst: return true
  if not fileExists(src): return true
  let (workspaces, _) = roots()
  try:
    ensureDir(dst.parentDir)
    moveFile(src, dst)
  except IOError, OSError:
    return false
  # Both paths are staged: the old one so its removal is recorded, the new one
  # so the file is. `gitAdd` stages and never commits, so this states what
  # happened without authoring a commit into the user's own tree.
  #
  # **Each side goes to its own repository.** A workspace is one of the four
  # things a move can change, and every workspace is a separate git tree — so
  # staging the source path against the *destination* repository named a path
  # outside it, and the removal went unrecorded in the tree it actually
  # happened in. `srcWs` and `ws` are the same string for a plain rename, which
  # is why this was invisible in the common case.
  gitAdd(workspaces / srcWs, src)
  gitAdd(workspaces / ws, dst)
  true

## Function purpose: whether this content would put a file on disk at all, which
## is what a rename has to know before it trashes the old one. `syncFileAsset`
## answers `true` for a row with no bytes because writing nothing is the correct
## outcome there (report 07, V-10) — but "succeeded" and "wrote a file" are then
## two different claims, and only the second one makes trashing the previous
## file safe. Asked of the content rather than of the disk, so it is the same
## decision the writer makes and cannot drift from it.
proc contentWritesAFile*(content: string): bool =
  let (decoded, payload) = assetPayload(content)
  decoded and payload.len > 0

proc syncFileAsset*(id, name, content, folderId, projectId,
                    workspaceId: string): bool =
  let (path, ws) = assetPath(id, name, folderId, projectId, workspaceId)
  if path.len == 0: return false
  let (workspaces, _) = roots()

  let (decoded, payload) = assetPayload(content)
  if not decoded: return false
  if payload.len == 0: return true

  try:
    ensureDir(path.parentDir)
    writeFile(path, payload)
  except IOError, OSError:
    return false
  gitAdd(workspaces / ws, path)
  true

## Function purpose: the read back for an asset, which is what lets the window
## open a file it filed rather than only list it. The mirror is preferred over
## the row because it is the file: `syncFileAsset` decodes a `data:` URI on the
## way out, so reading here gives bytes where the column gives base64, and an
## asset edited in place by anything else is read as it now stands.
##
## Action purpose: the path comes from the writer's own resolution, for the
## reason `readNoteMirror` says so — a reader that rebuilt it would drift from
## the writer the first time sanitising changed. `size` is returned alongside so
## a caller can refuse to read something too large without having read it.
proc readFileAssetMirror*(id, name, folderId, projectId, workspaceId: string):
    tuple[found: bool, size: int64, content: string] =
  let (path, _) = assetPath(id, name, folderId, projectId, workspaceId)
  if path.len == 0 or not fileExists(path): return (false, 0, "")
  try:
    let size = getFileSize(path)
    (true, size, readFile(path))
  except IOError, OSError:
    (false, 0, "")

## Function purpose: the size of an asset's mirror without reading it, so the
## window can decide whether opening it is affordable before it commits to the
## read.
proc fileAssetMirrorSize*(id, name, folderId, projectId, workspaceId: string):
    tuple[found: bool, size: int64] =
  let (path, _) = assetPath(id, name, folderId, projectId, workspaceId)
  if path.len == 0 or not fileExists(path): return (false, 0)
  try:
    (true, getFileSize(path))
  except IOError, OSError:
    (false, 0)

# ---------------------------------------------------------------------------
# Trash — move to trash rather than unlink
# ---------------------------------------------------------------------------

## Function purpose: the delete half for a note, which moves rather than
## unlinks so the row and the file can be restored together.
proc trashNote*(id, title, folderId, projectId, workspaceId: string): bool =
  let (path, ws) = notePath(id, title, folderId, projectId, workspaceId)
  if path.len == 0:
    # An unassigned item with no resolvable path is not an error: there was
    # nothing on disk to move.
    return ws == "unassigned"
  if not fileExists(path): return true
  let dest = workspaceTrash(ws) / epochPrefix() & "_" & path.extractFilename
  moveToTrash(path, dest, "notes", id)

## Function purpose: the same for an uploaded file, whose bytes are the only
## copy — there is no re-save path to recreate one from the database.
proc trashFileAsset*(id, name, folderId, projectId, workspaceId: string): bool =
  let (path, ws) = assetPath(id, name, folderId, projectId, workspaceId)
  if path.len == 0:
    return ws == "unassigned"
  if not fileExists(path): return true
  let dest = workspaceTrash(ws) / epochPrefix() & "_" & path.extractFilename
  moveToTrash(path, dest, "fileAssets", id)

## Function purpose: a workspace is a whole directory, so this takes its
## repository and everything below it into the global trash in one move.
##
## Action purpose: answers an `FsResult` rather than a bool, for the same reason
## `trashProject` and `trashFolder` do — the caller flags the rows *after* this
## has moved the directory, and when that step fails it has to put the directory
## back. A bool says the move happened and not where it went, so the undo was
## unavailable to a workspace and only to a workspace.
proc trashWorkspace*(id, name: string): FsResult =
  let (workspaces, trash) = roots()
  let safe = sanitize(name)
  let path = workspaces / safe
  if not dirExists(path): return FsResult(ok: true, original: path)
  ensureDir(trash)
  let dest = trash / epochPrefix() & "_" & safe
  try:
    moveDir(path, dest)
    writeTrashMetadata(dest, "workspaces", id, path)
    FsResult(ok: true, path: dest, original: path)
  except OSError:
    FsResult(ok: false, path: dest, original: path, msg: "rename failed")

## Function purpose: ancestry is resolved through the database first, because
## the on-disk path is built from ancestor names. An already-absent directory is
## success and anything else is failure: deleting something that was never
## mirrored is not an error.
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

## Function purpose: answers a result rather than a bool, because a folder's
## ancestry can fail to resolve and the caller has to say which failure it was.
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
# Trash listing, restore, empty
# ---------------------------------------------------------------------------

## Function purpose: filters the sidecars out of the listing, since a client is
## shown items rather than the metadata that describes them.
proc collectTrash(dir: string, kind: TrashKind, workspace: string,
                  acc: var seq[TrashEntry]) =
  if not dirExists(dir): return
  for path in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile}):
    let base = path.extractFilename
    if base == ".git" or path.contains("/.git/"): continue
    if path.endsWith(".metadata.json"): continue
    acc.add TrashEntry(path: path, kind: kind, workspace: workspace, name: base)

## Function purpose: the global trash and every workspace's own, in one listing,
## because a client asks the question once and should not have to know there are
## two places to look.
proc getTrash*(): seq[TrashEntry] =
  let (workspaces, trash) = roots()
  collectTrash(trash, tkGlobal, "", result)
  # Action purpose: storage deletions are filed directly under the workspaces
  # root's own trash so their relative structure survives the move. Walking that
  # root as a list of workspaces meets `.trash` among them and then looks for a
  # `.trash` inside it, which cannot exist — so those entries would be invisible
  # both here and to the emptying below.
  #
  # Classified as global because they belong to no one workspace, which also
  # keeps the emitted JSON unchanged: the workspace field is added only for
  # workspace-scoped entries.
  collectTrash(workspaces / ".trash", tkGlobal, "", result)
  if dirExists(workspaces):
    for kind, wsPath in walkDir(workspaces):
      if kind != pcDir: continue
      # Collected above, and it is not a workspace.
      if wsPath.extractFilename == ".trash": continue
      let wsTrash = wsPath / ".trash"
      if dirExists(wsTrash):
        collectTrash(wsTrash, tkWorkspace, wsPath.extractFilename, result)

## Function purpose: the root itself or something beneath it. A bare prefix test
## accepts a sibling whose name merely starts with the root's, so the separator
## is part of the test rather than decoration.
proc underRoot(path, root: string): bool =
  if root.len == 0: return false
  let r = root.normalizedPath
  path == r or path.startsWith(r & "/")

## Function purpose: containment a symlink cannot defeat. The lexical test above
## cannot see that a path component is a link pointing out of the tree, and this
## primitive is reachable from more than one caller — so the stronger standard
## belongs here rather than at each of them.
##
## Action purpose: resolve the root, walk up to the deepest ancestor that
## actually exists, resolve that, and require it inside the resolved root. The
## walk-up is what makes this work for a destination that does not exist yet,
## which is every restore: the unresolved tail below that ancestor holds no
## symlink because it holds nothing at all.
proc resolvedUnderRoot(path, root: string): bool =
  if path.len == 0 or root.len == 0: return false
  let normRoot = root.normalizedPath
  var realRoot = normRoot
  if dirExists(normRoot):
    try: realRoot = expandFilename(normRoot)
    except OSError: return false

  var probe = path.normalizedPath
  if probe.len == 0: return false
  while not (fileExists(probe) or dirExists(probe)):
    let up = probe.parentDir
    if up.len == 0 or up == probe: return false
    probe = up

  try:
    let realProbe = expandFilename(probe)
    realProbe == realRoot or realProbe.startsWith(realRoot & "/")
  except OSError:
    false

## Action purpose: the sidecar is a file on disk, so its type field is untrusted
## input that reaches an UPDATE statement by concatenation — only these names may
## get that far. They are equivalently the entity kinds with a physical form, and
## the restore outcome below is derived from this one list rather than a second,
## so an entity added here without a mirror cannot drift into reporting the wrong
## result.
const RestorableTables* = ["notes", "fileAssets", "workspaces", "projects", "folders"]

type
  ## What a restore actually did, because a bool says two very different things
  ## with one word. A conversation or message never had a file, so nothing is
  ## wrong and nothing should be said; a note whose file is not in the trash is
  ## wrong — the row is back and the content is not.
  ##
  ## The no-physical-form case is first deliberately, so it is the zero value: an
  ## outcome some future path forgets to assign then defaults to silence rather
  ## than to a claim that a restore happened.
  RestoreOutcome* = enum
    rmNoPhysicalForm    ## this kind never has a file; ordinary, say nothing
    rmRestored          ## row and file both back
    rmFileMissing       ## this kind does have files and this one did not return

## Function purpose: the move itself, with both ends contained. Every restore
## goes through here so the containment rule has one implementation.
proc restoreTrash*(trashPath, originalPath: string): bool =
  if trashPath.len == 0 or originalPath.len == 0: return false
  let (workspaces, trash) = roots()

  # Action purpose: only paths inside a known trash directory may be restored,
  # so a crafted request cannot move an arbitrary file. Resolved rather than
  # lexical, because the source is read and then moved and a link standing in
  # for a trash entry would have this move a file it was never shown.
  #
  # The `/.trash/` test stays lexical on purpose: it asks which root this is,
  # not whether the path is contained.
  let normalized = trashPath.normalizedPath
  if not (resolvedUnderRoot(normalized, trash) or
          (resolvedUnderRoot(normalized, workspaces) and
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

  # Action purpose: the destination is as much a filesystem write as the source
  # is a read, and comes from the same two untrusted places — the caller's path
  # and the sidecar. Without this a crafted pair moves a trashed file anywhere
  # the process could write.
  # The end that matters most: the destination does not exist yet, which is
  # exactly what a lexical check is blind to. It sees an existing file through a
  # symlink but misses a new one written through a symlinked parent, and that is
  # how a file gets outside the tree in the first place.
  let normalizedTarget = target.normalizedPath
  if not (resolvedUnderRoot(normalizedTarget, workspaces) or
          resolvedUnderRoot(normalizedTarget, trash)):
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

## Function purpose: puts back the file a delete filed in the trash, found by
## its sidecar. Without this the row comes back and the content does not — which
## is the opposite of what the delete confirmation promises.
##
## Action purpose: the id is the key, not the path. A path would have to be
## recomputed from the row, and the row's name may have changed since the
## delete; the sidecar records where the item actually came from, which is why
## it exists.
##
## All three trash roots are walked — the global one, the storage root's, and
## each workspace's — and the workspace loop has to skip an entry named `.trash`
## or it enumerates the storage root as though it were a workspace.
##
## The listing proc is deliberately not reused: it filters out the sidecars,
## which are the only thing being looked for here. The move itself goes through
## the trash primitive, so containment is enforced in one place rather than
## checked again here.
proc restoreMirror*(table, id: string): RestoreOutcome =
  # A bool conflates the two failures, which is why one is safe to discard and
  # the other is not: no physical form is the ordinary answer for a conversation
  # or a message, while a missing file is a restore that did not fully happen.
  if table notin RestorableTables: return rmNoPhysicalForm
  if id.len == 0: return rmFileMissing
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
      # The sidecar was found, so from here a failure is a real one: the move
      # itself did not happen.
      return (if restoreTrash(path[0 ..< path.len - Suffix.len],
                              meta{"original_path"}.getStr): rmRestored
              else: rmFileMissing)
  # No sidecar anywhere, for a kind that has files — deleted before the mirror
  # existed, or the sidecar was lost. Nothing to look up and nothing to say
  # except that the row is back and the file is not.
  #
  # Unless the row has no bytes, in which case there is no file and never was:
  # `syncFileAsset` writes none for an empty asset, so the delete had nothing to
  # move and left no sidecar. Reporting a file missing there would tell the user
  # something was lost every time they restore an image filed from a chat.
  if table == "fileAssets" and not hasAssetBytes(id): return rmNoPhysicalForm
  rmFileMissing

## Function purpose: entries are removed directly rather than through a shell,
## so there is no quoting to get wrong on a path the user named and no fork per
## workspace.
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
  # The storage trash root, for the same reason the listing above has to include
  # it: nothing else would ever clear it.
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

## Function purpose: the tree a client renders, optionally scoped to a
## workspace, project or folder. The trash and the git directory are excluded
## because neither is content the user put there.
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
# Raw file access under the workspaces root
# ---------------------------------------------------------------------------

## Function purpose: lexical normalisation that answers empty when an absolute
## path tries to escape its own root, rather than clamping at `/`. The
## distinction matters: clamping turns an escape attempt into a valid path.
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

## Function purpose: resolves a client-supplied path against the workspaces root
## and answers empty for anything landing outside it. The directory boundary is
## part of the test: a bare prefix match accepts a sibling whose name merely
## starts with the root's.
##
## Action purpose: two guards beyond the boundary check, both asserted. A literal
## `..` is rejected before normalisation, centralised here rather than repeated
## at each call site; and the symlink check exists because lexical normalisation
## cannot see that a component is a link pointing out of the tree.
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

  # Action purpose: resolved compared against resolved, at both ends, because
  # each end fails differently otherwise.
  #
  # Checking only paths that already exist sees a file through a symlink but
  # misses a new one written through a symlinked parent — the create path, which
  # is how a file gets outside the tree in the first place. Comparing against the
  # lexical root fails the other way: if the workspaces root is itself a symlink,
  # resolution returns the real location and the test refuses every legitimate
  # path.
  #
  # So the base is resolved, the walk goes up to the deepest ancestor that
  # exists, and that is required inside the resolved base. The unresolved tail
  # below it holds no symlink because it holds nothing, and `..` was already
  # rejected lexically above.
  var realBase = normBase
  if dirExists(normBase):
    try:
      realBase = expandFilename(normBase)
    except OSError:
      return ""

  var probe = candidate
  while not (fileExists(probe) or dirExists(probe)):
    let up = probe.parentDir
    # The parent of a root is itself or empty; either way there is nothing
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

## Function purpose: the body is written as bytes rather than text, because
## binary assets are stored through this route and a text write would re-encode
## them.
proc storageSave*(relative, content: string): bool =
  let path = resolveStoragePath(relative)
  if path.len == 0: return false
  try:
    ensureDir(path.parentDir)
    writeFile(path, content)
    true
  except IOError, OSError:
    false

## Function purpose: the flag distinguishes "not found" from "found but empty",
## which a bare string return cannot.
proc storageGet*(relative: string): tuple[found: bool, content: string] =
  let path = resolveStoragePath(relative)
  if path.len == 0 or not fileExists(path):
    return (false, "")
  try:
    (true, readFile(path))
  except IOError, OSError:
    (false, "")

## Function purpose: paths relative to the root, with dot entries, dependency
## directories and build output excluded — a listing of what the user put there
## rather than of everything a workspace accumulates. Depth is bounded so a deep
## tree cannot make one request walk the whole disk.
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

## Function purpose: moves into the trash rather than unlinking, and the layout
## keeps the original relative path under a timestamp — which is what gives a
## restore somewhere to put the file back.
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

## Function purpose: the workspace field is emitted only for workspace-scoped
## entries, which is the shape the frozen client parses.
proc toJson*(entries: seq[TrashEntry]): JsonNode =
  result = newJArray()
  for e in entries:
    var node = %*{"path": e.path, "type": $e.kind, "name": e.name}
    if e.kind == tkWorkspace:
      node["workspace"] = %e.workspace
    result.add node

## Function purpose: the tree's own encoding, kept beside the type so a field
## added to one is not forgotten in the other.
proc toJson*(nodes: seq[FsNode]): JsonNode =
  result = newJArray()
  for n in nodes:
    result.add %*{"path": n.path, "full_path": n.fullPath, "isDir": n.isDir}
