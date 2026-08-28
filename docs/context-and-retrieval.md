# Context and Retrieval

How content reaches the model. Verified against the source tree, August 2026, with `file:line`
citations throughout.

**There are two distinct systems, and only one of them currently supplies anything.** They are
routinely confused, including in this repository's own documentation and commit history, so this
document exists to keep them apart.

| | Client-side workspace context | Lua BM25 + vector retriever |
|---|---|---|
| Implementation | `jca_web/src/lib/services/workspace.service.ts:21-194` | `lib/search.lua` → `lib/proxy.lua:1267` |
| Status | **Live.** Fires on every send with a `conversationId` | **Wired but inert** — no indexer call |
| Method | Scope-based bulk inclusion + FOCUS/RULES tree propagation | Hybrid BM25 keyword + cosine similarity |
| Covers | Notes and uploaded file assets | Source code on disk |
| Injects | Full text of everything in scope | Top-N ranked snippets |
| Lands in | System message, `chat.service.ts:239-246` | System message, `lib/proxy.lua:1319/1324/1339/1344` |

They are **complementary by design, not redundant** — one covers workspace artefacts by scope, the
other covers a codebase by relevance. The `TODO` at `lib/proxy.lua:1269` flags the deduplication
question that arises once both are live.

---

## 1. Client-side workspace context — the one that works

`WorkspaceService.getWorkspaceContext(folderId, projectId, workspaceId)`.

### What it gathers

**Everything**, then filters by scope: `DatabaseService.getAllNotes()` and `getAllFileAssets()`
(`workspace.service.ts:27-30`), which hit `/api/db/notes/all` and `/api/db/fileAssets/all`
(`database.service.ts:473-475`, `:539-541`) → `lib/proxy.lua:873`, `:923` → SQLite.

### How it selects

Not semantic retrieval — **scope-based inclusion**, with one deliberate exception. Notes are split
into FOCUS and regular at `workspace.service.ts:33-34`, then four mutually exclusive branches:

| Conversation scope | Regular notes and files | FOCUS notes |
|---|---|---|
| Folder (`:40-73`) | that folder only | **entire workspace tree** (`:59-71`) |
| Project (`:74-112`) | project root + all its folders | **entire workspace tree** (`:102-111`) |
| Workspace (`:113-144`) | workspace + all projects + all folders | same scope (`:137-144`) |
| Global / unassigned (`:145-155`) | only unassigned items | none (`:154`) |

**FOCUS notes traverse the whole tree regardless of the conversation's scope.** That is the
distinguishing behaviour of this system and it is intentional — see §2.

### How it formats

Three plain-text sections (`workspace.service.ts:157-193`), with **no truncation, no ranking and no
token budget** — the `TODO` at `:26` acknowledges this:

```
--- FOCUS / RULES ---
[Workspace|Project|Folder] <title>
<content>

--- NOTES ---
Title: <title>
Content: <content>

--- FILES ---
File: <name> (Type: <type>)
Content:
<content>
```

Empty FOCUS notes are skipped (`:163`). Binary files emit
`(Binary file, content not available for direct reading)` (`:188`).

### How it is attached

`chat.service.ts:106-118` calls it when `options.workspaceContext` was not supplied **and
`conversationId` is truthy**. It is wrapped at `:182-184`, combined with `project_root`, thinking
directives (`:120-122`) and audio directives (`:123-125`) into `jcaContext` at `:233-237`, then
appended to the existing system message — or a new one is unshifted at index 0 — at `:239-246`.

### Known defects

| Defect | Site | Effect |
|---|---|---|
| Agentic path passes `conversationId: undefined` | `agentic.svelte.ts:436` | **No notes, no files, `project_root` stays `"unassigned"` for every agentic turn.** Masked today because agentic mode bails without MCP tools (`:237-242`) and `mcpServers` defaults to `"[]"` — but connecting any MCP server silently removes workspace context |
| "Continue generation" passes no `conversationId` | `chat.svelte.ts:1442` | Same loss |
| Text-file detection is MIME-based | `FilesView.svelte:137-141` | A `.ts`, `.py`, `.lua`, `.rs`, `.c` or `.h` file dragged from a file manager usually reports an empty MIME type, so its content is never stored. **The likely cause of "my files aren't in context"** |
| Whole payload polled every 30 s to compare `id:updatedAt` | `workspace.svelte.ts:47-68` | Full note bodies and base64 file contents transferred, then discarded |
| `fileAssets` has no `updatedAt` column | `lib/db.lua:135-146` | Every file keys as `id:0`, so in-place edits never trigger a refresh |

All five are remediation-plan Stage 0 and 1 items.

---

## 2. FOCUS / RULES notes

A pinned, auto-created, immutable note per container — the mechanism for persistent instructions
that follow the user everywhere in a workspace.

- **Schema:** `isFocusNote INTEGER DEFAULT 0` (`lib/db.lua:132`), migration at `:181`, persisted at
  `:782-789`.
- **Creation:** `workspace.svelte.ts:274-293` creates one titled `FOCUS / RULES` with empty content
  for every workspace, project and folder; `ensureFocusNotes()` (`:300-330`) backfills after init.
- **Immutability:** cannot be moved (`workspace.svelte.ts:162`) or deleted (`:238`).
- **Presentation:** pinned above regular notes in the sidebar (`ChatSidebar.svelte:235-236`,
  `:279-280`, `:324-325`), styled distinctly (`ChatSidebarNoteItem.svelte:22-36`).
- **Prompt effect:** emitted first, under `--- FOCUS / RULES ---`, and propagated across the whole
  workspace tree.

> Because empty FOCUS notes are skipped (`workspace.service.ts:163`), a user who has never typed
> into one sees nothing injected. That is correct behaviour, but it reads as a broken feature.

---

## 3. The Lua retriever — wired, not fed

### The call site is complete

`lib/proxy.lua:1267` calls `search.query(rag_query, rag_limit, true, local_project_root)`;
`:1271-1278` builds the `--- REPOSITORY CONTEXT ---` block; all four injection sites exist
(`:1319` agent mode, `:1324` conversational-with-intent, `:1339` and `:1344` no-intent). **None of
this is speculative code.**

### Why it returns nothing

The `index_dir` call was **deleted in commit `9d8bc08`**:

```diff
-if embed_ok then search.init_embeddings(embed) end
-search.index_dir(".", { "lua","sh","c","h","cpp","py","js","ts","go","rs", ... })
+-- Indexing moved to after server listen
```

That `+` line is `lib/proxy.lua:74` today. The intended destination, `lib/proxy.lua:1537`, contains
only:

```lua
print("[proxy] Search index deferred until project root is detected.")
```

**The move never completed.** Three independent breaks result, each individually sufficient:

1. **No indexer call.** `search.index_dir` (`lib/search.lua:511`) and `search.reindex_file` (`:458`)
   have **zero callers repo-wide**. `total_docs` is incremented only at `lib/search.lua:260`, inside
   `bm25_index_file`, reachable only from those two. So `search.query` returns `{}` at
   `lib/search.lua:759` before tokenising or embedding anything.
2. **`search.init_embeddings(embed)` is never called from the proxy.** `lib/proxy.lua:15` requires
   the module and `:63` initialises it successfully, but never hands it over — so `lib/search.lua`'s
   `embed` upvalue (`:36`) stays `nil`, and `search.load_vectors()` (whose only caller is
   `init_embeddings` at `:449`) never runs. The startup log at `lib/proxy.lua:86` prints
   `Embeddings: true` regardless.
3. **The ignition hook is a dead store.** `lib/proxy.lua:1233` writes `_G._last_project_root`;
   repo-wide grep returns exactly one hit — that write. Nothing reads it. `local_project_root` is
   used only as the `path_filter` argument to `search.query`, never to trigger indexing. The comment
   at `:1222` says as much: *"Detect project root (passive only, no auto-indexing in proxy)"*.

### Observable confirmation

`lib/proxy.lua:1379` appends `| RAG: N hits` to the dispatch log only when `#rag > 0`. **That line
has never fired.** It is a clean binary signal for whether the pipeline is alive.

Supporting evidence: `~/Jenova/.system/` does not exist and `vectors.json` has never been written on
this machine.

### Retrieval semantics, for when it is restored

- **BM25 degrades gracefully without embeddings.** `search.query` guards the vector path at
  `lib/search.lua:766` and falls back to `r.score = norm_bm25` at `:826`. It never dereferences a
  nil `embed`.
- **The reverse is impossible.** The vector path sits behind the same `total_docs` gate, which only
  BM25 indexing feeds. **Semantic search cannot run unless BM25 indexed first, in the same process.**
- `load_vectors` populates `vec_index` **only** (`lib/search.lua:434`) — never `bm25_index`, `df`,
  `avg_dl` or `total_docs`. A fully populated `vectors.json` is unreachable dead data on its own.
- `load_vectors` stores `text = ""` (`:429`), so restored chunks carry no snippet text.
- `vectors.json` is rewritten **wholesale** on every save (`:337-406`), re-serialised every 10 files
  (`:497-498`), with a 20 MB merge cap above which the on-disk index is **silently discarded**
  (`:369-372`).

Restoration is remediation-plan **Stage R**, gated on Stage 2 — `index_dir` shells out to `find`
(`lib/search.lua:527`) and `stat` per file (`:149`, `:170`), which cannot run on the event loop
until `async_popen_read` yields.

---

## 4. Server-side prompt augmentation

Everything below runs in `lib/proxy.lua` on every `POST /v1/chat/completions` (`:637`).

### Intent detection

Two sources, `:1203` and `:1236-1251`:

- **`X-Intent:` header** — **nothing in this repository ever sets it.**
- **Message-content prefixes** — `Visual Rewrite:` → `visual`, `Open File Chat:` / `Chatbot:` →
  `filechat`, `Web Search:` → `websearch`. The prefix is stripped at `:1247`.

**No client emits these prefixes either.** The only way to trigger one is to type it literally into
the chat box. In normal WebUI use `intent == nil` and the no-intent branch at `:1332` runs.

### Persona injection — always runs

Guarded by `:1253` (non-empty user message, not already carrying a `--- REPOSITORY CONTEXT ---`
block). Three branches:

| Branch | Site | Behaviour |
|---|---|---|
| Agent mode (request carried `tools[]`) | `:1308-1319` | Prepends a `CORE MANDATE` persona as a new system message if none exists; **appends** web and RAG context to `messages[1]` |
| Conversational with intent | `:1320-1331` | `prompts[intent]` + contexts **prepended** to the existing system message |
| No intent — the normal case | `:1332-1347` | `prompts.freechat` (`lib/prompts.lua:32-42`) prepended |

Net result for a normal chat, `messages[1].content` becomes:

```
prompts.freechat
  + WorkspaceService.INITIAL_IDENTITY
  + project_root: …
  + thinking / audio directives
  + [CURRENT WORKSPACE ARTIFACTS (Notes & Files)]: …
```

### Web search — works, but has no UI

`exec_web_search` (`:394-410`) → `ddg_html_search` (`:358-386`, max 5 title+snippet results) →
falls back to `ddg_instant_answer` (`:315-354`). Injected as `--- WEB SEARCH RESULTS ---` at
`:1280-1293`. Requires `fetch` or `curl` on `PATH` (`:258-277`).

**Triggered only by `intent == "websearch"`, i.e. by literally typing `Web Search:`.** There is no
button anywhere in `jca_web`. It is a hidden magic-word feature, and it is the one genuine outbound
network path in the system.

Note it forces `rag_limit = 0` (`:1254`) and clears `req_json.tools` (`:1300-1301`).

> The comment at `lib/proxy.lua:392` claims a ~13 s worst case. That is the *tool-declared* bound
> (`curl --max-time 8` + `5`). FreeBSD `fetch -T` sets a **per-operation**, not total, timeout — and
> the real backstop is `async_popen_read`'s own 15 s deadline per call, which per the scheduler's
> poke granularity can slip to ~31 s. Realistic worst case is closer to 60 s.

### FIM

`:1405-1409` performs no injection. The comment notes RAG context could be added there later.

---

## 5. Per-message attachments

A separate path from workspace file assets. Files attached to an individual message are expanded by
`ChatService.convertDbMessageToApiChatMessageData` (`chat.service.ts:802-979`) into multimodal
content parts: images (`:856-861`), text files (`:868-873`), pasted context (`:883-892`), audio
(`:899-907`), PDFs as text or page images (`:914-932`), MCP prompts (`:939-949`) and MCP resources
(`:956-966`). Text is wrapped by `formatAttachmentText` (`jca_web/src/lib/utils/formatters.ts:147-155`).

**These land in the user message, not the system message.** Images are stripped when the model lacks
vision (`chat.service.ts:151-176`).

---

## 6. MCP tools

Tool definitions come **entirely from connected external MCP servers**
(`mcp.svelte.ts:1035-1058`). There are **no built-in retrieval tools** — no `read_file`,
`search_code`, `grep` or `list_notes` anywhere in `jca_web/src/lib/**` or `lib/**` — and
`lib/proxy.lua` exposes no MCP endpoint.

Default is off: `mcpServers: "[]"` (`jca_web/src/lib/constants/settings-config.ts:32`).

> ⚠️ **Connecting an MCP server currently disables workspace context** — see the `agentic.svelte.ts:436`
> defect in §1.

---

## 7. Conversation history

**No summarisation, no truncation, no retrieval over history.** `chat.svelte.ts:602` sends
`conversationsStore.activeMessages.slice(0, -1)` — the entire active branch, every turn. Branching
(`jca_web/src/lib/utils/branching.ts`) selects which *path* through the message tree is active but
drops nothing from it.

The only reduction is `excludeReasoningFromContext` (`chat.service.ts:257-259`), which omits
`reasoning_content` from prior turns.

Context overflow surfaces as a server error carrying `contextInfo: { n_prompt_tokens, n_ctx }`
(`chat.svelte.ts:617-620`, `:902-905`). With the current profile (`-np 2 -c 32768`) each slot gets
16,384 tokens, because llama.cpp splits context per slot.

---

## Summary

| # | Mechanism | Live | Trigger | Injects into |
|---|---|---|---|---|
| 1 | Workspace context | ✅ | Automatic, any send with a `conversationId` | System message |
| 2 | FOCUS / RULES notes | ✅ | Same, tree-wide | System message, first |
| 3 | Persona | ✅ | Automatic, every non-empty request | System message, server-side |
| 4 | Per-message attachments | ✅ | User attaches a file | **User** message |
| 5 | Web search | ⚠️ code works, no UI | Typing `Web Search:` | System message |
| 6 | MCP tools | ⚠️ off by default | User configures a server | Conversation tail |
| 7 | Lua BM25 + vector retriever | ❌ inert | — | — |
| 8 | History summarisation | ❌ not implemented | — | — |

Restoration work is tracked as **Stage R** in
[`remediation-plan.md`](remediation-plan.md); the client-side defects in §1 are **Stage 0** items
0.8–0.10.
