# Report 01 — Documentation and Presentation Audit

**Status as of 2026-09-29T22:30Z (baseline `4acedfa0`; host Arch Linux):**
- Part A — capturable on this host, no longer FreeBSD-blocked; the screenshots wait only on
  `nimble gui` building here (`vte.nim` `GdkRGBA` error under gcc 16 / clang 22) — see PLANS.md.
- Part B — re-opened after #118: D-02 (route table misses `/v1/embeddings`) and D-07 (§5 contradicted
  by the 64 KiB workspace cap and the `X-Jenova-Scope` header). D-11 and D-15 open.
- New findings are inventoried in § "Product-doc findings at 4acedfa0" at the end; corrections to the
  product docs are scheduled in PLANS.md.
**Scope:** `README.md`, `docs/*.md`, `jca_web/README.md`, `hardware-profiles/README.md`, `jvim/README.md`, `png/`
[2026-09-29T22:30Z: `jvim/README.md` added — it was omitted from the original scope.]
**Method:** every factual claim in the user-facing documentation was read against the
source that implements it. Each finding below cites the documentation line and the
source line that contradicts it. Claims that could not be checked against source are
marked *unverified* rather than asserted.
**Audited at commit:** `c5111ce`; re-verified against `4acedfa0` on 2026-09-29T22:30Z. The product
docs were last edited in #117 (`989c2b5d`); #118 (`4acedfa0`) changed `routes.nim`, `server.nim`,
`rag.nim`, `pipeline.nim`, `workspace.nim` and `gui.nim` with no product-doc edit.

---

## Part A — The presentation problem: the screenshots show the Web UI, not the GUI

### A-1. Both README banners are Web UI screenshots, presented as generic branding

`README.md:3` and `README.md:229` embed `png/splash_top.png` and `png/splash_bottom.png`.
When this was written their alt text read *"Jenova Cognitive Architecture banner"* / *"…
footer"*; the alt text and captions now name them as the Web UI, and they are still the only
images in the README.

Both images are screenshots of the **SvelteKit Web UI**, identifiable without ambiguity:

| Evidence in the image | Source it belongs to |
|---|---|
| `Press `Enter` to send, `Shift + Enter` for new line` helper line | `jca_web/.../ChatFormHelperText.svelte` |
| Placeholder `Chat with Jenova...` | `jca_web/.../ChatFormTextarea.svelte:21` |
| Sidebar rows `MCP Servers`, `Push`, `Pull` | `jca_web/.../ChatSidebarActions.svelte` — **none of these exist in the GTK window** |
| `Canvas Idea` toggle pill in the composer | Web-only control |
| Browser-style flat sidebar with no GTK `HeaderBar` | — |

The GTK window's own composer placeholder is `Message Jenova…` (the composer in `gui.nim` `view`),
its sidebar has no MCP entry and no Push, and it carries a GTK `HeaderBar` holding an Adwaita
`WindowTitle` with a title and a status subtitle (`gui.nim` `topBar`). Nothing in either screenshot
is the desktop application.

**Why this matters beyond accuracy.** `README.md` § Desktop application (`:69-84`) states that the desktop
application is the product and that `jenova` *is* the server, and the project's own
direction is that the GUI becomes the primary surface. The two largest visual assets in
the README teach the opposite: a first-time reader forms their entire mental model of
"what Jenova looks like" from a client the README elsewhere calls the LAN client.

**Severity:** high (presentation), because it is the first thing a reader sees.

### A-2. There is no GUI screenshot anywhere in the repository

`png/` holds seven files. Five are icons/logos, near-square: `jca.jpg` 816×808, `jca_grey.jpg`
875×871, `jenova.jpg` and `jenova.png` 906×905, `jvim.jpg` 908×902. Two are the Web UI screenshots
above. **No image of the GTK4 window exists.** The window's distinguishing surfaces —
the Models panel, the Hardware profile panel, the Trash panel, the Settings panel with
its six sections, the embedded Neovim page, the neural canvas behind the chat column —
are undocumented visually. [2026-09-29T22:30Z: the window now also has Files, Preview and
Inspector panels (`filesPanel`, `previewPanel`, `inspectorPanel`) and a composer intent-prefix
menu (`intentMenuItems`); none is pictured either.]

### A-3. Recommended presentation model

The README should stop treating the two surfaces as interchangeable and present them in
the order the product intends:

1. **Hero image = the GTK window**, captioned as the desktop application.
2. **A second, clearly-labelled image = the Web UI**, captioned as the LAN/browser client.
3. Every screenshot gets alt text and a caption naming *which surface it is*.
4. `docs/usage.md` §"The desktop application" gains window screenshots for the four panels
   that have no equivalent anywhere else (Models, Hardware, Trash, Settings).

Required new assets (to be produced on a FreeBSD host with the GUI built):
`png/gui-chat.png`, `png/gui-models.png`, `png/gui-hardware.png`, `png/gui-settings.png`,
`png/gui-trash.png`, `png/gui-neovim.png`, and a relabelled `png/webui-chat.png`.
[2026-09-29T22:30Z: superseded — any supported host, FreeBSD or Linux (2026-09-29 ruling 1). The
repo's `bin/jenova` is a FreeBSD 15.1 build, so this Arch host needs `nimble gui` to build first
(`vte.nim` error, see PLANS.md); `tests/gui_build.sh`'s mapped-window tier cannot run here (no Xvfb,
xdotool, xclip, xwininfo), so capture is manual. Add `png/gui-files.png` and `png/gui-inspector.png`.]

---

## Part B — Factual defects in the documentation

Each is a statement that a reader can act on and that the source contradicts.

### D-01 — `GET /api/workspaces` is documented but does not exist  · severity: high

* **Claim:** `docs/usage.md:178` — `| GET /api/workspaces | List workspaces |`, under the
  heading *"Handled by the server"*.
* **Source:** `server.nim` `handle` (`rcApi` branch) dispatches exactly three API prefixes:
  `/api/db/`, `/api/fs/`, `/api/storage`. Anything else under `/api/` falls through to
  the same branch's `404 {"error":"not found", …}`. [2026-09-29T22:30Z: plus one debug-only path,
  `/api/_selftest/slow-query`, answered only when `server.start` is given `enableDebug`.]
* **Corroboration:** the string `api/workspaces` appears nowhere in `src/`, `tests/` or
  `jca_web/src/` — only in this documentation line.
* **Fix:** delete the row. Workspaces are listed via `GET /api/db/workspaces`.

### D-02 — "Any request that matches nothing above is relayed to `llama-server`" is false · severity: high

* **Claim:** `docs/usage.md:188-192`, heading *"Forwarded unchanged"* — *"Any request that
  matches nothing above — and any `GET` for a path with no matching file in `public/` —
  is relayed verbatim to `llama-server`."*
* **Source:** there is no fallback relay. `src/jenova/routes.nim:classify` forwards **only**
  the enumerated prefixes `/v1/`, `/completion`, `/infill`, `/chat`, `/props`, `/slots`
  to `rcCompletion`, and `/embed`/`/embeddings` to `rcEmbed`. Everything else returns
  `rcStatic`, and `server.nim` `serveStatic` answers a missing file with
  `404 text/plain "not found: <path>"`. No code path hands an unmatched request to
  `upstream.forward`.
* **Consequence.** The conclusion drawn in the same paragraph ("The rest of its
  OpenAI-compatible surface … is therefore reachable") is accidentally true for
  `/v1/models`, `/v1/completions` and `/props` — they match the listed prefixes — but the
  stated *reason* is wrong, and any llama.cpp endpoint outside those prefixes is **not**
  reachable. This is the same mechanism behind finding D-03 and parity finding P-C2.
* **Fix:** replace the paragraph with the explicit prefix list from `routes.nim:classify`,
  and state that anything else is served from `public/` or 404s.
* **Regressed by #118, and fixed again on 2026-09-30.** `classify` tests `/embed`, `/embeddings`
  and `/v1/embeddings` ahead of `/v1/`, so `/v1/embeddings` goes to `rcEmbed` (:8082), while the
  prefix table this fix had put into `docs/usage.md` sent every `/v1/` path to :8081 (inventory
  B27). The table now routes `/v1/embeddings` to :8082 and names the `/debug/` class and the 405
  for a non-GET static request.

### D-03 — `POST /infill` is documented as augmented; it is passed through untouched · severity: medium

* **Claim:** `docs/usage.md:185-186` — *"`POST /v1/chat/completions` and `POST /infill` are
  intercepted so retrieval context and tool results can be injected."*
* **Source:** `server.nim` hands every completion-class request with a body to
  `pipeline.prepare`, which returns `rawBody` unchanged when the body does not parse as a JSON
  object carrying `messages`. So augmentation is decided by the body, not the path: `/infill`
  and `/completion` carry a raw prompt and no `messages` array, so nothing is injected, while
  any completion-class path (`routes.classify`) whose body carries `messages` is rewritten.
* **Secondary error in the same sentence:** the pipeline **strips** tools for two intents
  (`pipeline.prepare`, before retrieval); it never injects tool results. No tool-result
  injection exists anywhere in `src/`.
* **Fix:** restrict the sentence to `POST /v1/chat/completions`, and say
  *"intent detection, retrieval, web search, editor context, persona injection and tool
  stripping"* rather than "tool results". That restriction was itself too narrow, since the
  body decides; `docs/usage.md` now says so (2026-09-30), and that tools are stripped only for
  `Visual Rewrite:` and `Web Search:`.

### D-04 — "no build or runtime step shells out to a project script" is false at build time · severity: medium

* **Claim:** `README.md:29-30` — *"There is no Makefile, and no build or runtime step shells
  out to a project script."* Restated at `docs/architecture.md:33` — *"nothing in the
  running product depends on a project shell script."*
* **Source:** `nimble web` (`jenova_core.nimble`, task `web`) runs `npm run build`, which is
  `jca_web/package.json:9`:
  `"build": "vite build && node scripts/finalize-build.js && ./scripts/post-build.sh"`.
  `jca_web/scripts/post-build.sh` and `jca_web/scripts/finalize-build.js` are both project
  scripts in this repository.
* **Note on precision:** the *runtime* claim in `docs/architecture.md:33` is correct as to
  project scripts — no running surface runs one. The runtime does start other processes: `/bin/sh`
  to evaluate the conf files (`config.nim`), `execCmdEx` probes in `hardware.nim`, `fetch`/`curl`
  for web search, `nvim`, `git` for the workspace mirror, and the backends.
* **Fix:** narrow `README.md:29` to *"no runtime step shells out to a project script; the
  Web UI build runs two scripts under `jca_web/scripts/`."* Done in `README.md` § Quick Start; on
  2026-09-30 both it and `docs/architecture.md` also name the `/bin/sh` conf evaluation and the
  other child processes (inventory B1).

### D-05 — "Every script in this repository is POSIX `/bin/sh`" is false · severity: low

* **Claim:** `docs/install.md:95`, in the table *"Deliberately not used"* —
  `| **bash** | Every script in this repository is POSIX /bin/sh |`.
* **Source:** two scripts are `#!/bin/bash`:
  * `jca_web/scripts/dev.sh:1`
  * `jca_web/scripts/install-git-hooks.sh:1` (and the hook it writes, at line 30)
  and `jca_web/package.json:8` invokes one explicitly: `"dev": "bash scripts/dev.sh"`.
* **Note:** all six suites under `tests/` and `jca_web/scripts/post-build.sh` **are**
  `#!/bin/sh` (eight suites today). Among the project's own scripts the claim is false only for
  the two Web UI developer scripts; the vendored plugins under `jvim/pack/` carry further
  `#!/bin/bash` scripts of their own.
* **Fix:** convert the two scripts to `/bin/sh`, or narrow the claim to *"every script the
  product builds or runs"*. The claim was narrowed; the GPL rationale first given for preferring
  the conversion is superseded by the 2026-09-29 ruling 2, which allows GPL code and tools, and
  `docs/install.md` no longer states it (2026-09-30). It now also names the vendored `jvim/pack/`
  bash scripts.

### D-06 — `docs/context-and-retrieval.md` states the retrieval index is never populated; it is · severity: high

* **Claim:** `docs/context-and-retrieval.md:14` —
  `| 1 | Server-side retrieval (BM25 + vectors) | src/jenova/rag.nim | **Query path live, index never populated** |`
  Repeated at `docs/context-and-retrieval.md:254`.
* **Source:** four production writers existed when this was written ("three" miscounted the
  list below); there are five today:
  1. `api.handleDb` — a `POST /api/db/messages` whose row is an assistant turn calls
     `rag.indexExchange` (the reply and its parent user turn); the message update route
     re-indexes only the edited message, and only when the body carries `content`. A user turn
     that never gets a reply is left to the backfill.
  2. `api.restoreItem` (reached by the HTTP restore route and the window's trash) — re-indexes
     a restored message, note or file asset, or a restored conversation's assistant turns with
     the turns they answer; items revived as descendants of a restored container wait for the
     backfill.
  3. `gui.ctlWorker` — the `index` job indexes each completed exchange; the `poll` job runs
     `rag.backfillChats()` and `rag.backfillWorkspace()` once the embedding server answers.
  4. `jenova_core.nim` `serve` — the watchdog thread runs both backfills once :8082 answers (first
     check after 30 s, retried on failure, skipped under `JENOVA_NO_BACKENDS=1`) — not "at start".
  5. `api.upsert` — a note or file asset saved on either surface is indexed (`rag.indexNote`,
     `rag.indexFileAsset`) when it is new or its title/name or content changed; an unchanged
     re-save is not.
* **Severity is high because the direction of the error is dangerous:** the document tells
  a user that a working feature does not work. Anyone tuning retrieval will read this and
  stop.
* **Fix:** rewrite §1's state to *"live; populated by the API message routes, by the
  desktop window's index worker, and backfilled at every `serve` start."* Done; on 2026-09-30 the
  writers table was corrected to the five above, with the backfill timing as built.

### D-07 — `docs/context-and-retrieval.md` mechanisms 5, 6, 7 are marked "Web UI only" and two of them are not · severity: high

* **Claim:** `docs/context-and-retrieval.md:18-20` and the section headings at `:194`,
  `:221`, `:230`.
* **Source:**
  * **Mechanism 5, workspace context** — `src/jenova/workspace.nim` is a server-side
    module; `gui.postConversation` calls `workspace.contextFor(folderId,
    projectId, workspaceId)` for the active conversation and passes it into
    `pipeline.chatBody`. It is **not** Web UI only.
  * **Mechanism 6, per-message attachments** — the desktop window has a full attachment
    path: file picker (`attachDialog`), drag-and-drop (`DropZone`, `onDrop`), clipboard image
    paste (`pasteImage`), PDF text extraction (`src/jenova/pdf.nim`), thumbnails, an image
    preview panel (`previewPanel`), and `messages.extra` written in the Web UI's own shape.
    It is **not** Web UI only.
  * **Mechanism 7, MCP tools** — this one *is* still Web UI only. Correct as written.
* **Fix:** re-mark 5 and 6 as *"both surfaces"*, rewrite §5 and §6 to describe the
  server-side and GTK paths, and keep §7 as-is.
* **Regressed by #118, and fixed again on 2026-09-30.** The rewritten §5 said the workspace block
  had "no truncation, no ranking and no token budget" and "reads identically on either surface",
  while `workspace.contextFor` is capped at `MaxContextBytes` (64 KiB) with an omission line and the
  Web UI's `WorkspaceService.getWorkspaceContext` is unbounded; and retrieval (§1) is
  container-scoped by `X-Jenova-Scope`, which only the window sends (inventory B33, B38). §5 now
  states the cap and the empty-FOCUS difference, and §1 and the opening of the document state the
  scoping and its consequence for Web UI turns.

### D-08 — "Conversation history — sent whole, never trimmed" is false · severity: medium

* **Claim:** `docs/context-and-retrieval.md:21` — `| 8 | Conversation history | client | Sent whole, never trimmed |`.
* **Source:** `pipeline.trimHistory(messages, budgetBytes)` is called inside `prepare`,
  recording the count in `Prepared.trimmed` (*"oldest turns dropped to fit the context
  budget"*; the `T-3` label once in that comment has since been stripped).
* **Fix:** document the budget, where it comes from, and that the oldest turns are dropped
  first. A user hitting silent history loss has no way to discover this today.

### D-09 — README model discovery vs. what the GUI model list actually shows · severity: medium

* **Claim:** `README.md:114-115` — *"`src/jenova/models.nim` discovers whatever `.gguf`
  files are in `~/Jenova/models/`."* `docs/usage.md:99-101` documents the resolution order
  including *"otherwise `models/*.gguf` in the flat root"*.
* **Source:** discovery is as documented, but the **GUI's Models panel** draws from
  `models.available`, which walks only `models.SourceRoles = ["instruct", "thinking"]`.
* **Consequence for a user following the README:** a `.gguf` placed in `~/Jenova/models/`
  or `~/Jenova/models/agent/` **is used for inference and never appears in the Models
  panel**. The restriction is deliberate (the `SourceRoles` doc comment). When found, the
  panel showed an empty list with no explanation; it now shows a "No models installed" status
  page naming `models/instruct/` and `models/thinking/` (parity finding P-C4).
* **Fix:** document in both README and `docs/usage.md` that the switcher's *sources* are
  `models/instruct/` and `models/thinking/`, distinct from discovery's search path.

### D-10 — Install instructions call `jenova-core` unqualified before it is on `PATH` · severity: low

* **Claim:** `docs/install.md:17` — `jenova-core hardware apply --best`, immediately after
  a build that puts binaries in `bin/` (`docs/install.md:20`: *"Both binaries land in `bin/`"*).
  Repeated at `docs/install.md:119-124`, `:129`, `:196`.
* **Fix:** use `./bin/jenova-core …` in the install flow, or add an explicit "put `bin/` on
  your `PATH`" step before the first bare invocation.
* **Residual, open.** The tracked `bin/jenova.desktop` has `Exec=jenova` and `Icon=jenova`;
  nothing installs it or the icon, and `jenova` is not on `PATH`, so the entry fails as shipped
  (inventory B20). Since 2026-09-30 `docs/usage.md` says so rather than claiming it launches
  `jenova`; installing it belongs to the install step (PLANS.md Stage 3).

---

## Part C — Stale statements (true once, not now)

### S-01 — `settings.nim`'s `awaiting` reasons point at work that has since shipped

When found, `src/jenova/settings.nim` marked four settings as not yet effective through the
`awaiting` field, each with the reason *"attachments — PLANS.md Step 7b (G-30)"* or *"audio
capture — PLANS.md Step 7b (G-30)"*, although attachments had shipped.

Two settings carry `awaiting` today, each with a reason that names what is actually missing:
`pdfAsImage` waits on a PDF rasteriser (`settings.nim:129`) and `autoMicOnEmpty` on audio
capture (`settings.nim:173`). `pasteLongTextToFileLen` is read by the composer
(`gui.nim:7250`) and `copyTextAttachmentsAsPlainText` by the message view (`gui.nim:4106`).
See parity finding P-C1.

### S-02 — Stale code comment: the composer claims drag-and-drop and paste are not implemented

`src/jenova/gui.nim:4956-4957`, on the paperclip button:
*"A file picker only — drag-and-drop and paste are the Web UI's other two routes and are
not here yet."* Both landed: the paste button is **eleven lines below the comment**
(`src/jenova/gui.nim:4964-4972`) and `DropZone` wraps the chat column at
`src/jenova/gui.nim:4838`. Delete the second clause. That was done, but the replacement comment
above the paperclip (`gui.nim:7197-7203`) still quotes the old clause as history, which AGENTS.md's
no-history rule forbids.

### S-03 — `jca_web/README.md` already self-documents one stale area; a second remains

`jca_web/README.md` correctly flags that `src/lib/services/index.ts` still describes a
Dexie/IndexedDB layer that no longer exists. A second instance is undocumented:
`jca_web/src/lib/services/sync.service.ts:100` — *"Pushes current IndexedDB state to the
backend as a JSON snapshot"* — describes the same removed layer. It sits on `push()`, which
nothing calls; the sidebar's sync button calls `SyncService.sync()`
(`ChatSidebarActions.svelte:38`). See parity finding P-C3.

### S-04 — `docs/context-and-retrieval.md` header asserts a verification date that no longer holds

`docs/context-and-retrieval.md:3` read *"Verified against the source tree on 2026-08-31."*
while findings D-06, D-07 and D-08 all stood in the same file. The line is gone; line 3 now
reads *"How content reaches the model."*

---

## Part D — Documented nowhere (gaps, not errors)

| # | Undocumented behaviour | Where it lives |
|---|---|---|
| G-01 | The response cache: 256-entry cap, 1 MiB per entry, oldest-first eviction, `X-Cache: HIT` header | `pipeline.cacheLookup`/`cacheStore`, `MaxCacheEntries`, `MaxCacheEntryBytes`; `server.nim` `handle` (hit splice) |
| G-02 | The five intent prefixes a user can type (`Visual Rewrite:`, `Open File Chat:`, `Chatbot:`, `Web Search:`, `Editor:`) | `pipeline.IntentPrefixes` — a user-facing feature with no user-facing documentation |
| G-03 | FOCUS notes escaping to the whole workspace tree | `workspace.contextFor` |
| G-04 | The `/debug/*` endpoints and the flag that enables them | `server.nim` `handle` (`rcDebug`), `server.start(enableDebug)` |
| G-05 | Attachment size ceiling and the refusal message | `pipeline.MaxAttachmentBytes`, `pipeline.readAttachment` |
| G-06 | Backend log files grew without rotation; `lifecycle.rotateLog` now moves a log over 8 MiB (`MaxLogBytes`) to `.1` when its backend starts | report 03, finding M-04 |
| G-07 | The GUI's only keyboard shortcut was `F11`; `gui.keyBindings` now holds five | `gui.keyBindings` |

---

## Tracker

| ID | Finding | Severity | State |
|---|---|---|---|
| A-1 | README banners are Web UI screenshots | high | **partly done** — both are now captioned as the Web UI, with alt text describing what they show and a pointer to the desktop section. The remaining half is A-2 |
| A-2 | No GUI screenshot exists | high | **open — not blocked.** Capturable on any supported host (FreeBSD or Linux); on this Arch host once `nimble gui` builds (`vte.nim` error, see PLANS.md). Capture is manual here: the mapped-window tools are absent |
| A-3 | Adopt surface-labelled presentation model | high | **partly done** — captions and an anchor to `#desktop-application` are in. Reordering so the window leads waits on A-2 |
| D-01 | `GET /api/workspaces` does not exist | high | **fixed** — row removed; `docs/usage.md` now says workspaces are listed through `/api/db/workspaces` and that anything else under `/api/` is a 404 |
| D-02 | "forwarded unchanged" fallback does not exist | high | **fixed (again, 2026-09-30)** — the prefix table from `routes.classify`, which #118 had made misroute `/v1/embeddings`, now sends it to :8082 (inventory B27) |
| D-03 | `/infill` is not augmented; tools are stripped not injected | medium | **fixed** — `/infill` and `/completion` are documented as forwarded verbatim and "tool results injected" as "tools stripped", for `Visual Rewrite:` and `Web Search:` only; since 2026-09-30 `usage.md` says the body decides augmentation (a JSON object with `messages`, on any forwarded path) rather than naming `/v1/chat/completions` alone |
| D-04 | Build does shell out to project scripts | medium | **fixed** — the claim is narrowed to the running product, with the Web UI build named as the exception; since 2026-09-30 README and `architecture.md` also name the runtime's `/bin/sh` conf evaluation and the other processes it starts |
| D-05 | Two `#!/bin/bash` scripts exist | low | **fixed as documentation** — the claim is narrowed to "every script the product builds or runs", both Web UI bash scripts are named, and since 2026-09-30 so are the vendored `jvim/pack/` bash scripts |
| D-06 | Retrieval index *is* populated | high | **fixed** — §1 lists the five writers and what a query costs; since 2026-09-30 it also documents the `X-Jenova-Scope` scoping and the fifth `query` parameter (inventory B33, B34) |
| D-07 | Workspace context and attachments are not Web-UI-only | high | **fixed (again, 2026-09-30)** — §5 and §6 cover both surfaces, and §5 now states the window's 64 KiB cap and the empty-FOCUS difference that #118 had made the old text contradict (inventory B38) |
| D-08 | History *is* trimmed | medium | **fixed** — §8 rewritten, and the silence itself fixed in code: a trimmed request now carries `X-Jenova-Trimmed` |
| D-09 | Model discovery vs. Models-panel sources | medium | **fixed** — both README and `usage.md` now state that discovery and the switcher read different directories, and why |
| D-10 | Bare `jenova-core` before `PATH` is set | low | **fixed** — the install step uses `./bin/`, with a note that the rest is written bare for readability. Residual open: `bin/jenova.desktop` needs `jenova` on `PATH` and is installed by nothing; `usage.md` says so since 2026-09-30 (inventory B20) |
| S-01 | Stale `awaiting` reasons | low | **fixed** — see report 03, W-01. Two are now wired; the other two name what they actually wait on, and a self-test refuses any reason that blames the finished step again |
| S-02 | Stale composer comment | low | **fixed in part** — the false clause is gone; the comment above the paperclip (`gui.nim:7197-7203`) still quotes it as history, to be cut when that code is next touched |
| S-03 | Stale IndexedDB comment in `sync.service.ts` | low | **open, low** — it was "won't fix" under the session-2 freeze, which the 2026-09-29T23:30Z ruling 4 supersedes |
| S-04 | False verification date | low | **fixed** — the date is removed rather than moved; a date is only worth printing if something re-checks it |
| G-01…G-07 | Undocumented behaviour | medium | **fixed** — see below; G-04's gap (`/api/_selftest/slow-query`) closed on 2026-09-30, and G-07 is superseded (five shortcuts) |

### Undocumented behaviour, now documented

| # | Behaviour | Where it went |
|---|---|---|
| G-01 | Response cache: 256 entries, 1 MiB each, oldest-first, `X-Cache: HIT` | `docs/architecture.md` § The response cache |
| G-02 | The five intent prefixes | `docs/usage.md` § Intent prefixes |
| G-03 | FOCUS notes escaping to the whole workspace tree | already in `docs/context-and-retrieval.md` §5; now correctly marked as applying to both surfaces |
| G-04 | `/debug/*` endpoints, off unless enabled | `docs/architecture.md` § Diagnostics, which since 2026-09-30 also names the debug-only `/api/_selftest/slow-query` (inventory B32) |
| G-05 | Attachment size ceiling and the refusal | `docs/usage.md` § Attachments |
| G-06 | Backend logs and the attachment cache | `docs/usage.md` § Disk that Jenova manages itself — **and both are now actually bounded**, see report 03 M-02 and M-04 |
| G-07 | `F11` is the only keyboard shortcut | `docs/usage.md` § The desktop application — superseded: `gui.keyBindings` holds five (F11, Ctrl+N, Ctrl+B, Ctrl+comma, Ctrl+Escape) and `usage.md` lists all five |

Also added: the response headers the pipeline emits (`docs/usage.md`), and how to run the
self-tests. `usage.md` § Self-tests carries no timing note, and after D-12's fix none is needed. The
header table's two wrong statements (inventory B25, B26) were corrected on 2026-09-30.

---

## Coverage gap found in session 4 — documentation I claimed to audit and did not

Ask 1 was "the readme and all documentation". Session 1 audited `README.md` and the five files
under `docs/`. It did not open:

| Never audited | Result of auditing it now |
|---|---|
| `hardware-profiles/README.md` (308 lines) | Profile tables **verified correct** against all six `jenova.conf` files, including the Drafter column, which I had suspected was wrong and is not — `JENOVA_DRAFT` is read in `lifecycle.llamaArgs` and all six values match. The tables re-verify; the file's other false claims were missed then (inventory B18, B43–B47, the `kern.ostype` and ARCHIVE lines) and corrected on 2026-09-30 |
| `docs/privacy.md`, second half | **Defect found** — see D-14 |
| `jca_web/README.md` claims | Reviewed then as holding only the stale statement it flags itself — wrong: three more defects, inventory B48–B50, still open |
| `jca_web/docs/**` (11 files) | **Still unaudited.** User-facing |
| `jvim/README.md` | First audited on 2026-09-29 — inventory B51–B56, B58, still open |

### D-14 — privacy.md's self-audit command does not support its own claim · severity: medium · **fixed**

The document said *"The outbound calls are the only `http` URLs in the runtime"* and handed the
reader `grep -rn 'https\?://' src/` to check it, and the output then held far more than the two
real hosts. At `4acedfa0` the command returns 28 lines: `html.duckduckgo.com` and
`api.duckduckgo.com` (`websearch.nim:90`, `:103`) are the real outbound hosts; the rest are
loopback (`rag.nim:227`, `gui.nim:928`), the project's GitHub URLs (`version.nim:23-24`), the
`LinkSchemes` constant (`markdown.nim:626`), and 21 self-test lines in `src/jenova_core.nim` — 20
fixtures (`x.example`, `img.example`, `i.example`, `rfc.example`, `e.example`) and one comment.

For a privacy document that invites verification, teaching a check whose output the reader cannot
interpret is worse than not offering one. The section first named the extras and offered a
narrowed command; it later withdrew the narrowed command and accounts for the full output line by
line instead, and on 2026-09-30 that table was brought up to the 28 lines above (inventory B41).

### D-15 — `etc/jenova.conf` has drifted from its source profile · severity: medium · **open, not changed here**

The deployed config sets `JENOVA_DRAFT=0`; its closest source profile,
`Vulkan/dgpu-igpu-i5-1135g7`, sets `1`, and the README's table says that profile has a drafter.
Speculative decoding is therefore off on the deployed configuration while three places document it
as on.

The drift came from commit `7b859f5` (#115) updating the profile without re-applying it —
`eee557e` (#113) had previously reverted a hand-edit for exactly this reason, so parity is the
established convention.

**Not fixed here.** It changes inference behaviour on the owner's own machine, and the correct
action is `jenova-core hardware apply` with the intended profile rather than a hand-edit of the
file — which is the thing #113 reverted. Re-applying the profile was thought to resolve it.

Still open, and that remedy does not work: `hardware apply` writes `$JCA_HOME/etc/jenova.conf`,
never the repository's copy, so re-applying bypasses the drifted file (`config.nim` then reads
`$JCA_HOME/etc/` whole, local conf included) but leaves the tracked copy drifted. On this host
`~/Jenova/etc/` does not exist, so the tracked `etc/jenova.conf` and the untracked
`etc/jenova.local.conf` are the live configuration. Under the 2026-09-29 ruling 4 the fix is
structural — see PLANS.md.

---

## Findings added in session 2

### D-11 — `PLANS.md` is referenced from ten places and does not exist · severity: low · **open (XS)**

`src/jenova_core.nim:20` named `.devdocs/PLANS.md` in a FreeBSD guard's **user-facing error
message**; that one was fixed first, to point at `docs/install.md`, and the guard itself has
since been removed. The one user-facing pointer to a document left in `src/` is
`pkgconfig.nim:15`'s build error, which names `docs/install.md`. Nine further references
remained in code comments as provenance markers (`settings.nim:2`, `convmd.nim:2`,
`composer.nim:6`, `pipeline.nim`, `gui.nim:280`, `gui.nim:3149`, `api.nim:688`, `api.nim:832`,
`fssync.nim:378`), and this finding left the choice open: restore the file, or strip the
references in a single pass.

**The decision was taken — strip — and it has been carried out.** Report 04 §2 D-01 widened it
from the dangling labels to the whole comment apparatus and settled on that option; report 03
records the same call as *"D-11 — WITHDRAWN AS FRAMED. The labels are the defect, not an asset"*.

**Verified against the tree, and the sweep did not reach all of it.** `grep -rn
'PLANS\.md\|TODOS\.md' src/` returns nothing — all nine Nim comment references are gone, and so is
the user-facing one. **Four remain in `tests/`**, all the same `TODOS.md A-2` provenance marker in
a comment explaining why a guard fails rather than exiting 0:

```
tests/test_api_db.sh:22   tests/test_api_fs.sh:28
tests/test_lifecycle.sh:23  tests/test_routes.sh:26
```

They are the last of the class, in the one directory report 04's batches did not cover, and all
four are still present. `.devdocs/PLANS.md` exists again and `TODOS.md` carries no `A-2`, so the
label resolves to nothing. Stripping them is the remainder of this finding and is XS.

### D-12 — `db-selftest` carries a wall-clock assertion that fails under load · severity: low · **fixed**

`db-selftest` measures what fraction of a reader's run overlapped a concurrent writer and fails
below a 25% floor. Observed failing at 23.3% and 23.6% on a loaded container, passing on re-runs of
the same binary, with `src/jenova/db.nim` untouched.

The property it tests is real and worth testing. The **threshold** is not robust: it is a
wall-clock ratio on a machine whose scheduling the test does not control, so it will fail on a
single-core or busy host with nothing wrong. `docs/usage.md` carries no note on it; after the fix
below none is needed.

**Fixed, and the diagnosis above was half wrong — the metric was the defect, not the threshold.**
Overlap was scored as a fraction of the *reader's* own span, so a reader was penalised for
outliving the writer. Two intervals of length `a` and `b` overlap by at most `min(a, b)`, so that
is the denominator now (`dbselftest.nim:15-20`), with a separate branch for the degenerate timing
that would otherwise read as a serialized layer (`:100-120`). Eight consecutive runs pass with
every reader at 100.0%: the concurrency was always there and the old measure could not see it.
Tracked to completion as report 03's D-12 row.

---

## Product-doc findings at 4acedfa0 (2026-09-29T22:30Z)

Inventory for PLANS.md, which schedules the corrections; the product docs are not edited here. Doc
lines are at `4acedfa0` (the docs are unchanged since #117). `install`, `usage`, `arch`, `c&r`,
`privacy` = `docs/*.md`; `hw` = `hardware-profiles/README.md`; `web` = `jca_web/README.md`;
`jvim` = `jvim/README.md`. Severity H/M/L.

**Status 2026-09-30T01:16Z.** README, the five `docs/*.md` files and `hardware-profiles/README.md`
were corrected against the code, and the platform framing rewritten under rulings 1 and 2: every
`K` and `B` row on those files is corrected in the text, with the code behind it unchanged — so
where a row describes a defect in the product (B8's configuration switch-over, B20's uninstalled
desktop entry, B31's reachable embeddings, B57's `vte.nim` build failure), the docs now state it
rather than contradict it, and the defect stays open in PLANS.md. Still open as documentation:
`jca_web/README.md` (B48–B50) and `jvim/README.md` (B51–B56, B58); the four user-facing string
defects below; and the rows under *Claims that must change under the 2026-09-29 rulings* that
depend on the install step (ruling 4) and the self-test move (ruling 5), which wait on that work.
The line numbers above are those of `4acedfa0` and no longer match the corrected files.

**Already known — one line each.**
- K1 — README:165-168, install:10-11 and :230-231, hw:216-217: detection reads `kern.ostype` and applies no profile off FreeBSD — `hardware.detectOs` hardcodes "FreeBSD"; on this host `detect` matched `CPU/generic`.
- K2 — README:151, :153; arch:14, :199-201: per-profile ZFS ARC tuning and an `mdmfs`/Optane swap-backed model store — neither exists (`mdmfs` appears only in comments: `models.nim`, and `Vulkan/dgpu-i5-1135g7/jenova.conf` lines 11 and 98).
- K3 — hw:259-260: links `.devdocs/ARCHIVE/hardware-profiles/`, which does not exist.
- K4 — install:101-109: the "no GPL tools" policy (superseded by ruling 2).
- K5 — README:155: "Supported elsewhere: No" (superseded by ruling 1).

**False claims.**

| # | Doc:line | Claim | Truth (evidence) | Sev |
|---|---|---|---|---|
| B1 | README:33-35 | nothing running shells out to a project script | `config.load` evaluates the shell-format conf files with `/bin/sh`; arch states this, README does not | L |
| B2 | README:46-47, :82-84; arch:25 | `jenova` supervises the backends | only `serve` has the watchdog; quitting the window stops only the embed backend and leaves `llama-server` running (`gui.run`) | M |
| B3 | README:66-67; arch:172; privacy:68 | chats are mirrored to `Workspaces/` as Markdown | true of the Web UI only: it writes every chat to `Workspaces/` as Markdown through `/api/storage` (`sync.service.ts`, `conversations.svelte.ts`). The window's chats are not mirrored; one exports on demand (`exportConversationMarkdown`). `fssync` itself mirrors workspaces, projects, folders, notes and file assets | M |
| B4 | README:77-78; usage:46 | live per-service health | the window polls the agent backend only (`ctlWorker` `poll`, `beLlama`); the tray reflects that one result as Active or Passive (`tray.setStatus`) | M |
| B5 | README:88-90 | window and tray toggle "the same thing" as `serve --lan` | the toggle writes `.system/lan_mode`; the bind address reads it only at the next `jenova` start (`isLanEnabled`), the 3 s poll re-reads it for the display only, and `serve` never reads it | L |
| B6 | README:112-113; hw:4-5; arch:11-12 | detection runs at install, detects RAM, deploys an overlay | manual (`hardware apply --best` or the Hardware panel); RAM is not scored (`scoreProfile`); apply replaces `$JCA_HOME/etc/jenova.conf` (`applyProfile`) | L |
| B7 | README:159 | `grep -rn 'defined(freebsd)' src/` returns nothing | it returns the `jenova_core.nim` header comment that quotes it | L |
| B8 | README:192; usage:157, :209; arch:31-34 | the repo `etc/`, incl. `jenova.local.conf`, is the active config | after `hardware apply`, `config.configDir` reads `$JCA_HOME/etc/` whole and the repo `etc/` (local conf included) stops applying; undocumented | H |
| B9 | README:201; arch:20 | `src/jenova/` = the modules both binaries link | canvas, dbus, gui, shortcuts, sourceview, theme, tray and vte are GUI-only | L |
| B10 | README:174-182, :186-205 | docs index; repository layout | omit `jvim/` (the embedded editor's runtime config, `nvimctl.editorEnv`) and `jvim/README.md` | L |
| B11 | README:216; arch:9-10 | web search runs "when a model invokes it" | only the `Web Search:` intent triggers it (`pipeline.prepare`); privacy:24 says no model can | M |
| B12 | install:9-11 | off FreeBSD only hardware detection breaks | also the LAN address (`lanAddress`: BSD `route`/`ifconfig`; shows 0.0.0.0 here) and the storage/swap probes; the tests need `nc` (`sockstat` appears only in the docs' own commands, install:210 and privacy:111) | M |
| B13 | install:53-90 | the package list is complete; the headless build needs no GUI stack | missing: PCRE2 (`std/re` in `hardware.nim` loads `libpcre2-8.so.0` at run time, both binaries), HarfBuzz (`mathfont`, linked into both binaries through pkg-config), FreeType (GUI), zlib (`zlib.nim`, `-lz`), neovim (run time, the embedded editor). `nc` is listed, but only as a FreeBSD base tool (install:97), and only the test suites use it. Floors unstated: Nim ≥ 2.2.10, GTK ≥ 4.10, libadwaita ≥ 1.4 | M |
| B14 | install:71 | git is only for cloning | runtime dependency: every workspace is a git repository (`fssync.gitInit`, `gitAdd`); workspace sync fails without it | M |
| B15 | install:73 | `db.nim` links libsqlite3 | loaded at run time (`SqliteLib`, `dynlib`) | L |
| B16 | install:44; README:40; usage:123 | `nimble suites` = build both binaries, run the suites | it also runs `nimble web` (`npm install`, network), the 22 self-tests and the GUI harnesses | L |
| B17 | install:96-97, :106 | base tools needed incl. pciconf, mdmfs, realpath, stat; coreutils wanted "only for realpath" | pciconf and mdmfs appear only in comments; realpath and stat are unused | L |
| B18 | install:178-180; usage:229-230; hw:175-177 | every `profile.conf` names RECOMMENDED_* models with a URL | `Vulkan/dgpu-igpu-i5-1135g7/profile.conf` has none | M |
| B19 | usage:44-47 | the window is `jenova-core` plus GTK; window and tray offer the same operations | no watchdog, ignores `JENOVA_NO_BACKENDS`, stops only embed on quit; the window has "Models…" only, the named switch items are tray-only | M |
| B20 | usage:49 | `jenova.desktop` launches `jenova` | `Exec=jenova`/`Icon=jenova`, never installed; install:31 says `jenova` is not on `PATH` | L |
| B21 | usage:70, :72; c&r:158-162 | file-chat gets more retrieval; Web Search skips retrieval | file-chat gets 3 hits like no prefix; the >2000-char `Path:` rewrite and the 5-hit limit apply to every intent (`ragLimitFor`, `ragQueryFor`) | L |
| B22 | usage:209-215 | `JENOVA_*_MODEL` may be set in `etc/jenova.local.conf` | inert there: `models.discover` reads them with `getEnv`, and conf evaluation returns only `config.Keys`; use `MODEL_PATH`/`MODEL_DRAFT`/`MODEL_EMBED` | H |
| B23 | usage:240-242, :264-265 | switching from the window or tray restarts the backend | neither restarts ("restart to load it", `ctlWorker`; `modelsPanel` says so); labels are lowercase and tray-only | M |
| B24 | usage:269-297 | the request contract | undocumented `X-Jenova-Scope` header scopes retrieval (`rag.parseScope`, `rag.inScope`); absent means unassigned items only; only the window sends it | H |
| B25 | usage:301 | headers appear only when there is something to report | `X-Jenova-Msg-Count` and `-Body-Bytes` on every chat completion, usually `-Sys-Bytes` and `-Injected` too (`diagnosticHeaders`) | L |
| B26 | usage:321-322 | a cache hit replays the original turn's diagnostics | the opposite: the current request's are spliced in and the stored bytes carry none (`server.nim` `handle`) | M |
| B27 | usage:332-333 | every `/v1/` path goes to :8081 | `/v1/embeddings` goes to :8082 (`routes.classify`) | M |
| B28 | usage:171-174 | `.gguf.old` is skipped because it no longer ends in `.gguf` | the rule is `models.isBackup`, which also excludes `X.old.gguf` | L |
| B29 | arch:31 | everything but llama.cpp lives in the repo | owlkettle is fetched by nimble; the Web UI's deps by npm | L |
| B30 | arch:31-35; `jenova-core help` | the environment has top precedence | only the `JENOVA_*` names the confs read win; an exported Key is overwritten by the conf; path keys are environment-only (`paths.resolve`) | M |
| B31 | arch:43-47 | :8082 is reached in-process only; embeddings never cross the public surface | `/embed*` and `/v1/embeddings` on :8080 relay to :8082, unauthenticated and LAN-reachable under `--lan` | M |
| B32 | arch:105-109 | the diagnostics endpoints | omits the debug-only `/api/_selftest/slow-query` | L |
| B33 | c&r:29-31, :315 | retrieval applies to every client, on both surfaces | scoped (B24): the Web UI, curl and OpenAI clients see only unassigned items, so Web UI workspace chats never retrieve workspace content | H |
| B34 | c&r:75, :88 | `rag.query(queryStr, topK, withSnippets, pathFilter)`; the filter is `pathFilter` alone | a fifth parameter, `scope`, filters both halves | M |
| B35 | c&r:135-146 | the contract order ends persona, tool stripping, cache key | tool stripping runs second, before retrieval; history trimming runs after persona and is missing from the list (`pipeline.prepare`) | M |
| B36 | c&r:164-165 | nothing sets the prefixes for you | the composer menu prepends them (`intentMenuItems`); jvim sends `Visual Rewrite:` and `Web Search:` (`chat.lua`) | M |
| B37 | c&r:219-220; privacy:24 | no button can trigger web search | the GUI intent menu; jvim `<leader>as`, `:JenovaWebSearch`, the dashboard entry | M |
| B38 | c&r:229-231, :251-253 | reads identically on both surfaces; no truncation, ranking or budget | `workspace.contextFor` is capped at `MaxContextBytes` (64 KiB) with an omission line; the Web UI is unbounded | M |
| B39 | c&r:104 | backfill runs at every `serve` start | in the watchdog thread, at least 30 s after start, once :8082 answers; never under `JENOVA_NO_BACKENDS` | L |
| B40 | privacy:20-27 | "four things" reach the network | missing: the npm registry (`nimble web`); `www.google.com/s2/favicons` once an MCP server is configured (web `getFaviconUrl`; Jenova 404s `/cors-proxy`); the standalone jvim sweep of each local IPv4 network (`lan.lua` `generate_candidates`: prefix clamped to /16, at most 1024 addresses per network), TCP to :8080 and then `curl` to :8081 `/health` on each host that answers | H |
| B41 | privacy:120, :130 | the grep returns about twenty lines; fixtures about a dozen | 28 lines; 21 of them self-test fixtures in `jenova_core.nim` (one a comment), including `e.example` and `i.example` | L |
| B42 | privacy:136-148 | the runtime's network scope | `bin/jenova` spawns Neovim with the in-repo jvim config, whose traffic is not covered | L |
| B43 | hw:3 | each profile sets the model | no `jenova.conf` sets `MODEL_PATH`; contradicts hw:30 | M |
| B44 | hw:30-34 | discovery takes the alphabetically first `.gguf` | `active.gguf` first, the flat root last (`models.agentModel`, `discover`) | L |
| B45 | hw:35-37 | model names in profiles are read by nothing | `PROFILE_DESC` is read (`readProfile`) and shown in `hardwarePanel`; dgpu-igpu's three model names disagree | L |
| B46 | hw:189-197 | the scoring table | lacks "MATCH_GPU_1 matches +5" (`scoreProfile`), which hw:200-201 relies on | L |
| B47 | hw:235, :289, :292 | "extended regex"; `JENOVA_HOST` moves "the proxy" | Nim `re` (PCRE), case-insensitive (`matchesRe`); it is the server, not a proxy | L |
| B48 | web:100 | the Web UI fetches nothing from a third party | Google's favicon service once an MCP server is configured (B40) | H |
| B49 | web:55-56 | Node 20+ and npm 10+ suffice | `dev` needs bash (`scripts/dev.sh`); a watch-mode `test:ui` spawns `pnpm run storybook --no-open` (`vite.config.ts:83`; the Storybook addon starts it only in watch mode, and `test` passes `--run`); the `ui` test project's setup file `./.storybook/vitest.setup.ts` does not exist — there is no `.storybook/` directory | L |
| B50 | web:61 | the dev server is on localhost:5173 | it binds 0.0.0.0 (`scripts/dev.sh`); the dev proxy omits `/api/fs`, `/health`, `/embed*`, `/infill`, `/completion`, `/slots` | L |
| B51 | jvim:18-24, :59 | `./install.sh` | does not exist | M |
| B52 | jvim:62 | `colors/jvim.lua` | it is `colors/jvim.vim`, beside 28 stock schemes | L |
| B53 | jvim:9 | Telescope, nvim-tree, lualine, which-key and others are "replaced" | all still vendored and auto-loaded from `pack/jenova/start/` | L |
| B54 | jvim:11, :84, :227, :255, :320 | LAN discovery; remote monitoring | cannot work as documented: a host answering on :8080 is validated with `curl` on port + 1, :8081 `/health` (`lan.lua` `validate_health`), which binds loopback only, while :8080 serves `/health` itself; without `curl` the check is skipped and any host accepting a connection on :8080 is taken; `monitor.lua` polls :8081 too | M |
| B55 | jvim:300 | `JENOVA_LLAMA_PORT` is the FIM port | FIM uses `JENOVA_PORT` :8080 `/infill` (`endpoints.fim_url`) | L |
| B56 | jvim:301 | `JENOVA_LAN_MODE=1` is needed to auto-scan | standalone jvim scans by default when no local server answers (`init.lua`); `JENOVA_LAN_SCAN=0` and `JENOVA_LLAMA_EMBED_PORT` are undocumented | M |
| B57 | README:154; install:6-7; arch:15; privacy:115-116 | builds and runs wherever Nim, GTK4 and libadwaita do | `nimble gui` fails on this host under gcc 16.2 and clang 22.1 (`vte.nim` binds `GdkRGBA` as a Nim object for the header-declared `vte_terminal_set_colors`); Debian 12 is below the toolkit floor | H |
| B58 | jvim:10 | vendored and self-contained, CMP engine included | `.gitignore` `core.*` keeps `nvim-cmp/lua/cmp/core.lua` out of git, so a fresh clone gets a broken nvim-cmp | M |
| B59 | privacy:24 | web search only when a client message begins `Web Search:` | `pipeline-selftest` (run by `nimble suites`) feeds `prepare` a `Web Search:` turn and makes live DuckDuckGo requests | M |

*Unverified:* jvim:10 "zero internet required on initial boot" — `lua/plugins/editor.lua` gives
nvim-treesitter an `ensure_installed` list and no parsers are vendored; whether the vendored
treesitter honours it and downloads them was not checked.

**Claims that must change under the 2026-09-29 rulings.**

| Doc:line | Must change | Ruling |
|---|---|---|
| README:10, :143-168 | FreeBSD-only framing and platform table; the "no OS conditional, guard removed" narrative | 1, 3 |
| install:3-12 | FreeBSD-only; "the package names below are FreeBSD's"; "nothing in the source is FreeBSD-only" | 1, 3 |
| install:53-99 | the `pkg(8)` line, Port column, `devel/nimble` note and FreeBSD base-tool list → lists for FreeBSD, Arch, Debian and Fedora | 1 |
| install:119-126, :164-172, :207-211; arch:197-198 | `drm-kmod`/`sysrc`, `vfs.zfs.arc_max` and `sockstat` are FreeBSD-only | 1 |
| install:101-109; web:107-109 | the GPL-exclusion rationale; OFL "check against the dependency policy" | 2 |
| install:22, :42, :137-139; README:25; arch:27 | Vulkan hard-wired in `nimble llama`, CUDA by manual copy → build-time detection | 3 |
| install:14-46, :187-199, :215-224; README:21-31, :96 | build into and run from the checkout (`./bin`, `public/`, `external/ext_bin`); updating = pull and rebuild in place | 4 |
| README:186-207 | the layout presents `bin/`, `etc/` ("Active configuration"), `external/ext_bin/` and `public/` as in-repo runtime locations, and `src/jenova/` as one flat tree | 4, 5 |
| arch:13-15, :23-26, :31-35, :133-141, :215-223 | "FreeBSD-native"; components as `bin/*`; the repo `etc/` in the hierarchy; `public/` served from the repo; source vs installed layouts | 1, 4 |
| usage:49 | the tracked `bin/jenova.desktop` | 4 |
| web:6-8, :62, :73-74 | the Web UI builds into the repo's `public/` | 4 |
| jvim:20-35 | install by symlinking the repo; the window loads `<root>/jvim` | 4, 5 |
| hw:3, :14, :212-214, :237 | "on FreeBSD", "the default on FreeBSD", "set `MATCH_OS="FreeBSD"`" (all six `profile.conf` files set it; three `jenova.conf` headers say FreeBSD 15: `apu-ryzen7-5700u`, `dgpu-i5-1135g7`, `dgpu-igpu-i5-1135g7`) | 1 |
| hw:60-87 | `Vulkan0` = GTX 1650 Ti and `Vulkan1` = Iris Xe is FreeBSD's order; `--list-devices` on this Linux host reports the reverse | 1 |
| privacy:27, :111-118, :36-37, :136 | "FreeBSD `pkg` mirrors", "tuned for FreeBSD"; the `bin/` paths | 1, 4 |
| README:103; usage:120-129; arch:87-88; c&r:188-190 | the self-tests are subcommands of the product binary; changes if they move out | 5 |
| `jenova_core.nimble` `description` | "native FreeBSD desktop application" | 1 |

**User-facing string defects.**
- `jenova-core backends start` and `serve` print "build it with: make llama" / "(make llama)"; there is no Makefile — the task is `nimble llama`.
- `jenova-core help` (`usage`) omits the dispatched `models` verb (`list`, `switch`), though `main`'s own comment says a verb cannot exist without appearing there.
- `jenova_core.nim`'s header says FreeBSD support "is stated in `--version`"; `--version` is rejected as an unknown command (the verb is `version`).
- `websearch.formatContext` tells the model "install curl or use FreeBSD".
- `pkgconfig.pkgQuery`'s build error names only the FreeBSD port.

**Inert configuration.**
- Read by nothing: `API_URL`, `LLAMA_URL`, `LLAMA_EMBED_URL`, `MAX_TURNS`, `MAX_ACTIONS`, `TIMEOUT`, `JENOVA_HEALTH_TIMEOUT`. `etc/jenova.conf`, `dgpu-generic-12gb`, `dgpu-i5-1135g7` and `dgpu-igpu-i5-1135g7` set all seven; `CPU/generic` omits `MAX_TURNS`, `MAX_ACTIONS` and `TIMEOUT`; `apu-ryzen7-5700u` omits `JENOVA_HEALTH_TIMEOUT`; `CUDA/dgpu-generic` sets none.
- Read, but absent from `config.Keys`, so always the default: `CANVAS` (`gui.nim`), `BACKEND_BIND_HOST` (`lifecycle.init`).
- In `Keys` but honoured only from the environment (`paths.resolve`): `JCA_HOME`, `JENOVA_STATE`, `LOG_DIR`, `CACHE_DIR`, `PID_FILE`, `LLAMA_SERVER` — `jenova-core config` prints the conf value and nothing uses it; the repo `etc/jenova.local.conf`'s `LLAMA_SERVER` and `GGML_VK_ALLOW_SYSMEM_FALLBACK` lines are inert.
- `JENOVA_MODEL`, `JENOVA_DRAFT_MODEL` and `JENOVA_EMBED_MODEL` in a conf file (B22).
