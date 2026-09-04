## Script function and purpose: the database, filesystem and storage routes, and
## the in-process entry points the window uses for the same operations. Route
## shapes, query parameters and response bodies are a fixed contract: the Web UI
## is frozen and cannot be changed to match a tidier one.
##
## The seven entity tables share one shape — a text id, some columns and an
## `is_deleted` flag — so they are described once as data and served by generic
## handlers. Writing twenty routes by hand is how cascade deletes drift apart
## from one another.
##
## Deletes are soft throughout: rows are flagged and never removed, which is
## what makes the trash view and restore possible at all.

import std/[algorithm, json, strutils, tables, os, oids, times]
import ./db
import ./http
import ./fssync
import ./rag
# For `cacheStore`, so this file's cache route cannot bypass the cap. No cycle:
# nothing in the pipeline's transitive imports reaches back here.
import ./pipeline

type
  Column = object
    name: string
    isInt: bool

  Entity = object
    name: string
    cols: seq[Column]

# Two-letter constructors because the entity table below is a wall of them and
# the column names are what a reader is scanning for.
proc c(n: string): Column = Column(name: n, isInt: false)
proc i(n: string): Column = Column(name: n, isInt: true)

## Action purpose: integer columns are declared rather than guessed. The driver
## returns every value as text, so emitting a timestamp as a JSON string instead
## of a number changes the type the client receives and breaks its date handling
## in a way that is tedious to trace back here.
##
## `const` rather than `let`, because a `let` table of this shape is refcounted
## memory read concurrently by every worker thread. Compile-time data has no
## refcount to race on.
const Entities = {
  "conversations": Entity(name: "conversations", cols: @[
    c"id", c"name", i"lastModified", c"currNode", c"folderId", c"projectId",
    c"workspaceId", c"forkedFromConversationId", c"mcpServerOverrides"]),
  "messages": Entity(name: "messages", cols: @[
    c"id", c"convId", c"type", c"role", i"timestamp", c"parent", c"children",
    c"content", c"thinking", c"toolCalls", c"extra", c"model", c"timings"]),
  "workspaces": Entity(name: "workspaces", cols: @[c"id", c"name"]),
  "projects": Entity(name: "projects", cols: @[c"id", c"workspaceId", c"name"]),
  "folders": Entity(name: "folders", cols: @[c"id", c"projectId", c"name"]),
  "notes": Entity(name: "notes", cols: @[
    c"id", c"folderId", c"projectId", c"workspaceId", c"title", c"content",
    i"updatedAt", i"isFocusNote"]),
  "fileAssets": Entity(name: "fileAssets", cols: @[
    c"id", c"folderId", c"projectId", c"workspaceId", c"name", i"size",
    c"type", i"uploadDate", c"content"]),
}.toTable

## Action purpose: cascades are set-based updates rather than a fetch-and-loop,
## so one statement per child table touches every descendant regardless of how
## many there are.
const Cascades = {
  "workspaces": @[
    "UPDATE projects SET is_deleted=1 WHERE workspaceId=?",
    "UPDATE folders SET is_deleted=1 WHERE projectId IN (SELECT id FROM projects WHERE workspaceId=?)",
    "UPDATE notes SET is_deleted=1 WHERE workspaceId=?",
    "UPDATE fileAssets SET is_deleted=1 WHERE workspaceId=?",
    "UPDATE conversations SET is_deleted=1 WHERE workspaceId=?"],
  "projects": @[
    "UPDATE folders SET is_deleted=1 WHERE projectId=?",
    "UPDATE notes SET is_deleted=1 WHERE projectId=?",
    "UPDATE fileAssets SET is_deleted=1 WHERE projectId=?",
    "UPDATE conversations SET is_deleted=1 WHERE projectId=?"],
  "folders": @[
    "UPDATE notes SET is_deleted=1 WHERE folderId=?",
    "UPDATE fileAssets SET is_deleted=1 WHERE folderId=?",
    "UPDATE conversations SET is_deleted=1 WHERE folderId=?"],
  "conversations": @[
    "UPDATE messages SET is_deleted=1 WHERE convId=?"],
}.toTable

## Function purpose: how many live rows a delete would take with it, so a
## confirmation can name the number rather than asking a question the user
## cannot answer.
##
## Action purpose: the counts are derived from the cascade statements themselves
## rather than written out a second time. A confirmation that under-reports what
## it is about to delete is worse than none, because it is trusted — and two
## independent lists would drift.
proc cascadeCount*(entity, id: string): int =
  if not Cascades.hasKey(entity): return 0
  for sql in Cascades[entity]:
    let setAt = sql.find(" SET ")
    let whereAt = sql.find(" WHERE ")
    if setAt < 0 or whereAt < 0: continue
    let table = sql["UPDATE ".len ..< setAt]
    let pred = sql[whereAt + " WHERE ".len .. ^1]
    for row in db.query("SELECT COUNT(*) FROM " & table & " WHERE " & pred &
                        " AND is_deleted=0", id):
      if row.len > 0:
        # Action purpose: silence needs its reason stated here, given what the
        # count is used for. `COUNT(*)` always yields an integer and this driver
        # renders every value as text, so reaching this branch means a driver
        # returning something the aggregate cannot produce — a total-function
        # guard on an unreachable case, not a swallowed failure.
        try: result += parseInt(row[0]) except ValueError: discard

type ApiResult* = object
  status*: int
  body*: string
  ## Empty means JSON, which every route but a storage download returns. Carried
  ## explicitly rather than inferred from the body, because a stored file whose
  ## first byte is a bracket would otherwise be mistaken for a JSON array.
  contentType*: string

## Function purpose: every handler answers a result rather than writing to the
## socket, so the same code serves an HTTP route and an in-process caller.
proc ok(body: string): ApiResult = ApiResult(status: 200, body: body)
## Function purpose: the error body is JSON like every other, so a client parses
## one shape whatever the status.
proc err(status: int, msg: string): ApiResult =
  ApiResult(status: status, body: $(%*{"error": msg}))

## Function purpose: the select list, built from the declared columns so a
## query cannot name one the row mapper does not expect.
proc colList(e: Entity): string =
  var names: seq[string]
  for col in e.cols: names.add col.name
  names.join(", ")

## Function purpose: applies the declared column types, which is the only place
## a stored text value becomes a JSON number.
proc rowToJson(e: Entity, row: seq[string]): JsonNode =
  result = newJObject()
  for idx, col in e.cols:
    if idx >= row.len: break
    if col.isInt:
      result[col.name] = %(try: parseBiggestInt(row[idx]) except ValueError: 0)
    else:
      result[col.name] = %row[idx]

## Function purpose: the array form, used by every list route.
proc rowsToJson(e: Entity, rows: seq[seq[string]]): JsonNode =
  result = newJArray()
  for r in rows:
    result.add rowToJson(e, r)

## Function purpose: one query shape for every list route, with the filter
## column named by the caller rather than built into a per-entity query.
proc listEntity(e: Entity, filterCol, filterVal: string, deleted = false): ApiResult =
  let flag = if deleted: "1" else: "0"
  var sql = "SELECT " & e.colList & " FROM " & e.name & " WHERE is_deleted=" & flag
  if filterCol.len > 0 and filterVal.len > 0:
    sql.add " AND " & filterCol & "=?"
    return ok($rowsToJson(e, db.query(sql, filterVal)))
  ok($rowsToJson(e, db.query(sql)))

## Function purpose: a missing row is a 404 rather than an empty object, so a
## caller can tell "not there" from "there and empty".
proc getOne(e: Entity, id: string): ApiResult =
  let rows = db.query("SELECT " & e.colList & " FROM " & e.name &
                      " WHERE id=? AND is_deleted=0", id)
  if rows.len == 0: err(404, "not found") else: ok($rowToJson(e, rows[0]))

## Function purpose: for the cases that need a row's *previous* state before
## overwriting it — a note that moved has to have its old file trashed, and that
## path can only be built from the row as it was.
proc rowFields(e: Entity, id: string): Table[string, string] =
  let rows = db.query("SELECT " & e.colList & " FROM " & e.name & " WHERE id=?", id)
  if rows.len == 0: return
  for idx, col in e.cols:
    if idx >= rows[0].len: break
    result[col.name] = rows[0][idx]

## Function purpose: an absent field reads as empty rather than raising, because
## the client posts partial objects and means them.
proc f(node: JsonNode, name: string): string =
  if node.hasKey(name) and node[name].kind != JNull:
    let v = node[name]
    (if v.kind == JString: v.getStr else: $v)
  else:
    ""

## Function purpose: the same rule for a row already read back as a table.
proc field(t: Table[string, string], name: string): string =
  if t.hasKey(name): t[name] else: ""

## Function purpose: mirrors an upserted row onto disk. Two behaviours here are
## easy to miss and both are load-bearing.
##
## A failed filesystem write rolls the database back: letting the row stand while
## the file is missing is what produces a workspace the client lists and the disk
## does not have.
##
## A note or asset that moved has its old file trashed — the new path is written
## first and the old one trashed after, or a rename leaves the previous copy
## behind and retrieval sees the same content twice.
proc mirrorUpsert(e: Entity, node: JsonNode, prior: Table[string, string],
                  existed: bool): bool =
  case e.name
  of "workspaces":
    fssync.syncWorkspace(node.f "name",
                         (if existed: prior.field("name") else: ""))
  of "projects":
    # Action purpose: a project's directory is named after the project and sits
    # inside its workspace's, so both a rename and a move to another workspace
    # relocate it. Without this every note and asset under it is stranded.
    #
    # The name and parent are compared before calling, because resolving a
    # container's directory costs a lookup per ancestor and the client re-posts
    # whole rows — an upsert that changed neither must not pay four queries to
    # discover it has nothing to move. An insert has nothing to move either: the
    # directory appears when the first item is written into it.
    if existed and (prior.field("name") != node.f("name") or
                    prior.field("workspaceId") != node.f("workspaceId")):
      fssync.renameContainer("projects", prior.field("name"),
                             prior.field("workspaceId"),
                             node.f "name", node.f "workspaceId")
    else:
      true
  of "folders":
    if existed and (prior.field("name") != node.f("name") or
                    prior.field("projectId") != node.f("projectId")):
      fssync.renameContainer("folders", prior.field("name"),
                             prior.field("projectId"),
                             node.f "name", node.f "projectId")
    else:
      true
  of "notes":
    let okFs = fssync.syncNote(node.f "id", node.f "title", node.f "content",
                               node.f "folderId", node.f "projectId",
                               node.f "workspaceId")
    if okFs and existed and
       (prior.field("folderId") != node.f("folderId") or
        prior.field("projectId") != node.f("projectId") or
        prior.field("workspaceId") != node.f("workspaceId") or
        prior.field("title") != node.f("title")):
      discard fssync.trashNote(prior.field("id"), prior.field("title"),
                               prior.field("folderId"), prior.field("projectId"),
                               prior.field("workspaceId"))
    okFs
  of "fileAssets":
    let okFs = fssync.syncFileAsset(node.f "id", node.f "name", node.f "content",
                                    node.f "folderId", node.f "projectId",
                                    node.f "workspaceId")
    # Action purpose: an asset that moved has two correct endings and this
    # chooses between them by whether a file was actually written.
    #
    # `syncFileAsset` answers `true` for a row with no bytes having written
    # nothing, which is right on its own (report 07, V-10) — but the location
    # columns are already stored by then, so pairing that success with the
    # cleanup below trashed the old file and left the row pointing at a path
    # with nothing at it. Skipping the cleanup instead only changed where the
    # orphan sat: the bytes stayed under the old name and the row still named
    # a path with no file.
    #
    # So: bytes written at the new path means the old copy is genuinely
    # superseded and goes to the trash. No bytes written means the existing
    # mirror *is* the asset and has to follow the row to its new path.
    let moved = existed and
       (prior.field("folderId") != node.f("folderId") or
        prior.field("projectId") != node.f("projectId") or
        prior.field("workspaceId") != node.f("workspaceId") or
        prior.field("name") != node.f("name"))
    # Action purpose: the move's answer is carried, not discarded. `upsert`
    # restores every prior column when this returns false, so a move that fails
    # puts the row back where its file still is — which is the whole point of
    # moving the mirror. Discarding it kept the new location on a row whose file
    # had not moved, which is the same disagreement one step later. The trash is
    # not treated the same way: there the new file is already written, so a
    # failure to tidy the superseded copy leaves a stray file and nothing wrong
    # with the row.
    var okMove = true
    if okFs and moved:
      if fssync.contentWritesAFile(node.f "content"):
        discard fssync.trashFileAsset(prior.field("id"), prior.field("name"),
                                      prior.field("folderId"),
                                      prior.field("projectId"),
                                      prior.field("workspaceId"))
      else:
        okMove = fssync.moveFileAssetMirror(
          node.f "id", prior.field("name"), prior.field("folderId"),
          prior.field("projectId"), prior.field("workspaceId"),
          node.f "name", node.f "folderId", node.f "projectId",
          node.f "workspaceId")
    okFs and okMove
  else:
    true

## Function purpose: insert-or-replace over every declared column, which is why
## a caller with a partial object has to merge first — see `putEntity`.
proc writeRow(e: Entity, node: JsonNode) =
  var placeholders: seq[string]
  var values: seq[string]
  for col in e.cols:
    placeholders.add "?"
    values.add node.f(col.name)
  db.exec("INSERT OR REPLACE INTO " & e.name & " (" & e.colList & ", is_deleted) VALUES (" &
          placeholders.join(", ") & ", 0)", values)

## Function purpose: runs a retrieval-index update without letting it fail the
## write it is attached to.
##
## Action purpose: indexing begins by deleting the path's existing rows, and
## that raises — so a database without the retrieval tables, or a locked index,
## would propagate out of a successful save and answer 500. The row is already
## written and mirrored by then, so the client is told a save failed that in
## fact succeeded, which is the worst shape a failure can take.
##
## Retrieval degrading is not worth a user's note, and the backfills repair a
## skipped index at the next start.
template indexing(body: untyped) =
  try:
    body
  except CatchableError:
    discard

## Function purpose: insert-or-replace from a JSON body, with a missing field
## becoming empty rather than an error — the client posts partial objects for
## several entities and means them.
##
## `mirror` is false only for bulk import, the one path that writes rows without
## touching the filesystem.
proc upsert(e: Entity, node: JsonNode, mirror = true): ApiResult =
  if node.kind != JObject or not node.hasKey("id"):
    return err(400, "body must be an object with an id")
  let id = node.f "id"
  let prior = if mirror: rowFields(e, id) else: initTable[string, string]()
  let existed = prior.len > 0

  # Action purpose: the deleted flag is not one of the declared columns, so the
  # writer always sets it to zero. Captured here before the row is overwritten,
  # so a rollback restores the flag the row actually had — otherwise a failed
  # upsert against a soft-deleted row silently resurrects it.
  var priorDeleted = "0"
  if mirror and existed:
    let flagRows = db.query("SELECT is_deleted FROM " & e.name & " WHERE id=?", id)
    if flagRows.len > 0 and flagRows[0].len > 0 and flagRows[0][0].len > 0:
      priorDeleted = flagRows[0][0]

  writeRow(e, node)

  if mirror and not mirrorUpsert(e, node, prior, existed):
    # Restore the previous state rather than leave a row with no file.
    if existed:
      var restoreNode = newJObject()
      for col in e.cols:
        restoreNode[col.name] = %prior.field(col.name)
      writeRow(e, restoreNode)
      db.exec("UPDATE " & e.name & " SET is_deleted=? WHERE id=?", priorDeleted, id)
    else:
      db.exec("DELETE FROM " & e.name & " WHERE id=?", id)
    return err(500, "filesystem sync failed for " & e.name)

  # Action purpose: hooked here rather than in each surface's own save path,
  # because this is the one layer the HTTP route and the window's in-process
  # write both pass through — so a third client is covered by construction
  # rather than by someone remembering.
  #
  # Only when the indexed text actually changed. Indexing costs an embedding
  # round trip, the prior row is already in hand, and a note is saved far more
  # often than it is rewritten; re-embedding an unchanged one would put that
  # round trip behind the save button.
  if mirror:
    case e.name
    of "notes":
      let title = node.f "title"
      let content = node.f "content"
      if not existed or prior.field("title") != title or
         prior.field("content") != content:
        indexing: discard rag.indexNote(id, title, content)
    of "fileAssets":
      let name = node.f "name"
      let content = node.f "content"
      if not existed or prior.field("name") != name or
         prior.field("content") != content:
        indexing: discard rag.indexFileAsset(id, name, content)
    else: discard

  ok("""{"status":"ok"}""")

const DescendantsCte = """
WITH RECURSIVE descendants AS (
    SELECT id FROM conversations WHERE id = ?
    UNION
    SELECT c.id FROM conversations c
    INNER JOIN descendants d ON c.forkedFromConversationId = d.id
)
"""

## Action purpose: two behaviours, both of which matter for the fork tree. With
## forks the descendant walk is recursive, because matching only direct children
## orphans grandchildren silently; without them, children are reparented onto the
## deleted conversation's own parent before it is flagged, so the tree stays
## connected rather than pointing at a deleted node.
proc deleteConversation(id: string, withForks: bool): ApiResult =
  # Action purpose: collected before the transaction and forgotten from the
  # index after it commits. A conversation's messages are flagged in one
  # statement, so there is no per-row site to hook, and unfiling inside the
  # transaction would strip the index for a delete that then rolled back.
  var affected = @[id]
  if withForks:
    for r in db.query(DescendantsCte & "SELECT id FROM descendants", id):
      if r.len > 0 and r[0].len > 0 and r[0] != id: affected.add r[0]

  db.begin()
  try:
    if withForks:
      db.exec(DescendantsCte &
        "UPDATE conversations SET is_deleted=1 WHERE id IN (SELECT id FROM descendants)", id)
      db.exec(DescendantsCte &
        "UPDATE messages SET is_deleted=1 WHERE convId IN (SELECT id FROM descendants)", id)
    else:
      db.exec("UPDATE conversations SET forkedFromConversationId = " &
              "(SELECT forkedFromConversationId FROM conversations WHERE id = ?) " &
              "WHERE forkedFromConversationId = ?", id, id)
      db.exec("UPDATE conversations SET is_deleted=1 WHERE id=?", id)
      db.exec("UPDATE messages SET is_deleted=1 WHERE convId=?", id)
    db.commit()
  except CatchableError:
    db.rollback()
    return err(500, "delete failed: " & getCurrentExceptionMsg())
  for c in affected: indexing: rag.forgetConversation(c)
  ok("""{"status":"ok"}""")

## Action purpose: the flag and its cascade are one transaction, so a container
## cannot end up deleted with its children still live. As a bare sequence of
## statements a throw part-way leaves the earlier ones standing and the rest
## unrun — a workspace gone from the sidebar whose conversations are still served.
##
## The exception is re-raised rather than swallowed: the caller catches it to
## move a directory back out of the trash, and that undo only works if it still
## hears about the failure.
proc dbSoftDelete(e: Entity, id: string) =
  db.begin()
  try:
    db.exec("UPDATE " & e.name & " SET is_deleted=1 WHERE id=?", id)
    if Cascades.hasKey(e.name):
      for sql in Cascades[e.name]:
        db.exec(sql, id)
    db.commit()
  except CatchableError:
    db.rollback()
    raise

## Function purpose: a cascade flags a container's descendants in one statement
## per table, so none of them ever passes through `softDelete` and nothing on
## that path unfiles them from the index. Deleting a workspace left every note,
## uploaded file and conversation under it still answering retrieval — the one
## place a deletion was invisible.
##
## Action purpose: the ids are derived from the cascade statements themselves,
## for the reason `cascadeCount` gives — two hand-written lists of what a delete
## reaches drift, and the drift here is silent. They are read *before* the
## transaction because afterwards the rows no longer match the cascade's own
## `is_deleted=0` predicate, which is the same ordering `deleteConversation`
## uses.
proc cascadeIndexTargets(entity, id: string): seq[(string, string)] =
  if not Cascades.hasKey(entity): return
  for sql in Cascades[entity]:
    let setAt = sql.find(" SET ")
    let whereAt = sql.find(" WHERE ")
    if setAt < 0 or whereAt < 0: continue
    let table = sql["UPDATE ".len ..< setAt]
    # `messages` is absent deliberately: no container cascade reaches it, and a
    # conversation's turns are unfiled by `rag.forgetConversation` reading the
    # index rather than the message table.
    if table notin ["notes", "fileAssets", "conversations"]: continue
    let pred = sql[whereAt + " WHERE ".len .. ^1]
    for row in db.query("SELECT id FROM " & table & " WHERE " & pred &
                        " AND is_deleted=0", id):
      if row.len > 0 and row[0].len > 0: result.add((table, row[0]))

## Function purpose: run only after the transaction commits — unfiling inside it
## would strip the index for a delete that then rolled back, leaving rows the
## interface still shows and retrieval no longer knows.
proc forgetIndexed(targets: seq[(string, string)]) =
  for (table, rowId) in targets:
    indexing:
      case table
      of "notes": rag.forgetNote(rowId)
      of "fileAssets": rag.forgetFileAsset(rowId)
      of "conversations": rag.forgetConversation(rowId)
      else: discard

## Action purpose: the order differs by entity and is deliberate. For a
## container the filesystem move happens first, so a failure leaves the row
## alone and the database never claims a deletion the disk did not perform;
## projects and folders additionally move the directory back out of the trash if
## the database step then fails, which is the only compensating undo here.
##
## For a note or asset the row is flagged first and the file trashed after,
## because the old path is rebuilt from the row — and a soft delete leaves it
## readable. Unifying the two orders would silently change a contract the frozen
## client depends on.
proc softDelete(e: Entity, id: string, withForks = false): ApiResult =
  if e.name == "conversations":
    return deleteConversation(id, withForks)

  let prior = rowFields(e, id)
  if prior.len == 0 and e.name in ["workspaces", "projects", "folders"]:
    return err(404, "not found")

  case e.name
  of "workspaces":
    if not fssync.trashWorkspace(id, prior.field "name"):
      return err(500, "filesystem trash failed for workspace")
    let cascaded = cascadeIndexTargets(e.name, id)
    dbSoftDelete(e, id)
    forgetIndexed(cascaded)

  of "projects":
    let r = fssync.trashProject(id, prior.field "workspaceId", prior.field "name")
    if not r.ok:
      return err(500, "filesystem trash failed for project")
    # Action purpose: inside the compensation boundary, not before it. The
    # directory is already in the trash by this point, and `cascadeIndexTargets`
    # runs a query — so a failure there escaped with the row still live and the
    # container still trashed, which is the one state this block exists to make
    # impossible.
    var cascaded: seq[(string, string)]
    try:
      cascaded = cascadeIndexTargets(e.name, id)
      dbSoftDelete(e, id)
    except CatchableError:
      if r.path.len > 0 and r.original.len > 0:
        try: moveDir(r.path, r.original)
        except OSError: discard
      return err(500, "delete failed: " & getCurrentExceptionMsg())
    forgetIndexed(cascaded)

  of "folders":
    let r = fssync.trashFolder(id, prior.field "projectId", prior.field "name")
    if not r.ok:
      return err(500, "filesystem trash failed for folder")
    # Action purpose: inside the compensation boundary, not before it. The
    # directory is already in the trash by this point, and `cascadeIndexTargets`
    # runs a query — so a failure there escaped with the row still live and the
    # container still trashed, which is the one state this block exists to make
    # impossible.
    var cascaded: seq[(string, string)]
    try:
      cascaded = cascadeIndexTargets(e.name, id)
      dbSoftDelete(e, id)
    except CatchableError:
      if r.path.len > 0 and r.original.len > 0:
        try: moveDir(r.path, r.original)
        except OSError: discard
      return err(500, "delete failed: " & getCurrentExceptionMsg())
    forgetIndexed(cascaded)

  of "notes":
    dbSoftDelete(e, id)
    # A deleted note must stop being recalled. Three deletes, no embedding
    # server, so this is safe to run from any thread.
    indexing: rag.forgetNote(id)
    if prior.len > 0:
      discard fssync.trashNote(id, prior.field "title", prior.field "folderId",
                               prior.field "projectId", prior.field "workspaceId")

  of "fileAssets":
    dbSoftDelete(e, id)
    indexing: rag.forgetFileAsset(id)
    if prior.len > 0:
      discard fssync.trashFileAsset(id, prior.field "name",
                                    prior.field "folderId",
                                    prior.field "projectId",
                                    prior.field "workspaceId")

  else:
    dbSoftDelete(e, id)
    # Action purpose: a deleted turn must stop being recalled. Reachable from
    # both surfaces, and safe on the GTK thread because forgetting a path is
    # three deletes and never touches the embedding server.
    if e.name == "messages": indexing: rag.forgetMessage(id)

  ok("""{"status":"ok"}""")

## Action purpose: restoring cascades upward as well as down. Reviving a note
## whose folder or workspace is still flagged leaves it present in the table and
## invisible in the interface, so the ancestry is restored first. The depth guard
## exists because this walks parent links read from data, and a cycle there would
## recurse without end.
##
## The outcome reports what happened to *this* item's file and not its
## ancestors'. Their results are dropped deliberately: the user asked about the
## thing they clicked, and a folder that was already on disk is not news.
proc restoreItem(entityName, id: string, outcome: var fssync.RestoreOutcome,
                 depth = 0): ApiResult =
  if depth > 8 or not Entities.hasKey(entityName):
    return ok("""{"status":"ok"}""")
  let e = Entities[entityName]
  let rows = db.query("SELECT " & e.colList & " FROM " & e.name & " WHERE id=?", id)
  if rows.len == 0:
    return err(404, "not found")

  let row = rows[0]
  for idx, col in e.cols:
    if idx >= row.len: break
    let v = row[idx]
    if v.len == 0 or v == "null": continue
    # An ancestor's own outcome goes nowhere on purpose.
    var ancestor: fssync.RestoreOutcome
    case col.name
    of "folderId": discard restoreItem("folders", v, ancestor, depth + 1)
    of "projectId": discard restoreItem("projects", v, ancestor, depth + 1)
    of "workspaceId": discard restoreItem("workspaces", v, ancestor, depth + 1)
    else: discard

  db.exec("UPDATE " & e.name & " SET is_deleted=0 WHERE id=?", id)
  # Action purpose: the file comes back with the row. Deletion moves it into a
  # trash tree beside a sidecar written for exactly this, and without the call
  # the sidecar is never read — leaving a note's markdown, an asset's bytes and
  # a container's whole directory in the trash under a dialog that told the user
  # they could be restored from there.
  #
  # The ancestors are restored first by the recursion above, so a directory is
  # back before anything is moved into it.
  #
  # The answer is carried out rather than discarded, because a bool says two
  # different things: "this kind never had a file", which is ordinary and must
  # stay silent, and "this kind has files and this one did not come back", which
  # is a restore that only half happened.
  outcome = fssync.restoreMirror(e.name, id)
  # Action purpose: deletion forgets, so restoring has to re-index or the turn
  # comes back everywhere except in what the model recalls. Immediately, and not
  # left to the backfill at the next start: a gap that closes itself before
  # anyone can reproduce it is worse than one that stays open.
  if e.name == "messages":
    indexing: discard rag.indexExchange(id, withParent = false)
  # The same for the two entities that carry index entries. The row here is
  # positional rather than the name/value table the delete path holds, so the
  # columns are read back through the one place that turns order into names.
  if e.name == "notes":
    let n = rowFields(e, id)
    indexing: discard rag.indexNote(id, n.field "title", n.field "content")
  if e.name == "fileAssets":
    let fa = rowFields(e, id)
    indexing: discard rag.indexFileAsset(id, fa.field "name", fa.field "content")
  if e.name == "conversations":
    # Every message of the conversation is revived, including any deleted
    # individually beforehand. That is the shipped contract, not a choice made
    # here.
    db.exec("UPDATE messages SET is_deleted=0 WHERE convId=?", id)
    # Every revived assistant turn goes back into the index with them. Only
    # assistant rows: indexing takes a reply and pulls in the turn it answers,
    # so walking user rows too would index each exchange twice.
    for r in db.query("SELECT id FROM messages WHERE convId=? AND role=? " &
                      "AND is_deleted=0", id, "assistant"):
      indexing: discard rag.indexExchange(r[0])
  ok("""{"status":"ok"}""")

## Function purpose: the route-shaped wrapper over the recursive restore, so the
## HTTP surface does not have to handle an outcome it cannot report.
proc restore(e: Entity, id: string): ApiResult =
  # The HTTP route has nowhere to put the outcome, since its response shape is
  # the frozen client's, so it is carried only to the window.
  var outcome: fssync.RestoreOutcome
  restoreItem(e.name, id, outcome)

## Function purpose: a malformed body answers nil rather than raising, so every
## route can turn it into a 400 rather than a 500.
proc parseBodyJson(body: string): JsonNode =
  try: parseJson(body) except CatchableError: nil

## Function purpose: writes only the columns the caller supplied. The generic
## writer is insert-or-replace over every column, so changing a message's text
## alone would blank its conversation, role and timestamp.
##
## A proc rather than route-inline because the window's edit action needs exactly
## this, and a second copy there would be two definitions of one contract.
proc updateMessage(node: JsonNode): ApiResult =
  if node.isNil or not node.hasKey("id"):
    return err(400, "id required")
  let e = Entities["messages"]
  var sets: seq[string]
  var vals: seq[string]
  for col in e.cols:
    if col.name != "id" and node.hasKey(col.name):
      sets.add col.name & "=?"
      let v = node[col.name]
      vals.add (if v.kind == JString: v.getStr else: $v)
  if sets.len == 0: return err(400, "no updatable fields present")
  vals.add node["id"].getStr
  db.exec("UPDATE messages SET " & sets.join(", ") & " WHERE id=?", vals)
  ok("""{"status":"ok"}""")

## Function purpose: shaped like the other in-process entry points, so the window
## keeps going through this module rather than writing message SQL of its own.
proc patchMessage*(node: JsonNode): bool =
  updateMessage(node).status == 200

# ---------------------------------------------------------------------------
# The message tree
# ---------------------------------------------------------------------------
#
# A conversation is a tree rather than a list: editing a turn or regenerating a
# reply produces an alternative version of it, a sibling, and the reader sees one
# path from the root down to whichever leaf they last landed on.
#
# Action purpose: these three are pure functions over (id, parent) pairs,
# deliberately. Branching is the part most likely to be silently wrong — an
# off-by-one in a sibling counter looks fine and misleads — and pure functions
# over data can be asserted against a known fork shape with no database and no
# window. The window calls them over messages it already holds, so they cost it
# no extra queries.

type MsgEdge* = tuple[id, parent: string]

## Function purpose: the conversation as it is currently being read — root to
## leaf, oldest first.
##
## Action purpose: the depth guard is not padding. `parent` is data a row can be
## edited into, and a cycle there hangs the window rather than drawing a wrong
## transcript.
proc pathTo*(edges: openArray[MsgEdge], leaf: string): seq[string] =
  if leaf.len == 0: return
  var parentOf = initTable[string, string]()
  for e in edges: parentOf[e.id] = e.parent
  if not parentOf.hasKey(leaf): return
  var cur = leaf
  var guard = 0
  while cur.len > 0 and guard < 4096:
    result.add cur
    inc guard
    if not parentOf.hasKey(cur): break
    cur = parentOf[cur]
  reverse(result)

## Function purpose: every version of one turn, in the order they were made —
## what a "2 of 3" counter counts and what the arrows step through.
##
## A message is its own sibling, so a turn that was never branched answers a list
## of one. That is what lets a caller ask unconditionally and show the control
## only when there is more than one.
proc siblingsIn*(edges: openArray[MsgEdge], id: string): seq[string] =
  var parent = ""
  var found = false
  for e in edges:
    if e.id == id:
      parent = e.parent
      found = true
      break
  if not found: return
  for e in edges:
    if e.parent == parent: result.add e.id

## Function purpose: where the reader lands after switching to a sibling — the
## deepest message under it, following the newest branch at each step.
##
## Newest is last in the edges the caller supplies, which arrive in timestamp
## order, so switching to an older version shows the reply made *for that
## version* rather than stranding the reader at the switch point.
proc deepestFrom*(edges: openArray[MsgEdge], id: string): string =
  result = id
  var guard = 0
  while guard < 4096:
    inc guard
    var next = ""
    for e in edges:
      if e.parent == result: next = e.id
    if next.len == 0: break
    result = next

## Function purpose: one transaction, so a partial dump cannot leave the
## database half-populated.
proc importData(node: JsonNode): ApiResult =
  if node.isNil or node.kind != JObject:
    return err(400, "body must be an object")
  const order = ["conversations", "messages", "workspaces", "projects",
                 "folders", "notes", "fileAssets"]
  db.begin()
  try:
    for name in order:
      if node.hasKey(name) and node[name].kind == JArray:
        for item in node[name]:
          # Rows only: a bulk import of thousands of notes must not run a git
          # add per row, and the files arrive with the dump.
          let r = upsert(Entities[name], item, mirror = false)
          if r.status != 200:
            db.rollback()
            return err(500, "import failed in " & name)
    db.commit()
  except CatchableError:
    db.rollback()
    return err(500, "import failed: " & getCurrentExceptionMsg())
  ok("""{"status":"ok"}""")

## Function purpose: nothing here reads the children column — the tree is built
## from parents — but it is the frozen client's, and a fork carrying the
## *source's* ids would hand that surface a turn claiming children in another
## conversation.
##
## Action purpose: re-emitted as a JSON array because that is how the client
## stores it, and a comma-separated value is accepted too since the column is
## text and this has no way to insist.
proc remapChildren(raw: string, idMap: Table[string, string]): string =
  var ids: seq[string]
  try:
    let parsed = parseJson(if raw.len == 0: "[]" else: raw)
    if parsed.kind == JArray:
      for k in parsed:
        if k.kind == JString: ids.add k.getStr
  except CatchableError:
    for k in raw.split(','): ids.add k.strip
  var kept = newJArray()
  for k in ids:
    if idMap.hasKey(k): kept.add %idMap[k]
  $kept

## Function purpose: copies one branch of a conversation into a new one, and is
## the only writer of the fork relationship the delete cascade already maintains.
##
## Action purpose: the copy is the path down to the named message and not the
## whole tree, because a fork means "continue from here, down this line" — the
## branches beside it are deliberately left behind.
##
## Ids are remapped through one table, so a copied parent points at the copy and
## never back at the original. A parent that escaped the remap would attach the
## new conversation's history to the old one's rows, and each would then edit the
## other.
##
## Written through the bulk import rather than row by row, so the whole fork is
## one transaction and a failure part way leaves nothing behind.
proc forkConversation*(sourceId, atMessageId, newName: string):
    tuple[ok: bool, id, msg: string] =
  let convs = Entities["conversations"]
  let src = rowFields(convs, sourceId)
  if src.len == 0: return (false, "", "no such conversation")

  let msgs = Entities["messages"]
  let rows = db.query("SELECT " & msgs.colList &
                      " FROM messages WHERE convId=? AND is_deleted=0" &
                      " ORDER BY timestamp", sourceId)
  var edges: seq[MsgEdge]
  var byId = initTable[string, seq[string]]()
  for r in rows:
    if r.len < msgs.cols.len: continue
    edges.add (id: r[0], parent: r[5])
    byId[r[0]] = r

  # An empty message id forks from the conversation's own read position, which
  # is what forking means with no message selected.
  let leaf = if atMessageId.len > 0: atMessageId else: src.field("currNode")
  let path = pathTo(edges, leaf)
  if path.len == 0:
    return (false, "", "could not resolve the message path to " & leaf)

  var idMap = initTable[string, string]()
  for id in path: idMap[id] = $genOid()
  let newId = $genOid()

  var outMsgs = newJArray()
  for id in path:
    let r = byId[id]
    var node = rowToJson(msgs, r)
    node["id"] = %idMap[id]
    node["convId"] = %newId
    # A parent outside the copied path becomes empty rather than dangling: the
    # first turn of a fork is a root, exactly as the source's own root is.
    node["parent"] = %idMap.getOrDefault(r[5], "")
    node["children"] = %remapChildren(r[6], idMap)
    outMsgs.add node

  var conv = newJObject()
  for col in convs.cols:
    conv[col.name] = %src.field(col.name)
  conv["id"] = %newId
  conv["name"] = %(if newName.len > 0: newName
                   else: src.field("name") & " (fork)")
  conv["currNode"] = %idMap[path[^1]]
  conv["forkedFromConversationId"] = %sourceId
  # Milliseconds, which is what this column holds everywhere else and what the
  # sidebar sorts on.
  conv["lastModified"] = %(epochTime() * 1000).int64

  var convArr = newJArray()
  convArr.add conv
  var payload = newJObject()
  payload["conversations"] = convArr
  payload["messages"] = outMsgs
  let r = importData(payload)
  if r.status != 200: return (false, "", r.body)
  (true, newId, "")

## Function purpose: entity writes for in-process callers, through the same
## upsert and delete the HTTP routes use, so cascades and the filesystem mirror
## apply identically whichever surface the user is on.
##
## Action purpose: the node is merged onto the stored row before it is written,
## and that is the one deliberate difference from the HTTP path. The generic
## writer is insert-or-replace over every column, so a caller that omits one
## blanks it — correct for a client that posts partial objects and means them,
## wrong for a window that builds its node from whatever fields the open screen
## happens to hold. Left to each call site the trap is inherited by every new
## one; merged at the boundary they all pass through, it is closed once.
##
## A create is unaffected: a row that does not exist yet has no stored fields to
## merge, so the node is written exactly as given.
proc putEntity*(entity: string, node: JsonNode): bool =
  if entity notin Entities: return false
  if node.kind != JObject or not node.hasKey("id"): return false
  let e = Entities[entity]
  let prior = rowFields(e, node.f "id")
  if prior.len == 0:
    return upsert(e, node).status == 200
  var merged = newJObject()
  for key, val in node: merged[key] = val
  for col in e.cols:
    if not merged.hasKey(col.name) and prior.hasKey(col.name):
      merged[col.name] = %prior[col.name]
  upsert(e, merged).status == 200

## Function purpose: the in-process delete, through the same soft delete and
## cascade the HTTP route uses.
proc deleteEntity*(entity, id: string): bool =
  entity in Entities and softDelete(Entities[entity], id).status == 200

## Function purpose: goes through the same restore the HTTP route uses, so the
## upward cascade and the re-index apply whichever surface the user restored
## from. A window that cleared the flag itself would skip both.
proc restoreEntity*(entity, id: string): bool =
  var outcome: fssync.RestoreOutcome
  entity in Entities and restoreItem(entity, id, outcome).status == 200

## Function purpose: restore, and say what happened to the file — which is what
## the trash view needs in order not to claim a restore it did not perform.
##
## Separate from the plain version rather than replacing it: the HTTP route and
## the tests want the bare answer, and a caller that cannot act on an outcome
## should not have to handle one. No physical form is not a failure — a
## conversation never had a file, and reporting there would cry wolf on the
## commonest restore of all.
proc restoreEntityOutcome*(entity, id: string):
    tuple[ok: bool, outcome: fssync.RestoreOutcome] =
  if entity notin Entities: return (false, fssync.rmNoPhysicalForm)
  var outcome: fssync.RestoreOutcome
  let r = restoreItem(entity, id, outcome)
  (r.status == 200, outcome)

## Function purpose: reconciles every live note against its file, which is what
## makes an edit written outside the note editor return rather than being
## overwritten by the next save.
##
## Action purpose: disk wins, and only when the file differs — a file matching
## the row is skipped so nothing is rewritten and no commit is made for a no-op.
## A missing file is left alone rather than read as a deletion: an absent mirror
## means the note has not been saved since the tree was made, and deleting one is
## not inferred from the filesystem.
##
## Written through the in-process entry point, so the merge at that boundary
## carries forward every column this does not mention.
proc pullNotes*(): tuple[updated: int, failed: int] =
  let e = Entities["notes"]
  for r in db.query("SELECT " & e.colList & " FROM notes WHERE is_deleted=0"):
    if r.len < e.cols.len: continue
    let (id, folderId, projectId, workspaceId, title, content) =
      (r[0], r[1], r[2], r[3], r[4], r[5])
    let (found, onDisk) = fssync.readNoteMirror(id, title, folderId, projectId,
                                                workspaceId)
    if not found or onDisk == content: continue
    if putEntity("notes", %*{"id": id, "content": onDisk,
                             "updatedAt": (epochTime() * 1000).int64}):
      inc result.updated
    else:
      inc result.failed

## Function purpose: the trash view's source — the entity's own column list with
## the deleted flag inverted, rather than a second query shape that could drift
## from it.
##
## Action purpose: newest first, because receipt order puts the oldest deletion
## at the top of a long trash. The ordering column is named per entity since
## there is no common one, and is checked against the declared list before use so
## a renamed column degrades to unordered rather than throwing SQL at the trash
## view. Three entities carry only an id and a name and are legitimately
## unordered.
const TrashOrder = {
  "conversations": "lastModified", "messages": "timestamp",
  "notes": "updatedAt", "fileAssets": "uploadDate",
}.toTable

## Function purpose: rows rather than JSON, because the window renders them into
## widgets and would only have to parse its own output back.
proc deletedRows*(entity: string): seq[seq[string]] =
  if entity notin Entities: return
  let e = Entities[entity]
  var sql = "SELECT " & e.colList & " FROM " & e.name & " WHERE is_deleted=1"
  if TrashOrder.hasKey(entity):
    let col = TrashOrder[entity]
    for c in e.cols:
      if c.name == col:
        sql.add " ORDER BY " & col & " DESC"
        break
  db.query(sql)

## Function purpose: every live row in the shape the importer reads, so export
## and import cannot drift — and so the window's Export button does not build a
## dump of its own from a second copy of the column list.
proc exportAll*(): JsonNode =
  const order = ["conversations", "messages", "workspaces", "projects",
                 "folders", "notes", "fileAssets"]
  result = newJObject()
  for name in order:
    let e = Entities[name]
    result[name] = rowsToJson(e, db.query(
      "SELECT " & e.colList & " FROM " & e.name & " WHERE is_deleted=0"))

## Function purpose: the window's Import, over the same transactional importer
## the HTTP route uses.
##
## Action purpose: two input shapes are accepted because there are two writers —
## this build's keyed object and the frozen client's per-conversation array.
## Converting the second here rather than adding a route keeps one transactional
## implementation and makes a file from either surface readable by the other.
proc importAll*(node: JsonNode): tuple[ok: bool, msg: string] =
  if node.isNil: return (false, "the file is not valid JSON")
  var payload = node
  if node.kind == JArray:
    var convs = newJArray()
    var msgs = newJArray()
    for entry in node:
      if entry.kind != JObject: continue
      if entry.hasKey("conv") and entry["conv"].kind == JObject:
        convs.add entry["conv"]
      if entry.hasKey("messages") and entry["messages"].kind == JArray:
        for m in entry["messages"]: msgs.add m
    if convs.len == 0 and msgs.len == 0:
      return (false, "no conversations found in the file")
    payload = %*{"conversations": convs, "messages": msgs}
  let r = importData(payload)
  if r.status == 200: (true, "") else: (false, r.body)

## Function purpose: the trash surface — list, restore, empty and the tree — kept
## apart from the entity routes because it addresses files rather than rows.
proc handleFs*(req: Request): ApiResult =
  if not req.path.startsWith("/api/fs/"):
    return err(404, "not found")
  let route = req.path[8 .. ^1]
  let isGet = req.meth == "GET"

  if isGet and route == "trash":
    return ok($fssync.toJson(fssync.getTrash()))

  if isGet and route == "tree":
    return ok($fssync.toJson(fssync.getFsTree(req.queryStr("workspace"),
                                              req.queryStr("project"),
                                              req.queryStr("folder"))))

  if req.meth == "POST" and route == "trash/restore":
    let node = parseBodyJson(req.body)
    if node.isNil or not node.hasKey("trash_path") or not node.hasKey("original_path"):
      return err(400, "trash_path and original_path required")
    if fssync.restoreTrash(node["trash_path"].getStr, node["original_path"].getStr):
      return ok("""{"status":"ok"}""")
    return err(500, "restore failed")

  if req.meth == "DELETE" and route == "trash/empty":
    if fssync.emptyTrash():
      return ok("""{"status":"ok"}""")
    return err(500, "empty trash failed")

  err(404, "not found")

## Function purpose: raw file access under the workspaces root — the one surface
## that takes a client-supplied path and reads, writes and deletes with it, so
## containment is the whole risk. Every path goes through one resolver, which
## refuses on a literal `..`, on lexical escape, on a directory-boundary
## mismatch, and on a symlinked component
## pointing out of the tree. A refusal is a 403 and never a 404, because a 404
## would tell a caller whether a path outside the root exists.
##
## All four verbs are called by the frozen client, so the response shapes are
## matched rather than improved.
proc handleStorage*(req: Request): ApiResult =
  # A bare prefix match accepts `/api/storagefoo` and then decodes `oo` as the
  # relative path, so the boundary is required: the route is the exact path or a
  # child of it, never a sibling that merely shares the first thirteen bytes.
  const Prefix = "/api/storage"
  if not (req.path == Prefix or req.path.startsWith(Prefix & "/")):
    return err(404, "not found")

  var rel = ""
  if req.path.len > Prefix.len + 1:   # everything after "/api/storage/"
    rel = urlDecode(req.path[Prefix.len + 1 .. ^1])

  # GET /api/storage or /api/storage/ — the listing
  if req.meth == "GET" and rel.len == 0:
    var arr = newJArray()
    for p in fssync.storageList():
      arr.add %p
    return ok($arr)

  if rel.len == 0:
    return err(400, "path required")

  case req.meth
  of "GET":
    let (found, content) = fssync.storageGet(rel)
    if not found:
      # Distinguish refusal from absence: a refused path must not reveal
      # whether anything exists there.
      if fssync.resolveStoragePath(rel).len == 0:
        return err(403, "forbidden")
      return err(404, "not found")
    return ApiResult(status: 200, body: content,
                     contentType: "application/octet-stream")
  of "POST":
    if fssync.resolveStoragePath(rel).len == 0:
      return err(403, "forbidden")
    if req.body.len == 0:
      return err(400, "empty body")
    if fssync.storageSave(rel, req.body):
      return ok("""{"status":"ok"}""")
    return err(500, "write failed")
  of "DELETE":
    if fssync.resolveStoragePath(rel).len == 0:
      return err(403, "forbidden")
    let r = fssync.storageTrash(rel)
    if r.ok:
      return ok("""{"status":"ok"}""")
    if r.msg == "not found":
      return err(404, "not found")
    return err(500, "delete failed")
  else:
    return err(405, "method not allowed")

## Function purpose: route one /api/db/* request. Returns a status and body; the
## caller writes the response, so this stays independent of the socket layer and
## can be exercised without one.
proc handleDb*(req: Request): ApiResult =
  if not req.path.startsWith("/api/db/"):
    return err(404, "not found")
  let route = req.path[8 .. ^1]
  let isGet = req.meth == "GET"
  let parts = route.split('/')
  let head = parts[0]

  # ---- cache -------------------------------------------------------------
  if head == "cache":
    if isGet:
      let key = req.queryStr("key")
      if key.len == 0: return err(400, "key required")
      let rows = db.query(
        "SELECT cache_key, response, timestamp FROM llm_cache WHERE cache_key=?", key)
      if rows.len == 0: return err(404, "not found")
      return ok($(%*{"cache_key": rows[0][0], "response": rows[0][1],
                     "timestamp": (try: parseBiggestInt(rows[0][2]) except ValueError: 0)}))
    # Anything that is not a GET fell through to the write below, so a DELETE or
    # a PUT stored a cache entry. Every other route in this file answers 405 for
    # an unsupported method; this one now does too.
    if req.meth != "POST":
      return err(405, "method not allowed")
    let node = parseBodyJson(req.body)
    if node.isNil or not node.hasKey("key") or not node.hasKey("response"):
      return err(400, "key and response required")
    # Action purpose: through the same door as the completion path, so there is
    # exactly one place a cache entry is written and the cap and eviction cannot
    # be bypassed by writing here instead.
    #
    # The stream-shape guard is deliberately not here and not in the shared
    # writer. That a stored body must carry event lines is a property of what
    # the completion path produces, not of the store, so it belongs on that
    # path — this route legitimately accepts a bare string.
    pipeline.cacheStore(node["key"].getStr, node["response"].getStr)
    return ok("""{"status":"ok"}""")

  # ---- import ------------------------------------------------------------
  if head == "import" and not isGet:
    return importData(parseBodyJson(req.body))

  # ---- single message by id (distinct route in the original) -------------
  if head == "message" and isGet:
    let id = req.queryStr("id")
    if id.len == 0: return err(400, "id required")
    return getOne(Entities["messages"], id)

  if not Entities.hasKey(head):
    return err(404, "unknown collection: " & head)
  let e = Entities[head]

  # ---- messages sub-routes ------------------------------------------------
  if head == "messages" and not isGet and parts.len > 1:
    case parts[1]
    of "bulk-delete":
      let node = parseBodyJson(req.body)
      if node.isNil or not node.hasKey("ids") or node["ids"].kind != JArray:
        return err(400, "ids array required")
      db.begin()
      try:
        for idNode in node["ids"]:
          db.exec("UPDATE messages SET is_deleted=1 WHERE id=?", idNode.getStr)
        db.commit()
      except CatchableError:
        db.rollback()
        return err(500, "bulk delete failed")
      # After the commit: a rolled-back delete must not leave the index
      # stripped of rows that are still live.
      for idNode in node["ids"]: indexing: rag.forgetMessage(idNode.getStr)
      return ok("""{"status":"ok"}""")
    of "update":
      # Action purpose: an edited message whose index entry holds the old text
      # is recalled by its old words and quoted back with its new ones.
      #
      # Re-indexed on the route rather than inside the shared update, because
      # the window calls that on the GTK thread and an embedding round trip
      # there would freeze the transcript — it feeds the index from its own
      # control worker instead.
      #
      # No parent: the turn this one answers has not changed.
      let node = parseBodyJson(req.body)
      let r = updateMessage(node)
      if r.status == 200 and not node.isNil and node.hasKey("content"):
        indexing: discard rag.indexExchange(node.f "id", withParent = false)
      return r
    else: discard

  # ---- /<entity>/deleted, /<entity>/all, /<entity>/<id>/restore ----------
  if parts.len > 1:
    if isGet and parts[1] == "deleted":
      return listEntity(e, "", "", deleted = true)
    if isGet and parts[1] == "all":
      return listEntity(e, "", "")
    if not isGet and parts.len > 2 and parts[2] == "restore":
      return restore(e, parts[1])
    if req.meth == "DELETE":
      return softDelete(e, parts[1],
                        withForks = req.queryStr("deleteWithForks") == "true")
    return err(404, "unknown route: " & route)

  # ---- collection root ----------------------------------------------------
  if isGet:
    if req.hasParam("id"):
      return getOne(e, req.queryStr("id"))
    # The filter each collection is scoped by, matching proxy.lua's handlers.
    for f in ["convId", "workspaceId", "projectId", "folderId"]:
      if req.hasParam(f):
        return listEntity(e, f, req.queryStr(f))
    return listEntity(e, "", "")

  if req.meth == "POST":
    let node = parseBodyJson(req.body)
    if node.isNil: return err(400, "invalid JSON body")
    let r = upsert(e, node)
    # Action purpose: feeds the index from the surface every network client
    # writes through. Only on an assistant row, which indexes the reply and the
    # turn it answers together — the same rule the window applies, so the two
    # surfaces cannot build different indexes.
    if r.status == 200 and head == "messages" and node.f("role") == "assistant":
      indexing: discard rag.indexExchange(node.f "id")
    return r

  err(405, "method not allowed")
