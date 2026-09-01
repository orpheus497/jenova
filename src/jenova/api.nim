## Script function and purpose: The `/api/db/*` routes the Web UI calls,
## replacing the database-routing half of `lib/proxy.lua` (`:687-1005`).
##
## The contract is reproduced from the existing implementation rather than
## designed afresh: `jca_web` is a shipped client that must keep working
## unchanged while it is deprecated (D-L), so route shapes, query parameters and
## response bodies match what `proxy.lua` answers today.
##
## The seven entity tables share one shape — a TEXT `id`, some columns, and an
## `is_deleted` flag — so they are described once as data and served by generic
## handlers. `proxy.lua` wrote each of the twenty routes by hand, which is why
## its cascade deletes drifted apart from one another.
##
## Deletes are soft throughout: rows are flagged, never removed, which is what
## makes the trash view and restore possible.

import std/[algorithm, json, strutils, tables, os]
import ./db
import ./http
import ./fssync
import ./rag

type
  Column = object
    name: string
    isInt: bool

  Entity = object
    name: string
    cols: seq[Column]

proc c(n: string): Column = Column(name: n, isInt: false)
proc i(n: string): Column = Column(name: n, isInt: true)

## Action purpose: integer columns are declared, not guessed. SQLite returns
## every value as text through this driver, and emitting a timestamp as "1730..."
## instead of 1730... would change the JSON type the Web UI receives and break
## date handling and sorting in a way that is tedious to trace back to here.
## It is `const`, not `let`, for a concrete reason: a `let` table of this shape is
## reference-counted memory read concurrently by every worker thread, which the
## compiler correctly rejects as not GC-safe. Compile-time data has no refcount
## to race on.
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

## Action purpose: cascade deletes are expressed as set-based UPDATEs rather than
## by fetching children and looping over them, which is what `proxy.lua` did.
## One statement per child table touches every descendant regardless of count.
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

type ApiResult* = object
  status*: int
  body*: string
  ## Empty means application/json, which every route but a storage download
  ## returns. Carried explicitly rather than inferred from the body: a stored
  ## file whose first byte is `[` would otherwise be mistaken for a JSON array.
  contentType*: string

proc ok(body: string): ApiResult = ApiResult(status: 200, body: body)
proc err(status: int, msg: string): ApiResult =
  ApiResult(status: status, body: $(%*{"error": msg}))

proc colList(e: Entity): string =
  var names: seq[string]
  for col in e.cols: names.add col.name
  names.join(", ")

## Function purpose: turn a result row into JSON with the declared column types.
proc rowToJson(e: Entity, row: seq[string]): JsonNode =
  result = newJObject()
  for idx, col in e.cols:
    if idx >= row.len: break
    if col.isInt:
      result[col.name] = %(try: parseBiggestInt(row[idx]) except ValueError: 0)
    else:
      result[col.name] = %row[idx]

proc rowsToJson(e: Entity, rows: seq[seq[string]]): JsonNode =
  result = newJArray()
  for r in rows:
    result.add rowToJson(e, r)

proc listEntity(e: Entity, filterCol, filterVal: string, deleted = false): ApiResult =
  let flag = if deleted: "1" else: "0"
  var sql = "SELECT " & e.colList & " FROM " & e.name & " WHERE is_deleted=" & flag
  if filterCol.len > 0 and filterVal.len > 0:
    sql.add " AND " & filterCol & "=?"
    return ok($rowsToJson(e, db.query(sql, filterVal)))
  ok($rowsToJson(e, db.query(sql)))

proc getOne(e: Entity, id: string): ApiResult =
  let rows = db.query("SELECT " & e.colList & " FROM " & e.name &
                      " WHERE id=? AND is_deleted=0", id)
  if rows.len == 0: err(404, "not found") else: ok($rowToJson(e, rows[0]))

## Function purpose: read one row as a name→value table, for the cases that need
## the *previous* state of a row before overwriting it — a note that moved has to
## have its old file trashed, and that old path can only be built from the old
## row.
proc rowFields(e: Entity, id: string): Table[string, string] =
  let rows = db.query("SELECT " & e.colList & " FROM " & e.name & " WHERE id=?", id)
  if rows.len == 0: return
  for idx, col in e.cols:
    if idx >= rows[0].len: break
    result[col.name] = rows[0][idx]

proc f(node: JsonNode, name: string): string =
  if node.hasKey(name) and node[name].kind != JNull:
    let v = node[name]
    (if v.kind == JString: v.getStr else: $v)
  else:
    ""

proc field(t: Table[string, string], name: string): string =
  if t.hasKey(name): t[name] else: ""

## Function purpose: mirror an upserted row onto disk, reproducing the ten
## `fs_sync` call sites in `lib/proxy.lua`'s `/api/db/*` handlers (N-27).
##
## Two behaviours here are easy to miss and both are load-bearing:
##
## * **A failed filesystem write rolls the database back.** `proxy.lua` deletes a
##   newly inserted row, or rewrites the previous one, and answers 500. Letting
##   the row stand while the file is missing is what produces a workspace the UI
##   lists and the disk does not have.
## * **A note or asset that moved has its old file trashed.** When `folderId`,
##   `projectId`, `workspaceId` or the title/name changes, the new path is
##   written first and the *old* path is then trashed — otherwise a rename leaves
##   the previous copy behind and the RAG index sees the file twice.
proc mirrorUpsert(e: Entity, node: JsonNode, prior: Table[string, string],
                  existed: bool): bool =
  case e.name
  of "workspaces":
    fssync.syncWorkspace(node.f "name",
                         (if existed: prior.field("name") else: ""))
  of "projects":
    # Action purpose: a project's directory is named after the project and sits
    # inside its workspace's, so both a rename and a move to another workspace
    # relocate it. Until this branch existed both fell through to `else: true`
    # and every note and asset under the project was stranded on disk (T-14).
    #
    # The name and parent are compared *before* calling, because resolving a
    # container's directory costs a database lookup per ancestor and the Web UI
    # re-posts whole rows: an upsert that changed neither must not pay for four
    # queries and two path builds to discover it has nothing to move. An insert
    # has nothing to move either — the directory appears when the first note or
    # asset is written into it, which `physicalPath` already handles.
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
    if okFs and existed and
       (prior.field("folderId") != node.f("folderId") or
        prior.field("projectId") != node.f("projectId") or
        prior.field("workspaceId") != node.f("workspaceId") or
        prior.field("name") != node.f("name")):
      discard fssync.trashFileAsset(prior.field("id"), prior.field("name"),
                                    prior.field("folderId"),
                                    prior.field("projectId"),
                                    prior.field("workspaceId"))
    okFs
  else:
    true

proc writeRow(e: Entity, node: JsonNode) =
  var placeholders: seq[string]
  var values: seq[string]
  for col in e.cols:
    placeholders.add "?"
    values.add node.f(col.name)
  db.exec("INSERT OR REPLACE INTO " & e.name & " (" & e.colList & ", is_deleted) VALUES (" &
          placeholders.join(", ") & ", 0)", values)

## Function purpose: insert-or-replace from a JSON body. Missing fields become
## empty rather than failing, matching what `proxy.lua` accepted — the Web UI
## posts partial objects for several entities.
##
## `mirror` is false for bulk import, which is the one path in the original that
## writes rows without touching the filesystem (`db.import_data`).
proc upsert(e: Entity, node: JsonNode, mirror = true): ApiResult =
  if node.kind != JObject or not node.hasKey("id"):
    return err(400, "body must be an object with an id")
  let id = node.f "id"
  let prior = if mirror: rowFields(e, id) else: initTable[string, string]()
  let existed = prior.len > 0

  # Action purpose: `is_deleted` is not one of `e.cols`, so `rowFields` cannot
  # carry it and `writeRow` always writes 0. Captured here, before the row is
  # overwritten, so a rollback restores the flag the row actually had — otherwise
  # a failed upsert against a soft-deleted row silently resurrects it.
  var priorDeleted = "0"
  if mirror and existed:
    let flagRows = db.query("SELECT is_deleted FROM " & e.name & " WHERE id=?", id)
    if flagRows.len > 0 and flagRows[0].len > 0 and flagRows[0][0].len > 0:
      priorDeleted = flagRows[0][0]

  writeRow(e, node)

  if mirror and not mirrorUpsert(e, node, prior, existed):
    # Restore the previous state rather than leaving a row with no file.
    if existed:
      var restoreNode = newJObject()
      for col in e.cols:
        restoreNode[col.name] = %prior.field(col.name)
      writeRow(e, restoreNode)
      db.exec("UPDATE " & e.name & " SET is_deleted=? WHERE id=?", priorDeleted, id)
    else:
      db.exec("DELETE FROM " & e.name & " WHERE id=?", id)
    return err(500, "filesystem sync failed for " & e.name)

  ok("""{"status":"ok"}""")

const DescendantsCte = """
WITH RECURSIVE descendants AS (
    SELECT id FROM conversations WHERE id = ?
    UNION
    SELECT c.id FROM conversations c
    INNER JOIN descendants d ON c.forkedFromConversationId = d.id
)
"""

## Action purpose: conversation deletion has two distinct behaviours in the
## original (`db.delete_conversation`) and both matter for the fork tree.
##
## * **With forks:** a *recursive* descendant walk, so nested forks are removed
##   too. Matching only direct children — which an earlier revision of this file
##   did — silently orphans grandchildren.
## * **Without forks:** children are **reparented onto the deleted
##   conversation's own parent** before it is flagged, so the fork tree stays
##   connected instead of leaving children pointing at a deleted node.
proc deleteConversation(id: string, withForks: bool): ApiResult =
  # Action purpose: the conversations whose messages this call is about to flag,
  # collected **before** the transaction and forgotten from the retrieval index
  # **after** it commits (T-17). A conversation's messages are flagged in one
  # statement, so there is no per-row site to hook, and doing it inside the
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
  for c in affected: rag.forgetConversation(c)
  ok("""{"status":"ok"}""")

proc dbSoftDelete(e: Entity, id: string) =
  db.exec("UPDATE " & e.name & " SET is_deleted=1 WHERE id=?", id)
  if Cascades.hasKey(e.name):
    for sql in Cascades[e.name]:
      db.exec(sql, id)

## Action purpose: deletion mirrors to the trash tree, and **the order differs by
## entity because `proxy.lua`'s does** — this is reproduced, not tidied.
##
## * **Workspaces, projects, folders:** the filesystem move happens *first*. If it
##   fails, the row is left alone and the request 500s, so the database never
##   claims a deletion the disk did not perform. For projects and folders, if the
##   database step then fails, **the directory is moved back out of the trash** —
##   a compensating undo, and the only place in the contract that has one.
## * **Notes and file assets:** the row is flagged first and the file trashed
##   after, because the old path is rebuilt from the row that is still readable
##   (soft delete leaves it in place).
##
## Tidying these into one order would be a silent behaviour change to a contract
## the frozen client depends on (D-Z).
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
    dbSoftDelete(e, id)

  of "projects":
    let r = fssync.trashProject(id, prior.field "workspaceId", prior.field "name")
    if not r.ok:
      return err(500, "filesystem trash failed for project")
    try:
      dbSoftDelete(e, id)
    except CatchableError:
      if r.path.len > 0 and r.original.len > 0:
        try: moveDir(r.path, r.original)
        except OSError: discard
      return err(500, "delete failed: " & getCurrentExceptionMsg())

  of "folders":
    let r = fssync.trashFolder(id, prior.field "projectId", prior.field "name")
    if not r.ok:
      return err(500, "filesystem trash failed for folder")
    try:
      dbSoftDelete(e, id)
    except CatchableError:
      if r.path.len > 0 and r.original.len > 0:
        try: moveDir(r.path, r.original)
        except OSError: discard
      return err(500, "delete failed: " & getCurrentExceptionMsg())

  of "notes":
    dbSoftDelete(e, id)
    if prior.len > 0:
      discard fssync.trashNote(id, prior.field "title", prior.field "folderId",
                               prior.field "projectId", prior.field "workspaceId")

  of "fileAssets":
    dbSoftDelete(e, id)
    if prior.len > 0:
      discard fssync.trashFileAsset(id, prior.field "name",
                                    prior.field "folderId",
                                    prior.field "projectId",
                                    prior.field "workspaceId")

  else:
    dbSoftDelete(e, id)
    # Action purpose: a deleted turn must stop being recalled (T-17). Reachable
    # from both surfaces — the window's per-message delete goes through
    # `deleteEntity`, which is this proc — and safe on the GTK thread, because
    # forgetting a path is three DELETEs and never touches the embedding server.
    if e.name == "messages": rag.forgetMessage(id)

  ok("""{"status":"ok"}""")

## Action purpose: restoring cascades *upward* as well as down. Reviving a note
## whose folder, project or workspace is still flagged would leave it invisible
## in the UI — present in the table but inside a deleted container — so the
## original restores the ancestry first. The depth guard exists because this
## walks parent links read from data, and a cycle there would otherwise recurse
## without end.
proc restoreItem(entityName, id: string, depth = 0): ApiResult =
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
    case col.name
    of "folderId": discard restoreItem("folders", v, depth + 1)
    of "projectId": discard restoreItem("projects", v, depth + 1)
    of "workspaceId": discard restoreItem("workspaces", v, depth + 1)
    else: discard

  db.exec("UPDATE " & e.name & " SET is_deleted=0 WHERE id=?", id)
  if e.name == "conversations":
    # Faithful to db.restore_item: every message of the conversation is revived,
    # including any deleted individually beforehand. Recorded as N-21 — it is a
    # pre-existing behaviour of the shipped client's contract, not a new one.
    db.exec("UPDATE messages SET is_deleted=0 WHERE convId=?", id)
  ok("""{"status":"ok"}""")

proc restore(e: Entity, id: string): ApiResult = restoreItem(e.name, id)

proc parseBodyJson(body: string): JsonNode =
  try: parseJson(body) except CatchableError: nil

## Function purpose: write only the message columns the caller actually supplied.
## `writeRow` is INSERT OR REPLACE over every column, so upserting a message to
## change its text alone would blank its `convId`, `role` and `timestamp` — which
## is why editing a message needs this and not `putEntity`.
##
## It is a proc rather than inline in the route because the GUI's edit action
## needs exactly this behaviour, and a second copy in `gui.nim` would be two
## definitions of one contract. `POST /api/db/messages/update` and the window now
## call the same code.
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

## Function purpose: the GUI's entry point to the partial message update above,
## shaped like `putEntity`/`deleteEntity` so the window keeps going through this
## module rather than writing message SQL of its own.
proc patchMessage*(node: JsonNode): bool =
  updateMessage(node).status == 200

# ---------------------------------------------------------------------------
# The message tree (G-29)
# ---------------------------------------------------------------------------
#
# A conversation is a tree, not a list. Editing a turn or regenerating a reply
# produces an *alternative version* of it — a sibling — and what the reader sees
# is one path from the root down to whichever leaf they last landed on. The
# `messages.parent` column has always existed to hold this and nothing wrote it.
#
# These three are **pure functions over (id, parent) pairs**, deliberately. They
# are the part of branching most likely to be silently wrong — an off-by-one in a
# sibling counter looks fine and misleads — and pure functions over data can be
# asserted against a known fork shape without a database or a window, which is
# what `jenova-core tree-selftest` does. The window calls them over the messages
# it already holds, so this costs it no extra queries.

type MsgEdge* = tuple[id, parent: string]

## Function purpose: the chain from the conversation root down to `leaf`, oldest
## first — the conversation as it is currently being read.
##
## The depth guard is not defensive padding: `parent` is data, a row can be
## edited through the API, and a cycle would otherwise hang the window rather
## than draw a wrong transcript. `restoreItem` guards its parent walk for the
## same reason.
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
## what a "2 of 3" counter counts and what prev/next steps through.
##
## A message is its own sibling, so a turn that was never branched returns a list
## of one. That is what lets the caller ask for siblings unconditionally and show
## the control only when there is more than one.
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
## deepest message under `id`, always following the newest branch.
##
## "Newest" is last in `edges`, which the caller supplies in timestamp order, so
## switching to an older version of a turn shows the reply that was made *for
## that version* rather than stranding the reader at the switch point.
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

## Function purpose: bulk import, reproducing `db.import_data`. Wrapped in a
## transaction so a partial dump cannot leave the database half-populated —
## the original rolled back on any failure and so does this.
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
          # mirror = false: `db.import_data` writes rows only. A bulk import of
          # thousands of notes must not run a git add per row, and the files are
          # expected to arrive with the dump.
          let r = upsert(Entities[name], item, mirror = false)
          if r.status != 200:
            db.rollback()
            return err(500, "import failed in " & name)
    db.commit()
  except CatchableError:
    db.rollback()
    return err(500, "import failed: " & getCurrentExceptionMsg())
  ok("""{"status":"ok"}""")

## Function purpose: route one `/api/fs/*` request — the last surface `lib/proxy.lua`
## still served (N-20). Four routes, reproduced from `proxy.lua:647-672`.
## Entity writes for in-process callers (the GUI sidebar). Goes through the same
## upsert/softDelete the HTTP routes use, so cascades and the filesystem mirror
## apply identically whichever surface the user is on.
proc putEntity*(entity: string, node: JsonNode): bool =
  entity in Entities and upsert(Entities[entity], node).status == 200

proc deleteEntity*(entity, id: string): bool =
  entity in Entities and softDelete(Entities[entity], id).status == 200

## Function purpose: every live row, in the shape `importData` reads (G-32).
## Exported for the desktop application's Export button, which must not build a
## dump of its own: a hand-rolled writer and this reader would drift, and the
## column list is already declared once in `Entities`.
proc exportAll*(): JsonNode =
  const order = ["conversations", "messages", "workspaces", "projects",
                 "folders", "notes", "fileAssets"]
  result = newJObject()
  for name in order:
    let e = Entities[name]
    result[name] = rowsToJson(e, db.query(
      "SELECT " & e.colList & " FROM " & e.name & " WHERE is_deleted=0"))

## Function purpose: the import behind the desktop application's Import button,
## over the same transactional `importData` the HTTP route uses (G-32).
##
## Action purpose: **two input shapes are accepted, because there are two
## writers.** This build exports the keyed object `importData` consumes; the
## frozen Web UI (D-Z) exports `[{conv, messages}, …]`, one entry per
## conversation. Converting the second here rather than adding a route keeps one
## transactional implementation and makes a file from either surface readable by
## the other.
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

## Function purpose: route one `/api/storage/*` request — raw file access under
## the workspaces root, reproducing `lib/proxy.lua:1009,1041,1068,1126`.
##
## This is the one surface that takes a client-supplied path and reads, writes
## and deletes with it, so containment is the whole risk. Every path goes through
## `fssync.resolveStoragePath`, which refuses on a literal `..`, on lexical
## escape, on a directory-boundary mismatch, and on a symlinked component
## pointing out of the tree. **A refusal is a 403, never a 404** — a 404 would
## tell a caller whether a path outside the root exists.
##
## `storage.service.ts` in the frozen Web UI calls all four verbs (D-Z), so the
## response shapes are matched rather than improved.
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
    db.exec("INSERT OR REPLACE INTO llm_cache (cache_key, response, timestamp) " &
            "VALUES (?, ?, strftime('%s','now'))",
            node["key"].getStr, node["response"].getStr)
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
      # After the commit, for the reason `deleteConversation` does it after its
      # own: a rolled-back delete must not leave the index stripped (T-17).
      for idNode in node["ids"]: rag.forgetMessage(idNode.getStr)
      return ok("""{"status":"ok"}""")
    of "update":
      # Action purpose: an edited message whose index entry still holds the old
      # text is recalled by its old words and quoted back with its new ones.
      # Re-indexed here, on the route, and **not inside `updateMessage`** —
      # `patchMessage` shares that proc and is called by the window on the GTK
      # thread, where an embedding round trip would freeze the transcript. The
      # window feeds the index from its own control worker instead (T-17).
      #
      # No parent: the turn this one answers has not changed.
      let node = parseBodyJson(req.body)
      let r = updateMessage(node)
      if r.status == 200 and not node.isNil and node.hasKey("content"):
        discard rag.indexExchange(node.f "id", withParent = false)
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
    # Action purpose: feed the retrieval index from the surface the Web UI and
    # any LAN client write through (T-17). **Only on an assistant row**, which
    # indexes the reply and the turn it answers together — see
    # `rag.indexExchange` for why a user turn is not indexed the moment it
    # arrives. This is the same rule the window applies, so the two surfaces
    # cannot build different indexes.
    if r.status == 200 and head == "messages" and node.f("role") == "assistant":
      discard rag.indexExchange(node.f "id")
    return r

  err(405, "method not allowed")
