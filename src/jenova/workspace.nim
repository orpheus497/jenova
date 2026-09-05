## Script function and purpose: the notes and files belonging to a
## conversation's workspace, project or folder, rendered so the model answers
## with them in view. Depends on `db` and `std` and nothing else, which is what
## lets the self-test assert the whole scoping ladder with no window and no
## backend.
##
## Three scoping rules carry the behaviour and none is obvious from the code:
## a FOCUS note applies across its entire workspace tree, so a rule written at
## the root reaches a chat three levels down; regular notes at folder level are
## strictly isolated from sibling folders, widening to the project's folders at
## project level and to everything nested at workspace level; and files have no
## FOCUS concept at all.
##
## Known limit: there is no token budget here, so a large workspace can overflow
## the context on its own. The second half of this note used to read "bounding it
## here alone buys nothing while the history is also untrimmed" — the history is
## trimmed now, and a request that dropped turns says so in `X-Jenova-Trimmed`,
## so that is no longer a reason to leave this unbounded.

import std/[strutils, tables]
import ./db

const
  ## Literal because it is a format the model has already been taught; a
  ## reworded heading is a different prompt.
  ContextHeading* = "[CURRENT WORKSPACE ARTIFACTS (Notes & Files)]:"

type
  Note* = object
    title*, content*: string
    folderId*, projectId*, workspaceId*: string
    isFocus*: bool

  FileAsset* = object
    name*, kind*, content*: string
    folderId*, projectId*, workspaceId*: string

## Function purpose: exported because the window reads the same column when it
## opens a note, and two copies of this test would drift the moment either was
## widened — leaving a note FOCUS to the context builder and not to the toggle
## showing it. The column is written by three surfaces with three notions of a
## boolean, so all four falsehoods are named rather than assumed away.
proc isFocusValue*(raw: string): bool =
  raw notin ["", "0", "null", "false"]

## Function purpose: deleted rows are excluded here rather than at each call
## site. A soft-deleted note is in the trash, and the model quoting it back
## makes the deletion look ignored exactly where the user would notice.
proc allNotes*(): seq[Note] =
  for r in db.query("SELECT title, content, folderId, projectId, workspaceId, " &
                    "isFocusNote FROM notes WHERE is_deleted=0"):
    result.add Note(
      title: r[0], content: r[1], folderId: r[2], projectId: r[3],
      workspaceId: r[4], isFocus: isFocusValue(r[5]))

## Function purpose: the file half of the same rule, excluded the same way.
proc allFiles*(): seq[FileAsset] =
  for r in db.query("SELECT name, type, content, folderId, projectId, " &
                    "workspaceId FROM fileAssets WHERE is_deleted=0"):
    result.add FileAsset(
      name: r[0], kind: r[1], content: r[2], folderId: r[3], projectId: r[4],
      workspaceId: r[5])

## Function purpose: built once per call rather than queried per note, because
## the scoping below asks the same question of every row.
proc folderParents*(): Table[string, string] =
  for r in db.query("SELECT id, projectId FROM folders WHERE is_deleted=0"):
    result[r[0]] = r[1]

## Function purpose: the other half of the ladder, kept separate so a caller
## scoping to a project need not load the folder table at all.
proc projectParents*(): Table[string, string] =
  for r in db.query("SELECT id, workspaceId FROM projects WHERE is_deleted=0"):
    result[r[0]] = r[1]

## Function purpose: the level is the deepest container the *note* carries, not
## the chat asking. That is what tells the model whether a rule is workspace-wide
## or local, and deriving it from the asker would invert the meaning.
proc focusLevel(n: Note): string =
  if n.folderId.len > 0: "Folder"
  elif n.projectId.len > 0: "Project"
  else: "Workspace"

## Function purpose: scoped by the deepest container id the conversation
## carries, and empty when there is nothing to say, so a caller can test `.len`
## without knowing the format.
##
## Action purpose: the branches are ordered folder, project, workspace, global,
## and global means artifacts belonging to nothing at all rather than to
## everything.
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

  ## The workspace a scope sits in and everything beneath it. FOCUS notes are
  ## gathered against this whole set at every level, which is how a FOCUS note
  ## escapes the level it was written at.
  proc treeOf(wsId: string): tuple[projects, folders: seq[string]] =
    for pid, wid in projectOf:
      if wid == wsId: result.projects.add pid
    for fid, pid in folderOf:
      if pid.len > 0 and pid in result.projects: result.folders.add fid

  ## `projectNeedsNoFolder` narrows a project-level FOCUS note to one that names
  ## no folder, which the folder and project branches need and the workspace
  ## branch does not.
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
    # Strictly this folder: a sibling folder's notes are deliberately invisible.
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
    # Action purpose: no folder guard on the project clause here, unlike the two
    # branches above. A workspace chat already sees everything below it, so the
    # narrower test would exclude nothing and only diverge.
    gatherFocus(workspaceId, tree.projects, tree.folders, false)

  else:
    # Action purpose: only what belongs to nothing. An unassigned chat seeing
    # every workspace's notes is how a rule from one project ends up answering a
    # question about another.
    for n in regular:
      if n.folderId.len == 0 and n.projectId.len == 0 and
         n.workspaceId.len == 0: targetNotes.add n
    for f in files:
      if f.folderId.len == 0 and f.projectId.len == 0 and
         f.workspaceId.len == 0: targetFiles.add f
    # And no FOCUS notes: a focus note is a rule for a workspace, and a global
    # chat is in none.

  if targetFocus.len > 0:
    var any = false
    var block1 = "--- FOCUS / RULES ---\n"
    for n in targetFocus:
      # An empty focus note contributes nothing rather than a bare heading.
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
