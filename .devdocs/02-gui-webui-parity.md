# Report 02 — GUI ↔ Web UI Parity Audit

> **Status as of 2026-09-29T22:31Z** (baseline `4acedfa0` / `154e0cf9` mode-only; host Arch Linux, GTK 4.22.5, libadwaita 1.9.4).
> **Current:** the §1 matrix and the Tracker, regenerated from the code at that baseline. Citations name the proc, const or renderable; a line number appears only where it helps.
> **Superseded:** every `file:line` written before this pass (taken at `c5111ce` and in later sessions, and since drifted). Once-true narrative in §2–§6 is annotated, not deleted.
> **Validation:** on this host `nimble gui` fails under gcc 16.2 and clang 22.1 (`vte.nim`'s `GdkRGBA`); with that one error downgraded the window builds and `--check` passes. No mapped-window run exists.
> **Rulings:** the 2026-09-29 rulings make FreeBSD and Linux (Arch, Debian, Fedora) first-class targets and allow GPL code; the 23:30Z ruling 4 makes the GUI and the Web UI the two points of access, kept and behaving the same (DECISIONS_LOG).
> **Re-checked 2026-09-30T01:16Z:** every claim a code verification flagged in this report was read against the code and corrected in place.
> Forward work: see PLANS.md.

**Rulings in force.** Session 2 froze `jca_web`; the 2026-09-29T23:30Z ruling 4 supersedes that
freeze wherever parity needs a Web-side change — where the Web UI lacks behaviour the GUI has, the
Web UI is changed. Two session-2 rulings have not been revisited since: Push/Pull is **out of scope
for the GUI**, and **MCP and TTS are deferred**, so P-A1, P-A2, P-A4 and W-04 are parked rather than
open.
**Goal being tracked:** the GTK4 desktop window (`bin/jenova`) reaches **1:1 parity** with
the SvelteKit Web UI (`jca_web`), then exceeds it, and becomes the primary surface.
**Method:** the Web UI's feature surface was enumerated from its stores, services, route
tree and component tree; the GUI's from `src/jenova/gui.nim` and the modules it links.
Every gap below cites the source on both sides. Nothing is asserted from a screenshot.
**First audited at:** `c5111ce`; re-verified at `4acedfa0` (see the status block).

---

## 0. Scale of the two surfaces

| | Web UI | Desktop window |
|---|---|---|
| Implementation | `jca_web/src` — 244 `.svelte` files, ~22.6k lines (~19.8k non-blank), + ~13.3k lines of stores/services | `src/jenova/gui.nim` — 7,547 lines at `4acedfa0`, plus linked modules |
| Chat transport | `fetch('./v1/chat/completions')`, relative to whichever origin served the page — the Jenova server, `PORT` (default 8080) | raw socket → `127.0.0.1:$PORT/v1/chat/completions` (`gui.streamOnce`) |
| Persistence | server SQLite via `/api/db/*` | the **same** database, in-process: `api.nim` procs for entity writes, deletes, restores, forks, import/export and cascades (`putEntity`, `deleteEntity`, `restoreEntity`, `forkConversation`, `importAll`, `exportAll`, `cascadeCount`, `siblingsIn`), and its own SQL for conversations and messages (`newConversation`, `saveMessage`, `loadMessages`, `listConversations`, `saveLeaf`, `retitleConversation`) |
| Tool/agent loop | client-side, in `agentic.svelte.ts` (772 lines) | none |

Both surfaces therefore share the pipeline, personas, retrieval, cache and database — though
retrieval is scoped by the `X-Jenova-Scope` header, which only the window sends (PLANS.md
Stage 4). The gaps are almost entirely **client-side features the Web UI implements in the
browser**, not server capabilities the GUI cannot reach.

---

## 1. Parity matrix

Legend: **=** parity · **~** partial · **✗** absent in GUI · **+** GUI ahead of Web UI

*Regenerated 2026-09-29T22:31Z from the verified Tracker below. A bold row is open, partial or
parked; a closed item keeps its ID in the evidence column.*

### 1.1 Chat

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| Token streaming | ✔ | ✔ | = | `gui.streamOnce` |
| Generation and prompt tok/s, token counts, cache-n, context used | ✔ | ✔ | = | `gui.statsLine`, `gui.messageStats`; neither surface computes a time-to-first-token figure |
| `X-Cache: HIT` badge | ✔ | ✔ | = | `gui.streamOnce` (response head) |
| Reasoning (`reasoning_content`) block | ✔ | ✔ | = | `gui.streamOnce`; the "Reasoning" `Expander` in `gui.messageCard` |
| Stop mid-generation | ✔ | ✔ | = | `gui.cancelStream` (atomic fd + `shutdown(2)`) |
| Edit a user turn | ✔ | ✔ | = | `gui.startEdit`, `gui.saveEdit`, `gui.cancelEdit` |
| Regenerate | ✔ | ✔ | = | `gui.regenerate` |
| Continue (opt-in) | ✔ | ✔ | = | `gui.continueReply`, gated on `enableContinueGeneration` |
| Branch/sibling navigation | ✔ | ✔ | = | `gui.switchSibling` |
| Delete a message (cascade) | ✔ | ✔ | = | `gui.deleteMessage` |
| Copy | ✔ | ✔ | = | `gui.messageActions` → `pipeline.copyTextFor` |
| Raw-output toggle | ✔ | ✔ | = | `gui.messageActions`, gated on `showRawOutputSwitch` |
| Auto-scroll follow + disable | ✔ | ✔ | = | `AutoScroll` renderable; its `pin` in `gui.mainArea` |
| Conversation auto-title from first message | ✔ | ✔ | = | `gui.titleFrom`, `gui.retitleConversation` |
| Fork from a specific message | ✔ | ✔ | = | P-A6 done — `gui.messageActions` calls `forkFrom(convId, m.id)`; the sidebar row keeps the whole-conversation fork (`forkConversationRow`) |
| **Fork options (name, include attachments)** | ✔ | ✗ | **P-A6 remainder** | `ChatMessageActions.svelte:69-71` vs `gui.forkFrom` passing an empty name; `api.forkConversation` takes a name but has no attachments flag |
| **Speak a reply (TTS)** | ✔ | ✗ | **P-A4** (parked) | `ChatMessageAssistant.svelte:110-120`, `audio.service.ts:27` |
| **Microphone / audio input** | ✔ | ✗ | **P-A3** | `ChatFormActionRecord.svelte`, `utils/audio-recording.ts` |
| **Error dialog with detail** | ✔ | ~ | **P-B1** | `DialogChatError.svelte` vs one wrapping error row with Retry (the notice row in `view`); `ChatError.detail` never reaches it — see P-B1 |
| Processing-state indicator | ✔ | ✔ | = | P-B2 done — `gui.processingBar` over `inspect.processingDetails` |

### 1.2 Content rendering

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| **GFM markdown** | ✔ | ~ | **P-B3** | nearly all of it — see the corrections below; what remains is maths M-4 |
| Syntax highlighting | ✔ highlight.js | ✔ GtkSourceView | = | `src/jenova/sourceview.nim` |
| **KaTeX / LaTeX math** | ✔ | ~ | **P-A5** | not KaTeX: a native Cairo layout over the font's OpenType MATH table. Inline (M-1, `markdown.mathMarkup`) and display (M-2 `mathtex.renderMath`; M-3 `bkMath` → `gui.mdBlock` → `gui.drawMathBoxRoot`) have shipped; M-4 is open |
| Code-block copy / preview | ✔ | ✔ | = | P-B4 done — per-block copy and a whole-block preview popover in `gui.mdBlock`; `DialogCodePreview`'s *run* half needs a decision |
| Full-height code blocks setting | ✔ | ✔ | = | `gui.mdBlock`, `fullHeightCodeBlocks` |
| Render user content as markdown | ✔ | ✔ | = | `gui.messageBody`, `renderUserContentAsMarkdown` |
| Image attachment preview | ✔ | ✔ | = | `gui.previewPanel` |
| **In-app PDF viewing** | ✔ pdfjs | ✗ | **P-A7** | GUI extracts text only (`pdf.textFrom`, via `pipeline.readAttachment`) |

### 1.3 Attachments

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| File picker | ✔ | ✔ | = | `gui.attachDialog` |
| Drag and drop | ✔ | ✔ | = | `DropZone` renderable around the chat column |
| Clipboard image paste | ✔ | ✔ | = | `gui.pasteImage` |
| Image thumbnails | ✔ | ✔ | = | `gui.attachmentPixbuf` |
| PDF text extraction | ✔ | ✔ | = | `pdf.textFrom`, via `pipeline.readAttachment` |
| Written to `messages.extra` in Web UI shape | ✔ | ✔ | = | `gui.pendingExtra` |
| Filed as a workspace `fileAssets` row | — | ✔ | **+** | `gui.fileAttachmentsAsArtefacts` — the Web UI does not do this |
| **`pdfAsImage` (PDF pages as images)** | ✔ | ✗ | **P-A7** | P-C1 done: the setting's `awaiting` names the missing rasteriser, and no product code reads it |
| `pasteLongTextToFileLen` | ✔ | ✔ | = | P-C1 done — `composer.classifyInsertion` in the composer's `changed` |
| `copyTextAttachmentsAsPlainText` | ✔ | ✔ | = | P-C1 done — `pipeline.copyTextFor` |
| **Audio attachments** | ✔ | ✗ | **P-A3** | `pipeline.contentFor` can *send* `input_audio` parts but the GUI cannot create one |
| **Attachment "view all" sheet** | ✔ | ~ | **P-B5** | `ChatAttachmentsViewAll.svelte` vs an inline chip strip |

### 1.4 Workspace tree

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| Workspace / project / folder / chat / note CRUD | ✔ | ✔ | = | `gui.newChat`, `createNode`, `createNote`, `deleteNode`, `commitRename` |
| Cascade-aware delete confirmation | ~ | ✔ | **+** | `api.cascadeCount` — the GUI names what a delete takes |
| Search chats + notes + files | ✔ | ✔ | = | the sidebar `SearchEntry`; `gui.visibleConvs`, `gui.leavesIn` |
| Note editor with dirty-state guard | ✔ | ✔ | = | `gui.openNoteEditor`, `noteDirty`, `confirmLoseNoteEdits` |
| FOCUS-note pin | ✔ | ✔ | = | the note editor's FOCUS toggle in `gui.mainArea` (`noteFocus`) |
| Trash view + restore + empty | ✔ | ✔ | = | `gui.trashPanel`, `restoreFromTrash`, `restoreTrashFile`, `emptyTrashConfirmed` |
| Open / preview / download a file asset | ✔ | ✔ | = | P-A8 done — `assetview.classify`, `gui.openAsset`, `gui.exportAsset` |
| Dedicated `/files` and `/trash` pages | ✔ | ✔ | = | P-B6 done — native `ColumnView` lists in `filesPanel` and `trashPanel` (overlay panels, not routes) |
| **Move / reparent an item** | ✔ | ✗ | **P-E2** | the Web UI moves chats, notes and files by drag and drop (`FilesView.svelte` `handleDrop` → `workspaceStore.moveConversation`/`moveNote`/`moveFileAsset`); the GUI writes container ids only at creation (`newChat`, `createNote`, attachment filing) |

### 1.5 Models, hardware, backend

| Feature | Web | GUI | State | Evidence |
|---|---|---|---|---|
| Model list + switch | ~ | ✔ | **+** | `gui.modelsPanel`, `gui.switchToModel`. Web's load/unload targets endpoints this server does not serve — see **P-C2** |
| **Model information (modalities, context)** | ✔ | ~ | **P-B7** | `DialogModelInformation.svelte` (251 lines) vs name, folder and size columns in `modelsPanel` |
| **Favourite models** | ✔ | ✗ | **P-B8** | `FAVORITE_MODELS_LOCALSTORAGE_KEY` |
| Hardware profile detection + apply | ✗ | ✔ | **+** | `gui.hardwarePanel`, `src/jenova/hardware.nim` — its OS, CPU, memory, swap and storage probes are FreeBSD-only today; the GPU probe runs `llama-server --list-devices` |
| Backend start / stop / restart | ✗ | ✔ | **+** | `gui.ctlWorker` — all backends together (`startAll`, `stopAll`) |
| Live backend status | ✗ | ✔ | **+** | one status, the chat backend's: `gui.ctlWorker`'s `poll` checks `beLlama`; the embedding backend's health only gates the retrieval backfill |
| LAN toggle + address display | ✗ | ✔ | **+** | `gui.topBar` subtitle and the LAN `Banner`. `gui.lanAddress` runs once at start, when the socket is bound to 0.0.0.0: BSD `route -n get default`, then plain `ifconfig`. On Linux without net-tools it finds nothing and the subtitle shows "0.0.0.0" |
| System tray (StatusNotifierItem) | ✗ | ✔ | **+** | `src/jenova/tray.nim` |
| Embedded Neovim page | ✗ | ✔ | **+** | `src/jenova/vte.nim`, `src/jenova/nvimctl.nim` |
| `Editor:` live-document intent | ✔ | ✔ | = | server-side, `pipeline.prepare` (`inEditor`): both the window's server and `serve` call `configureEditor`, so a turn from either surface that begins `Editor:` gets the open document whenever an `nvim` listens on that socket — the window's embedded page is one |

### 1.6 Settings

`settings.Defs` defines 43 fields; `SETTING_CONFIG_DEFAULT` in
`jca_web/src/lib/constants/settings-config.ts` defines 52. The GUI covers every shared field, and
the delta is nine keys. [2026-09-29T22:31Z: first written as "39 … 48", which was wrong even at
`c5111ce` — 41 and 52.]

| Web key | In GUI | Why / tracker |
|---|---|---|
| `serverUrl` | ✗ | **deliberate**, recorded in `settings.OmittedFields` — the window *is* the server |
| `apiKey` | ✗ | **deliberate**, `settings.OmittedFields` — no authentication exists |
| `mcpServers`, `mcpServerUsageStats` | ✗ | **P-A1** (parked) |
| `agenticMaxTurns`, `agenticMaxToolPreviewLines`, `showToolCallInProgress`, `alwaysShowAgenticTurns` | ✗ | **P-A2** (parked) |
| `useAudioVoice` | ✗ | **P-A4** (parked) |
| `showSystemMessage` | ✔ | P-B9 done |
| `useThinking` | ✔ | P-B10 done |

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
(`conversations.mcpServerOverrides` in `db.nim`'s schema).

The Nim side has **no MCP implementation at all**: `grep -rin mcp src/` returns exactly three
lines, and none of them implements MCP. They are the `mcpServerOverrides` column in `db.nim`'s
schema string and in `api.nim`'s entity column list, and the `settings.OmittedFields` entry
recording its deliberate exclusion (*"the whole MCP section is excluded by the USER; MCP is
deferred (SETTLED FACT)"*).

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

`grep -rn 'agentic' src/` returns **nothing** — re-verified. The `messages.toolCalls` column
exists (`db.nim`'s schema, `api.nim`'s entity map) and the GUI never reads or writes it.

Note the coupling: the agentic loop is only useful with tools, and tools only come from
MCP. P-A2 is downstream of P-A1.

### P-A3 — Audio capture · size: medium

Web: `ChatFormActionRecord.svelte`, `services/audio.service.ts`, `utils/audio-recording.ts`,
gated by the `autoMicOnEmpty` setting.
GUI: the `autoMicOnEmpty` setting is **present and does nothing** — see P-C1.
`pipeline.contentFor` can already emit `input_audio` parts, so the send path exists; only capture
is missing. Still open (re-verified 2026-09-29T22:31Z), and the setting's own `awaiting` string
now says so rather than blaming a shipped step. GTK4 has no recorder; the 2026-09-29 GPL ruling
widens the choice of capture library — see PLANS.md.

### P-A4 — Speech synthesis (read a reply aloud) · size: small

Web: `ChatMessageAssistant.svelte:110-120` via `window.speechSynthesis`, plus the
`useAudioVoice` setting.
GUI: absent, and still absent. A GTK equivalent needs an external synthesiser; on FreeBSD and
Linux alike this means a process invocation or a linked synthesiser library. **The premise stated
here has since changed and the conclusion has not.** This row used to cite a "the GUI spawns no
shell at all" property at `gui.nim:26` (at `c5111ce`). The window starts three kinds of process
today: `route` and `ifconfig` once at start-up, on the main thread before the window exists and
only when the socket is bound to 0.0.0.0 (`lanAddress`); `xdg-open` on the control worker, to open
the web UI; and the embedded terminal's `nvim` (`vte_terminal_spawn_async`). The `gui.nim` header
names only the first two and says both run on the control worker, which the code does not match.
So the objection is no longer "this window spawns nothing"; it is that a synthesiser is one more
spawn with a much larger surface and no equivalent justification. **Flag for a ruling before any
work.**

### P-A5 — Math rendering (KaTeX) · size: medium · **M-1–M-3 shipped; M-4 open**

Web renders LaTeX via KaTeX with dedicated protection passes
(`utils/latex-protection.ts`, `constants/latex-protection.ts`, `styles/katex-custom.scss`).

**As first written this row said `src/jenova/markdown.nim` "has no math concept" and that `$…$`
and `\[…\]` "render as literal text". Both are now false**, and the route taken was not KaTeX —
it is a native Cairo layout over the font's own OpenType MATH table, decided in report 05's open
decision 1 and planned in `.devdocs/08-math-rendering.md`. Against that plan's four phases:

* **M-1 shipped** — inline Tier 1 in `markdown.nim`: `mathSymbol`, `mathUpright`,
  `mathDoubleStruck`, `mathAccent` and the `mathItem`/`mathRun`/`mathArg`/`mathMarkup` pass turn
  Greek and operator names into Unicode and `^`/`_` into Pango sup/sub.
* **M-2 shipped** — `src/jenova/mathtex.nim` (1,316 lines at `4acedfa0`) parses to a tree and lays
  out to boxes over TeXbook Appendix G rules (`renderMath`). No drawing at all, by design, and
  asserted as numbers by `math-selftest`.
* **M-3 shipped** (2026-09-10) — `src/jenova/mathfont.nim` (702 lines) probes the font, reads the
  MATH constants into `mathtex`'s own `MathConstants` and supplies HarfBuzz metrics and size
  variants; `markdown.BlockKind` has `bkMath` for `$$…$$` and `\[…\]`; `gui.mdBlock` lays out
  through `mathLayoutFor` and paints with `drawMathBoxRoot` into a `DrawingArea` — size-variant
  glyphs by glyph index through a FreeType face, every other glyph as text (`cairo_show_text`) —
  and shows the literal LaTeX when there is no font or no layout.
* **M-4 open** — alignment, `\begin{align}`, `\begin{cases}`, spacing classes, and the
  `docs/usage.md` statement of the supported subset.

**Before M-3, what remained was more than "the draw", and this row said otherwise for three
sessions.** `gui.nim` then imported neither `mathtex` nor `mathfont` and `markdown.BlockKind` had no
`bkMath`, so Tier 2 was reachable only from `jenova_core.nim`'s self-tests. M-3 took every landing
site report 08's §5 lists: `gui.nim` imports both modules, `BlockKind` has `bkMath`, and the window
reaches Tier 2 — `mathtex.nim` (1,316 lines) and `mathfont.nim` (702) — through `gui.mdBlock` →
`mathLayoutFor` → `mathtex.renderMath`. Only M-4 remains.

### P-A6 — Fork from a message, with options · size: small · **fixed**

Web forks from any message with a name and an `includeAttachments` choice
(`ChatMessageActions.svelte:31,69-84`). The GUI used to fork only whole conversations from the
sidebar row, always unnamed, because it passed an empty `atMessageId` to a proc that had always
taken one. It now passes the message (`gui.messageActions` → `forkFrom`), and the sidebar's own
fork keeps the whole-conversation meaning deliberately (`forkConversationRow`).
`api.forkConversation` is unchanged — this was a UI-layer gap and it is closed. The name and
`includeAttachments` options are not surfaced; that is the remainder. The API already takes a
name; it has no attachments flag.

### P-A7 — PDF viewing · size: medium

Open. `pdf.nim` extracts a page's text and there is no rasteriser, so `pdfAsImage` cannot be
honoured — which is now what its `awaiting` string says rather than blaming attachments.
Neither `gui.nim` nor `assetview.nim` imports `pdf.nim` or renders a page; the window only packs
an attached PDF's extracted text into `extra` (`gui.pendingExtra`). [2026-09-29T22:31Z:
corrected — this said nothing in either file "references `pdf`", which `pendingExtra`'s PDF branch
contradicted.] The 2026-09-29 GPL ruling admits GPL rasterisers; the choice is PLANS.md's.

### P-A8 — File-asset access · size: medium · **fixed**

**As first written this row said a `fileAssets` row was a dead button — "renamed and deleted but
never opened, previewed, exported or read" — on the strength of `sensitive = entity == "notes"`.
That is no longer the code.** `src/jenova/assetview.nim` is new and classifies an asset into
`avEmpty` / `avImage` / `avText` / `avBinary` (`AssetViewer`, decided by `classify`), the window
imports it, holds the decision (`AppState.assetView`), and `openAsset` opens the row — called from
the sidebar row's button and from its Open menu item. The Files screen's list sorts by name, size,
date or type (`sortFiles`) and filters on name, workspace or type (`refreshVisibleFiles`); the
sidebar tree stays ordered by name and is not filtered by type.

`avEmpty` exists as its own answer because "nothing stored" and "no viewer for this type" are
different claims — see report 07, V-10, which is what made an empty asset a real case rather than
a defect.

---

## 3. Class B — partial implementations

| ID | Gap | Web | GUI (verified 2026-09-29T22:31Z) | Size |
|---|---|---|---|---|
| P-B1 | Error surface: a dialog with the server's own detail | `DialogChatError.svelte` | **open, and wider than first recorded.** Stream errors land on one wrapping row with Retry, but `pipeline.ChatError.detail` never crosses the UI channel: `streamOnce` sends only `message`, so the server's words survive only where `classifyError` folds them in: 400/422, 413, and its `else` branch, which covers every status not listed (500, 504, 429 and the rest). 502/503, 401/403 and 404 get fixed messages without the server's text, and a context overflow keeps only the two numbers. Every other failure (model switch, hardware detection, fork, export, import, restore) goes through `setNotice` and expires as a toast | S–M |
| P-B2 | Processing-state detail while generating | `ChatScreenProcessingInfo.svelte` | done — `processingBar` | S |
| P-B3 | Markdown coverage — **restated, see the correction below** | remark→rehype | nearly all; the remainder is maths M-4 (P-A5) | S (remaining) |
| P-B4 | Per-code-block copy button and a preview dialog | `ActionIconsCodeBlock`, `DialogCodePreview` | done — per-block copy and a preview popover in `mdBlock` | S |
| P-B5 | Attachment "view all" surface | `ChatAttachmentsViewAll.svelte` | open — inline chip strip | S |
| P-B6 | Dedicated Files/Trash pages vs overlay panels | `src/routes/files/**` | done — `ColumnView` lists in overlay panels | M |
| P-B7 | Model information detail (modalities, parameters, quantisation) | `DialogModelInformation.svelte` | open — name, folder and size columns. `/props` is already fetched for the loaded model (its context size reaches the stats line, its defaults the settings placeholders), but there is no model-information view | S (loaded model) – M (per-file GGUF) |
| P-B8 | Favourite / pinned models | localStorage | open — none | S |
| P-B9 | Show the system message in the transcript | `showSystemMessage` | done | S |
| P-B10 | `useThinking` request toggle | setting | done | S |
| P-B11 | Selective export (choose conversations) | `DialogConversationSelection` | open — the JSON export is all-or-nothing (`exportConversations` → `api.exportAll()`); `exportConversationMarkdown` writes only the open conversation's visible branch; nothing lets you choose several | S–M |
| P-B12 | Keyboard shortcuts | Ctrl+K search, Ctrl+Shift+O new chat, Ctrl+Shift+E rename, Ctrl+Shift+D delete, Ctrl+B sidebar | partial — five bindings in `keyBindings` (F11, `<Ctrl>n`, `<Ctrl>b`, `<Ctrl>comma`, `<Ctrl>Escape`); no search, rename, delete or focus-composer binding | S–M |

### Correction — P-B3 as first written was wrong

**The original text said "three block kinds means every ordered list, bullet list, heading, block
quote and inline link renders as raw text". That is false**, and it was reached by reading the
`BlockKind` enum without reading `lineMarkup` beneath it. `markdown.nim` already handled headings
h1–h3, bullets, task lists with rendered check boxes, block quotes, and links and images behind a
scheme allowlist — all as Pango markup inside a `bkText` block, which is why the enum had three
cases then and not eight (four now, with `bkMath`). An image is not displayed: it renders as its
alt text, linked to its source.

What was **actually** missing, verified line by line:

| Gap | Status |
|---|---|
| Ordered lists (`1. `, `2) `) — rendered as their own source text | **fixed**, session 2 |
| Nested list indentation — `lineMarkup` stripped the indent before measuring it, so every outline rendered flat | **fixed**, session 2 |
| Headings h4–h6 — fell through and rendered their own hashes | **fixed**, session 2 |
| Horizontal rules (`---`, `***`, `___`) | **fixed**, session 2 |
| `+ ` bullets | **fixed**, session 2 |
| Math / KaTeX | absent then — that is P-A5, and **it was not the only remaining gap; see below**. Inline and display maths have since shipped (M-1–M-3); M-4 remains |

Twenty-five assertions cover the new behaviour in `markdown-selftest`, including that the branches
which already worked still do. The change is parser-only: no widget-tree change, which is where
this project has had its crashes.

### Second correction — "math is the only remaining markdown gap" was also wrong

The correction above closed by naming P-A5 as the one gap left in the markdown path. Session 9
compiled and ran that path and found **three live defects in the emphasis passes**, the first of
which was destroying whole lines:

| Defect | Effect |
|---|---|
| `***bold italic***` emitted `<b><i>x</b></i>` | Pango's parser is XML-shaped and rejects the **whole string**, so the label drew *nothing*. Not a lost bold — a lost line, on the path every streaming reply takes |
| `2 * 3 * 4` | rendered as italic arithmetic |
| An unpaired `**` | eaten as an empty italic, contradicting `inlineSpan`'s own docstring |

The fix is a `markupBalanced` guard whose fallback costs a line its emphasis rather than costing
the reader the line, because ordering alone cannot resolve `*a~~b*c~~`. It was proved in a mapped
window first, by running the gate against a reverted copy.

**And the assertion count quoted in the first correction was already stale when written.**
`markdown-selftest` carried **77** assertions, not twenty-five. Its branch of `jenova_core.nim`
now holds **159** `check` calls, and several sit inside loops, so a run executes more than that.

The lesson is the same one twice: this section was written by reading `markdown.nim`, and both
times what it concluded about the file was wrong in the direction of "the remaining work is
small". A compiler and a mapped window were what settled it.

**P-B12 carries a structural hazard.** `owlkettle`'s `Button.shortcut` has no update path —
it builds a `GtkShortcutController` once and its update hook asserts the value never
changed (`src/jenova/gui.nim:3336-3340`). Two separate defects have already been caused by
changing the child count of a container holding the one shortcut-carrying button
(`gui.nim:3327-3340` and `:4918-4924` at `c5111ce`). **Adding shortcuts required fixing the
mechanism first** — a window-level `GtkShortcutController` — not adding more
shortcut-carrying buttons. That is done: the window-level controller exists
(`shortcuts.ShortcutHost`) and no `Button` carries a `shortcut`. Report 06 §6 also corrected this
paragraph's reasoning.

---

## 4. Class C — false implementations, dead surfaces, stale claims

### P-C1 — Three settings are drawn, saved, and connected to nothing · severity: high · **fixed**

As first written: `src/jenova/settings.nim` marked three settings
`awaiting: "attachments — PLANS.md Step 7b (G-30)"` — a blocker that had already shipped in full
(file picker, drop zone, paste, PDF extraction, thumbnails, preview) — and each had **zero**
consumers anywhere in `src/` outside `settings.nim`. They read as work forgotten rather than
deferred, and a user setting `pdfAsImage` got no behaviour change and no warning beyond a stale
sentence.

**Re-counted against the tree — all three are wired:**

| Key | Lines naming it in `src/` outside `settings.nim` (`gui.nim` / self-tests) | State |
|---|---|---|
| `pasteLongTextToFileLen` | **9** (1 / 8) | wired through `composer.classifyInsertion` |
| `copyTextAttachmentsAsPlainText` | **4** (2 / 2) | wired through `pipeline.copyTextFor` |
| `pdfAsImage` | **5** (0 / 5) | **honestly blocked** — its `awaiting` names *a PDF rasteriser*, not attachments; no product code reads it |
| `autoMicOnEmpty` | **2** (0 / 2) | **honestly blocked** — its `awaiting` names audio capture (P-A3), which is real |

[2026-09-29T22:31Z: corrected — `pdfAsImage` was described as "read"; all five of its references
are self-test lines.]

So both halves of the fix were taken: two were wired, and the two that stay deferred name the
blocker they actually have. No `awaiting` string in the file mentions attachments or `PLANS.md`
any more.

The self-test that only asserted these strings are non-empty would have passed either way. It is
no longer the only guard: `pipeline-selftest`'s `helpTextIsSafeAsMarkup` block walks
`settings.Defs` and fails the self-test run on a raw `<`, `>` or `&` in any `label` or `help`
[2026-09-29T22:31Z: corrected — this said it "fails the build"; it fails `nimble suites`, not the
compile] — see report 07, V-16, which is a different
defect in the same strings, found by actually rendering the panel.

### P-C2 — The Web UI calls three endpoints this server does not implement · severity: medium

`jca_web/src/lib/constants/api-endpoints.ts`:

```
export const API_MODELS = { LIST: "/v1/models", LOAD: "/models/load", UNLOAD: "/models/unload" };
export const CORS_PROXY_ENDPOINT = "/cors-proxy";
```

`/v1/models` is forwarded (matches the `/v1/` prefix). The other three are not:
`routes.classify` has no case for `/models/` or `/cors-proxy`, so both fall to `rcStatic`. The
Web UI sends `/models/load` and `/models/unload` as `POST`, which the `rcStatic` branch answers
`405 text/plain "method not allowed"` before any file lookup; the `HEAD` probe of `/cors-proxy`
reaches `serveStatic`, which has no single-page fallback and answers `404 text/plain`.

* `/models/load`, `/models/unload` — called from `services/models.service.ts:75,87`, only
  reachable in ROUTER mode. `serverStore.detectRole` (`stores/server.svelte.ts:148-150`)
  only enters ROUTER mode when `/props` reports `role: "router"`, which single-model
  `llama-server` never does. **Currently unreachable dead code, not a live break** — but it
  is a live break the moment anyone puts a router in front.
* `/cors-proxy` — `mcpStore.probeProxy` (`stores/mcp.svelte.ts:114`) HEADs it at
  construction, gets a 404, and sets `_proxyAvailable = false`. The failure is graceful, but
  the consequence is real: **every remote MCP server that needs the proxy is unusable in
  the shipped Web UI**, silently. The comment at `stores/mcp.svelte.ts:110` names an
  upstream flag (`--webui-mcp-proxy`) that this server has never had.

### P-C3 — Sidebar "Push" / "Pull" are vestigial and can move data backwards · **PARKED**

> **Ruling, session 2:** the Web UI's buttons stay as they are, and Push/Pull is explicitly
> **not** to be built into the GUI — it is unnecessary there, because the window *is* the server
> and has no separate store to synchronise. The freeze that ruling rested on is superseded by the
> 2026-09-29T23:30Z ruling 4; the Push/Pull part has not been revisited, so the decision at the
> end of this section is still open.
>
> The window's "Sync notes from disk" (`gui.pullNotesFromDisk` → `api.pullNotes`) already covers
> the one case that is real on a single-process surface: a note edited outside the window, in the
> embedded Neovim or another editor, coming back into the database.



`ChatSidebarActions.svelte:33-59` renders two prominent sidebar buttons (visible in the README's
`splash_bottom.png`; `splash_top.png` has the sidebar collapsed). Their implementation:

* **Push** calls `SyncService.sync()` (`services/sync.service.ts:336-427`), not `push()`. It
  writes every note and every conversation as its own `.md` file through `POST
  ./api/storage/<path>`, deleting the old file first when the path has moved, then saves the full
  `DatabaseService.exportData()` snapshot — the server's whole database read over `/api/db/*`,
  plus four `localStorage` keys — as `jenova-snapshot.json`. The storage root is the workspaces
  tree (`fssync.resolveStoragePath`). `SyncService.push()` (`:102-121`), which saves only the
  snapshot and carries the stale *"Pushes current IndexedDB state"* comment, is called by
  nothing; `jca_web/README.md` already flags that comment class as stale.
* **Pull** (`SyncService.pull()`, `:127-334`) reads the snapshot and calls
  `DatabaseService.importData`, which writes the snapshot's `localStorage` keys and POSTs to
  `/api/db/import`. It then reads every `.md` file under the storage root: it updates or creates
  notes, and for a chat file that matches an existing conversation it deletes that conversation's
  messages and rebuilds them from the Markdown. It does not reload the page — it dispatches
  `jenova-sync-updated`, which `+layout.svelte` answers by refreshing its stores — although
  `ChatSidebarActions.handlePull` resets `isSyncing` only on error, on the assumption that it
  does.

`api.importData` is an upsert inside one transaction, so it
merges rather than replacing — it will not delete anything. But it **will** overwrite rows
edited since the snapshot and un-delete soft-deleted rows. A round trip through the server's
own storage to reach the server's own database is a leftover from the browser-persistence
era, and the buttons give no indication of what they overwrite.

The GUI's nearest equivalent — "Sync notes from disk" (`gui.pullNotesFromDisk` →
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

### P-C5 — Stale comment claims drop and paste are unimplemented · severity: low · **fixed in part**

At `c5111ce`, `gui.nim:4956-4957` read *"A file picker only — drag-and-drop and paste are the Web
UI's other two routes and are not here yet."* while the paste button sat a few lines below and
`DropZone` wrapped the chat column. Also tracked in report 01 as S-02.

No comment claims drop or paste are missing any more; the paste button calls `gui.pasteImage`, and
`DropZone` still wraps the chat column. But the comment above the paperclip (`gui.nim:7197-7203`)
still quotes the old text as history — *"This said 'a file picker only — drag-and-drop and paste
are not here yet' long after both landed"* — which AGENTS.md's no-history rule forbids. It goes
when that code is next touched.

---

## 5. Class D — where the GUI is already ahead

Recording these matters: parity work must not regress them, and they are the seed of the
"and more" half of the goal.

| # | GUI-only capability | Source |
|---|---|---|
| 1 | Backend control — start, stop and restart all backends together, and the chat backend's live status | `src/jenova/lifecycle.nim` (`startAll`, `stopAll`), `gui.ctlWorker` (`poll` checks `beLlama` only; the embedding backend's health gates the backfill and is never shown). The window runs no watchdog; the only one is `jenova-core serve`'s `watchLoop` |
| 2 | Hardware detection, profile scoring and deployment | `src/jenova/hardware.nim`, `gui.hardwarePanel` — the OS, CPU, memory, storage and swap probes are FreeBSD-only today; the GPU probe runs `llama-server --list-devices` |
| 3 | Model switching that relinks `models/agent` | `models.switchModel`, `gui.switchToModel` |
| 4 | LAN toggle, with the bind address in the title bar | `gui.topBar`, `gui.lanAddress` — looked up once at start-up when the socket is bound to 0.0.0.0, and shown only while `lanBound`. BSD `route -n get default`, then plain `ifconfig`: Linux shows "0.0.0.0" only when `ifconfig` is missing or prints no non-loopback `inet` line |
| 5 | System tray, D-Bus `StatusNotifierItem` | `src/jenova/tray.nim` — needs a StatusNotifierWatcher, which stock GNOME does not run |
| 6 | Embedded Neovim page (VTE) | `src/jenova/vte.nim`, `src/jenova/nvimctl.nim`. The `Editor:` intent it serves is not GUI-only: `pipeline.prepare` answers it for any client whenever an `nvim` listens on the editor socket |
| 7 | Cascade-aware delete confirmations that count what will go | `api.cascadeCount` |
| 8 | Chat attachments filed as workspace `fileAssets` rows | `gui.fileAttachmentsAsArtefacts` |
| 9 | Native canvas drawn straight onto Cairo, with no browser runtime | `src/jenova/canvas.nim` (145 lines — the 5,212 this row used to carry was `gui.nim`'s length at audit time; 7,547 at `4acedfa0`) |
| 10 | Backend crash diagnosis from the log tail, surfaced in the window | `gui.lastBackendError` |

---

## 6. Class E — proposed GUI-beyond-Web-UI features

Candidates that exploit what a native process on FreeBSD and Linux can do and a browser cannot.
P-E4, P-E5 and P-E8 have shipped and P-E1 is open; P-E3, P-E6 and P-E7 are parked pending a
ruling. P-E2 turned out not to be beyond parity at all — the Web UI already has it — so it is a
parity gap. Forward work: see PLANS.md.

| ID | Proposal | Why the GUI can and the Web UI cannot |
|---|---|---|
| P-E1 | Window-level command palette over conversations, notes, files, settings and backend actions | needs global key capture |
| P-E2 | Move / reparent items in the tree by drag | not a browser limit — the Web UI already does it (`FilesView.svelte` `handleDrop`); the GUI cannot move anything, so this is a parity gap |
| P-E3 | Native file-manager integration for `fileAssets` (open with, reveal in folder) | process/desktop integration |
| P-E4 | Live retrieval inspector: show which chunks the last turn retrieved, with scores | `rag.query` returns them; **done** — `X-Jenova-Hit` headers read by `gui.inspectorPanel` |
| P-E5 | Pipeline inspector: intent, RAG hit count, trimmed-turn count and the shape of the rewrite | `pipeline.Prepared` carries it; **done** — `server.diagnosticHeaders`, shown by `gui.inspectorPanel`: message count and bytes on both sides, system-message bytes, intent, injected blocks, retrieval and web hits, editor document, trimmed turns and bytes, cache. The rewritten body itself never leaves the server |
| P-E6 | Backend log viewer inside the window | the GUI already reads the tail for errors |
| P-E7 | Multi-window / detached conversation | native only |
| P-E8 | Intent-prefix picker in the composer, so the five prefixes are discoverable | see report 01, G-02. **Done**: the empty transcript's `StatusPage` names them, read from `pipeline.IntentPrefixes` rather than restated, and Send is a `SplitButton` whose menu inserts them (`gui.intentMenuItems`) |

**P-E4 and P-E5 are the strongest**: the data already exists and is thrown away, the cost
is a channel message and a panel, and no other surface can show it. Both have shipped — see the
Tracker.

---

## Tracker

| ID | Gap | Class | Size | State (verified 2026-09-29T22:31Z; flagged rows re-checked 2026-09-30T01:16Z) |
|---|---|---|---|---|
| P-A1 | MCP client | absent | XL | **parked** — deferred to future planning (ruling) |
| P-A2 | Agentic tool loop | absent | L | **parked** — downstream of P-A1 |
| P-A3 | Audio capture | absent | M | **open.** `pipeline.contentFor` already emits `input_audio` parts, so the wire format is done and only the recorder is missing; see PLANS.md |
| P-A4 | Speech synthesis | absent | S | **parked** — deferred to future planning (ruling) |
| P-A5 | Math rendering | partial | M | **M-1–M-3 shipped; M-4 open.** Not KaTeX — a native Cairo layout over the font's OpenType MATH table (report 08). Inline maths in `markdown.nim`, `mathtex.nim`'s parser and box layout, and M-3's font bridge and Cairo draw (`bkMath` → `gui.mdBlock`) are all in the window. `math-selftest` asserts the layout and the font bridge (`defaultConstants`, `chooseFont`, `buildMathLayoutFont`, `buildDefaultMathFont`) and `markdown-selftest` the `bkMath` split; the Cairo draw (`gui.drawMathBox`, `drawMathBoxRoot`) lives in `gui.nim`, which no self-test links, so nothing exercises it. Open: M-4 — alignment environments, spacing classes and the documented subset |
| P-A6 | Fork from a message | absent | S | **done** — `api.forkConversation` already took an `atMessageId`; the window had never passed one. Remainder: the name and include-attachments options (the API has no attachments flag) |
| P-A7 | PDF viewing | absent | M | **open** — no rasteriser, so `pdfAsImage` stays blocked; the 2026-09-29 GPL ruling widens the choice — see PLANS.md |
| P-A8 | File-asset open/preview/export | absent | M | **done (session 9).** New `src/jenova/assetview.nim` decides image/text/binary/empty below the widget layer, 40 assertions; the row activates into a viewer reusing the transcript's own decoder, and Export is a `FileChooserSave` with `filters`. `avEmpty` is its own answer because of V-10 |
| P-B1 | Error surface with the server's own detail | partial | S–M | **open, and wider than first recorded** — `ChatError.detail` is dropped before the UI channel, and failures outside the chat stream expire as toasts (§3) |
| P-B2 | Processing-state detail while generating | partial | S | **done (session 9)** — from the widened `diagHeaders`, the same channel as P-E5, not a second one |
| P-B4 | Per-code-block copy and preview | partial | S | **done (session 9).** The copy button already existed and this report said otherwise; what was missing was preview, now a `MenuButton`+`Popover` owning its own open state. Copy goes insensitive on an unterminated fence. `DialogCodePreview` *runs* code in an iframe — that half needs a decision, not an implementation |
| P-B5, P-B7, P-B8, P-B11 | Attachment "view all", model information detail, favourite models, selective export | partial | S–M | **open** — see PLANS.md. P-B7's model detail can be an `ExpanderRow`, which owlkettle binds ungated |
| P-B6 | Files and Trash as native lists | partial | M | **done (session 9)** — both are `ColumnView`s on the models panel's idiom, the trash as one table over both of its lists. Header-click sorting does not exist to wire: owlkettle binds no `GtkSorter` at `ac61ecf` (report 07, V-13) |
| P-B9 | Show the system message | partial | S | **done (session 9).** Defaults on. Returns an empty `Box` from `viewItem` rather than filtering `app.messages` — the `ListView` is indexed into that seq and three mutators take that index: `startEdit`, `regenerate` and `deleteMessage`, through `messageActions`. The comment above `viewItem` names `deleteMessage`, `saveEdit` and `forkFrom`, the last two of which take an id |
| P-B10 | `useThinking` toggle | absent | S | **done (session 9).** Verified against `chat.service.ts:120-122`: it is a `[THINKING LOGIC]` directive on the system message, **never a wire flag** — `llama-server` has no such parameter, so a JSON key of that name would have been a control wired to nothing |
| P-B3 | Markdown block coverage | partial | S remaining | **mostly done** — see the correction above. What is left is P-A5's M-4 |
| P-B12 | Keyboard shortcuts | partial | S–M | **partial — mechanism done, five bindings.** `shortcuts.ShortcutHost` owns one window-level `GtkShortcutController` at `GTK_SHORTCUT_SCOPE_MANAGED`; bindings are a `seq[Binding]` (`gui.keyBindings`), so adding one is a table row. F11 moved off `fullscreenButton`, which removes the container constraint at its source — no button carries a `shortcut` now. Bound: F11, `<Ctrl>n`, `<Ctrl>b`, `<Ctrl>comma`, `<Ctrl>Escape`. Missing against the Web UI: Ctrl+K search, Ctrl+Shift+E rename, Ctrl+Shift+D delete (its new-chat chord is Ctrl+Shift+O); missing against the plan: focus composer and search, which need a focus hook owlkettle does not expose. No mapped-window run has exercised them |
| P-C1 | Three unwired settings | false impl | S | **done.** `copyTextAttachmentsAsPlainText` and `pasteLongTextToFileLen` are wired — re-counted, 4 and 9 lines outside `settings.nim`; `pdfAsImage` is read only by self-tests and needs a rasteriser, and its `awaiting` now says so, as does `autoMicOnEmpty`'s. No `awaiting` string blames attachments or `PLANS.md` any more — see report 03, W-01 |
| P-C2 | Three unserved endpoints called by the Web UI | dead surface | S | **open, low.** It was "won't fix" under the session-2 freeze, which ruling 4 supersedes. `/models/load` and `/models/unload` are unreachable in practice (they need ROUTER mode, which this server never reports). `/cors-proxy` fails gracefully but does silently disable remote MCP servers — which is moot while MCP is parked, and is the argument for a **server-side** MCP client when it is revisited |
| P-C3 | Push/Pull vestigial | dead surface | S | **parked** — ruling: out of scope for the GUI. The freeze it also cited is superseded by ruling 4; the remove-or-re-specify decision in §4 is open |
| P-C4 | Models panel empty-state | — | — | **withdrawn — the finding was wrong**, see above |
| P-C5 | Stale composer comment | stale | XS | **done** |
| P-E4 | Retrieval inspector | new | M | **done (session 9).** One `X-Jenova-Hit` header per hit — `score;bm25;semantic;line;percent-encoded-path`. `ragLimitFor` caps at 5, so it fits; snippet prose stays off the wire |
| P-E5 | Pipeline inspector | new | M | **done (session 9).** Carries the shape — system bytes, message count, body bytes, injected blocks, trimmed turns and bytes — with both sides labelled separately so the delta *is* the rewriting. The full prompt cannot ride a header and must not ride the body: the relay stores the captured stream verbatim for replay, so injecting would poison the cache |
| P-E8 | Intent-prefix picker | new | S | **done** — the empty transcript's `StatusPage` names the prefixes, and the Send `SplitButton`'s menu inserts them (`gui.intentMenuItems`) |
| P-E1 | Command palette | new | M | **open** — does not exist (`palette` in `src/` means colour palettes only); see PLANS.md |
| P-E2 | Move / reparent by drag | parity gap | M | **open** — the Web UI moves chats, notes and files by drag (`FilesView.svelte` `handleDrop`); the GUI writes container ids only at creation |
| P-E3, P-E6, P-E7 | Beyond-parity proposals | new | — | **parked** — pending a ruling; see PLANS.md |
