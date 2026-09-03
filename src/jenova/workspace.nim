## Script function and purpose: build the workspace artifact context — the notes
## and files belonging to a conversation's workspace, project or folder — so the
## model answers with them in view (G-43, ruling D-BU).
##
## **This module is deliberately below the window.** It depends on `db` and `std`
## and nothing else, which is what lets `workspace-selftest` assert the whole
## scoping ladder with no window, no backend and no conversation. Same layering
## argument as `settings.nim` and `hardware.nim`.
##
## ## Why this exists at all
##
## The `notes` and `fileAssets` tables, their `isFocusNote` flag and the
## `folderId`/`projectId`/`workspaceId` columns on `conversations` have existed
## since the schema was written, and `api.nim` round-trips every one of them.
## **Nothing ever read them.** A user could write notes into a workspace and the
## model never saw a word. That is the third time this project has shipped a
## complete, tested store with no reader — `rag.nim` was the first (T-17) and
## `fileAssets` is the third — and it is why rule 15 says to assert the *join*.
##
## ## Parity is exact, and taken from the source
##
## Ported from `jca_web/src/lib/services/workspace.service.ts`,
## `WorkspaceService.getWorkspaceContext`, read directly rather than from a
## summary of it (rule 11). Three behaviours a summary loses, all of them load
## bearing:
##
## * **A FOCUS note escapes its level.** A note with `isFocusNote` applies across
##   the entire workspace tree, so a rule written once at the workspace root
##   reaches a chat scoped to a folder three levels down. That is the whole
##   reason the flag exists, and it is the first thing a re-implementation drops.
## * **Regular notes at folder level are strictly isolated.** A folder chat sees
##   its own folder's notes and *not* its siblings'. Project level widens to the
##   project's folders; workspace level takes everything nested.
## * **Files have no FOCUS concept** and follow the regular-note scoping only.
##
## The output strings are literal, because the model is being shown a format the
## Web UI already teaches it.
##
## ## One defect inherited on purpose
##
## **There is no token budget.** The upstream carries a standing `TODO` saying
## exactly that, so a large workspace can overflow the context on its own. Taking
## parity takes the defect with it. It is not fixed here because it is the same
## problem as **T-3** (untrimmed history) and fixing either alone buys nothing.

import std/[strutils, tables]
import ./db

const
  ## The heading `jca_web/src/lib/services/chat.service.ts` injects this block
  ## under. Copied exactly: it is what the model has been shown before.
  ContextHeading* = "[CURRENT WORKSPACE ARTIFACTS (Notes & Files)]:"

type
  Note* = object
    title*, content*: string
    folderId*, projectId*, workspaceId*: string
    isFocus*: bool

  FileAsset* = object
    name*, kind*, content*: string
    folderId*, projectId*, workspaceId*: string

## Function purpose: every live note, as the context builder needs it. Deleted
## rows are excluded here rather than at each call site — a soft-deleted note is
## in the trash, and the model quoting it back would make the deletion look
## ignored everywhere the user would actually notice.
## Function purpose: decide whether a stored `isFocusNote` cell means FOCUS.
## Exported because the window reads the same column when it opens a note, and
## two copies of this test would drift the moment either was widened — a note
## would be FOCUS to the context builder and not to the toggle showing it, or the
## reverse. The column is written by three surfaces with three notions of a
## boolean: SQLite has no boolean type, the Web UI posts `0`/`1`, and a JSON
## body can carry `false` or `null`, so all four falsehoods are named here rather
## than assumed away.
proc isFocusValue*(raw: string): bool =
  raw notin ["", "0", "null", "false"]

proc allNotes*(): seq[Note] =
  for r in db.query("SELECT title, content, folderId, projectId, workspaceId, " &
                    "isFocusNote FROM notes WHERE is_deleted=0"):
    result.add Note(
      title: r[0], content: r[1], folderId: r[2], projectId: r[3],
      workspaceId: r[4], isFocus: isFocusValue(r[5]))

proc allFiles*(): seq[FileAsset] =
  for r in db.query("SELECT name, type, content, folderId, projectId, " &
                    "workspaceId FROM fileAssets WHERE is_deleted=0"):
    result.add FileAsset(
      name: r[0], kind: r[1], content: r[2], folderId: r[3], projectId: r[4],
      workspaceId: r[5])

## Function purpose: the workspace a project belongs to, and the project a folder
## belongs to, as two lookups. Built once per call rather than queried per note,
## because the scoping below asks the same question of every row.
proc folderParents*(): Table[string, string] =
  for r in db.query("SELECT id, projectId FROM folders WHERE is_deleted=0"):
    result[r[0]] = r[1]

proc projectParents*(): Table[string, string] =
  for r in db.query("SELECT id, workspaceId FROM projects WHERE is_deleted=0"):
    result[r[0]] = r[1]

## Function purpose: render one note under FOCUS / RULES. The level is the
## deepest container the note itself carries — which is what tells the model
## whether a rule is workspace-wide or local, and is why the label is derived
## from the note and never from the chat asking.
proc focusLevel(n: Note): string =
  if n.folderId.len > 0: "Folder"
  elif n.projectId.len > 0: "Project"
  else: "Workspace"

## Function purpose: the artifact context for a conversation, scoped by the
## deepest container id it carries. Empty when there is nothing to say, so the
## caller can test `.len` rather than needing to know the format.
##
## The four scope branches are the upstream's, in its order: folder, else
## project, else workspace, else *global* — and global means artifacts with no
## container at all, not "everything".
proc contextFor*(folderId, projectId, workspaceId: string): string =
  let notes = allNotes()
  let files = allFiles()
  let folderOf = folderParents()
  let projectOf = projectParents()

  var regular, focus: seq[Note]
  for n in notes:
    if n.isFocus: focus.add n else: regular.add n

  var targetNotes, targetFocus: seq[Note]
  var targetFiles: seq[FileAsset]

  ## The workspace a scope sits in, and every project and folder beneath it.
  ## FOCUS notes are gathered against this whole set at every level, which is
  ## what "a FOCUS note escapes its level" means in practice.
  proc treeOf(wsId: string): tuple[projects, folders: seq[string]] =
    for pid, wid in projectOf:
      if wid == wsId: result.projects.add pid
    for fid, pid in folderOf:
      if pid.len > 0 and pid in result.projects: result.folders.add fid

  proc gatherFocus(wsId: string, projects, folders: seq[string],
                   projectNeedsNoFolder: bool) =
    for n in focus:
      let atRoot = n.workspaceId == wsId and n.projectId.len == 0 and
                   n.folderId.len == 0
      let inProject = n.projectId.len > 0 and n.projectId in projects and
                      (not projectNeedsNoFolder or n.folderId.len == 0)
      let inFolder = n.folderId.len > 0 and n.folderId in folders
      if atRoot or inProject or inFolder:
        targetFocus.add n

  if folderId.len > 0:
    # Strictly this folder. A sibling folder's notes are deliberately invisible.
    for n in regular:
      if n.folderId == folderId: targetNotes.add n
    for f in files:
      if f.folderId == folderId: targetFiles.add f
    let pid = folderOf.getOrDefault(folderId, "")
    let wsId = projectOf.getOrDefault(pid, "")
    if wsId.len > 0:
      let tree = treeOf(wsId)
      gatherFocus(wsId, tree.projects, tree.folders, true)

  elif projectId.len > 0:
    var childFolders: seq[string]
    for fid, pid in folderOf:
      if pid == projectId: childFolders.add fid
    for n in regular:
      if n.projectId == projectId or
         (n.folderId.len > 0 and n.folderId in childFolders): targetNotes.add n
    for f in files:
      if f.projectId == projectId or
         (f.folderId.len > 0 and f.folderId in childFolders): targetFiles.add f
    let wsId = projectOf.getOrDefault(projectId, "")
    if wsId.len > 0:
      let tree = treeOf(wsId)
      gatherFocus(wsId, tree.projects, tree.folders, true)

  elif workspaceId.len > 0:
    let tree = treeOf(workspaceId)
    for n in regular:
      if n.workspaceId == workspaceId or
         (n.projectId.len > 0 and n.projectId in tree.projects) or
         (n.folderId.len > 0 and n.folderId in tree.folders): targetNotes.add n
    for f in files:
      if f.workspaceId == workspaceId or
         (f.projectId.len > 0 and f.projectId in tree.projects) or
         (f.folderId.len > 0 and f.folderId in tree.folders): targetFiles.add f
    # No `!n.folderId` guard on the project clause here, unlike the two branches
    # above. That asymmetry is the upstream's and is reproduced rather than
    # tidied: a workspace chat already sees everything below it, so the narrower
    # test would exclude nothing and only diverge.
    gatherFocus(workspaceId, tree.projects, tree.folders, false)

  else:
    # Global: only what belongs to nothing. Not "everything" — an unassigned chat
    # seeing every workspace's notes is how a rule from one project ends up
    # answering a question about another.
    for n in regular:
      if n.folderId.len == 0 and n.projectId.len == 0 and
         n.workspaceId.len == 0: targetNotes.add n
    for f in files:
      if f.folderId.len == 0 and f.projectId.len == 0 and
         f.workspaceId.len == 0: targetFiles.add f
    # And no FOCUS notes at all, which is the upstream's behaviour: a focus note
    # is a rule for a workspace, and a global chat is in none.

  if targetFocus.len > 0:
    var any = false
    var block1 = "--- FOCUS / RULES ---\n"
    for n in targetFocus:
      # An empty focus note contributes nothing rather than an empty heading.
      if n.content.strip.len == 0: continue
      any = true
      block1.add "[" & n.focusLevel & "] " & n.title & "\n" & n.content & "\n\n"
    if any: result.add block1

  if targetNotes.len > 0:
    result.add "--- NOTES ---\n"
    for n in targetNotes:
      result.add "Title: " & n.title & "\nContent: " & n.content & "\n\n"

  if targetFiles.len > 0:
    result.add "--- FILES ---\n"
    for f in targetFiles:
      result.add "File: " & f.name & " (Type: " & f.kind & ")\n"
      if f.content.len > 0:
        result.add "Content:\n" & f.content & "\n\n"
      else:
        result.add "(Binary file, content not available for direct reading)\n\n"
