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

import std/[json, strutils, tables]
import ./db
import ./http

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

## Function purpose: insert-or-replace from a JSON body. Missing fields become
## empty rather than failing, matching what `proxy.lua` accepted — the Web UI
## posts partial objects for several entities.
proc upsert(e: Entity, node: JsonNode): ApiResult =
  if node.kind != JObject or not node.hasKey("id"):
    return err(400, "body must be an object with an id")
  var placeholders: seq[string]
  var values: seq[string]
  for col in e.cols:
    placeholders.add "?"
    if node.hasKey(col.name) and node[col.name].kind != JNull:
      let v = node[col.name]
      values.add (if v.kind == JString: v.getStr else: $v)
    else:
      values.add ""
  db.exec("INSERT OR REPLACE INTO " & e.name & " (" & e.colList & ", is_deleted) VALUES (" &
          placeholders.join(", ") & ", 0)", values)
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
  ok("""{"status":"ok"}""")

proc softDelete(e: Entity, id: string, withForks = false): ApiResult =
  if e.name == "conversations":
    return deleteConversation(id, withForks)
  db.exec("UPDATE " & e.name & " SET is_deleted=1 WHERE id=?", id)
  if Cascades.hasKey(e.name):
    for sql in Cascades[e.name]:
      db.exec(sql, id)
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
          let r = upsert(Entities[name], item)
          if r.status != 200:
            db.rollback()
            return err(500, "import failed in " & name)
    db.commit()
  except CatchableError:
    db.rollback()
    return err(500, "import failed: " & getCurrentExceptionMsg())
  ok("""{"status":"ok"}""")

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
      return ok("""{"status":"ok"}""")
    of "update":
      let node = parseBodyJson(req.body)
      if node.isNil or not node.hasKey("id"):
        return err(400, "id required")
      # Partial update: only the columns present in the body are written.
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
      return ok("""{"status":"ok"}""")
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
    return upsert(e, node)

  err(405, "method not allowed")
