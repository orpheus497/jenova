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
(`conversations.mcpServerOverrides`, `src/jenova/db.nim:312`).

The Nim side has **no MCP implementation at all** — re-verified: `grep -rin mcp src/` returns
exactly three lines, and none of them is code. They are the `mcpServerOverrides` column in the
schema (`src/jenova/db.nim:312`) and in the entity map (`src/jenova/api.nim:48`), and the settings
note recording its deliberate exclusion (`src/jenova/settings.nim:380`, *"the whole MCP section is
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

`grep -rn 'agentic' src/` returns **nothing** — re-verified. The `messages.toolCalls` column
exists (`src/jenova/api.nim:51`, `src/jenova/db.nim:317`) and the GUI never reads or writes it.

Note the coupling: the agentic loop is only useful with tools, and tools only come from
MCP. P-A2 is downstream of P-A1.

### P-A3 — Audio capture · size: medium

Web: `ChatFormActionRecord.svelte`, `services/audio.service.ts`, `utils/audio-recording.ts`,
gated by the `autoMicOnEmpty` setting.
GUI: the `autoMicOnEmpty` setting is **present and does nothing** — see P-C1.
`pipeline.contentFor` can already emit `input_audio` parts (`src/jenova/pipeline.nim:738`),
so the send path exists; only capture is missing. Still open, and `settings.nim:173` now says so
in the setting's own `awaiting` string rather than blaming a shipped step.

### P-A4 — Speech synthesis (read a reply aloud) · size: small

Web: `ChatMessageAssistant.svelte:110-120` via `window.speechSynthesis`, plus the
`useAudioVoice` setting.
GUI: absent, and still absent. A GTK equivalent needs an external synthesiser; on FreeBSD this
means a process invocation. **The premise stated here has since changed and the conclusion has
not.** This row used to cite a "the GUI spawns no shell at all" property at `src/jenova/gui.nim:26`;
the header now says the opposite in as many words (`src/jenova/gui.nim:14-22`) — two things do
spawn a process, `route`/`ifconfig` for the LAN address and `xdg-open` for the web UI, both off the
GTK thread on the control worker. So the objection is no longer "this window spawns nothing"; it is
that a synthesiser is a third spawn with a much larger surface and no equivalent justification.
**Flag for a ruling before any work.**

### P-A5 — Math rendering (KaTeX) · size: medium · **largely shipped**

Web renders LaTeX via KaTeX with dedicated protection passes
(`utils/latex-protection.ts`, `constants/latex-protection.ts`, `styles/katex-custom.scss`).

**As first written this row said `src/jenova/markdown.nim` "has no math concept" and that `$…$`
and `\[…\]` "render as literal text". Both are now false**, and the route taken was not KaTeX —
it is a native Cairo layout over the font's own OpenType MATH table, decided in report 05's open
decision 1 and planned in `.devdocs/08-math-rendering.md`. Against that plan's four phases:

* **M-1 shipped** — inline Tier 1 in `markdown.nim`: `mathSymbol` (`:150`), `mathUpright`
  (`:340`), `mathDoubleStruck` (`:352`), `mathAccent` (`:369`) and the `mathItem`/`mathRun`/
  `mathArg`/`mathMarkup` pass (`:386-590`) turn Greek and operator names into Unicode and `^`/`_`
  into Pango sup/sub.
* **M-2 shipped** — `src/jenova/mathtex.nim` (1,293 lines) parses to a tree and lays out to boxes
  over TeXbook Appendix G rules, with `renderMath` at `:1258`. No drawing at all, by design, and
  asserted as numbers by `math-selftest`.
* **M-3 half shipped** — `src/jenova/mathfont.nim` (391 lines) is the font probe and constants
  reader. **The Cairo draw is the open half**: `renderMath` has exactly one caller in the tree
  (`src/jenova_core.nim:1959`, the self-test), so display maths is laid out and not yet painted.
* **M-4 open** — alignment, `\begin{align}`, spacing classes, and the `docs/usage.md` statement of
  the supported subset.

**What remains of this row is M-3's draw and M-4.** Report 08 is the live plan and is accurate;
this row is the parity view of it.

### P-A6 — Fork from a message, with options · size: small · **fixed**

Web forks from any message with a name and an `includeAttachments` choice
(`ChatMessageActions.svelte:31,69-84`). The GUI used to fork only whole conversations from the
sidebar row, always unnamed, because it passed an empty `atMessageId` to a proc that had always
taken one. It now passes the message (`src/jenova/gui.nim:3706-3726`), and the sidebar's own fork
keeps the whole-conversation meaning deliberately (`:3980-3983`). `api.forkConversation`
(`src/jenova/api.nim:786`) is unchanged — this was a UI-layer gap and it is closed. The name and
`includeAttachments` options are not surfaced; that is the remainder.

### P-A7 — PDF viewing · size: medium

Open. `pdf.nim` extracts a page's text and there is no rasteriser, so `pdfAsImage` cannot be
honoured — which is now what its `awaiting` string says (`src/jenova/settings.nim:129`) rather
than blaming attachments. Nothing in `gui.nim` or `assetview.nim` references `pdf`.

### P-A8 — File-asset access · size: medium · **fixed**

**As first written this row said a `fileAssets` row was a dead button — "renamed and deleted but
never opened, previewed, exported or read" — on the strength of `sensitive = entity == "notes"`.
That is no longer the code.** `src/jenova/assetview.nim` is new and classifies an asset into
`avEmpty` / `avImage` / `avText` / `avBinary` (`:20-23`, `classify` at `:104`), the window imports
it (`gui.nim:58`), holds the decision (`:1303-1305`), and `openFileAsset` (`:4070`) opens the row —
its own comment stating the defect it closes: *"a row that can only be renamed and deleted is a
file this window wrote and cannot read"*. The tree sorts and filters by asset type as well
(`:4003-4004`, `:4043`).

`avEmpty` exists as its own answer because "nothing stored" and "no viewer for this type" are
different claims — see report 07, V-10, which is what made an empty asset a real case rather than
a defect.

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
| Math / KaTeX | still absent — that is P-A5, and **it was not the only remaining gap; see below** |

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
`markdown-selftest` carried **77** assertions, not twenty-five; it now carries **119**.

The lesson is the same one twice: this section was written by reading `markdown.nim`, and both
times what it concluded about the file was wrong in the direction of "the remaining work is
small". A compiler and a mapped window were what settled it.

**P-B12 carries a structural hazard.** `owlkettle`'s `Button.shortcut` has no update path —
it builds a `GtkShortcutController` once and its update hook asserts the value never
changed (`src/jenova/gui.nim:3336-3340`). Two separate defects have already been caused by
changing the child count of a container holding the one shortcut-carrying button
(`src/jenova/gui.nim:3327-3340`, `:4918-4924`). **Adding shortcuts requires fixing the
mechanism first** — a window-level `GtkShortcutController` — not adding more
shortcut-carrying buttons.

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

| Key | Def | Consumers in `src/` outside `settings.nim` | State |
|---|---|---|---|
| `pasteLongTextToFileLen` | `settings.nim:98` | **9** | wired through `composer.classifyInsertion` |
| `copyTextAttachmentsAsPlainText` | `settings.nim:105` | **4** | wired through `pipeline.copyTextFor` |
| `pdfAsImage` | `settings.nim:121` | **5** | read, but **honestly blocked** — `awaiting` at `:129` now names *a PDF rasteriser*, not attachments |
| `autoMicOnEmpty` | `settings.nim:168` | **2** | **honestly blocked** — `awaiting` at `:173` names audio capture (P-A3), which is real |

So both halves of the fix were taken: two were wired, and the two that stay deferred name the
blocker they actually have. No `awaiting` string in the file mentions attachments or `PLANS.md`
any more.

The self-test that only asserted these strings are non-empty would have passed either way. It is
no longer the only guard: `src/jenova_core.nim:4961-4968` walks `settings.Defs` and fails the build
on a raw `<`, `>` or `&` in any `label` or `help` — see report 07, V-16, which is a different
defect in the same strings, found by actually rendering the panel.

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
| P-A5 | Math rendering | partial | M | **largely shipped.** Not KaTeX — a native Cairo layout over the font's OpenType MATH table (report 08). M-1 inline maths in `markdown.nim` and M-2 `mathtex.nim`'s parser and box layout are both in, asserted by `math-selftest`; `mathfont.nim` is M-3's font half. **Open: M-3's Cairo draw** — `renderMath` has one caller and it is the self-test, so display maths is laid out and not painted — **and M-4** |
| P-A6 | Fork from a message | absent | S | **done** — `api.forkConversation` already took an `atMessageId`; the window had never passed one |
| P-A7 | PDF viewing | absent | M | open |
| P-A8 | File-asset open/preview/export | absent | M | **done (session 9).** New `src/jenova/assetview.nim` decides image/text/binary/empty below the widget layer, 40 assertions; the row activates into a viewer reusing the transcript's own decoder, and Export is a `FileChooserSave` with `filters`. `avEmpty` is its own answer because of V-10 |
| P-B1 | Error surface with the server's own detail | partial | S | open |
| P-B2 | Processing-state detail while generating | partial | S | **done (session 9)** — from the widened `diagHeaders`, the same channel as P-E5, not a second one |
| P-B4 | Per-code-block copy and preview | partial | S | **done (session 9).** The copy button already existed and this report said otherwise; what was missing was preview, now a `MenuButton`+`Popover` owning its own open state. Copy goes insensitive on an unterminated fence. `DialogCodePreview` *runs* code in an iframe — that half needs a decision, not an implementation |
| P-B5…P-B8, P-B11 | Partial implementations | partial | S–M | open |
| P-B6 | Files and Trash as native lists | partial | M | **done (session 9)** — both are `ColumnView`s on the models panel's idiom. Header-click sorting does not exist to wire: owlkettle binds no `GtkSorter` at `ac61ecf` (report 07, V-13) |
| P-B9 | Show the system message | partial | S | **done (session 9).** Defaults on. Returns an empty `Box` from `viewItem` rather than filtering `app.messages` — the `ListView` is indexed into that seq and three mutators take that index |
| P-B10 | `useThinking` toggle | absent | S | **done (session 9).** Verified against `chat.service.ts:120-122`: it is a `[THINKING LOGIC]` directive on the system message, **never a wire flag** — `llama-server` has no such parameter, so a JSON key of that name would have been a control wired to nothing |
| P-B3 | Markdown block coverage | partial | S remaining | **mostly done** — see the correction above. What is left is P-A5 |
| P-B12 | Keyboard shortcuts | partial | M | **mechanism done, bindings started.** `shortcuts.ShortcutHost` owns one window-level `GtkShortcutController` at `GTK_SHORTCUT_SCOPE_MANAGED`; bindings are a `seq[Binding]`, so adding one is a table row. F11 moved off `fullscreenButton`, which removes the container constraint at its source — no button carries a `shortcut` now. Five bindings ship: F11, `<Ctrl>n`, `<Ctrl>b`, `<Ctrl>comma`, `<Ctrl>Escape`. **Type-checked, not run** |
| P-C1 | Three unwired settings | false impl | S | **done.** `copyTextAttachmentsAsPlainText` and `pasteLongTextToFileLen` are wired — re-counted, 4 and 9 consumers outside `settings.nim`; `pdfAsImage` is read but needs a rasteriser and its `awaiting` now says so, as does `autoMicOnEmpty`'s. No `awaiting` string blames attachments or `PLANS.md` any more — see report 03, W-01 |
| P-C2 | Three unserved endpoints called by the Web UI | dead surface | S | **won't fix — `jca_web` is frozen.** `/models/load` and `/models/unload` are unreachable in practice (they need ROUTER mode, which this server never reports). `/cors-proxy` fails gracefully but does silently disable remote MCP servers — which is moot while MCP is parked, and is the argument for a **server-side** MCP client when it is revisited |
| P-C3 | Push/Pull vestigial | dead surface | S | **parked** — ruling: out of scope for the GUI, and `jca_web` is frozen |
| P-C4 | Models panel empty-state | — | — | **withdrawn — the finding was wrong**, see above |
| P-C5 | Stale composer comment | stale | XS | **done** |
| P-E4 | Retrieval inspector | new | M | **done (session 9).** One `X-Jenova-Hit` header per hit — `score;bm25;semantic;line;percent-encoded-path`. `ragLimitFor` caps at 5, so it fits; snippet prose stays off the wire |
| P-E5 | Pipeline inspector | new | M | **done (session 9).** Carries the shape — system bytes, message count, body bytes, injected blocks, trimmed turns and bytes — with both sides labelled separately so the delta *is* the rewriting. The full prompt cannot ride a header and must not ride the body: the relay stores the captured stream verbatim for replay, so injecting would poison the cache |
| P-E1…P-E3, P-E6…P-E8 | Beyond-parity proposals | new | — | proposed |
