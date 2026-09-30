# Context and Retrieval

How content reaches the model.

This document was written against the Lua proxy and its `lib/search.lua` retriever. Both are gone —
the retrieval path is `src/jenova/rag.nim` and the injection path is `src/jenova/pipeline.nim`.
Where a mechanism is implemented but not reached in normal operation, it says so rather than
describing intent as behaviour.

> **Four states in this document were wrong and are corrected below.** It reported the retrieval
> index as never populated, workspace context and per-message attachments as existing only in the
> Web UI, and conversation history as never trimmed. All four claims had been overtaken by the
> code. Recorded here rather than quietly edited, because a document that told a reader a working
> feature did not work is the failure this note exists to make visible.

## What supplies context

| # | Mechanism | Owner | State |
|---|---|---|---|
| 1 | Server-side retrieval (BM25 + vectors) | `src/jenova/rag.nim` | **Live, and populated**, scoped by the `X-Jenova-Scope` header — see §1 |
| 2 | Persona and context injection | `src/jenova/pipeline.nim` | Live on every chat completion whose last user message is non-empty and carries no context block |
| 3 | Editor context | `src/jenova/nvimctl.nim` | Live, and **only** for the `Editor:` intent |
| 4 | Web search | `src/jenova/websearch.nim` | Live, and only for the `Web Search:` intent |
| 5 | Workspace context | `src/jenova/workspace.nim` + `jca_web` | Live on **both** surfaces |
| 6 | Per-message attachments | `src/jenova/pipeline.nim` + `jca_web` | Live on **both** surfaces |
| 7 | MCP tools | `jca_web` | Web UI only, off by default |
| 8 | Conversation history | `src/jenova/pipeline.nim` | **Trimmed oldest-first** to fit the context budget |

Mechanisms 1–4 and 8 are server-side and apply to **every** client — the desktop window, the Web
UI and any OpenAI-compatible client pointed at `:8080` — with one difference in what retrieval can
see. Retrieval is scoped by the `X-Jenova-Scope` request header, and **only the desktop window
sends it**. A request without it — every Web UI turn, `curl`, any OpenAI client — retrieves only
items that belong to no workspace, so a Web UI chat inside a workspace never retrieves that
workspace's notes, files or chats (§1, *Filter*). Mechanism 5 exists on both surfaces but by two
different routes; 6 likewise. Only mechanism 7 is still Web UI only.

---

## 1. Server-side retrieval — `src/jenova/rag.nim`

### Storage

Both indexes live in SQLite, alongside the workspace database, so they survive a restart and every
thread gets its own connection:

| Table | Holds |
|---|---|
| `rag_documents` | one row per indexed path, with its size (the content length) and the time it was indexed. It also has an `mtime` column, which no writer sets, so it is always 0 |
| `rag_chunks` | chunk text, its starting line, and its embedding as a `BLOB` of raw float32 values in the host's byte order (little-endian on x86 and ARM, not enforced); `NULL` for a chunk stored without a vector |
| `rag_fts` | an FTS5 virtual table over the full document body, tokenised `unicode61` |

This is the part that is a redesign rather than a port. `lib/search.lua` kept its BM25 index in
process memory and lost it on every restart, wrote its vectors to one whole-file `vectors.json`
under a 20 MB cap above which merging silently stopped, and stored chunk text as `""` — so after a
restart a semantic hit could be scored but could not produce a snippet.

**FTS5 is checked, not assumed.** `jenova-core db-capabilities` reports whether the linked
`libsqlite3` has it; when it does not, `initSchema` records that and retrieval runs vector-only.

### Chunking

300 words per chunk with 50 words of overlap, tracking the line each chunk starts on so a hit can
cite a location. The overlap exists so a passage spanning a boundary is still retrievable whole
from one chunk.

### Embeddings

`rag.embed` posts to `/v1/embeddings` on the embedding server in batches of 8, and unit-normalises
each vector so similarity is a plain dot product. An unreachable server returns an empty result,
which is a **supported** state: chunks are stored without vectors, keyword search still works, and
every chunk still carries its text for snippets.

The address is per thread (`rag.configureEmbed`), defaulting to `127.0.0.1:8082`. The main thread,
the window's control worker and `serve`'s watchdog set it from `LLAMA_EMBED_PORT`; the server's
worker threads, which run retrieval queries and index what the Web UI saves over `/api/db`, never
do, so they always use 8082. Moving `LLAMA_EMBED_PORT` therefore leaves those paths keyword-only.

Each batch contributes exactly one vector slot per chunk it was given, padding with an empty vector
where the server returned fewer than it was asked for. Without that padding the vectors shifted
against the chunks and each remaining chunk was stored with a different chunk's embedding.

### Query

`rag.query(queryStr, topK = 5, withSnippets = true, pathFilter = "", scope = ScopeContext())`.
`scope` is parsed from the request's `X-Jenova-Scope` header (`folder=…;project=…;workspace=…`); it
returns at once when the query is empty or the index holds no documents:

1. **Keyword.** The query is tokenised, each term quoted and the terms OR'd into an FTS5 `MATCH`,
   scored by FTS5's own `bm25()`. FTS5 returns a *more negative* score for a better match, so it is
   negated. This is a correct BM25 over a persisted index rather than the hand-rolled
   k1=1.5/b=0.75 loop `search.lua` ran over an in-memory one.
2. **Semantic.** Up to `rag.MaxVectorScan` (50,000) chunk vectors are read from SQLite, newest
   first, with the path filter applied in the SQL, and scored in Nim by a dot product over the raw
   blob against the query embedding. A chunk at or below `SemanticFloor` (0.3) is not a hit at all.
   The best chunk per path wins, and its start line becomes the hit's line.
3. **Mix.** Both families are normalised **by the maximum within this result set** and weighted
   0.4 keyword / 0.6 semantic. Normalising against the set rather than an absolute scale is what
   makes BM25 and cosine comparable, since they share no range. With no embedder available the
   score is the normalised keyword score alone.
4. **Filter.** `pathFilter` matches a path exactly or as a directory prefix (no caller sets it
   today). Every hit must also fall inside `scope`: with a folder named, only items filed directly
   in that folder; with a project, the project and its folders; with a workspace, everything in it;
   and with **no scope — the absent header — only items that belong to no workspace, project or
   folder**. After sorting, a hit whose source row is flagged deleted is skipped, and the walk
   continues until `topK` live hits are collected.
5. **Snippets.** The chunk at the hit's start line, truncated at 1000 characters; the file's first
   chunk if that lookup finds nothing.

### What fills the index

**This section previously said the index was never populated. That has not been true for some
time** — the writers below all exist, and the `--- REPOSITORY CONTEXT ---` block does appear in
real requests.

| Writer | When |
|---|---|
| `api.upsert` → `rag.indexNote` / `rag.indexFileAsset` | **A note or file asset saved on either surface**, when it is new or its title (or name) or content changed. Hooked at `upsert` rather than in each client, because that is the one layer the Web UI's `/api/db/*` route and the window's in-process `putEntity` both pass through. A bulk import (`importData`, which calls `upsert` without the mirror) indexes nothing; those rows wait for the backfill |
| `api.handleDb` → `rag.indexExchange` | On `POST /api/db/messages`, an **assistant** row, together with the user turn it answers; a user message is not indexed when it is created. `/api/db/messages/update` re-indexes the edited message when the body carries `content` |
| `api.restoreItem` | Reached by the HTTP restore route and by the window's trash. Re-indexes a restored message, note or file asset, or a restored conversation's assistant turns with the turns they answer. Notes and files revived as descendants of a restored container wait for the backfill |
| `gui.ctlWorker` → `rag.indexExchange` | Each completed exchange in the desktop window, on a worker thread so the embedding round trip never touches the GTK loop |
| `rag.backfillChats`, `rag.backfillWorkspace` | Once per process, and only after the embedding server answers a health check — **not before**, or content would be indexed while the embedder is still loading and stored keyword-only. In `jenova-core serve` they run on the watchdog thread, at least one 30 s interval after start, are retried on the next cycle after a failure, and are skipped entirely under `JENOVA_NO_BACKENDS=1`. In the window they run from the control worker's poll |

Until recently the index held **chats and nothing else**: notes and uploaded documents were not
searchable by keyword or by vector, only injected wholesale by scope through mechanism 5. A note is
indexed with its title prepended to the body, and a file asset with its filename, so a note called
"Pooling" whose text never repeats the word is still findable by it. An image is not indexed: its
`content` column is deliberately empty because the bytes live in `messages.extra`.

Indexing is **best-effort and never fails the write it is attached to** — a note is saved whether
or not it could be indexed, and the backfills repair a skipped entry at the next start. It runs
only when the indexed text actually changed, so re-saving an unedited note costs no embedding
round trip.

`backfillChats` is incremental, so a later start does no work twice, and `indexExchange` indexes a
reply together with the user turn that prompted it — never at the moment the question is asked,
which would let a request retrieve itself.

Indexing is **best-effort**: a chunk with no vector is still keyword-searchable, and a failure
degrades retrieval rather than failing the turn.

### What one query costs

The keyword half is capped at 200 documents by FTS5. The semantic half reads chunk vectors from
SQLite, newest first, up to `rag.MaxVectorScan` (50,000 chunks), and scores them in Nim — a ceiling
rather than a working size, since a chunk is 300 words and an ordinary install never reaches it. Past that ceiling a
document is still findable by its words; only its vector is out of scope.

---

## 2. The completion pipeline — `src/jenova/pipeline.nim`

`pipeline.prepare` runs on every completion-class request with a body — `/v1/chat/completions`
above all — and rewrites it when the body is a JSON object carrying `messages`. **The order is part
of the contract**:

1. **Intent detection.** A prefix on the last user message, stripped after matching so the model
   never sees the marker.
2. **Tool stripping**, for the two intents that gain nothing from tools (`Visual Rewrite:` and
   `Web Search:`). It comes before retrieval because whether tools are present decides the persona
   mode below.
3. **Retrieval** at a per-intent result limit, with a rewritten query for large payloads.
4. **Web search**, for the `Web Search:` intent only.
5. **Editor context**, for the `Editor:` intent only.
6. **Injection**, in one step: the persona, in one of three modes, and the web, editor and
   `--- REPOSITORY CONTEXT ---` blocks.
7. **History trimming** — the oldest turns dropped to fit the budget (§8).
8. **Cache key** — SHA-256 of the **rewritten** body.

Steps 3 to 6 are skipped when the last user message is empty or already contains the context
marker. The cache key must stay last: hashing the client's original body would produce a different
key and orphan every entry already written.

A body with no `messages` passes through untouched, so `/completion` and `/infill` — the Neovim FIM
path — reach `llama-server` byte for byte.

### Intents

| Prefix | Intent | Effect |
|---|---|---|
| `Visual Rewrite:` | visual | 1 retrieval hit; tools stripped and `tool_choice` forced to `none` |
| `Open File Chat:`, `Chatbot:` | filechat | 3 hits |
| `Web Search:` | websearch | 0 retrieval hits — its context comes from the web; tools stripped and `tool_choice` forced to `none` |
| `Editor:` | editor | 3 hits, plus the live Neovim buffer |
| *(none)* | none | 3 hits, freechat persona |

Whatever the intent, a large payload (below) gets 5 hits instead, `Web Search:` included.

**Where the prefixes come from.** The desktop window's Send split-button has a menu listing all
five, which puts the chosen one at the start of the draft (`gui.intentMenuItems`). The bundled
Neovim layer sends `Visual Rewrite:` from its rewrite command and `Web Search:` from its web-search
command. The Web UI sets none, so there — and for any plain typed message — the no-intent branch
runs.

A message that already contains `--- REPOSITORY CONTEXT ---` is a follow-up turn and skips
retrieval, web search and editor context entirely — which is what stops the same block stacking
down a conversation.

### Large-payload query rewriting

Above 2000 characters, a message carrying a `Path:` marker is mostly file content, and searching on
all of it retrieves noise — whatever its intent. The query becomes the file's basename plus
whatever prose follows the closing code fence — the user's actual question — and the limit becomes
5.

### Persona injection — three modes, not interchangeable

| Mode | Condition | Behaviour |
|---|---|---|
| Agent | the request carries a non-empty `tools[]` and the turn is not `Visual Rewrite:` or `Web Search:` (those have their tools stripped first) | The client's own system prompt is **never overridden** and no persona is added to it. A `CORE MANDATE` is inserted only when no system message exists; contexts are **appended** to the system message |
| Conversational | an intent was detected | The intent's persona and the contexts are **prepended** above any existing system message |
| No intent | the normal case | `prompts.FreeChat` prepended, RAG appended |

### Response cache

Keyed on the SHA-256 of the rewritten body, stored in the `llm_cache` table. A hit is returned with
an `X-Cache: HIT` header. `jenova-core sha256-selftest` asserts the digest against the published
FIPS 180-4 vectors, because a wrong hash does not fail loudly — it produces plausible digests that
silently orphan every existing entry.

---

## 3. Editor context — `src/jenova/nvimctl.nim`

For the `Editor:` intent only, the pipeline reads the document open in a running Neovim through
`nvim --server <sock> --remote-expr` and appends it as a fenced block tagged with the buffer's
`&filetype`, naming the path, the cursor line and whether there are unsaved changes.

`getline(1,"$")` returns the **buffer**, not the file, which is the entire point: unsaved edits are
what the user is looking at. An unnamed scratch buffer has no path and is not treated as a
document.

**It is never attached to a turn that did not ask for it.** It is the largest block the pipeline can
inject, and silently including it would make every unrelated question carry whatever file happened
to be open. With no editor running the turn does not fail and no editor block is injected, but it is
not a plain answer either: the `Editor` persona is still applied, and it tells the model it is
reading the file the user has open.

Each query is bounded by a 2 s deadline and the child is terminated if it expires, so a wedged
editor cannot stall the chat turn that asked.

---

## 4. Web search

`websearch.search` queries DuckDuckGo's HTML endpoint and falls back to its instant-answer API,
injecting the results as `--- WEB SEARCH RESULTS ---`. It requires `fetch(1)` or `curl` on `PATH`.

**Triggered only by a message that begins `Web Search:`.** In the desktop window the Send menu can
insert that prefix; the Web UI has no control for it, so it is typed there. It is the only path to
the internet in the Nim server and the desktop application — their other HTTP traffic goes to the
local backends. The Web UI can also connect to MCP servers you configure, which may be remote; none
is configured by default. The full list is in [privacy.md](privacy.md).

---

## 5. Workspace context — both surfaces

**This section previously said "the Web UI only".** The desktop window has had its own
server-side path since `src/jenova/workspace.nim` was written: `gui.postConversation` calls
`workspace.contextFor(folderId, projectId, workspaceId)` for the active conversation and passes
the result into `pipeline.chatBody`. The two routes differ — the Web UI gathers over `/api/db/*`
from the browser, the window reads the database in-process — and the scoping rules and the section
headings are the same. The output is not quite: the window caps the block (below), and the two
treat an empty FOCUS note differently.

What follows describes `WorkspaceService.getWorkspaceContext` in `jca_web`; `workspace.contextFor`
applies the same table.

Every note and file asset is gathered and filtered **by scope**, not by relevance:

| Conversation scope | Regular notes and files | FOCUS notes |
|---|---|---|
| Folder | that folder only | the entire workspace tree |
| Project | project root plus all its folders | the entire workspace tree |
| Workspace | workspace plus all projects and folders | same scope |
| Global / unassigned | only unassigned items | none |

**FOCUS / RULES notes traverse the whole tree regardless of the conversation's scope.** That is the
distinguishing behaviour of this system and it is deliberate: the Web UI's workspace store
auto-creates one FOCUS note per workspace, project and folder, which cannot be moved or deleted
(its content can be edited), and it is the mechanism for persistent instructions that follow the
user everywhere in a workspace. The FOCUS section comes first within the workspace block. Neither
surface adds an entry for an empty FOCUS note; the window emits nothing when every FOCUS note in
scope is empty, while the Web UI still emits the bare `--- FOCUS / RULES ---` heading. So a user who
has never typed into one sees nothing injected — correct, but it reads as a broken feature.

The result is three plain-text sections — `--- FOCUS / RULES ---`, `--- NOTES ---`,
`--- FILES ---` — appended to the system message with **no truncation and no ranking**, above which
the server then prepends the persona. The Web UI's block has no budget. The window's is capped at
64 KiB (`workspace.MaxContextBytes`), spent in the order FOCUS, notes, files: an entry that does
not fit is skipped whole rather than shortened, and a `--- N further workspace artefacts omitted to
fit the context budget ---` line counts what was left out. The Web UI attaches the block only when a
`conversationId` is supplied, so client paths that omit one send no workspace context at all.

The desktop application reaches the same result through `workspace.contextFor` rather than over
HTTP, so an unassigned chat resolves to the global scope on both surfaces — the notes and files
that belong to no workspace, which is *not* everything.

---

## 6. Per-message attachments — both surfaces

**This section previously said "the Web UI only".** The desktop window has a full attachment path:
a file picker, drag-and-drop, clipboard image paste, PDF text extraction, thumbnails and an image
preview. It writes `messages.extra` in the Web UI's own array shape, so a conversation moves
between the two surfaces without conversion, and it additionally files the attachment as a
workspace `fileAssets` row — which the Web UI does not do.

Files attached to an individual message are expanded into multimodal content parts. The window
does it in `pipeline.contentFor`: images, text files, pasted context, audio and PDFs. The Web UI
does its own expansion (`ChatService.convertDbMessageToApiChatMessageData`), which also handles MCP
prompts and resources. **These land in the user message, not the system message.** The Web UI
strips image parts from every message when the model has no vision support. The window refuses to
attach a new image once the server reports no vision, but it does not strip images already in the
conversation: `pipeline.contentFor` always sends them.

Two differences remain between the surfaces. The Web UI can send a PDF's pages as images and can
record audio; the window extracts PDF text and has no recorder. Both are tracked in
`.devdocs/02-gui-webui-parity.md`.

---

## 7. MCP tools — the Web UI only

Tool definitions come entirely from connected external MCP servers. There are **no built-in
retrieval tools** — no `read_file`, `search_code`, `grep` or `list_notes` — and the server exposes
no MCP endpoint. The default is off, with no servers configured.

---

## 8. Conversation history

**This section previously said "sent whole, never trimmed". It is trimmed.**
`pipeline.trimHistory` drops the **oldest turns first** until the branch fits a byte budget derived
from `CTX_SIZE` and `NUM_SLOTS`, and `pipeline.prepare` calls it on every chat completion. There
is still no summarisation — what does not fit is dropped, not condensed. Nor is there a retrieval
pass over history as such, though completed exchanges are in the retrieval index
(`chat/<convId>/<role>/<id>`), so a dropped earlier turn can come back as a `REPOSITORY CONTEXT` hit
when it ranks for the current question.

`llama.cpp` divides `CTX_SIZE` between `NUM_SLOTS`, so each slot gets a fraction of the configured
context. Only `Vulkan/dgpu-i5-1135g7` defaults to `NUM_SLOTS=1` (with an 8192 context); every other
shipped profile defaults to 2, and `JENOVA_SLOTS` overrides it. Both
binaries set the budget in their own process (`configureHistoryBudget`), because each runs its own
pipeline.

**Trimming used to be silent, and that was the real defect.** A user had no way to discover that
the model was never shown the start of their own conversation. A trimmed request now carries
`X-Jenova-Trimmed: N` on the response — see [usage.md](usage.md#http-api).

Branching selects which *path* through the message tree is active; that is independent of
trimming and drops nothing of its own.

---

## Summary

| # | Mechanism | Live | Trigger | Injects into |
|---|---|---|---|---|
| 1 | Server-side retrieval | ✅ both surfaces, scoped only for the window | every non-empty chat request without a context block, except `Web Search:` turns (limit 0) | System message |
| 2 | Persona | ✅ | every non-empty chat request without a context block; in agent mode only when there is no system message | System message |
| 3 | Editor context | ✅ | a message beginning `Editor:` | System message |
| 4 | Web search | ✅ | a message beginning `Web Search:` | System message |
| 5 | Workspace context | ✅ both surfaces | any send in a conversation (on the Web UI, one with a `conversationId`); an unassigned chat gets the unassigned notes and files | System message |
| 6 | FOCUS / RULES notes | ✅ both surfaces | same, tree-wide | System message — first within the workspace block, below the persona the server prepends |
| 7 | Per-message attachments | ✅ both surfaces | user attaches a file | **User** message |
| 8 | MCP tools | ⚠️ Web UI only, off by default | user configures a server | Conversation tail |
| 9 | History trimming | ✅ oldest-first, reported as `X-Jenova-Trimmed` | the branch exceeds the budget | — |
| 10 | History summarisation | ❌ not implemented | — | — |

The two open items are **MCP tools**, which is a deferred product decision rather than a gap, and
**history summarisation**, which is not implemented.

They are named rather than numbered because the two tables on this page number differently: the
first counts eight mechanisms and this one splits FOCUS notes out as their own row, so every number
from 6 down is shifted. A reference by number is ambiguous about which table it means.
