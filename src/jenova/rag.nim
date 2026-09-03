## Script function and purpose: hybrid retrieval — BM25 keyword search plus
## semantic vector search — replacing `lib/search.lua`. This is the R in RAG;
## `lib/proxy.lua`'s completion pipeline is what consumes it (N-30, stage N-S5c).
##
## **Why this is a redesign and not a transcription.** `search.lua` works, but
## its storage has three defects that a direct port would carry forward:
##
## 1. **The BM25 index lived only in process memory** — `bm25_index`, `df` and
##    `total_docs` were module-level tables that nothing persisted, so every
##    restart lost the entire keyword index.
## 2. **The vector index was one JSON blob** (`$JENOVA_STATE/vectors.json`) read
##    whole into memory and merged under a hard 20 MB cap, above which it
##    silently stopped merging.
## 3. **Chunk text was not persisted** — `load_vectors` set `text = ""`. After a
##    restart a semantic hit could be scored but could not produce a snippet, so
##    retrieval half-worked in a way that looks like a ranking bug.
##
## All three are storage problems, and ruling **Q-24** puts both indexes in
## SQLite: BM25 in **FTS5**, vectors in a **BLOB** column, chunk text alongside
## them. That also removes the concurrency problem those globals would have
## become — under D-S there are 14 worker threads and no event loop, and shared
## refcounted globals are not GC-safe across them. `db.nim` already gives every
## thread its own connection, so the index inherits that for free.
##
## **FTS5 is verified present, not assumed** (`jenova-core db-capabilities`,
## D-AB). When it is absent this module degrades to vector-only retrieval and
## says so, rather than failing to start.
##
## Embeddings are obtained from the embedding server on :8082 — ruling **D-E**
## settled the ports and D-AF settled that `llama-server` is the backend.
##
## **What is in the index: chats** (D-BD). The feed is at the bottom of this
## file, and it is what made the difference between a proven module and a used
## one — until 2026-09-01 `indexContent` had no caller outside the self-test.

import std/[os, json, sets, strutils, strformat, algorithm, math, tables, times,
            httpclient]
import ./db

const
  ChunkWords* = 300      ## `search.lua:39` — chunk size in words
  ChunkOverlap* = 50     ## `search.lua:40` — overlap between consecutive chunks
  EmbedBatch* = 8        ## `search.lua:41`
  Bm25Weight* = 0.4      ## `search.lua:43`
  SemanticWeight* = 0.6  ## `search.lua:44`
  SemanticFloor* = 0.3   ## `search.lua:775` — a chunk below this is not a hit
  SnippetChars* = 1000   ## `proxy.lua:1273` truncates snippets at this

const MaxVectorScan* = 50_000
  ## M-03. The ceiling on how many chunk vectors one query may score.
  ##
  ## **Before this the semantic half read the whole table on every completion.**
  ## The statement was `SELECT path, start_line, vec FROM rag_chunks WHERE vec
  ## IS NOT NULL` with no `LIMIT` and no filter — while the keyword half four
  ## lines above it is correctly capped at `LIMIT 200`. Two things made that
  ## expensive rather than merely linear: `db.queryBlob` accumulates **every**
  ## row into a `seq` before returning, so the entire vector table was resident
  ## at once; and the index is fed by every message on both surfaces plus
  ## `backfillChats`, so it grows with the user's whole history and never
  ## shrinks. At 768 dimensions a chunk vector is about 3 KB, so a hundred
  ## thousand chunks is a ~300 MB read and allocation in front of every single
  ## token generated.
  ##
  ## Action purpose: **`ORDER BY rowid DESC`, and the ordering is the honest
  ## part of this change.** A cap has to drop something, and there is no index
  ## that can pre-select "most similar" — that is what the scan was computing.
  ## `rowid` is insertion order, so newest-first keeps the most recently indexed
  ## chunks, which for a personal assistant whose index is its own conversation
  ## history is the right prior: a question is far more often about last week
  ## than about the first thing ever said to it.
  ##
  ## The number is deliberately generous. At 300-word chunks this is on the
  ## order of a hundred thousand messages, so an ordinary install never reaches
  ## it and loses no recall at all; it engages only where the alternative was
  ## already unusable. **The keyword half is unaffected and has no such
  ## horizon** — FTS5 still searches the whole corpus — so a document past the
  ## cap remains findable by its words.

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

proc ftsOk(): bool =
  if ftsAvailable == 0:
    ftsAvailable = if db.hasFts5(): 1 else: 2
  ftsAvailable == 1

## Function purpose: create the retrieval schema. Separate from `db.nim`'s core
## schema because the FTS5 table can legitimately fail to create on a build
## without the extension, and that must degrade rather than abort startup.
proc initSchema*() =
  db.execScript(RagSchema)
  if ftsOk():
    try:
      db.execScript(RagFtsSchema)
    except DbError:
      ftsAvailable = 2

proc available*(): tuple[fts: bool] = (fts: ftsOk())

# ---------------------------------------------------------------------------
# Vector encoding — float32 little-endian, the layout llama.cpp emits
# ---------------------------------------------------------------------------

proc packVec(v: seq[float32]): string =
  if v.len == 0: return ""
  result = newString(v.len * 4)
  copyMem(addr result[0], unsafeAddr v[0], v.len * 4)

proc unpackVec(s: string): seq[float32] =
  if s.len < 4: return @[]
  result = newSeq[float32](s.len div 4)
  copyMem(addr result[0], unsafeAddr s[0], result.len * 4)

## Function purpose: unit-normalise in place so similarity is a plain dot
## product. `search.lua:188` normalises on both sides for the same reason —
## cosine on pre-normalised vectors costs one multiply-add per dimension.
proc normalize(v: var seq[float32]) =
  var sum = 0.0
  for x in v: sum += x.float * x.float
  if sum <= 0.0: return
  let inv = 1.0 / sqrt(sum)
  for i in 0 ..< v.len:
    v[i] = (v[i].float * inv).float32

proc dot(a, b: seq[float32]): float =
  if a.len == 0 or a.len != b.len: return 0.0
  for i in 0 ..< a.len:
    result += a[i].float * b[i].float

## Function purpose: the same dot product, taken straight off a packed vector's
## bytes without materialising it (M-03).
##
## Action purpose: `query` scored every candidate as `dot(qv, unpackVec(blob))`,
## and `unpackVec` allocates a fresh `seq[float32]` per row — one allocation and
## one copy of every vector in the table, per query, purely to read it once. The
## bytes are already in hand and their layout is this module's own
## (`packVec`), so the multiply-add can read them where they are.
##
## The length guard is `dot`'s, restated in bytes: a blob that is not exactly
## four bytes per query dimension is a vector of a different width — a model
## change mid-index — and scores 0 rather than reading past its end.
proc dotBlob(q: seq[float32], blob: string): float =
  if q.len == 0 or blob.len != q.len * 4: return 0.0
  let p = cast[ptr UncheckedArray[float32]](unsafeAddr blob[0])
  for i in 0 ..< q.len:
    result += q[i].float * p[i].float

# ---------------------------------------------------------------------------
# Embeddings — the server on :8082 (D-E, D-AF)
# ---------------------------------------------------------------------------

var embedHost {.threadvar.}: string
var embedPort {.threadvar.}: int

proc configureEmbed*(host: string, port: int) =
  embedHost = host
  embedPort = port

## Function purpose: embed a batch through the embedding server. Returns an
## empty sequence when the server is unreachable, which is a supported state:
## retrieval degrades to keyword-only rather than failing the request. That is
## `search.lua`'s behaviour too — it scores BM25 alone when no embedder is set.
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
# Chunking — reproduces search.lua:62-100
# ---------------------------------------------------------------------------

type Chunk* = object
  text*: string
  startLine*: int

## Function purpose: split content into overlapping word windows, tracking the
## line each chunk starts on so a hit can cite a location. Overlap exists so a
## passage spanning a boundary is still retrievable from one chunk.
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

proc forgetFile*(path: string) =
  db.exec("DELETE FROM rag_chunks WHERE path=?", path)
  db.exec("DELETE FROM rag_documents WHERE path=?", path)
  if ftsOk():
    db.exec("DELETE FROM rag_fts WHERE path=?", path)

## Function purpose: index one file's content — keyword rows into FTS5, chunk
## text and vectors into `rag_chunks`. Idempotent: an existing entry for the path
## is removed first, so re-indexing a changed file cannot leave stale chunks
## behind. **This is the call `search.lua`'s `reindex_file` never had** — B-15's
## root cause was that `index_dir` and `reindex_file` had zero callers repo-wide.
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
  # and still carries its text for snippets, which is the property `search.lua`
  # lost by not persisting chunk text.
  # Action purpose: every batch must contribute exactly one slot per chunk it was
  # given. `embed` returns an empty sequence when the server is unreachable and
  # can return fewer vectors than inputs, so appending its result directly made
  # `vectors` shorter than `chunks` — and the `vectors[idx]` lookup below then
  # handed each remaining chunk a *different* chunk's vector. Padding keeps the
  # index alignment that lookup assumes.
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

proc documentCount*(): int =
  let rows = db.query("SELECT COUNT(*) FROM rag_documents")
  if rows.len > 0 and rows[0].len > 0:
    try: parseInt(rows[0][0]) except ValueError: 0
  else: 0

proc chunkCount*(): int =
  let rows = db.query("SELECT COUNT(*) FROM rag_chunks WHERE vec IS NOT NULL")
  if rows.len > 0 and rows[0].len > 0:
    try: parseInt(rows[0][0]) except ValueError: 0
  else: 0

# ---------------------------------------------------------------------------
# Chat indexing (T-17, D-BD)
# ---------------------------------------------------------------------------
#
# Everything above this line worked and was proven by `rag-selftest`, and none
# of it had ever been fed: `indexContent` had no caller outside that self-test,
# so `documentCount()` was always 0, `query` short-circuited on its second line,
# and `pipeline.prepare` — which asks this module a question on every chat turn
# — always got nothing back. **The engine was finished and starved.** What it
# indexes is ruled at **D-BD**: chats.
#
# A message occupies `chat/<convId>/<role>/<id>`. That shape is chosen so the
# existing `pathFilter` becomes useful without changing it — it matches a path
# exactly or as a directory prefix, so `chat` scopes a search to every
# conversation and `chat/<convId>` to one. **The role sits in the path and not
# in the indexed body**: `formatContext` prints the path above the snippet, so
# the model is told who said it, whereas a role word inside the body would be a
# keyword that every query containing "user" could match.

const ChatRoot* = "chat"

## Function purpose: the index path one chat message occupies. It is stable for
## the life of the row, which is what makes re-indexing *replace* rather than
## duplicate — `indexContent` forgets a path before it writes it.
proc chatPath*(convId, role, msgId: string): string =
  ChatRoot & "/" & convId & "/" &
  (if role.len > 0: role else: "message") & "/" & msgId

## Function purpose: the `pathFilter` value that confines a query to one
## conversation, for a caller that wants recall of this chat rather than all of
## them.
proc chatScope*(convId: string): string = ChatRoot & "/" & convId

## Function purpose: index one message. Empty content is not an error and not a
## document — a turn that is pure reasoning has nothing to retrieve *by*, and
## indexing it would put an empty body in the keyword index.
proc indexMessage*(convId, role, msgId, content: string): bool =
  if convId.len == 0 or msgId.len == 0: return false
  if content.strip().len == 0: return false
  indexContent(chatPath(convId, role, msgId), content)

## Function purpose: index a completed exchange — an assistant reply and the
## turn it answers — from the reply's id alone, so a caller needs to hold only
## the row it just wrote.
##
## **Why an exchange and not each message the moment it is written.** The
## pipeline queries this index with the user's own words on the way to the
## model. A user turn indexed when it is saved is therefore in the index
## *before* the request it belongs to has been answered, and comes back as its
## own top-ranked "context" — the model is handed the question it was just
## asked. Waiting for the reply removes that race rather than narrowing it: by
## the time this runs, the request that could have retrieved itself is over. A
## question that never got an answer is picked up by `backfillChats` at the next
## start.
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

## Function purpose: take a message out of the index when it is deleted. An
## index that keeps answering with turns the user removed is worse than an empty
## one — the deletion is visible everywhere except in what the model recalls.
##
## The row is read rather than remembered because deletion here is *soft*: the
## row is still present with `is_deleted=1`, so the path can still be rebuilt
## from it and the call site does not have to capture anything beforehand.
proc forgetMessage*(msgId: string) =
  if msgId.len == 0: return
  for r in db.query("SELECT convId, role FROM messages WHERE id=?", msgId):
    if r.len >= 2: forgetFile(chatPath(r[0], r[1], msgId))

## Function purpose: the same for a whole conversation, which is deleted in one
## statement over its messages and so has no per-row call site to hook.
##
## The paths come from `rag_documents` rather than from `messages`, because a
## conversation delete flags every one of its rows including ones that were
## never indexed — this way the work is proportional to what is actually in the
## index.
proc forgetConversation*(convId: string) =
  if convId.len == 0: return
  var paths: seq[string]
  for r in db.query("SELECT path FROM rag_documents WHERE path LIKE ?",
                    chatScope(convId) & "/%"):
    if r.len > 0: paths.add r[0]
  for p in paths: forgetFile(p)

# ---------------------------------------------------------------------------
# Workspace documents — notes and file assets (W-06)
# ---------------------------------------------------------------------------
#
# **The retrieval index held chats and nothing else.** `indexContent` was
# exported, correct, and called by no production code at all — as was an
# `indexFile` beside it, since removed for want of a caller. The only writers
# were the chat path above. So the two things a user
# deliberately puts into a workspace *to be found again* — a note they wrote and
# a document they uploaded — were not searchable by keyword or by vector.
#
# They still reached the model, through `workspace.contextFor`, but that is
# **scope**, not relevance: everything in the conversation's branch of the tree,
# whole, ranked by nothing. Retrieval is the part that answers "which of these
# is about what I just asked", and it could not see them.

const
  NoteRoot* = "note"
  FileRoot* = "file"

proc notePath*(id: string): string = NoteRoot & "/" & id
proc fileAssetPath*(id: string): string = FileRoot & "/" & id

## The title leads the body because it is usually the most retrievable thing
## about a note and is not otherwise in the text.
##
## An empty note is not a document — there is nothing to retrieve *by* — but it
## may have had a body before, so the emptying still has to unfile it.
proc indexNote*(id, title, content: string): bool =
  if id.len == 0: return false
  let body = (if title.len > 0: title & "\n\n" else: "") & content
  if body.strip().len == 0:
    forgetFile(notePath(id))
    return false
  indexContent(notePath(id), body)

## By the same rule, and an image is skipped rather than indexed empty: the
## `content` column holds the text a model can be shown, and the attachment
## writer leaves it empty for an image. Indexing that would file a document
## whose whole body is the file name, matching every query weakly.
proc indexFileAsset*(id, name, content: string): bool =
  if id.len == 0: return false
  if content.strip().len == 0:
    forgetFile(fileAssetPath(id))
    return false
  let body = (if name.len > 0: name & "\n\n" else: "") & content
  indexContent(fileAssetPath(id), body)

proc forgetNote*(id: string) =
  if id.len > 0: forgetFile(notePath(id))

proc forgetFileAsset*(id: string) =
  if id.len > 0: forgetFile(fileAssetPath(id))

## Function purpose: index the notes and file assets that are not in the index
## yet, so a workspace that existed before this was wired becomes searchable
## without the user re-saving every note.
##
## Incremental in the same way `backfillChats` is: a path already carrying a
## vector is skipped, so a later start does no work twice and a run interrupted
## half way resumes rather than restarting.
proc backfillWorkspace*(): int =
  var indexed: HashSet[string]
  for r in db.query(
      "SELECT d.path FROM rag_documents d WHERE (d.path LIKE ? OR d.path LIKE ?)" &
      " AND EXISTS (SELECT 1 FROM rag_chunks c WHERE c.path = d.path" &
      " AND c.vec IS NOT NULL)",
      NoteRoot & "/%", FileRoot & "/%"):
    if r.len > 0: indexed.incl r[0]

  var notes: seq[tuple[id, title, content: string]]
  for r in db.query(
      "SELECT id, title, content FROM notes WHERE is_deleted=0"):
    if r.len < 3 or r[0].len == 0: continue
    if notePath(r[0]) in indexed: continue
    notes.add (id: r[0], title: r[1], content: r[2])

  var files: seq[tuple[id, name, content: string]]
  for r in db.query(
      "SELECT id, name, content FROM fileAssets WHERE is_deleted=0"):
    if r.len < 3 or r[0].len == 0: continue
    if fileAssetPath(r[0]) in indexed: continue
    files.add (id: r[0], name: r[1], content: r[2])

  for n in notes:
    if indexNote(n.id, n.title, n.content): inc result
  for f in files:
    if indexFileAsset(f.id, f.name, f.content): inc result

## Function purpose: put existing history into the index once, so recall works
## on the chats that already exist rather than only on ones created after this
## shipped (**D-BD**'s third clause).
##
## **Incremental, so it is safe to call at every start.** A message is skipped
## when its path is already indexed *and* carries at least one chunk with a
## vector. That second condition is what makes this self-healing: a message
## indexed while the embedding server was down has keyword rows and no vectors,
## and would otherwise stay semantically invisible forever — here it is simply
## picked up again on a later start. Callers gate this on the embedder being
## reachable, so the retry cannot loop.
##
## **Content is fetched one row at a time, deliberately.** Selecting id, convId
## and role for the whole table costs three short strings per message; selecting
## the content with it would hold every message ever written in memory at once,
## for a pass that then indexes them one by one anyway.
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
# Query — the hybrid scoring of search.lua:741-830
# ---------------------------------------------------------------------------

## Action purpose: FTS5 needs a query string, and raw user text is not one —
## an apostrophe or a bare `AND` is syntax there. Each term is quoted and the
## terms OR'd, which matches `search.lua`'s tokenise-then-score-any-term
## behaviour rather than requiring every term to be present.
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

proc snippetFor(path: string, startLine: int): string =
  let rows = db.query(
    "SELECT text FROM rag_chunks WHERE path=? AND start_line=? LIMIT 1",
    path, $startLine)
  if rows.len > 0 and rows[0].len > 0:
    result = rows[0][0]
    if result.len > SnippetChars:
      result = result[0 ..< SnippetChars]

## Function purpose: hybrid retrieval, reproducing `search.lua:741`'s shape.
##
## Both score families are normalised **by the maximum within this result set**
## and then weighted 0.4 keyword / 0.6 semantic — the same combination the Lua
## implementation used. Normalising against the set rather than an absolute
## scale is what makes the two comparable at all, since BM25 and cosine have no
## common range.
##
## **One deliberate deviation:** the keyword score comes from FTS5's own `bm25()`
## rather than the hand-rolled k1=1.5/b=0.75 loop. It is a correct BM25 over a
## persisted index instead of an approximation over an in-memory one, and since
## scores are max-normalised before mixing, only the ordering matters. FTS5
## returns a *more negative* score for a better match, so it is negated.
##
## `pathFilter` matches the path exactly or as a directory prefix, as
## `search.lua:775` does.
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
    # M-03. **The path index is not an optimisation, it is a complexity fix.**
    # Keeping only the best chunk per document was a linear search of `best` for
    # every scored row, so the loop was O(rows x documents) — and `best` grows
    # with the number of *distinct matching documents*, which on a large index
    # is most of them. A hash lookup makes it O(rows). `best` is kept as a `seq`
    # alongside it so the result order stays insertion order and a run of this
    # query is reproducible; a bare `Table` would hand the caller an
    # unspecified order and make two identical queries disagree on ties.
    var at = initTable[string, int]()
    # Action purpose: **the path filter belongs in the SQL, before the ceiling,
    # not after it.** `passesFilter` below runs on the rows this query already
    # returned, so with the filter applied only in Nim the `LIMIT` selects the
    # newest `MaxVectorScan` rows *globally* and the filter then discards most
    # of them — a scoped search whose documents happen to be older than 50,000
    # other chunks would find nothing at all while its vectors sat in the table.
    # Pushing the predicate down makes the ceiling a bound on the *candidate*
    # rows rather than on the whole index.
    #
    # `substr` rather than `LIKE`: a path containing `%` or `_` is an ordinary
    # path and a wildcard to `LIKE`, which would silently widen the scope. The
    # empty-filter case is tested first so an unscoped query still scans
    # normally. `passesFilter` is kept below as the final check — this is a
    # narrowing of what is read, not a replacement for it.
    let pf = pathFilter
    for (cols, blob) in db.queryBlob(
        "SELECT path, start_line, vec FROM rag_chunks WHERE vec IS NOT NULL " &
        "AND (? = '' OR path = ? OR substr(path, 1, length(?) + 1) = ? || '/') " &
        # The ceiling is a compile-time constant, not input, so it is written
        # into the statement rather than bound: SQLite's LIMIT wants an integer
        # and this driver binds every parameter as text.
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

  # The same index, for the same reason, over the merge: this was a linear
  # search of `merged` per semantic hit.
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

## Function purpose: store a vector for an already-indexed chunk directly,
## bypassing the embedding server. Exists so the **blob round-trip and the
## similarity maths can be verified without a running embedder** — float32
## endianness, the BLOB write/read path and the dot product are the parts most
## likely to be silently wrong, and leaving them untested until a server happens
## to be up is how "unverified logic" ships.
proc storeChunkVector*(path: string, startLine: int, v: seq[float32]) =
  var vec = v
  normalize(vec)
  # The blob is parameter 1 here — `SET vec=?` precedes the WHERE predicates —
  # so the index is stated rather than left to the default.
  db.execBlob("UPDATE rag_chunks SET vec=? WHERE path=? AND start_line=?",
              [path, $startLine], packVec(vec), blobIndex = 1)

## Function purpose: expose the similarity used by `query`, so a test can assert
## the maths rather than infer it from a ranking.
proc similarity*(a, b: seq[float32]): float =
  var x = a
  var y = b
  normalize(x)
  normalize(y)
  dot(x, y)

proc vectorRoundTrip*(v: seq[float32]): seq[float32] =
  unpackVec(packVec(v))

## Function purpose: expose the packed-blob dot product against the unpacked
## one, so a test can assert they agree (M-03).
##
## Exported for the assertion and nothing else, the same way `similarity` above
## and `pipeline.cacheCount` are. `dotBlob` replaced `dot(qv, unpackVec(blob))`
## on the hot path of every completion; a disagreement between the two would not
## fail anything — it would silently re-rank retrieval, which is the class of
## defect that is only ever found by someone noticing the answers got worse.
proc blobDotMatchesUnpacked*(q, v: seq[float32]): tuple[blob, unpacked: float] =
  let packed = packVec(v)
  (dotBlob(q, packed), dot(q, unpackVec(packed)))

## Function purpose: the `--- REPOSITORY CONTEXT ---` block `proxy.lua:1270`
## injects into a system prompt. Kept here rather than in the pipeline so the
## exact format has one owner.
proc formatContext*(hits: seq[Hit]): string =
  if hits.len == 0: return ""
  var parts = @["\n--- REPOSITORY CONTEXT ---"]
  for i, h in hits:
    parts.add &"[{i + 1}] {h.path}"
    if h.snippet.len > 0:
      parts.add h.snippet
  parts.join("\n")
