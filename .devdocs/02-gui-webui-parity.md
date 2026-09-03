# Report 02 — GUI ↔ Web UI Parity Audit

**Status:** open tracker
**Rulings in force** (session 2): `jca_web` is **frozen** — no Web-side change may be proposed as a
fix. Push/Pull is **out of scope for the GUI** and is not to be built there. **MCP and TTS are
deferred** to future planning, so P-A1, P-A2, P-A4 and W-04 are parked rather than open.
**Last worked:** session 2
**Goal being tracked:** the GTK4 desktop window (`bin/jenova`) reaches **1:1 parity** with
the SvelteKit Web UI (`jca_web`), then exceeds it, and becomes the primary surface.
**Method:** the Web UI's feature surface was enumerated from its stores, services, route
tree and component tree; the GUI's from `src/jenova/gui.nim` and the modules it links.
Every gap below cites the source on both sides. Nothing is asserted from a screenshot.
**Audited at commit:** `c5111ce`

---

## 0. Scale of the two surfaces

| | Web UI | Desktop window |
|---|---|---|
| Implementation | `jca_web/src` — ~19.6k lines of Svelte + ~13.3k lines of stores/services | `src/jenova/gui.nim` — 5,212 lines, plus linked modules |
| Chat transport | `fetch` → `:8080/v1/chat/completions` | raw socket → `127.0.0.1:$PORT/v1/chat/completions` (`src/jenova/gui.nim:272-397`) |
| Persistence | server SQLite via `/api/db/*` | the **same** `api.nim` procs, called in-process |
| Tool/agent loop | client-side, in `agentic.svelte.ts` (772 lines) | none |

Both surfaces therefore share the pipeline, personas, retrieval, cache and database. The
gaps are almost entirely **client-side features the Web UI implements in the browser**,
not server capabilities the GUI cannot reach.

---

## 1. Parity matrix

Legend: **=** parity · **~** partial · **✗** absent in GUI · **+** GUI ahead of Web UI

### 1.1 Chat

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| Token streaming | ✔ | ✔ | = | `src/jenova/gui.nim:340-377` |
| TPS / TTFT / prompt / cache-n stats | ✔ | ✔ | = | `src/jenova/gui.nim:2958-3055` |
| `X-Cache: HIT` badge | ✔ | ✔ | = | `src/jenova/gui.nim:328-333` |
| Reasoning (`reasoning_content`) block | ✔ | ✔ | = | `src/jenova/gui.nim:356-359`, `:3495` |
| Stop mid-generation | ✔ | ✔ | = | `src/jenova/gui.nim:266-271` (atomic fd + `shutdown(2)`) |
| Edit a user turn | ✔ | ✔ | = | `src/jenova/gui.nim:2083-2149` |
| Regenerate | ✔ | ✔ | = | `src/jenova/gui.nim:2150` |
| Continue (opt-in) | ✔ | ✔ | = | `src/jenova/gui.nim:2167`, gated on `enableContinueGeneration` |
| Branch/sibling navigation | ✔ | ✔ | = | `src/jenova/gui.nim:3062-3079` |
| Delete a message (cascade) | ✔ | ✔ | = | `src/jenova/gui.nim:2027` |
| Copy | ✔ | ✔ | = | `src/jenova/gui.nim:3081-3085` |
| Raw-output toggle | ✔ | ✔ | = | `src/jenova/gui.nim:3086-3095` |
| Auto-scroll follow + disable | ✔ | ✔ | = | `src/jenova/gui.nim:3298-3300` |
| Conversation auto-title from first message | ✔ | ✔ | = | `src/jenova/gui.nim:1835` |
| **Fork from a specific message** | ✔ | ✗ | **P-A6** | `ChatMessageActions.svelte:31,73-84` vs GUI fork is conversation-level only (`src/jenova/gui.nim:3163`) |
| **Fork options (name, include attachments)** | ✔ | ✗ | **P-A6** | `ChatMessageActions.svelte:69-71` vs `api.forkConversation(id,"","")` |
| **Speak a reply (TTS)** | ✔ | ✗ | **P-A4** | `ChatMessageAssistant.svelte:110-120`, `audio.service.ts:27` |
| **Microphone / audio input** | ✔ | ✗ | **P-A3** | `ChatFormActionRecord.svelte`, `utils/audio-recording.ts` |
| **Error dialog with detail** | ✔ | ~ | **P-B1** | `DialogChatError.svelte` vs a one-line notice + Retry (`src/jenova/gui.nim:4870-4900`) |
| **Processing-state indicator** | ✔ | ~ | **P-B2** | `ChatScreenProcessingInfo.svelte` (119 lines) vs a status subtitle |

### 1.2 Content rendering

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| GFM markdown | ✔ | ~ | **P-B3** | See the correction below — much closer than first reported, and now closer still |
| Syntax highlighting | ✔ highlight.js | ✔ GtkSourceView | = | `src/jenova/sourceview.nim` |
| **KaTeX / LaTeX math** | ✔ | ✗ | **P-A5** | `jca_web/src/styles/katex-custom.scss`, `utils/latex-protection.ts` — **no math handling anywhere in `src/`** |
| Code-block copy / preview | ✔ | ~ | **P-B4** | `ActionIconsCodeBlock.svelte`, `DialogCodePreview.svelte` vs GUI copy only |
| Full-height code blocks setting | ✔ | ✔ | = | `src/jenova/gui.nim:2885` |
| Render user content as markdown | ✔ | ✔ | = | `src/jenova/gui.nim:2910` |
| Image attachment preview | ✔ | ✔ | = | `src/jenova/gui.nim:4359` |
| **In-app PDF viewing** | ✔ pdfjs | ✗ | **P-A7** | GUI extracts text only (`src/jenova/pdf.nim`) |

### 1.3 Attachments

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| File picker | ✔ | ✔ | = | `src/jenova/gui.nim:1859` |
| Drag and drop | ✔ | ✔ | = | `DropZone`, `src/jenova/gui.nim:2585`, `:4838` |
| Clipboard image paste | ✔ | ✔ | = | `src/jenova/gui.nim:2559` |
| Image thumbnails | ✔ | ✔ | = | `src/jenova/gui.nim:1891` |
| PDF text extraction | ✔ | ✔ | = | `src/jenova/pdf.nim` |
| Written to `messages.extra` in Web UI shape | ✔ | ✔ | = | `src/jenova/gui.nim:1923-1938` |
| Filed as a workspace `fileAssets` row | — | ✔ | **+** | `src/jenova/gui.nim:1956` — the Web UI does not do this |
| **`pdfAsImage` (PDF pages as images)** | ✔ | ✗ | **P-C1** | setting exists, unwired |
| **`pasteLongTextToFileLen`** | ✔ | ✗ | **P-C1** | setting exists, unwired |
| **`copyTextAttachmentsAsPlainText`** | ✔ | ✗ | **P-C1** | setting exists, unwired |
| **Audio attachments** | ✔ | ✗ | **P-A3** | `contentFor` can *send* `AUDIO` parts (`src/jenova/pipeline.nim:737`) but the GUI cannot create one |
| Attachment "view all" sheet | ✔ | ~ | **P-B5** | `ChatAttachmentsViewAll.svelte` vs an inline chip strip |

### 1.4 Workspace tree

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| Workspace / project / folder / chat / note CRUD | ✔ | ✔ | = | `src/jenova/gui.nim:1593-1744` |
| Cascade-aware delete confirmation | ~ | ✔ | **+** | `api.cascadeCount` (`src/jenova/api.nim:98`) — the GUI names what a delete takes |
| Search chats + notes + files | ✔ | ✔ | = | `src/jenova/gui.nim:4724-4732` |
| Note editor with dirty-state guard | ✔ | ✔ | = | `src/jenova/gui.nim:1456-1574` |
| FOCUS-note pin | ✔ | ✔ | = | `src/jenova/gui.nim:3335` |
| Trash view + restore + empty | ✔ | ✔ | = | `src/jenova/gui.nim:4013` |
| **Open / preview / download a file asset** | ✔ | ✗ | **P-A8** | `FilesView.svelte` (559 lines), `VFSExplorer.svelte` (216). GUI row is inert: `sensitive = entity == "notes"` (`src/jenova/gui.nim:3213`) |
| **Dedicated `/files` and `/trash` pages** | ✔ | ~ | **P-B6** | Web has four route trees under `src/routes/files/` |
| **Move / reparent an item** | ✗ | ✗ | **P-E2** | absent from *both* — a parity-neutral gap and a "GUI goes further" candidate |

### 1.5 Models, hardware, backend

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| Model list + switch | ~ | ✔ | **+** | GUI: `src/jenova/gui.nim:4275`. Web's load/unload targets endpoints this server does not serve — see **P-C2** |
| Model information (modalities, context) | ✔ | ~ | **P-B7** | `DialogModelInformation.svelte` (251 lines) vs the GUI panel's row summary |
| Favourite models | ✔ | ✗ | **P-B8** | `FAVORITE_MODELS_LOCALSTORAGE_KEY` |
| **Hardware profile detection + apply** | ✗ | ✔ | **+** | `src/jenova/gui.nim:4145`, `src/jenova/hardware.nim` (436 lines) |
| **Backend start / stop / restart** | ✗ | ✔ | **+** | `src/jenova/gui.nim:4589-4601` |
| **Live per-backend health** | ✗ | ✔ | **+** | `src/jenova/gui.nim:820-830` |
| **LAN toggle + address display** | ✗ | ✔ | **+** | `src/jenova/gui.nim:4520-4531`, `:4626` |
| **System tray (StatusNotifierItem)** | ✗ | ✔ | **+** | `src/jenova/tray.nim` (414 lines) |
| **Embedded Neovim page** | ✗ | ✔ | **+** | `src/jenova/vte.nim`, `src/jenova/nvimctl.nim` |
| **`Editor:` live-document intent** | ✗ | ✔ | **+** | `src/jenova/pipeline.nim:403-408` |

### 1.6 Settings

`src/jenova/settings.nim` defines 39 fields; `jca_web/src/lib/constants/settings-config.ts`
defines 48. The GUI covers every shared field. The delta:

| Web key | In GUI | Why / tracker |
|---|---|---|
| `serverUrl` | ✗ | **deliberate**, documented at `src/jenova/settings.nim:369-374` — the window *is* the server |
| `apiKey` | ✗ | **deliberate**, `src/jenova/settings.nim:366` — no authentication exists |
| `showSystemMessage` | ✗ | **P-B9** |
| `mcpServers`, `mcpServerUsageStats` | ✗ | **P-A1** |
| `agenticMaxTurns`, `agenticMaxToolPreviewLines`, `showToolCallInProgress`, `alwaysShowAgenticTurns` | ✗ | **P-A2** |
| `useThinking` | ✗ | **P-B10** |
| `useAudioVoice` | ✗ | **P-A4** |

---

## 2. Class A — subsystems absent from the GUI

### P-A1 — MCP client · size: very large · blocks 1:1 parity

The Web UI ships a complete Model Context Protocol client:
`stores/mcp.svelte.ts` (2,129 lines), `stores/mcp-resources.svelte.ts` (639),
`services/mcp.service.ts` (880), plus ~20 components under
`components/app/mcp/` and the resource/prompt pickers in the composer.
Capabilities: server registration and connection, tool listing and invocation,
resource browsing and preview, URI-template resources, prompt templates with typed
arguments, connection logs, per-conversation server overrides
(`conversations.mcpServerOverrides`, `src/jenova/db.nim:325`).

The Nim side has **no MCP implementation at all**. `mcp` appears in `src/` only as:
the `mcpServerOverrides` column (`src/jenova/api.nim:49`), and the settings note recording
its deliberate exclusion (`src/jenova/settings.nim:367-368`, *"the whole MCP section is
excluded by the USER; MCP is deferred (SETTLED FACT)"*).

**This is the single largest parity gap and it is a decision, not an oversight.** Nothing
should be built here until that ruling is revisited. If it is revisited, the correct
architecture is almost certainly a **server-side MCP client in `src/jenova/`** driving the
pipeline — which would give the Web UI a working remote transport (see P-C2) and the GUI
MCP at once, instead of two clients.

### P-A2 — Agentic tool loop · size: large

`stores/agentic.svelte.ts` (772 lines) implements multi-turn tool calling entirely in the
browser: streaming with tool-call detection, execution through `mcpStore`, one DB message
per LLM turn plus one per tool result, turn limits, per-turn timing statistics
(`ChatMessageAgenticContent.svelte`, 333 lines).

`grep -rn 'agentic' src/` returns **nothing**. The `messages.toolCalls` column exists
(`src/jenova/api.nim:52`) and the GUI never reads or writes it.

Note the coupling: the agentic loop is only useful with tools, and tools only come from
MCP. P-A2 is downstream of P-A1.

### P-A3 — Audio capture · size: medium

Web: `ChatFormActionRecord.svelte`, `services/audio.service.ts`, `utils/audio-recording.ts`,
gated by the `autoMicOnEmpty` setting.
GUI: the `autoMicOnEmpty` setting is **present and does nothing** — see P-C1.
`pipeline.contentFor` can already emit `input_audio` parts (`src/jenova/pipeline.nim:737`),
so the send path exists; only capture is missing.

### P-A4 — Speech synthesis (read a reply aloud) · size: small

Web: `ChatMessageAssistant.svelte:110-120` via `window.speechSynthesis`, plus the
`useAudioVoice` setting.
GUI: absent. A GTK equivalent needs an external synthesiser; on FreeBSD this means a
process invocation, which conflicts with the "the GUI spawns no shell at all" property
stated at `src/jenova/gui.nim:26`. **Flag for a ruling before any work.**

### P-A5 — Math rendering (KaTeX) · size: medium

Web renders LaTeX via KaTeX with dedicated protection passes
(`utils/latex-protection.ts`, `constants/latex-protection.ts`, `styles/katex-custom.scss`).
`src/jenova/markdown.nim` has no math concept; `$…$` and `\[…\]` render as literal text.
For a system whose stated purpose is helping the user think, this is a real content gap.

### P-A6 — Fork from a message, with options · size: small

Web forks from any message with a name and an `includeAttachments` choice
(`ChatMessageActions.svelte:31,69-84`). The GUI forks only whole conversations from the
sidebar row, always unnamed (`src/jenova/gui.nim:3163-3174`). `api.forkConversation`
already takes name and target parameters, so this is a UI-layer gap only.

### P-A7 — PDF viewing · size: medium
### P-A8 — File-asset access · size: medium

`src/jenova/gui.nim:3213` — `sensitive = entity == "notes"`. A `fileAssets` row in the GUI
tree is a **dead button**: it can be renamed and deleted but never opened, previewed,
exported or read. The comment above it explains the choice ("a file asset has no editor to
open, because its content may be binary"), but the effect is that files attached to a chat
— which the GUI itself now writes (`src/jenova/gui.nim:1956`) — are write-only from the
window that wrote them. The Web UI has a full explorer for the same rows.

---

## 3. Class B — partial implementations

| ID | Gap | Web | GUI | Size |
|---|---|---|---|---|
| P-B1 | Error surface: dialog with the server's own detail, vs a single truncated notice line | `DialogChatError.svelte` | `src/jenova/gui.nim:4874-4900` | S |
| P-B2 | Processing-state detail while generating | `ChatScreenProcessingInfo.svelte` | status subtitle only | S |
| P-B3 | Markdown coverage — **restated, see the correction below** | remark→rehype | most of it, and more since session 2 | S (remaining) |
| P-B4 | Per-code-block copy button and a preview dialog | `ActionIconsCodeBlock`, `DialogCodePreview` | message-level copy only | S |
| P-B5 | Attachment "view all" surface | `ChatAttachmentsViewAll.svelte` | inline chip strip | S |
| P-B6 | Dedicated Files/Trash pages vs overlay panels | `src/routes/files/**` | overlay panels | M |
| P-B7 | Model information detail (modalities, parameters, quantisation) | `DialogModelInformation.svelte` | row summary | S |
| P-B8 | Favourite / pinned models | localStorage | — | S |
| P-B9 | Show the system message in the transcript | `showSystemMessage` | `rSystem` renders but no toggle | S |
| P-B10 | `useThinking` request toggle | setting | — | S |
| P-B11 | Selective export (choose conversations) | `DialogConversationSelection` | `api.exportAll()` only (`src/jenova/gui.nim:3587`) | S |
| P-B12 | Keyboard shortcuts | several, documented in-app | **exactly one: `F11`** (`src/jenova/gui.nim:3151`) | M |

### Correction — P-B3 as first written was wrong

**The original text said "three block kinds means every ordered list, bullet list, heading, block
quote and inline link renders as raw text". That is false**, and it was reached by reading the
`BlockKind` enum without reading `lineMarkup` beneath it. `markdown.nim` already handled headings
h1–h3, bullets, task lists with rendered check boxes, block quotes, and links and images behind a
scheme allowlist — all as Pango markup inside a `bkText` block, which is why the enum has three
cases and not eight.

What was **actually** missing, verified line by line:

| Gap | Status |
|---|---|
| Ordered lists (`1. `, `2) `) — rendered as their own source text | **fixed**, session 2 |
| Nested list indentation — `lineMarkup` stripped the indent before measuring it, so every outline rendered flat | **fixed**, session 2 |
| Headings h4–h6 — fell through and rendered their own hashes | **fixed**, session 2 |
| Horizontal rules (`---`, `***`, `___`) | **fixed**, session 2 |
| `+ ` bullets | **fixed**, session 2 |
| Math / KaTeX | still absent — that is P-A5, and it is the real remaining gap |

Twenty-five assertions cover the new behaviour in `markdown-selftest`, including that the branches
which already worked still do. The change is parser-only: no widget-tree change, which is where
this project has had its crashes.

**P-B12 carries a structural hazard.** `owlkettle`'s `Button.shortcut` has no update path —
it builds a `GtkShortcutController` once and its update hook asserts the value never
changed (`src/jenova/gui.nim:3336-3340`). Two separate defects have already been caused by
changing the child count of a container holding the one shortcut-carrying button
(`src/jenova/gui.nim:3327-3340`, `:4918-4924`). **Adding shortcuts requires fixing the
mechanism first** — a window-level `GtkShortcutController` — not adding more
shortcut-carrying buttons.

---

## 4. Class C — false implementations, dead surfaces, stale claims

### P-C1 — Three settings are drawn, saved, and connected to nothing · severity: high

`src/jenova/settings.nim` marks these `awaiting: "attachments — PLANS.md Step 7b (G-30)"`:

| Key | Def | Consumers in `src/` outside `settings.nim` |
|---|---|---|
| `pasteLongTextToFileLen` | `src/jenova/settings.nim:105-111` | **0** |
| `copyTextAttachmentsAsPlainText` | `src/jenova/settings.nim:112-118` | **0** |
| `pdfAsImage` | `src/jenova/settings.nim:126-131` | **0** |

Attachments (G-30) have shipped in full — file picker, drop zone, paste, PDF extraction,
thumbnails, preview. The blocker these three name **no longer exists**, so they now read
as work that was forgotten rather than deferred. A user setting `pdfAsImage` gets no
behaviour change and no warning beyond a stale sentence.

A fourth, `autoMicOnEmpty` (`src/jenova/settings.nim:157-163`, `awaiting: "audio capture"`),
is honestly blocked — its blocker (P-A3) is real.

**Fix:** wire the three, or if they are to stay deferred, update `awaiting` to name the
actual remaining blocker. The self-test at `src/jenova_core.nim:2773-2774` asserts these
strings are non-empty, so it will keep passing either way — the assertion checks that a
reason exists, not that it is true.

### P-C2 — The Web UI calls three endpoints this server does not implement · severity: medium

`jca_web/src/lib/constants/api-endpoints.ts`:

```
export const API_MODELS = { LIST: "/v1/models", LOAD: "/models/load", UNLOAD: "/models/unload" };
export const CORS_PROXY_ENDPOINT = "/cors-proxy";
```

`/v1/models` is forwarded (matches the `/v1/` prefix). The other three are not:
`routes.classify` has no case for `/models/` or `/cors-proxy`, so both fall to `rcStatic`
and `serveStatic` answers `404 text/plain` (`src/jenova/server.nim:160-163`).

* `/models/load`, `/models/unload` — called from `services/models.service.ts:75,87`, only
  reachable in ROUTER mode. `serverStore.detectRole` (`stores/server.svelte.ts:148-150`)
  only enters ROUTER mode when `/props` reports `role: "router"`, which single-model
  `llama-server` never does. **Currently unreachable dead code, not a live break** — but it
  is a live break the moment anyone puts a router in front.
* `/cors-proxy` — `mcpStore.probeProxy` (`stores/mcp.svelte.ts:114`) HEADs it at
  construction, gets 404, and sets `_proxyAvailable = false`. The failure is graceful, but
  the consequence is real: **every remote MCP server that needs the proxy is unusable in
  the shipped Web UI**, silently. The comment at `stores/mcp.svelte.ts:110` names an
  upstream flag (`--webui-mcp-proxy`) that this server has never had.

### P-C3 — Sidebar "Push" / "Pull" are vestigial and can move data backwards · **PARKED**

> **Ruling, session 2:** `jca_web` is frozen, so the Web UI's buttons stay as they are, and
> Push/Pull is explicitly **not** to be built into the GUI — it is unnecessary there, because the
> window *is* the server and has no separate store to synchronise. The analysis below is kept as
> the record of why, not as work to do.
>
> The window's "Sync notes from disk" (`gui.pullNotesFromDisk` → `api.pullNotes`) already covers
> the one case that is real on a single-process surface: a note edited outside the window, in the
> embedded Neovim or another editor, coming back into the database.



`ChatSidebarActions.svelte:33-59` renders two prominent sidebar buttons (visible in both
README screenshots). Their implementation:

* **Push** (`services/sync.service.ts:102-121`) — documented as *"Pushes current IndexedDB
  state"*. IndexedDB is gone; `jca_web/README.md` already flags that comment class as
  stale. What it actually does: `DatabaseService.exportData()` (a full read of the server's
  own database over `/api/db/*`), then `StorageService.save("jenova-snapshot.json", …)`,
  which POSTs the entire database as JSON into the workspaces tree via `/api/storage`.
* **Pull** (`services/sync.service.ts:127+`) — reads that snapshot back and calls
  `DatabaseService.importData(data)`, then reloads the page.

`api.importData` (`src/jenova/api.nim:641-662`) is an upsert inside one transaction, so it
merges rather than replacing — it will not delete anything. But it **will** overwrite rows
edited since the snapshot and un-delete soft-deleted rows. A round trip through the server's
own storage to reach the server's own database is a leftover from the browser-persistence
era, and the buttons give no indication of what they overwrite.

The GUI's nearest equivalent — "Sync notes from disk" (`src/jenova/gui.nim:4495` →
`api.pullNotes`) — is the correct shape: narrow, named for what it does, and reporting a
count.

**Decide:** remove Push/Pull from the Web UI, or re-specify them as an explicit
backup/restore with a confirmation naming what will be overwritten.

### P-C4 — WITHDRAWN. The Models panel already explains itself · severity: none

The original finding claimed an "empty Models panel with no explanation". It is wrong.
`gui.modelsPanel` (`src/jenova/gui.nim`) already carries an empty state naming **both** directories
it searched:

> *No .gguf files in `<JCA_HOME>`/models/instruct or `<JCA_HOME>`/models/thinking.*

with the comment above it making exactly the argument the finding was about to make: *"name both
folders that were actually looked in. 'No models found' over a tree the user knows has models in
it is the report that sends them looking in the wrong place."*

The **documentation** half of this was real and is fixed — README and `docs/usage.md` now state
that discovery and the switcher read different directory sets (report 01, D-09). No code change
was needed or made.

### P-C5 — Stale comment claims drop and paste are unimplemented · severity: low

`src/jenova/gui.nim:4956-4957` — *"A file picker only — drag-and-drop and paste are the Web
UI's other two routes and are not here yet."* The paste button is at
`src/jenova/gui.nim:4964`; `DropZone` wraps the chat column at `src/jenova/gui.nim:4838`.
Also tracked in report 01 as S-02.

---

## 5. Class D — where the GUI is already ahead

Recording these matters: parity work must not regress them, and they are the seed of the
"and more" half of the goal.

| # | GUI-only capability | Source |
|---|---|---|
| 1 | Backend supervision — start, stop, restart, watchdog, per-backend health | `src/jenova/lifecycle.nim`, `src/jenova/gui.nim:4589` |
| 2 | Hardware detection, profile scoring and deployment | `src/jenova/hardware.nim` (436 lines), `src/jenova/gui.nim:4145` |
| 3 | Model switching that relinks `models/agent` | `src/jenova/models.nim:227`, `src/jenova/gui.nim:4259` |
| 4 | LAN toggle with the live bind address in the title bar | `src/jenova/gui.nim:4520-4531` |
| 5 | System tray, D-Bus `StatusNotifierItem` | `src/jenova/tray.nim` |
| 6 | Embedded Neovim page (VTE) and the `Editor:` live-document intent | `src/jenova/vte.nim`, `src/jenova/nvimctl.nim`, `src/jenova/pipeline.nim:403` |
| 7 | Cascade-aware delete confirmations that count what will go | `src/jenova/api.nim:98` |
| 8 | Chat attachments filed as workspace `fileAssets` rows | `src/jenova/gui.nim:1956` |
| 9 | Native canvas at 5,212 lines of GTK with no browser runtime | `src/jenova/canvas.nim` |
| 10 | Backend crash diagnosis from the log tail, surfaced in the window | `src/jenova/gui.nim:724-756` |

---

## 6. Class E — proposed GUI-beyond-Web-UI features

Candidates that exploit what a native FreeBSD process can do and a browser cannot. Not yet
approved — listed for the plan's Phase 5.

| ID | Proposal | Why the GUI can and the Web UI cannot |
|---|---|---|
| P-E1 | Window-level command palette over conversations, notes, files, settings and backend actions | needs global key capture |
| P-E2 | Move / reparent items in the tree by drag | absent from both surfaces today |
| P-E3 | Native file-manager integration for `fileAssets` (open with, reveal in folder) | process/desktop integration |
| P-E4 | Live retrieval inspector: show which chunks the last turn retrieved, with scores | `rag.query` returns them; nothing surfaces them on either surface |
| P-E5 | Pipeline inspector: the rewritten body, intent, RAG hit count, trimmed-turn count | `Prepared` (`src/jenova/pipeline.nim:44-52`) already carries all of it and it is discarded |
| P-E6 | Backend log viewer inside the window | the GUI already reads the tail for errors |
| P-E7 | Multi-window / detached conversation | native only |
| P-E8 | Intent-prefix picker in the composer, so the five prefixes are discoverable | see report 01, G-02. **Half done**: the empty transcript's `StatusPage` now names them, read from `pipeline.IntentPrefixes` rather than restated. A picker in the composer is what remains |

**P-E4 and P-E5 are the strongest**: the data already exists and is thrown away, the cost
is a channel message and a panel, and no other surface can show it.

---

## Tracker

| ID | Gap | Class | Size | State after session 2 |
|---|---|---|---|---|
| P-A1 | MCP client | absent | XL | **parked** — deferred to future planning (ruling) |
| P-A2 | Agentic tool loop | absent | L | **parked** — downstream of P-A1 |
| P-A3 | Audio capture | absent | M | open. `pipeline.contentFor` already emits `input_audio` parts, so the wire format is done and only the recorder is missing |
| P-A4 | Speech synthesis | absent | S | **parked** — deferred to future planning (ruling) |
| P-A5 | Math rendering | absent | M | **open — now the largest rendering gap**, and the only one left in the markdown path |
| P-A6 | Fork from a message | absent | S | **done** — `api.forkConversation` already took an `atMessageId`; the window had never passed one |
| P-A7 | PDF viewing | absent | M | open |
| P-A8 | File-asset open/preview/export | absent | M | open. The window writes `fileAssets` rows it cannot then read |
| P-B1, P-B2, P-B4…P-B11 | Partial implementations | partial | S–M | open |
| P-B3 | Markdown block coverage | partial | S remaining | **mostly done** — see the correction above. What is left is P-A5 |
| P-B12 | Keyboard shortcuts | partial | M | **mechanism done, bindings started.** `shortcuts.ShortcutHost` owns one window-level `GtkShortcutController` at `GTK_SHORTCUT_SCOPE_MANAGED`; bindings are a `seq[Binding]`, so adding one is a table row. F11 moved off `fullscreenButton`, which removes the container constraint at its source — no button carries a `shortcut` now. Five bindings ship: F11, `<Ctrl>n`, `<Ctrl>b`, `<Ctrl>comma`, `<Ctrl>Escape`. **Type-checked, not run** |
| P-C1 | Three unwired settings | false impl | S | **2 of 3 done.** `copyTextAttachmentsAsPlainText` and `pasteLongTextToFileLen` are wired; `pdfAsImage` needs a rasteriser and is honestly blocked — see report 03, W-01 |
| P-C2 | Three unserved endpoints called by the Web UI | dead surface | S | **won't fix — `jca_web` is frozen.** `/models/load` and `/models/unload` are unreachable in practice (they need ROUTER mode, which this server never reports). `/cors-proxy` fails gracefully but does silently disable remote MCP servers — which is moot while MCP is parked, and is the argument for a **server-side** MCP client when it is revisited |
| P-C3 | Push/Pull vestigial | dead surface | S | **parked** — ruling: out of scope for the GUI, and `jca_web` is frozen |
| P-C4 | Models panel empty-state | — | — | **withdrawn — the finding was wrong**, see above |
| P-C5 | Stale composer comment | stale | XS | **done** |
| P-E1…P-E8 | Beyond-parity proposals | new | — | proposed. **P-E5 is now half-built**: the pipeline diagnostics it needed are no longer discarded (report 03, E-05) and travel as response headers — what remains is a panel to show them |
