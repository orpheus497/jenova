## Script function and purpose: hybrid retrieval — BM25 keyword search plus
## semantic vector search — which the completion pipeline consumes on every
## chat turn.
##
## Both indexes live in SQLite: keywords in FTS5, vectors as a BLOB column, and
## chunk text alongside them. That is what makes retrieval survive a restart and
## what makes it thread-safe, since the fourteen worker threads share no state
## and each already has its own connection. An in-process index would be both a
## data race and lost on every exit.
##
## FTS5 is probed rather than assumed. Where the extension is absent this
## degrades to vector-only retrieval and says so, rather than failing to start.
## The same applies to the embedding server: unreachable means keyword-only.
##
## What is indexed is chats, notes and file assets; the writers are at the
## bottom of this file.

import std/[json, sets, strutils, strformat, algorithm, math, tables, times,
            httpclient]
import ./db

const
  ChunkWords* = 300      ## words per chunk
  ChunkOverlap* = 50     ## carried between consecutive chunks, so a passage
                         ## spanning a boundary is retrievable from one of them
  EmbedBatch* = 8        ## texts per request to the embedding server
  Bm25Weight* = 0.4      ## the two weights sum to 1; semantic leads because
  SemanticWeight* = 0.6  ## keyword search already has the sharper precision
  SemanticFloor* = 0.3   ## below this a chunk is noise, not a weak hit
  SnippetChars* = 1000   ## the ceiling on one snippet in the injected block

const MaxVectorScan* = 50_000
  ## The ceiling on how many chunk vectors one query may score. Without it the
  ## semantic half reads the whole table on every completion — the row reader
  ## materialises every row before returning, and the index grows with the
  ## user's entire history and never shrinks, so a large install pays a
  ## multi-hundred-megabyte read and allocation in front of every token.
  ##
  ## Action purpose: newest-first, and that ordering is the honest part. A cap
  ## has to drop something and no index can pre-select "most similar" — that is
  ## what the scan computes. Insertion order is the right prior for an assistant
  ## whose index is its own history: a question is more often about last week
  ## than about the first thing ever said to it.
  ##
  ## Deliberately generous, so an ordinary install never reaches it. The keyword
  ## half has no such horizon, so a document past the cap stays findable by its
  ## words.

const RagSchema = """
CREATE TABLE IF NOT EXISTS rag_documents (
    path      TEXT PRIMARY KEY,
    mtime     INTEGER NOT NULL DEFAULT 0,
    size      INTEGER NOT NULL DEFAULT 0,
    indexed   INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS rag_chunks (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    path       TEXT NOT NULL,
    start_line INTEGER NOT NULL DEFAULT 1,
    text       TEXT NOT NULL DEFAULT '',
    vec        BLOB
);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_path ON rag_chunks(path);
"""

const RagFtsSchema = """
CREATE VIRTUAL TABLE IF NOT EXISTS rag_fts USING fts5(
    path UNINDEXED,
    body,
    tokenize = 'unicode61'
);
"""

type
  Hit* = object
    path*: string
    score*: float
    bm25*: float
    semantic*: float
    snippet*: string
    startLine*: int

var ftsAvailable {.threadvar.}: int   ## 0 unknown, 1 yes, 2 no

## Function purpose: probed once per thread and cached, because the answer
## cannot change while the process runs and the probe creates a table.
proc ftsOk(): bool =
  if ftsAvailable == 0:
    ftsAvailable = if db.hasFts5(): 1 else: 2
  ftsAvailable == 1

## Function purpose: separate from the core schema because the FTS5 table can
## legitimately fail to create on a build without the extension, and that has to
## degrade rather than abort startup.
proc initSchema*() =
  db.execScript(RagSchema)
  if ftsOk():
    try:
      db.execScript(RagFtsSchema)
    except DbError:
      ftsAvailable = 2

## Function purpose: lets a caller report degraded retrieval rather than
## discover it as an empty result set.
proc available*(): tuple[fts: bool] = (fts: ftsOk())

# ---------------------------------------------------------------------------
# Vector encoding — float32 little-endian, the layout the embedding server emits
# ---------------------------------------------------------------------------

## Function purpose: a raw copy rather than a serialiser, because this layout is
## also what `dotBlob` reads in place.
proc packVec(v: seq[float32]): string =
  if v.len == 0: return ""
  result = newString(v.len * 4)
  copyMem(addr result[0], unsafeAddr v[0], v.len * 4)

## Function purpose: kept for the assertions; the query path reads the packed
## bytes directly instead.
proc unpackVec(s: string): seq[float32] =
  if s.len < 4: return @[]
  result = newSeq[float32](s.len div 4)
  copyMem(addr result[0], unsafeAddr s[0], result.len * 4)

## Function purpose: normalising both sides once makes similarity a plain dot
## product, at one multiply-add per dimension instead of a cosine per pair.
proc normalize(v: var seq[float32]) =
  var sum = 0.0
  for x in v: sum += x.float * x.float
  if sum <= 0.0: return
  let inv = 1.0 / sqrt(sum)
  for i in 0 ..< v.len:
    v[i] = (v[i].float * inv).float32

## Function purpose: mismatched lengths score zero rather than raising, since a
## width change means the embedding model changed mid-index.
proc dot(a, b: seq[float32]): float =
  if a.len == 0 or a.len != b.len: return 0.0
  for i in 0 ..< a.len:
    result += a[i].float * b[i].float

## Function purpose: the same dot product taken straight off a packed vector's
## bytes. Unpacking first allocates and copies every vector in the table, per
## query, purely to read each once — and the layout is this module's own, so the
## multiply-add can read the bytes where they are.
##
## Action purpose: the length guard, in bytes: a blob that is not exactly four
## bytes per query dimension is a vector of a different width, which means the
## model changed mid-index. It scores zero rather than reading past its end.
proc dotBlob(q: seq[float32], blob: string): float =
  if q.len == 0 or blob.len != q.len * 4: return 0.0
  let p = cast[ptr UncheckedArray[float32]](unsafeAddr blob[0])
  for i in 0 ..< q.len:
    result += q[i].float * p[i].float

# ---------------------------------------------------------------------------
# Embeddings — the separate embedding backend
# ---------------------------------------------------------------------------

var embedHost {.threadvar.}: string
var embedPort {.threadvar.}: int

## Function purpose: per thread, because the settings are threadvars — each
## worker configures its own before its first query.
proc configureEmbed*(host: string, port: int) =
  embedHost = host
  embedPort = port

## Function purpose: an unreachable embedder answers empty rather than raising,
## which is a supported state — retrieval degrades to keyword-only rather than
## failing the request that asked for it.
proc embed*(texts: seq[string]): seq[seq[float32]] =
  if texts.len == 0: return @[]
  let host = if embedHost.len > 0: embedHost else: "127.0.0.1"
  let port = if embedPort > 0: embedPort else: 8082
  var client = newHttpClient(timeout = 30_000)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  var body = %*{"input": texts}
  try:
    let resp = client.request(&"http://{host}:{port}/v1/embeddings",
                              httpMethod = HttpPost, body = $body)
    if resp.code.int != 200: return @[]
    let parsed = parseJson(resp.body)
    if not parsed.hasKey("data"): return @[]
    for item in parsed["data"]:
      if not item.hasKey("embedding"): continue
      var v: seq[float32]
      for f in item["embedding"]:
        v.add f.getFloat.float32
      normalize(v)
      result.add v
  except CatchableError:
    return @[]

# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

type Chunk* = object
  text*: string
  startLine*: int

## Function purpose: the line each chunk starts on is tracked so a hit can cite
## a location, and the windows overlap so a passage spanning a boundary is still
## retrievable from one chunk rather than from neither.
proc chunkText*(content: string): seq[Chunk] =
  if content.len == 0: return @[]
  let lines = content.splitLines()
  var words: seq[tuple[w: string, line: int]]
  for idx, line in lines:
    for w in line.splitWhitespace():
      words.add (w, idx + 1)
  if words.len == 0: return @[]

  var i = 0
  while i < words.len:
    let stop = min(i + ChunkWords, words.len)
    var buf: seq[string]
    for k in i ..< stop: buf.add words[k].w
    result.add Chunk(text: buf.join(" "), startLine: words[i].line)
    if stop >= words.len: break
    i += ChunkWords - ChunkOverlap

# ---------------------------------------------------------------------------
# Indexing
# ---------------------------------------------------------------------------

## Function purpose: the unfiling half of indexing, called before every write so
## re-indexing replaces rather than duplicates.
proc forgetFile*(path: string) =
  db.exec("DELETE FROM rag_chunks WHERE path=?", path)
  db.exec("DELETE FROM rag_documents WHERE path=?", path)
  if ftsOk():
    db.exec("DELETE FROM rag_fts WHERE path=?", path)

## Function purpose: idempotent by construction — an existing entry for the path
## is removed first, so re-indexing changed content cannot leave stale chunks
## behind and every writer can call it unconditionally.
proc indexContent*(path, content: string, mtime = 0): bool =
  if path.len == 0: return false
  forgetFile(path)

  db.exec("INSERT OR REPLACE INTO rag_documents (path, mtime, size, indexed) " &
          "VALUES (?, ?, ?, ?)",
          path, $mtime, $content.len, $int(epochTime()))
  if ftsOk():
    db.exec("INSERT INTO rag_fts (path, body) VALUES (?, ?)", path, content)

  let chunks = chunkText(content)
  if chunks.len == 0: return true

  # Embedding is best-effort: a chunk with no vector is still keyword-searchable
  # and still carries its own text for snippets.
  #
  # Action purpose: every batch must contribute exactly one slot per chunk it
  # was given. The embedder can return fewer vectors than inputs, or none, so
  # appending its result directly leaves the sequences misaligned and the
  # indexed lookup below hands each remaining chunk a different chunk's vector.
  var vectors: seq[seq[float32]]
  var batch: seq[string]

  proc flushBatch() =
    if batch.len == 0: return
    let got = embed(batch)
    for k in 0 ..< batch.len:
      vectors.add (if k < got.len: got[k] else: newSeq[float32]())
    batch.setLen 0

  for c in chunks:
    batch.add c.text
    if batch.len == EmbedBatch:
      flushBatch()
  flushBatch()

  for idx, c in chunks:
    let vec = if idx < vectors.len: packVec(vectors[idx]) else: ""
    db.execBlob(
      "INSERT INTO rag_chunks (path, start_line, text, vec) VALUES (?, ?, ?, ?)",
      [path, $c.startLine, c.text], vec)
  true

## Function purpose: the query path short-circuits on zero, so this is a live
## check rather than only a diagnostic.
proc documentCount*(): int =
  let rows = db.query("SELECT COUNT(*) FROM rag_documents")
  if rows.len > 0 and rows[0].len > 0:
    try: parseInt(rows[0][0]) except ValueError: 0
  else: 0

## Function purpose: exported for the assertions, which need to see that a
## re-index replaced chunks rather than adding to them.
proc chunkCount*(): int =
  let rows = db.query("SELECT COUNT(*) FROM rag_chunks WHERE vec IS NOT NULL")
  if rows.len > 0 and rows[0].len > 0:
    try: parseInt(rows[0][0]) except ValueError: 0
  else: 0

# ---------------------------------------------------------------------------
# Chat indexing
# ---------------------------------------------------------------------------
#
# Action purpose: a message occupies `chat/<convId>/<role>/<id>`, and the shape
# is what makes `pathFilter` useful without changing it — that filter matches a
# path exactly or as a directory prefix, so `chat` scopes a search to every
# conversation and `chat/<convId>` to one.
#
# The role sits in the path and not in the indexed body. The context formatter
# prints the path above the snippet, so the model is told who said it, whereas
# a role word inside the body would be a keyword every query containing "user"
# could match.

const ChatRoot* = "chat"

## Function purpose: stable for the life of the row, which is what makes
## re-indexing replace rather than duplicate.
proc chatPath*(convId, role, msgId: string): string =
  ChatRoot & "/" & convId & "/" &
  (if role.len > 0: role else: "message") & "/" & msgId

## Function purpose: the filter value that confines a query to one conversation,
## for a caller wanting recall of this chat rather than of all of them.
proc chatScope*(convId: string): string = ChatRoot & "/" & convId

## Function purpose: empty content is neither an error nor a document — a turn
## that is pure reasoning has nothing to retrieve *by*, and indexing it puts an
## empty body in the keyword index that matches weakly against everything.
proc indexMessage*(convId, role, msgId, content: string): bool =
  if convId.len == 0 or msgId.len == 0: return false
  if content.strip().len == 0: return false
  indexContent(chatPath(convId, role, msgId), content)

## Function purpose: takes the reply's id alone, so a caller holds only the row
## it just wrote.
##
## Action purpose: an exchange rather than each message as it is written. The
## pipeline queries this index with the user's own words on the way to the
## model, so a user turn indexed at save time is in the index before the request
## it belongs to is answered — and comes back as its own top-ranked context,
## handing the model the question it was just asked. Waiting for the reply
## removes that race rather than narrowing it, and a question that never got an
## answer is picked up by the backfill at the next start.
proc indexExchange*(replyId: string, withParent = true): int =
  var id = replyId
  var remaining = if withParent: 2 else: 1
  while id.len > 0 and remaining > 0:
    let rows = db.query(
      "SELECT convId, role, content, parent FROM messages " &
      "WHERE id=? AND is_deleted=0", id)
    if rows.len == 0 or rows[0].len < 4: break
    if indexMessage(rows[0][0], rows[0][1], id, rows[0][2]): inc result
    dec remaining
    id = rows[0][3]

## Function purpose: an index that keeps answering with turns the user removed
## is worse than an empty one — the deletion is visible everywhere except in
## what the model recalls.
##
## Action purpose: the row is read rather than remembered, because deletion here
## is soft and the row is still present — so the path can be rebuilt from it and
## no call site has to capture anything beforehand.
proc forgetMessage*(msgId: string) =
  if msgId.len == 0: return
  for r in db.query("SELECT convId, role FROM messages WHERE id=?", msgId):
    if r.len >= 2: forgetFile(chatPath(r[0], r[1], msgId))

## Function purpose: a conversation is deleted in one statement over its
## messages, so there is no per-row call site to hook.
##
## Action purpose: the paths come from the index rather than from the message
## table, because a conversation delete flags every row including ones never
## indexed — this way the work is proportional to what is actually there.
proc forgetConversation*(convId: string) =
  if convId.len == 0: return
  var paths: seq[string]
  for r in db.query("SELECT path FROM rag_documents WHERE path LIKE ?",
                    chatScope(convId) & "/%"):
    if r.len > 0: paths.add r[0]
  for p in paths: forgetFile(p)

# ---------------------------------------------------------------------------
# Workspace documents — notes and file assets
# ---------------------------------------------------------------------------
#
# These are indexed as well as scoped. The workspace context builder already
# puts everything in a conversation's branch of the tree in front of the model,
# whole and ranked by nothing; retrieval is the part that answers which of them
# is about what was just asked, and it can only do that if they are here.

const
  NoteRoot* = "note"
  FileRoot* = "file"

## Function purpose: the index path a note occupies, under its own root so a
## path filter can scope a search to notes alone.
proc notePath*(id: string): string = NoteRoot & "/" & id
## Function purpose: the same for an uploaded file, under a separate root.
proc fileAssetPath*(id: string): string = FileRoot & "/" & id

## Function purpose: the title leads the body because it is usually the most
## retrievable thing about a note and is not otherwise in the text.
##
## Action purpose: an empty note is not a document, but it may have had a body
## before — so emptying one still has to unfile it rather than skip it.
proc indexNote*(id, title, content: string): bool =
  if id.len == 0: return false
  let body = (if title.len > 0: title & "\n\n" else: "") & content
  if body.strip().len == 0:
    forgetFile(notePath(id))
    return false
  indexContent(notePath(id), body)

## Function purpose: by the same rule, except that an image is skipped rather
## than indexed empty — the stored content is the text a model can be shown, and
## an image has none, so indexing it files a document whose whole body is a file
## name and which matches every query weakly.
proc indexFileAsset*(id, name, content: string): bool =
  if id.len == 0: return false
  if content.strip().len == 0:
    forgetFile(fileAssetPath(id))
    return false
  let body = (if name.len > 0: name & "\n\n" else: "") & content
  indexContent(fileAssetPath(id), body)

## Function purpose: called when a note is deleted or emptied, so retrieval
## stops answering with content the user removed.
proc forgetNote*(id: string) =
  if id.len > 0: forgetFile(notePath(id))

## Function purpose: the same for an uploaded file.
proc forgetFileAsset*(id: string) =
  if id.len > 0: forgetFile(fileAssetPath(id))

## Function purpose: makes a workspace that predates the index searchable
## without the user re-saving every note. Incremental — a path already carrying
## a vector is skipped — so a later start does no work twice and a run
## interrupted half way resumes rather than restarting.
proc backfillWorkspace*(): int =
  var indexed: HashSet[string]
  for r in db.query(
      "SELECT d.path FROM rag_documents d WHERE (d.path LIKE ? OR d.path LIKE ?)" &
      " AND EXISTS (SELECT 1 FROM rag_chunks c WHERE c.path = d.path" &
      " AND c.vec IS NOT NULL)",
      NoteRoot & "/%", FileRoot & "/%"):
    if r.len > 0: indexed.incl r[0]

  # Action purpose: ids and titles first, bodies one at a time. Selecting the
  # content with the id list holds every note and uploaded file in memory at
  # once, for a pass that indexes them singly anyway.
  var notes: seq[tuple[id, title: string]]
  for r in db.query("SELECT id, title FROM notes WHERE is_deleted=0"):
    if r.len < 2 or r[0].len == 0: continue
    if notePath(r[0]) in indexed: continue
    notes.add (id: r[0], title: r[1])

  var files: seq[tuple[id, name: string]]
  for r in db.query("SELECT id, name FROM fileAssets WHERE is_deleted=0"):
    if r.len < 2 or r[0].len == 0: continue
    if fileAssetPath(r[0]) in indexed: continue
    files.add (id: r[0], name: r[1])

  for n in notes:
    let rows = db.query("SELECT content FROM notes WHERE id=?", n.id)
    if rows.len == 0 or rows[0].len == 0: continue
    if indexNote(n.id, n.title, rows[0][0]): inc result
  for f in files:
    let rows = db.query("SELECT content FROM fileAssets WHERE id=?", f.id)
    if rows.len == 0 or rows[0].len == 0: continue
    if indexFileAsset(f.id, f.name, rows[0][0]): inc result

## Function purpose: puts existing history into the index, so recall works on
## chats that predate it. Safe to call at every start because it is incremental.
##
## Action purpose: a message is skipped only when its path is indexed *and*
## carries a chunk with a vector, and that second condition is what makes this
## self-healing — a message indexed while the embedder was down has keyword rows
## and no vectors, and would otherwise stay semantically invisible for ever.
## Callers gate this on the embedder being reachable, so the retry cannot loop.
##
## Content is fetched one row at a time: selecting it with the id list would
## hold every message ever written in memory at once, for a pass that indexes
## them singly anyway.
proc backfillChats*(): int =
  var indexed: HashSet[string]
  for r in db.query(
      "SELECT d.path FROM rag_documents d WHERE d.path LIKE ? AND EXISTS (" &
      "SELECT 1 FROM rag_chunks c WHERE c.path = d.path AND c.vec IS NOT NULL)",
      ChatRoot & "/%"):
    if r.len > 0: indexed.incl r[0]

  var todo: seq[tuple[convId, role, id: string]]
  for r in db.query("SELECT id, convId, role FROM messages WHERE is_deleted=0"):
    if r.len < 3 or r[1].len == 0: continue
    if chatPath(r[1], r[2], r[0]) in indexed: continue
    todo.add (convId: r[1], role: r[2], id: r[0])

  for t in todo:
    let rows = db.query("SELECT content FROM messages WHERE id=?", t.id)
    if rows.len == 0 or rows[0].len == 0: continue
    if indexMessage(t.convId, t.role, t.id, rows[0][0]): inc result

# ---------------------------------------------------------------------------
# Query — the hybrid scoring
# ---------------------------------------------------------------------------

## Function purpose: raw user text is not an FTS5 query — an apostrophe or a
## bare `AND` is syntax there. Each term is quoted and the terms OR'd, so a
## query scores on any term rather than requiring all of them.
proc ftsQueryString(query: string): string =
  var terms: seq[string]
  for raw in query.toLowerAscii.split({' ', '\t', '\n', '\r', ',', '.', ';',
                                       ':', '(', ')', '[', ']', '{', '}',
                                       '"', '\'', '/', '\\', '!', '?', '<',
                                       '>', '=', '|', '&', '*', '+', '#'}):
    let t = raw.strip()
    if t.len > 1 and t.len < 60:
      terms.add "\"" & t & "\""
  terms.join(" OR ")

## Function purpose: read from the stored chunk text rather than from the
## original file, which may have changed or gone since it was indexed.
proc snippetFor(path: string, startLine: int): string =
  let rows = db.query(
    "SELECT text FROM rag_chunks WHERE path=? AND start_line=? LIMIT 1",
    path, $startLine)
  if rows.len > 0 and rows[0].len > 0:
    result = rows[0][0]
    if result.len > SnippetChars:
      result = result[0 ..< SnippetChars]

## Function purpose: mixes the two score families, each normalised by the
## maximum within this result set. Normalising against the set rather than an
## absolute scale is what makes them comparable at all, since BM25 and cosine
## share no range.
##
## Action purpose: the keyword score is FTS5's own `bm25()`, which returns a
## *more negative* number for a better match and is therefore negated. Only the
## ordering matters, since both families are max-normalised before mixing.
##
## `pathFilter` matches a path exactly or as a directory prefix.
proc query*(queryStr: string, topK = 5, withSnippets = true,
            pathFilter = ""): seq[Hit] =
  if queryStr.strip().len == 0: return @[]
  if documentCount() == 0: return @[]

  var bm: seq[tuple[path: string, score: float]]
  if ftsOk():
    let q = ftsQueryString(queryStr)
    if q.len > 0:
      try:
        for row in db.query(
            "SELECT path, bm25(rag_fts) FROM rag_fts WHERE rag_fts MATCH ? " &
            "ORDER BY bm25(rag_fts) LIMIT 200", q):
          if row.len < 2: continue
          let raw = try: parseFloat(row[1]) except ValueError: 0.0
          bm.add (row[0], -raw)     # FTS5: more negative is a better match
      except DbError:
        discard

  var sem: seq[tuple[path: string, score: float, startLine: int]]
  let qvecs = embed(@[queryStr])
  if qvecs.len > 0:
    let qv = qvecs[0]
    var best: seq[tuple[path: string, score: float, startLine: int]]
    # Action purpose: a complexity fix, not an optimisation. Keeping only the
    # best chunk per document by scanning the accumulator is O(rows x
    # documents), and the accumulator grows with the number of distinct matching
    # documents. The sequence is kept alongside the index so result order stays
    # insertion order — a bare table would hand the caller an unspecified order
    # and make two identical queries disagree on ties.
    var at = initTable[string, int]()
    # Action purpose: the path filter belongs in the SQL, before the ceiling.
    # Applied afterwards it filters rows the limit already chose, so the limit
    # takes the newest chunks globally and the filter discards most of them — a
    # scoped search whose documents are older than the ceiling finds nothing
    # while its vectors sit in the table. Pushed down, the ceiling bounds the
    # candidate rows instead of the whole index.
    #
    # `substr` rather than `LIKE`, because `%` and `_` are ordinary characters
    # in a path and wildcards to `LIKE`, which would silently widen the scope.
    # The filter below stays as the final check: this narrows what is read, it
    # does not replace it.
    let pf = pathFilter
    for (cols, blob) in db.queryBlob(
        "SELECT path, start_line, vec FROM rag_chunks WHERE vec IS NOT NULL " &
        "AND (? = '' OR path = ? OR substr(path, 1, length(?) + 1) = ? || '/') " &
        # The ceiling is a compile-time constant rather than input, so it is
        # written into the statement: a limit wants an integer and this driver
        # binds every parameter as text.
        "ORDER BY rowid DESC LIMIT " & $MaxVectorScan, pf, pf, pf, pf):
      if cols.len < 2 or blob.len == 0: continue
      let s = dotBlob(qv, blob)
      if s <= SemanticFloor: continue
      let line = try: parseInt(cols[1]) except ValueError: 1
      let idx = at.getOrDefault(cols[0], -1)
      if idx < 0:
        at[cols[0]] = best.len
        best.add (cols[0], s, line)
      elif s > best[idx].score:
        best[idx].score = s
        best[idx].startLine = line
    sem = best

  proc passesFilter(p: string): bool =
    pathFilter.len == 0 or p == pathFilter or p.startsWith(pathFilter & "/")

  var merged: seq[Hit]
  var maxBm = 0.0
  var maxSem = 0.0

  # The same index for the same reason, over the merge.
  var mergedAt = initTable[string, int]()

  for e in bm:
    if not passesFilter(e.path): continue
    if not mergedAt.hasKey(e.path):
      mergedAt[e.path] = merged.len
      merged.add Hit(path: e.path, bm25: e.score)
    if e.score > maxBm: maxBm = e.score
  for e in sem:
    if not passesFilter(e.path): continue
    let idx = mergedAt.getOrDefault(e.path, -1)
    if idx >= 0:
      merged[idx].semantic = e.score
      merged[idx].startLine = e.startLine
    else:
      mergedAt[e.path] = merged.len
      merged.add Hit(path: e.path, semantic: e.score, startLine: e.startLine)
    if e.score > maxSem: maxSem = e.score

  let haveSemantic = qvecs.len > 0
  for i in 0 ..< merged.len:
    let nb = if maxBm > 0: merged[i].bm25 / maxBm else: 0.0
    let ns = if maxSem > 0: merged[i].semantic / maxSem else: 0.0
    merged[i].score =
      if haveSemantic: Bm25Weight * nb + SemanticWeight * ns
      else: nb

  merged.sort(proc (a, b: Hit): int = cmp(b.score, a.score))
  if merged.len > topK: merged.setLen topK

  if withSnippets:
    for i in 0 ..< merged.len:
      merged[i].snippet = snippetFor(merged[i].path, max(merged[i].startLine, 1))
      if merged[i].snippet.len == 0:
        let rows = db.query(
          "SELECT text FROM rag_chunks WHERE path=? ORDER BY start_line LIMIT 1",
          merged[i].path)
        if rows.len > 0 and rows[0].len > 0:
          merged[i].snippet = rows[0][0]
          if merged[i].snippet.len > SnippetChars:
            merged[i].snippet = merged[i].snippet[0 ..< SnippetChars]

  merged

## Function purpose: bypasses the embedder so the blob round trip and the
## similarity maths can be asserted without one running. Endianness, the BLOB
## write and read path and the dot product are the parts most likely to be
## silently wrong, and they would otherwise go untested until a server happens
## to be up.
proc storeChunkVector*(path: string, startLine: int, v: seq[float32]) =
  var vec = v
  normalize(vec)
  # The blob is the first parameter here, since the assignment precedes the
  # predicates, so its index is stated rather than left to the default.
  db.execBlob("UPDATE rag_chunks SET vec=? WHERE path=? AND start_line=?",
              [path, $startLine], packVec(vec), blobIndex = 1)

## Function purpose: exported so a test can assert the maths directly rather
## than infer it from a ranking.
proc similarity*(a, b: seq[float32]): float =
  var x = a
  var y = b
  normalize(x)
  normalize(y)
  dot(x, y)

## Function purpose: exported so a test can prove the pack and unpack agree —
## an endianness error here silently degrades every ranking.
proc vectorRoundTrip*(v: seq[float32]): seq[float32] =
  unpackVec(packVec(v))

## Function purpose: exported so a test can assert that the packed and unpacked
## dot products agree. A disagreement between them fails nothing — it silently
## re-ranks retrieval, which is only ever found by someone noticing the answers
## got worse.
proc blobDotMatchesUnpacked*(q, v: seq[float32]): tuple[blob, unpacked: float] =
  let packed = packVec(v)
  (dotBlob(q, packed), dot(q, unpackVec(packed)))

## Function purpose: the block injected into a system prompt, kept here rather
## than in the pipeline so the exact format has one owner.
proc formatContext*(hits: seq[Hit]): string =
  if hits.len == 0: return ""
  var parts = @["\n--- REPOSITORY CONTEXT ---"]
  for i, h in hits:
    parts.add &"[{i + 1}] {h.path}"
    if h.snippet.len > 0:
      parts.add h.snippet
  parts.join("\n")
