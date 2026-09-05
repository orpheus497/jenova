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
| 1 | Server-side retrieval (BM25 + vectors) | `src/jenova/rag.nim` | **Live, and populated** — see §1 |
| 2 | Persona and context injection | `src/jenova/pipeline.nim` | Live on every chat completion |
| 3 | Editor context | `src/jenova/nvimctl.nim` | Live, and **only** for the `Editor:` intent |
| 4 | Web search | `src/jenova/websearch.nim` | Live, and only for the `Web Search:` intent |
| 5 | Workspace context | `src/jenova/workspace.nim` + `jca_web` | Live on **both** surfaces |
| 6 | Per-message attachments | `src/jenova/pipeline.nim` + `jca_web` | Live on **both** surfaces |
| 7 | MCP tools | `jca_web` | Web UI only, off by default |
| 8 | Conversation history | `src/jenova/pipeline.nim` | **Trimmed oldest-first** to fit the context budget |

Mechanisms 1–4 and 8 are server-side and apply to **every** client — the desktop window, the Web
UI and any OpenAI-compatible client pointed at `:8080`. Mechanism 5 exists on both surfaces but by
two different routes; 6 likewise. Only mechanism 7 is still Web UI only.

---

## 1. Server-side retrieval — `src/jenova/rag.nim`

### Storage

Both indexes live in SQLite, alongside the workspace database, so they survive a restart and every
thread gets its own connection:

| Table | Holds |
|---|---|
| `rag_documents` | one row per indexed path, with `mtime`, `size` and the time it was indexed |
| `rag_chunks` | chunk text, its starting line, and its embedding as a float32 little-endian `BLOB` |
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

`rag.embed` posts to `/v1/embeddings` on the embedding server (`127.0.0.1:8082`) in batches of 8,
and unit-normalises each vector so similarity is a plain dot product. An unreachable server returns
an empty result, which is a **supported** state: chunks are stored without vectors, keyword search
still works, and every chunk still carries its text for snippets.

Each batch contributes exactly one vector slot per chunk it was given, padding with an empty vector
where the server returned fewer than it was asked for. Without that padding the vectors shifted
against the chunks and each remaining chunk was stored with a different chunk's embedding.

### Query

`rag.query(queryStr, topK, withSnippets, pathFilter)`:

1. **Keyword.** The query is tokenised, each term quoted and the terms OR'd into an FTS5 `MATCH`,
   scored by FTS5's own `bm25()`. FTS5 returns a *more negative* score for a better match, so it is
   negated. This is a correct BM25 over a persisted index rather than the hand-rolled
   k1=1.5/b=0.75 loop `search.lua` ran over an in-memory one.
2. **Semantic.** Every chunk with a vector is scored by dot product against the query embedding.
   A chunk at or below `SemanticFloor` (0.3) is not a hit at all. The best chunk per path wins, and
   its start line becomes the hit's line.
3. **Mix.** Both families are normalised **by the maximum within this result set** and weighted
   0.4 keyword / 0.6 semantic. Normalising against the set rather than an absolute scale is what
   makes BM25 and cosine comparable, since they share no range. With no embedder available the
   score is the normalised keyword score alone.
4. **Filter.** `pathFilter` matches a path exactly or as a directory prefix.
5. **Snippets.** The chunk at the hit's start line, truncated at 1000 characters; the file's first
   chunk if that lookup finds nothing.

### What fills the index

**This section previously said the index was never populated. That has not been true for some
time** — the writers below all exist, and the `--- REPOSITORY CONTEXT ---` block does appear in
real requests.

| Writer | When |
|---|---|
| `api.upsert` → `rag.indexNote` / `rag.indexFileAsset` | **Every note and file asset saved on either surface.** Hooked at `upsert` rather than in each client, because that is the one layer the Web UI's `/api/db/*` route and the window's in-process `putEntity` both pass through |
| `api.handleDb` → `rag.indexExchange` | Every message the Web UI creates or edits, on the `/api/db/messages` route |
| `api.restoreEntity` | Anything restored from the trash is re-indexed — a message, a conversation, a note, a file |
| `gui.ctlWorker` → `rag.indexExchange` | Each completed exchange in the desktop window, on a worker thread so the embedding round trip never touches the GTK loop |
| `rag.backfillChats`, `rag.backfillWorkspace` | Once at every `jenova-core serve` start, and once in the window as soon as the embedding server answers — **not before**, or content would be indexed while the embedder is still loading and stored keyword-only |

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

The keyword half is capped at 200 documents by FTS5. The semantic half scores chunk vectors in
SQLite, newest first, up to `rag.MaxVectorScan` (50,000 chunks) — a ceiling rather than a working
size, since a chunk is 300 words and an ordinary install never reaches it. Past that ceiling a
document is still findable by its words; only its vector is out of scope.

---

## 2. The completion pipeline — `src/jenova/pipeline.nim`

`pipeline.prepare` runs on every `POST /v1/chat/completions`, and **the order is part of the
contract**:

1. **Intent detection.** A prefix on the last user message, stripped after matching so the model
   never sees the marker.
2. **Retrieval** at a per-intent result limit, with a rewritten query for large file-chat payloads.
3. **RAG injection** as a `--- REPOSITORY CONTEXT ---` block.
4. **Web search**, for the websearch intent only.
5. **Editor context**, for the `Editor:` intent only.
6. **Persona injection**, in one of three modes.
7. **Tool stripping**, for the two intents that gain nothing from tools.
8. **Cache key** — SHA-256 of the **rewritten** body.

The cache key must stay last: hashing the client's original body would produce a different key and
orphan every entry already written.

A body with no `messages` passes through untouched, so `/completion` and `/infill` — the Neovim FIM
path — reach `llama-server` byte for byte.

### Intents

| Prefix | Intent | Effect |
|---|---|---|
| `Visual Rewrite:` | visual | 1 retrieval hit; tools stripped and `tool_choice` forced to `none` |
| `Open File Chat:`, `Chatbot:` | filechat | 3 hits, or 5 for a large payload |
| `Web Search:` | websearch | 0 retrieval hits — its context comes from the web; tools stripped |
| `Editor:` | editor | 3 hits, plus the live Neovim buffer |
| *(none)* | none | 3 hits, freechat persona |

**Nothing in this repository sets these prefixes for you.** They are typed literally into the
message. In ordinary use the no-intent branch runs.

A message that already contains `--- REPOSITORY CONTEXT ---` is a follow-up turn and skips
retrieval, web search and editor context entirely — which is what stops the same block stacking
down a conversation.

### Large-payload query rewriting

Above 2000 characters, a message carrying a `Path:` marker is mostly file content, and searching on
all of it retrieves noise. The query becomes the file's basename plus whatever prose follows the
closing code fence — the user's actual question.

### Persona injection — three modes, not interchangeable

| Mode | Condition | Behaviour |
|---|---|---|
| Agent | the request carries a non-empty `tools[]` | The client's own system prompt is **never overridden**. A `CORE MANDATE` is inserted only when no system message exists; contexts are **appended** to it |
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
to be open. With no editor running the intent degrades to a plain answer rather than failing.

Each query is bounded by a 2 s deadline and the child is terminated if it expires, so a wedged
editor cannot stall the chat turn that asked.

---

## 4. Web search — works, no button

`websearch.search` queries DuckDuckGo's HTML endpoint and falls back to its instant-answer API,
injecting the results as `--- WEB SEARCH RESULTS ---`. It requires base `fetch(1)` or `curl` on
`PATH`.

**Triggered only by typing `Web Search:`.** There is no button anywhere. It is the one genuine
outbound network path in the system — see [privacy.md](privacy.md).

---

## 5. Workspace context — both surfaces

**This section previously said "the Web UI only".** The desktop window has had its own
server-side path since `src/jenova/workspace.nim` was written: `gui.postConversation` calls
`workspace.contextFor(folderId, projectId, workspaceId)` for the active conversation and passes
the result into `pipeline.chatBody`. The two routes differ — the Web UI gathers over `/api/db/*`
from the browser, the window reads the database in-process — but the scoping rules and the output
format are the same, which is what makes a conversation read identically on either surface.

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
distinguishing behaviour of this system and it is deliberate: one pinned, auto-created, immutable
note per container, emitted first, which is the mechanism for persistent instructions that follow
the user everywhere in a workspace. An empty one is skipped, so a user who has never typed into one
sees nothing injected — correct, but it reads as a broken feature.

The result is three plain-text sections — `--- FOCUS / RULES ---`, `--- NOTES ---`,
`--- FILES ---` — appended to the system message with **no truncation, no ranking and no token
budget**. It is attached only when a `conversationId` is supplied, so client paths that omit one
send no workspace context at all.

The desktop application reaches the same result through `workspace.contextFor` rather than over
HTTP, so an unassigned chat resolves to the global scope on both surfaces — which is *not*
everything.

---

## 6. Per-message attachments — both surfaces

**This section previously said "the Web UI only".** The desktop window has a full attachment path:
a file picker, drag-and-drop, clipboard image paste, PDF text extraction, thumbnails and an image
preview. It writes `messages.extra` in the Web UI's own array shape, so a conversation moves
between the two surfaces without conversion, and it additionally files the attachment as a
workspace `fileAssets` row — which the Web UI does not do.

Files attached to an individual message are expanded into multimodal content parts by
`pipeline.contentFor`: images, text files, pasted context, audio, PDFs, and (in the Web UI) MCP
prompts and resources. **These land in the user message, not the system message.** Images are
stripped when the model has no vision support.

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
is still no summarisation and no retrieval over history — what does not fit is dropped, not
condensed.

`llama.cpp` divides `CTX_SIZE` between `NUM_SLOTS`, so each slot gets a fraction of the configured
context — which is why the profiles that want a wide single conversation set `NUM_SLOTS=1`. Both
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
| 1 | Server-side retrieval | ✅ both surfaces | every non-empty chat request without a context block | System message |
| 2 | Persona | ✅ | every non-empty chat request | System message |
| 3 | Editor context | ✅ | typing `Editor:` | System message |
| 4 | Web search | ✅ | typing `Web Search:` | System message |
| 5 | Workspace context | ✅ both surfaces | any send within a workspace scope | System message |
| 6 | FOCUS / RULES notes | ✅ both surfaces | same, tree-wide | System message, first |
| 7 | Per-message attachments | ✅ both surfaces | user attaches a file | **User** message |
| 8 | MCP tools | ⚠️ Web UI only, off by default | user configures a server | Conversation tail |
| 9 | History trimming | ✅ oldest-first, reported as `X-Jenova-Trimmed` | the branch exceeds the budget | — |
| 10 | History summarisation | ❌ not implemented | — | — |

The two open items are **MCP tools**, which is a deferred product decision rather than a gap, and
**history summarisation**, which is not implemented.

They are named rather than numbered because the two tables on this page number differently: the
first counts eight mechanisms and this one splits FOCUS notes out as their own row, so every number
from 6 down is shifted. A reference by number is ambiguous about which table it means.
