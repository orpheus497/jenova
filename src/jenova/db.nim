## Script function and purpose: SQLite persistence, bound to libsqlite3 directly
## so no package dependency is added. The concurrency model is the point of the
## module rather than a detail of it, and the four choices below hold each other
## up:
##
## * One connection per thread in a threadvar — no shared handle, no global
##   lock, so two threads never queue behind each other here.
## * WAL journalling, so readers proceed during a write and the writer during
##   reads.
## * A prepared-statement cache per connection, so a hot query is prepared once
##   instead of prepared and finalized on every call.
## * `SQLITE_OPEN_NOMUTEX`, sound only because a connection never leaves its
##   thread; serialized mode would add a per-call mutex for nothing.
##
## Every call here blocks the calling thread, so none belongs on an event loop.

import std/[os, tables]

type
  DbHandle* = pointer
  StmtHandle* = pointer

  DbError* = object of CatchableError

  ## Action purpose: deliberately not exported. `SQLITE_OPEN_NOMUTEX` is sound
  ## only while a handle never leaves the thread that opened it, and an exported
  ## type would let a caller hold one and pass it to another thread. Unnameable
  ## outside this module, the invariant is the compiler's rather than a habit.
  Conn = ref object
    h: DbHandle
    path: string
    cache: Table[string, StmtHandle]

  Row* = seq[string]

const
  ## The ceiling on one connection's statement cache. Comfortably above the
  ## fixed set of statements the program issues, so the flush in `prepared` fires
  ## only on the combinatorial key space `api.updateMessage` produces — which is
  ## the growth this bound exists for.
  MaxCachedStatements* = 256

  SQLITE_OK = 0
  SQLITE_ROW = 100
  SQLITE_DONE = 101

  SQLITE_OPEN_READWRITE = 0x00000002
  SQLITE_OPEN_CREATE = 0x00000004
  SQLITE_OPEN_NOMUTEX = 0x00008000

  SqliteLib = "libsqlite3.so(|.0|.3)"

# Action purpose: loaded by name at runtime rather than linked, so the binary
# runs against whichever libsqlite3 the host has. Only the calls this layer
# makes are declared; the library's surface is far larger.
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

# Action purpose: tells SQLite to copy a bound string, which it must — the Nim
# string behind it may be collected before the statement is stepped.
let SQLITE_TRANSIENT = cast[pointer](-1)

## Action purpose: a threadvar is what makes this layer callable from any worker
## without a lock. Each thread opens its own handle on first use and holds it
## for the thread's lifetime.
var tlsConn {.threadvar.}: Conn
var dbPath {.threadvar.}: string

# Action purpose: a raw buffer rather than a `string`, because a shared string
# global is reference-counted memory read concurrently by every worker — a data
# race of exactly the kind this module exists to avoid. Written once by `initDb`
# before any thread starts, and read-only thereafter.
var globalDbPathBuf: array[4096, char]
var globalDbPathLen: int

## Function purpose: the one writer of that buffer, truncating rather than
## overflowing, because a path this long is a caller error and not a state to
## corrupt memory over.
proc setGlobalPath(p: string) =
  let n = min(p.len, globalDbPathBuf.high)
  if n > 0:
    copyMem(addr globalDbPathBuf[0], p.cstring, n)
  globalDbPathLen = n

## Function purpose: copies out so each thread gets its own string rather than a
## view onto shared memory.
proc getGlobalPath(): string =
  result = newString(globalDbPathLen)
  if globalDbPathLen > 0:
    copyMem(addr result[0], addr globalDbPathBuf[0], globalDbPathLen)

## Function purpose: pairs the return code with the connection's own error
## message, which is the only place SQLite says what actually went wrong.
proc check(c: Conn, rc: cint, ctx: string) =
  if rc != SQLITE_OK:
    raise newException(DbError, ctx & ": " & $sqlite3_errmsg(c.h) &
                       " (code " & $rc & ")")

## Function purpose: WAL is the load-bearing one — without it a writer blocks
## every reader, which reinstates the serialization this module exists to avoid.
## The rest are tuning and are safe to lose.
proc applyPragmas(c: Conn) =
  const pragmas = [
    "PRAGMA journal_mode=WAL;",
    "PRAGMA synchronous=NORMAL;",
    "PRAGMA busy_timeout=5000;",
    "PRAGMA cache_size=-8000;",
    "PRAGMA mmap_size=67108864;",
  ]
  for p in pragmas:
    # `journal_mode` answers with a row, which `sqlite3_exec` tolerates.
    discard sqlite3_exec(c.h, p.cstring, nil, nil, nil)

## Function purpose: the only place a handle is created, so the pragmas cannot
## be applied to some connections and not others. `NOMUTEX` is safe only while
## the handle never leaves this thread; if that is ever broken it is a race.
proc openConn(path: string): Conn =
  var h: DbHandle
  let flags = (SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or
               SQLITE_OPEN_NOMUTEX).cint
  let rc = sqlite3_open_v2(path.cstring, addr h, flags, nil)
  if rc != SQLITE_OK:
    raise newException(DbError, "cannot open database " & path &
                       " (code " & $rc & ")")
  result = Conn(h: h, path: path, cache: initTable[string, StmtHandle]())
  result.applyPragmas()

## Function purpose: every query goes through here, so no caller ever holds or
## passes a handle — which is what keeps the `NOMUTEX` invariant true.
proc conn(): Conn =
  if tlsConn == nil:
    if dbPath.len == 0:
      dbPath = getGlobalPath()
    if dbPath.len == 0:
      raise newException(DbError, "database path not set; call initDb() first")
    tlsConn = openConn(dbPath)
  tlsConn

## Function purpose: prepares once per connection and reuses, which costs
## nothing in safety because the cache lives on the thread's own connection.
proc prepared(c: Conn, sql: string): StmtHandle =
  if c.cache.hasKey(sql):
    result = c.cache[sql]
    discard sqlite3_reset(result)
    discard sqlite3_clear_bindings(result)
  else:
    # Action purpose: the cache is keyed by SQL text and `api.updateMessage`
    # builds a different text per combination of fields a client sends, so the
    # key space is combinatorial and an unbounded cache grows for the life of the
    # process.
    #
    # Flush-all rather than LRU, deliberately: an LRU maintains a recency order
    # on every hit — the hot path — to bound something that is not otherwise a
    # problem, since the real working set is a few dozen fixed statements that
    # never reach the cap. Re-preparing those once costs less than the ordering
    # bookkeeping would on every query.
    #
    # Before the new statement is prepared, never after: flushing afterwards
    # would finalize the handle about to be returned. Nothing holds a handle
    # across this call — `query` materialises its rows and resets, `exec` steps
    # once and resets — so no live cursor can be pulled out from under.
    if c.cache.len >= MaxCachedStatements:
      for _, s in c.cache:
        discard sqlite3_finalize(s)
      c.cache.clear()
    var s: StmtHandle
    let rc = sqlite3_prepare_v2(c.h, sql.cstring, -1, addr s, nil)
    c.check(rc, "prepare failed for: " & sql)
    c.cache[sql] = s
    result = s

## Function purpose: one place binds text parameters, so the transient flag and
## the 1-based indexing cannot be got right in some callers and wrong in others.
proc bindParams(s: StmtHandle, params: openArray[string]) =
  for i, p in params:
    discard sqlite3_bind_text(s, (i + 1).cint, p.cstring, p.len.cint,
                              SQLITE_TRANSIENT)

## Function purpose: a binary parameter needs its own binding call. Binding an
## embedding as text corrupts it the moment a float's bytes contain a NUL, which
## for normalised float32 vectors is the common case rather than an edge one.
##
## Action purpose: `blobIndex` is the 1-based position of that parameter and
## defaults to last, which suits an INSERT. An UPDATE needs `SET vec=?` first
## with the predicates after, so the position is a parameter rather than an
## assumption — getting it wrong fails at runtime, not at compile time.
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

## Function purpose: the read half of the same rule. Only the final column comes
## back as raw bytes; every other is text exactly as `query` returns it.
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

## Function purpose: the ordinary write path. A statement that unexpectedly
## returns a row is accepted rather than refused, because `INSERT … RETURNING`
## is still a write.
proc exec*(sql: string, params: varargs[string]) =
  let c = conn()
  let s = c.prepared(sql)
  bindParams(s, params)
  let rc = sqlite3_step(s)
  if rc != SQLITE_DONE and rc != SQLITE_ROW:
    raise newException(DbError, "exec failed: " & $sqlite3_errmsg(c.h) &
                       " [" & sql & "]")
  discard sqlite3_reset(s)

## Function purpose: prepared statements handle one statement at a time, so
## schema and migrations need this path. It takes no parameters, which is what
## keeps it away from anything carrying user input.
proc execScript*(sql: string) =
  let c = conn()
  var err: cstring
  let rc = sqlite3_exec(c.h, sql.cstring, nil, nil, addr err)
  if rc != SQLITE_OK:
    let msg = if err.isNil: "unknown error" else: $err
    if not err.isNil: sqlite3_free(err)
    raise newException(DbError, "script failed: " & msg)

## Function purpose: materialises every row before returning, so no cursor stays
## open across a caller's work. A caller expecting a large result set must page
## with LIMIT and OFFSET; this layer will not do it for them.
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

## Function purpose: a tree in which every node is a root is not a tree. Rows
## written before branching existed have a NULL `parent`, which the branching
## code reads as "all alternative versions of one another" — collapsing the
## transcript to one message with the rest reachable only through the version
## arrows. This chains each conversation in the order it was written.
##
## Action purpose: only NULL parents are touched, so it is idempotent and cannot
## disturb a row branching has already parented; a genuine first turn carries an
## empty string rather than NULL and stays a root. Soft-deleted rows are skipped
## so the chain matches the transcript — one restored later returns as its own
## root, which is better than a hole in the middle of a live conversation.
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

## Function purpose: must run on the main thread before any worker touches the
## database; workers then open their own connections lazily against this path.
## Refuses a single-threaded SQLite build outright rather than letting the whole
## design's assumption surface later as corruption.
proc initDb*(path: string) =
  if sqlite3_threadsafe() == 0:
    raise newException(DbError,
      "libsqlite3 was built without thread support (SQLITE_THREADSAFE=0); " &
      "the Nim core requires a threadsafe build")
  createDir(path.parentDir)
  setGlobalPath(path)
  dbPath = path
  execScript(Schema)
  # After the schema, because it reads the table the schema creates. Both
  # binaries open the database through here, so neither sees an unmigrated tree.
  migrateMessageParents()

## Action purpose: transaction control goes through `execScript` rather than the
## statement cache. These are connection state and not reusable queries, and
## caching them keeps a finished transaction's statement alive on the connection.
proc begin*() = execScript("BEGIN;")
proc commit*() = execScript("COMMIT;")
proc rollback*() =
  try: execScript("ROLLBACK;")
  except DbError: discard   # already rolled back, or no transaction open

## Function purpose: the keyword index is built on FTS5, which is an optional
## extension the linked library may not carry — so it is probed rather than
## assumed. A false answer makes retrieval fall back to vectors only instead of
## failing to start.
proc hasFts5*(): bool =
  try:
    execScript("CREATE VIRTUAL TABLE IF NOT EXISTS _fts5_probe USING fts5(x);")
    execScript("DROP TABLE IF EXISTS _fts5_probe;")
    true
  except DbError:
    false

## Function purpose: exported for the self-test's report; `initDb` already
## refuses to start on a zero, so no caller has to check it.
proc threadsafeMode*(): int = sqlite3_threadsafe().int

## Function purpose: reports what the pragma actually took, which is the only
## proof WAL is in force — `applyPragmas` discards its return codes.
proc journalMode*(): string =
  let rows = query("PRAGMA journal_mode;")
  if rows.len > 0 and rows[0].len > 0: rows[0][0] else: "unknown"

## Function purpose: lets the self-test show that threads genuinely hold
## distinct handles, which is the claim the whole concurrency model rests on.
proc connAddr*(): uint = cast[uint](conn().h)

## Function purpose: exported so the cache bound can be asserted. A bound
## nothing can observe is a claim rather than a property.
proc cachedStatements*(): int = conn().cache.len

## Function purpose: every worker must call this before exiting. The statements
## are finalized first because closing a connection that still holds one leaks
## it rather than reporting an error.
proc closeConn*() =
  if tlsConn != nil:
    for _, s in tlsConn.cache:
      discard sqlite3_finalize(s)
    tlsConn.cache.clear()
    discard sqlite3_close_v2(tlsConn.h)
    tlsConn = nil
