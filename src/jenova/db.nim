## Script function and purpose: SQLite persistence for the Nim core, replacing
## `lib/db.lua`. Binds libsqlite3 directly, as `db.lua` did via
## `ffi.load("sqlite3")`, so no new package dependency is introduced.
##
## The concurrency model is the point of this module, not an afterthought.
## `lib/proxy.lua` ran every database call on a single-threaded `ffi.C.select`
## event loop, so one slow query stalled token streaming for every client — the
## "desync and lagging" the refactor analysis diagnoses. SQLite was never the
## bottleneck: `db.lua:65-68` already enabled WAL and a busy timeout. The caller
## was.
##
## Therefore:
##
## * **One connection per thread**, held in a threadvar. There is no shared
##   handle and no global lock, so two threads never queue behind each other in
##   this layer.
## * **WAL journalling**, which lets readers proceed during a write and the
##   writer proceed during reads. Carried over from `db.lua`.
## * **Per-connection prepared-statement cache**, so a hot query is prepared
##   once rather than prepared and finalized on every call (TODOS.md B-18).
## * **`SQLITE_OPEN_NOMUTEX`**, valid precisely because a connection is never
##   shared between threads. Serialized mode would add a per-call mutex we do
##   not need.
##
## Nothing here may be called from an async event loop directly: these calls
## block the calling thread. They belong on worker threads (stage N-S3).

import std/[os, tables]

type
  DbHandle* = pointer
  StmtHandle* = pointer

  DbError* = object of CatchableError

  ## Action purpose: `Conn` is deliberately NOT exported (TODOS.md N-14).
  ## `SQLITE_OPEN_NOMUTEX` is only sound while a handle never leaves the thread
  ## that opened it. Exporting the type would let a caller hold one and hand it
  ## to another thread, turning that soundness argument into a data race. Since
  ## no code outside this module can name the type, the invariant is enforced by
  ## the compiler rather than by discipline. Callers use exec/query, which reach
  ## the thread's own connection internally.
  Conn = ref object
    h: DbHandle
    path: string
    cache: Table[string, StmtHandle]

  Row* = seq[string]

const
  ## T-2. The ceiling on one connection's prepared-statement cache. Comfortably
  ## above the fixed statement set the program actually issues, so the flush in
  ## `prepared` fires only on the combinatorial key space `api.updateMessage`
  ## produces — which is the leak, not the cache.
  MaxCachedStatements* = 256

  SQLITE_OK = 0
  SQLITE_ROW = 100
  SQLITE_DONE = 101

  SQLITE_OPEN_READWRITE = 0x00000002
  SQLITE_OPEN_CREATE = 0x00000004
  SQLITE_OPEN_NOMUTEX = 0x00008000

  SqliteLib = "libsqlite3.so(|.0|.3)"

{.push importc, cdecl, dynlib: SqliteLib.}
proc sqlite3_open_v2(filename: cstring, ppDb: ptr DbHandle, flags: cint,
                     zVfs: cstring): cint
proc sqlite3_close_v2(db: DbHandle): cint
proc sqlite3_exec(db: DbHandle, sql: cstring, cb: pointer, arg: pointer,
                  errmsg: ptr cstring): cint
proc sqlite3_errmsg(db: DbHandle): cstring
proc sqlite3_free(p: pointer)
proc sqlite3_threadsafe(): cint
proc sqlite3_prepare_v2(db: DbHandle, sql: cstring, nByte: cint,
                        ppStmt: ptr StmtHandle, pzTail: ptr cstring): cint
proc sqlite3_step(s: StmtHandle): cint
proc sqlite3_reset(s: StmtHandle): cint
proc sqlite3_clear_bindings(s: StmtHandle): cint
proc sqlite3_finalize(s: StmtHandle): cint
proc sqlite3_bind_text(s: StmtHandle, idx: cint, value: cstring, n: cint,
                       destructor: pointer): cint
proc sqlite3_bind_null(s: StmtHandle, idx: cint): cint
proc sqlite3_bind_blob(s: StmtHandle, idx: cint, value: pointer, n: cint,
                       destructor: pointer): cint
proc sqlite3_column_blob(s: StmtHandle, col: cint): pointer
proc sqlite3_column_bytes(s: StmtHandle, col: cint): cint
proc sqlite3_column_count(s: StmtHandle): cint
proc sqlite3_column_text(s: StmtHandle, col: cint): ptr uint8
proc sqlite3_column_name(s: StmtHandle, col: cint): cstring
{.pop.}

# SQLITE_TRANSIENT tells SQLite to copy the bound string, which it must: the Nim
# string backing it may be collected before the statement runs.
let SQLITE_TRANSIENT = cast[pointer](-1)

## Action purpose: the connection is a threadvar, which is what makes this layer
## safe to call from any worker thread without a lock. Each thread opens its own
## handle on first use and keeps it for the thread's lifetime.
var tlsConn {.threadvar.}: Conn
var dbPath {.threadvar.}: string

# Action purpose: the shared database path is held as a raw character buffer, not
# as a `string`. A shared `string` global would be reference-counted memory read
# concurrently by every worker thread, which is a data race in itself — exactly
# the class of bug this module is meant to avoid. The buffer is written once by
# initDb() before any thread starts and is read-only thereafter.
var globalDbPathBuf: array[4096, char]
var globalDbPathLen: int

proc setGlobalPath(p: string) =
  let n = min(p.len, globalDbPathBuf.high)
  if n > 0:
    copyMem(addr globalDbPathBuf[0], p.cstring, n)
  globalDbPathLen = n

proc getGlobalPath(): string =
  result = newString(globalDbPathLen)
  if globalDbPathLen > 0:
    copyMem(addr result[0], addr globalDbPathBuf[0], globalDbPathLen)

proc check(c: Conn, rc: cint, ctx: string) =
  if rc != SQLITE_OK:
    raise newException(DbError, ctx & ": " & $sqlite3_errmsg(c.h) &
                       " (code " & $rc & ")")

## Function purpose: apply the pragmas that make concurrent access work. WAL is
## the load-bearing one — without it a writer blocks every reader, which would
## reintroduce the serialization this module exists to avoid.
proc applyPragmas(c: Conn) =
  const pragmas = [
    "PRAGMA journal_mode=WAL;",
    "PRAGMA synchronous=NORMAL;",
    "PRAGMA busy_timeout=5000;",
    "PRAGMA cache_size=-8000;",
    "PRAGMA mmap_size=67108864;",
  ]
  for p in pragmas:
    # journal_mode returns a row; sqlite3_exec tolerates that.
    discard sqlite3_exec(c.h, p.cstring, nil, nil, nil)

proc openConn(path: string): Conn =
  ## NOMUTEX is safe only because this handle never leaves the thread that
  ## opened it. If that invariant is ever broken, this flag becomes a data race.
  var h: DbHandle
  let flags = (SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or
               SQLITE_OPEN_NOMUTEX).cint
  let rc = sqlite3_open_v2(path.cstring, addr h, flags, nil)
  if rc != SQLITE_OK:
    raise newException(DbError, "cannot open database " & path &
                       " (code " & $rc & ")")
  result = Conn(h: h, path: path, cache: initTable[string, StmtHandle]())
  result.applyPragmas()

## Function purpose: the accessor every query goes through. Opens this thread's
## connection on first use, so callers never manage handles or pass them around.
proc conn(): Conn =
  if tlsConn == nil:
    if dbPath.len == 0:
      dbPath = getGlobalPath()
    if dbPath.len == 0:
      raise newException(DbError, "database path not set; call initDb() first")
    tlsConn = openConn(dbPath)
  tlsConn

## Function purpose: prepare a statement once per connection and reuse it.
## `db.lua`'s execute_query prepared and finalized on every single call (B-18);
## caching removes that cost without sharing anything across threads, because
## the cache lives on the thread's own connection.
proc prepared(c: Conn, sql: string): StmtHandle =
  if c.cache.hasKey(sql):
    result = c.cache[sql]
    discard sqlite3_reset(result)
    discard sqlite3_clear_bindings(result)
  else:
    # Action purpose: **T-2 — the cache had no bound and a long-running server
    # leaked.** It is keyed by SQL text, and `api.updateMessage` builds a
    # different text for every combination of fields a client sends, so the key
    # space is combinatorial rather than fixed and a `serve` process grew a
    # prepared statement per distinct shape, for ever. The only
    # `sqlite3_finalize` was the shutdown loop in `closeConn`.
    #
    # **Flush-all rather than LRU, and that is a deliberate trade.** An LRU needs
    # a recency order maintained on every hit — the hot path — to bound something
    # that is not otherwise a problem: the real working set is a few dozen fixed
    # statements and never reaches the cap, so the flush fires only on the
    # combinatorial path it exists for, and re-preparing a few dozen statements
    # once is far cheaper than the ordering bookkeeping would be on every query.
    #
    # **Before the new statement is prepared, never after** — flushing afterwards
    # would finalize the handle about to be returned. Nothing else holds one
    # across this call: `query` materialises its rows and resets before
    # returning, and `exec` steps once and resets, so no live cursor spans a
    # `prepared` call and the flush cannot pull a handle out from under one.
    if c.cache.len >= MaxCachedStatements:
      for _, s in c.cache:
        discard sqlite3_finalize(s)
      c.cache.clear()
    var s: StmtHandle
    let rc = sqlite3_prepare_v2(c.h, sql.cstring, -1, addr s, nil)
    c.check(rc, "prepare failed for: " & sql)
    c.cache[sql] = s
    result = s

proc bindParams(s: StmtHandle, params: openArray[string]) =
  for i, p in params:
    discard sqlite3_bind_text(s, (i + 1).cint, p.cstring, p.len.cint,
                              SQLITE_TRANSIENT)

## Function purpose: write a row whose last column is binary, for the RAG
## vector store (Q-24 puts embeddings in a BLOB). Text binding would corrupt an
## embedding the moment a float's byte pattern contained a NUL — which for
## normalised float32 vectors is not an edge case but the common case, so this
## is a correctness requirement rather than an optimisation.
## `blobIndex` is the 1-based position of the binary parameter in the statement.
## It defaults to last, which suits an INSERT, but an UPDATE needs `SET vec=?`
## first with the WHERE predicates after it — so the position is a parameter
## rather than an assumption. Getting this wrong binds a blob where a path
## belongs and fails at runtime, not at compile time.
proc execBlob*(sql: string, textParams: openArray[string], blob: string,
               blobIndex = 0) =
  let c = conn()
  let s = c.prepared(sql)
  let bIdx = if blobIndex > 0: blobIndex else: textParams.len + 1
  var textPos = 1
  for p in textParams:
    if textPos == bIdx: inc textPos
    discard sqlite3_bind_text(s, textPos.cint, p.cstring, p.len.cint,
                              SQLITE_TRANSIENT)
    inc textPos
  if blob.len == 0:
    discard sqlite3_bind_null(s, bIdx.cint)
  else:
    discard sqlite3_bind_blob(s, bIdx.cint, unsafeAddr blob[0], blob.len.cint,
                              SQLITE_TRANSIENT)
  let rc = sqlite3_step(s)
  if rc != SQLITE_DONE and rc != SQLITE_ROW:
    raise newException(DbError, "execBlob failed: " & $sqlite3_errmsg(c.h) &
                       " [" & sql & "]")
  discard sqlite3_reset(s)

## Function purpose: read rows whose final column is binary. Every other column
## comes back as text exactly as `query` returns it; only the last is raw bytes.
proc queryBlob*(sql: string, params: varargs[string]):
    seq[tuple[cols: seq[string], blob: string]] =
  let c = conn()
  let s = c.prepared(sql)
  for i, p in params:
    discard sqlite3_bind_text(s, (i + 1).cint, p.cstring, p.len.cint,
                              SQLITE_TRANSIENT)
  let nCols = sqlite3_column_count(s)
  while true:
    let rc = sqlite3_step(s)
    if rc != SQLITE_ROW: break
    var cols: seq[string]
    for i in 0 ..< nCols - 1:
      let t = sqlite3_column_text(s, i.cint)
      cols.add (if t.isNil: "" else: $cast[cstring](t))
    var blob = ""
    let n = sqlite3_column_bytes(s, nCols - 1)
    if n > 0:
      let p = sqlite3_column_blob(s, nCols - 1)
      if not p.isNil:
        blob = newString(n)
        copyMem(addr blob[0], p, n)
    result.add (cols, blob)
  discard sqlite3_reset(s)

## Function purpose: run a statement that returns no rows.
proc exec*(sql: string, params: varargs[string]) =
  let c = conn()
  let s = c.prepared(sql)
  bindParams(s, params)
  let rc = sqlite3_step(s)
  if rc != SQLITE_DONE and rc != SQLITE_ROW:
    raise newException(DbError, "exec failed: " & $sqlite3_errmsg(c.h) &
                       " [" & sql & "]")
  discard sqlite3_reset(s)

## Function purpose: run raw multi-statement SQL (schema and migrations only).
## Prepared statements handle one statement at a time, so this path exists for
## the cases that legitimately need several.
proc execScript*(sql: string) =
  let c = conn()
  var err: cstring
  let rc = sqlite3_exec(c.h, sql.cstring, nil, nil, addr err)
  if rc != SQLITE_OK:
    let msg = if err.isNil: "unknown error" else: $err
    if not err.isNil: sqlite3_free(err)
    raise newException(DbError, "script failed: " & msg)

## Function purpose: run a query and collect its rows. Callers that expect large
## result sets must page with LIMIT/OFFSET — `db.lua`'s get_all_messages did an
## unbounded SELECT * (B-18) and this layer does not restore that.
proc query*(sql: string, params: varargs[string]): seq[Row] =
  let c = conn()
  let s = c.prepared(sql)
  bindParams(s, params)
  let cols = sqlite3_column_count(s)
  while true:
    let rc = sqlite3_step(s)
    if rc == SQLITE_ROW:
      var row: Row = newSeq[string](cols)
      for i in 0 ..< cols:
        let t = sqlite3_column_text(s, i.cint)
        row[i] = if t.isNil: "" else: $cast[cstring](t)
      result.add row
    elif rc == SQLITE_DONE:
      break
    else:
      raise newException(DbError, "query failed: " & $sqlite3_errmsg(c.h) &
                         " [" & sql & "]")
  discard sqlite3_reset(s)

proc columnNames*(sql: string): seq[string] =
  let s = conn().prepared(sql)
  for i in 0 ..< sqlite3_column_count(s):
    result.add $sqlite3_column_name(s, i.cint)

const Schema* = """
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY, name TEXT, lastModified INTEGER, currNode TEXT,
    folderId TEXT, projectId TEXT, workspaceId TEXT,
    forkedFromConversationId TEXT, mcpServerOverrides TEXT,
    is_deleted INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY, convId TEXT, type TEXT, role TEXT, timestamp INTEGER,
    parent TEXT, children TEXT, content TEXT, thinking TEXT, toolCalls TEXT,
    extra TEXT, model TEXT, timings TEXT, is_deleted INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_messages_convId ON messages(convId);
CREATE TABLE IF NOT EXISTS workspaces (
    id TEXT PRIMARY KEY, name TEXT, is_deleted INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY, workspaceId TEXT, name TEXT, is_deleted INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS folders (
    id TEXT PRIMARY KEY, projectId TEXT, name TEXT, is_deleted INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY, folderId TEXT, projectId TEXT, workspaceId TEXT,
    title TEXT, content TEXT, updatedAt INTEGER, isFocusNote INTEGER DEFAULT 0,
    is_deleted INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS fileAssets (
    id TEXT PRIMARY KEY, folderId TEXT, projectId TEXT, workspaceId TEXT,
    name TEXT, size INTEGER, type TEXT, uploadDate INTEGER, content TEXT,
    is_deleted INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_projects_workspaceId ON projects(workspaceId);
CREATE INDEX IF NOT EXISTS idx_folders_projectId ON folders(projectId);
CREATE INDEX IF NOT EXISTS idx_notes_folderId ON notes(folderId);
CREATE INDEX IF NOT EXISTS idx_fileAssets_folderId ON fileAssets(folderId);
CREATE TABLE IF NOT EXISTS llm_cache (
    cache_key TEXT PRIMARY KEY, response TEXT, timestamp INTEGER
);
"""

## Function purpose: establish the database path and schema. Must be called on
## the main thread before any worker thread touches the database; workers then
## open their own connections lazily against this path.
##
## Refuses to run against a single-threaded SQLite build rather than discovering
## it later as corruption — the whole design assumes concurrent connections.
## Function purpose: give every message a parent, once (G-29).
##
## **A tree in which every node is a root is not a tree.** Messages written before
## conversation branching existed never had `parent` bound, so it is NULL on all of
## them — and the branching code reads that as "these are all alternative versions of
## one another": the transcript collapses to a single message and the rest of the
## conversation is reachable only through the version arrows. That is what shipped, and
## it is what this repairs.
##
## Each conversation's messages are chained in the order they were written, which is the
## conversation as it actually happened. **Only rows whose `parent` is NULL are touched**,
## so this is idempotent and cannot disturb a row that branching has already parented — a
## genuine first turn carries an empty string, not NULL, and stays a root.
##
## Soft-deleted rows are skipped so the chain matches what the transcript shows. One
## restored later comes back as its own root; that is the trash view's problem (G-21) and
## it is better than a hole in the middle of a live conversation.
proc migrateMessageParents*() =
  let convs = query(
    "SELECT DISTINCT convId FROM messages WHERE parent IS NULL AND is_deleted=0")
  for c in convs:
    if c.len == 0 or c[0].len == 0: continue
    var prev = ""
    for r in query("SELECT id FROM messages WHERE convId=? AND is_deleted=0 " &
                   "ORDER BY timestamp ASC, rowid ASC", c[0]):
      if r.len == 0: continue
      exec("UPDATE messages SET parent=? WHERE id=? AND parent IS NULL", prev, r[0])
      prev = r[0]

proc initDb*(path: string) =
  if sqlite3_threadsafe() == 0:
    raise newException(DbError,
      "libsqlite3 was built without thread support (SQLITE_THREADSAFE=0); " &
      "the Nim core requires a threadsafe build")
  createDir(path.parentDir)
  setGlobalPath(path)
  dbPath = path
  execScript(Schema)
  # After the schema, because it reads the table the schema creates. Both binaries
  # open the database through here, so neither can see an unmigrated tree.
  migrateMessageParents()

## Action purpose: transaction control goes through execScript rather than the
## prepared-statement cache. BEGIN/COMMIT/ROLLBACK are connection state, not
## reusable queries, and caching them would keep a finished transaction's
## statement alive on the connection.
proc begin*() = execScript("BEGIN;")
proc commit*() = execScript("COMMIT;")
proc rollback*() =
  try: execScript("ROLLBACK;")
  except DbError: discard   # already rolled back, or no transaction open

## Function purpose: report whether this libsqlite3 has the FTS5 extension.
## Ruling Q-24 puts the BM25 keyword index in FTS5, and that choice is
## **contingent on the extension actually being present in the linked library**
## — which cannot be assumed from the Linux side of this container (D-AB), so it
## is compiled and asked. The RAG layer falls back to an in-memory keyword index
## when this returns false, rather than failing to start.
proc hasFts5*(): bool =
  try:
    execScript("CREATE VIRTUAL TABLE IF NOT EXISTS _fts5_probe USING fts5(x);")
    execScript("DROP TABLE IF EXISTS _fts5_probe;")
    true
  except DbError:
    false

proc threadsafeMode*(): int = sqlite3_threadsafe().int

proc journalMode*(): string =
  let rows = query("PRAGMA journal_mode;")
  if rows.len > 0 and rows[0].len > 0: rows[0][0] else: "unknown"

## Function purpose: expose this thread's connection address so the self-test can
## show that threads genuinely hold distinct handles rather than sharing one.
proc connAddr*(): uint = cast[uint](conn().h)

## Function purpose: how many statements this thread's connection is holding.
## Exported for the T-2 assertion and for nothing else — the bound is the whole
## fix, and a bound nothing can observe is a claim rather than a property.
proc cachedStatements*(): int = conn().cache.len

proc closeConn*() =
  if tlsConn != nil:
    for _, s in tlsConn.cache:
      discard sqlite3_finalize(s)
    tlsConn.cache.clear()
    discard sqlite3_close_v2(tlsConn.h)
    tlsConn = nil
