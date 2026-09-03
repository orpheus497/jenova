# Report 01 — Documentation and Presentation Audit

**Status:** Part A open (needs a FreeBSD host); Parts B, C and D **closed**
**Last worked:** session 2 — every factual defect below is fixed in `docs/` and `README.md`
**Scope:** `README.md`, `docs/*.md`, `jca_web/README.md`, `hardware-profiles/README.md`, `png/`
**Method:** every factual claim in the user-facing documentation was read against the
source that implements it. Each finding below cites the documentation line and the
source line that contradicts it. Claims that could not be checked against source are
marked *unverified* rather than asserted.
**Audited at commit:** `c5111ce`

---

## Part A — The presentation problem: the screenshots show the Web UI, not the GUI

### A-1. Both README banners are Web UI screenshots, presented as generic branding

`README.md:3` and `README.md:202` embed `png/splash_top.png` and `png/splash_bottom.png`
with the alt text *"Jenova Cognitive Architecture banner"* / *"… footer"*.

Both images are screenshots of the **SvelteKit Web UI**, identifiable without ambiguity:

| Evidence in the image | Source it belongs to |
|---|---|
| `Press `Enter` to send, `Shift + Enter` for new line` helper line | `jca_web/.../ChatFormHelperText.svelte` |
| Placeholder `Chat with Jenova...` | `jca_web/.../ChatFormTextarea.svelte:21` |
| Sidebar rows `MCP Servers`, `Push`, `Pull` | `jca_web/.../ChatSidebarActions.svelte` — **none of these exist in the GTK window** |
| `Canvas Idea` toggle pill in the composer | Web-only control |
| Browser-style flat sidebar with no GTK `HeaderBar` | — |

The GTK window's own composer placeholder is `Message Jenova…` (`src/jenova/gui.nim:5000`),
its sidebar has no MCP entry and no Push, and it carries an Adwaita `HeaderBar` with a
window title and subtitle (`src/jenova/gui.nim:4519-4531`). Nothing in either screenshot
is the desktop application.

**Why this matters beyond accuracy.** `README.md:53-70` states that the desktop
application is the product and that `jenova` *is* the server, and the project's own
direction is that the GUI becomes the primary surface. The two largest visual assets in
the README teach the opposite: a first-time reader forms their entire mental model of
"what Jenova looks like" from a client the README elsewhere calls the LAN client.

**Severity:** high (presentation), because it is the first thing a reader sees.

### A-2. There is no GUI screenshot anywhere in the repository

`png/` holds seven files. Five are icons/logos (`jca.jpg`, `jca_grey.jpg`, `jenova.jpg`,
`jenova.png`, `jvim.jpg`, all ~900×900 square marks). Two are the Web UI screenshots
above. **No image of the GTK4 window exists.** The window's distinguishing surfaces —
the Models panel, the Hardware profile panel, the Trash panel, the Settings panel with
its six sections, the embedded Neovim page, the neural canvas behind the chat column —
are undocumented visually.

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

---

## Part B — Factual defects in the documentation

Each is a statement that a reader can act on and that the source contradicts.

### D-01 — `GET /api/workspaces` is documented but does not exist  · severity: high

* **Claim:** `docs/usage.md:178` — `| GET /api/workspaces | List workspaces |`, under the
  heading *"Handled by the server"*.
* **Source:** `src/jenova/server.nim:260-273` dispatches exactly three API prefixes:
  `/api/db/`, `/api/fs/`, `/api/storage`. Anything else under `/api/` falls to
  `src/jenova/server.nim:274-275`, which answers `404 {"error":"not found", …}`.
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
  `rcStatic`, and `src/jenova/server.nim:160-163` answers a missing file with
  `404 text/plain "not found: <path>"`. No code path hands an unmatched request to
  `upstream.forward`.
* **Consequence.** The conclusion drawn in the same paragraph ("The rest of its
  OpenAI-compatible surface … is therefore reachable") is accidentally true for
  `/v1/models`, `/v1/completions` and `/props` — they match the listed prefixes — but the
  stated *reason* is wrong, and any llama.cpp endpoint outside those prefixes is **not**
  reachable. This is the same mechanism behind finding D-03 and parity finding P-C2.
* **Fix:** replace the paragraph with the explicit prefix list from `routes.nim:classify`,
  and state that anything else is served from `public/` or 404s.

### D-03 — `POST /infill` is documented as augmented; it is passed through untouched · severity: medium

* **Claim:** `docs/usage.md:185-186` — *"`POST /v1/chat/completions` and `POST /infill` are
  intercepted so retrieval context and tool results can be injected."*
* **Source:** `src/jenova/pipeline.nim:350-356`. `prepare` returns `rawBody` unchanged when
  the body does not parse as a JSON object carrying `messages`. `/infill` and
  `/completion` carry a raw prompt and no `messages` array, so nothing is injected. The
  module header says so directly at `src/jenova/pipeline.nim:17-20` of `server.nim`'s
  comment block (`src/jenova/server.nim:186-188`): *"`/infill` and `/completion` carry a raw
  prompt with no messages to inject into, so `prepare` returns them untouched."*
* **Secondary error in the same sentence:** the pipeline **strips** tools for two intents
  (`src/jenova/pipeline.nim:374-377`); it never injects tool results. No tool-result
  injection exists anywhere in `src/`.
* **Fix:** restrict the sentence to `POST /v1/chat/completions`, and say
  *"intent detection, retrieval, web search, editor context, persona injection and tool
  stripping"* rather than "tool results".

### D-04 — "no build or runtime step shells out to a project script" is false at build time · severity: medium

* **Claim:** `README.md:29-30` — *"There is no Makefile, and no build or runtime step shells
  out to a project script."* Restated at `docs/architecture.md:33` — *"nothing in the
  running product depends on a project shell script."*
* **Source:** `nimble web` (`jenova_core.nimble`, task `web`) runs `npm run build`, which is
  `jca_web/package.json:9`:
  `"build": "vite build && node scripts/finalize-build.js && ./scripts/post-build.sh"`.
  `jca_web/scripts/post-build.sh` and `jca_web/scripts/finalize-build.js` are both project
  scripts in this repository.
* **Note on precision:** the *runtime* claim in `docs/architecture.md:33` is correct — no
  running surface shells to a project script. Only the **build** claim in `README.md:29`
  is wrong.
* **Fix:** narrow `README.md:29` to *"no runtime step shells out to a project script; the
  Web UI build runs two scripts under `jca_web/scripts/`."*

### D-05 — "Every script in this repository is POSIX `/bin/sh`" is false · severity: low

* **Claim:** `docs/install.md:95`, in the table *"Deliberately not used"* —
  `| **bash** | Every script in this repository is POSIX /bin/sh |`.
* **Source:** two scripts are `#!/bin/bash`:
  * `jca_web/scripts/dev.sh:1`
  * `jca_web/scripts/install-git-hooks.sh:1` (and the hook it writes, at line 30)
  and `jca_web/package.json:8` invokes one explicitly: `"dev": "bash scripts/dev.sh"`.
* **Note:** all six suites under `tests/` and `jca_web/scripts/post-build.sh` **are**
  `#!/bin/sh`. The claim is true of everything except the two Web UI developer scripts.
* **Fix:** either convert the two scripts to `/bin/sh` (preferred — they are short and the
  stated dependency policy excludes GPL tooling), or narrow the claim to
  *"every script the product builds or runs"*.

### D-06 — `docs/context-and-retrieval.md` states the retrieval index is never populated; it is · severity: high

* **Claim:** `docs/context-and-retrieval.md:14` —
  `| 1 | Server-side retrieval (BM25 + vectors) | src/jenova/rag.nim | **Query path live, index never populated** |`
  Repeated at `docs/context-and-retrieval.md:254`.
* **Source:** three production writers now exist.
  1. `src/jenova/api.nim:1123` and `:1161` — the `/api/db/messages` create and update
     routes call `rag.indexExchange`, so **every Web UI message is indexed**.
  2. `src/jenova/api.nim:508, 520` — restore-from-trash re-indexes.
  3. `src/jenova/gui.nim:874` — the desktop window's control worker indexes each
     completed exchange; `src/jenova/gui.nim:865` runs `rag.backfillChats()` once the
     embedding server answers.
  4. `src/jenova_core.nim:3622` — `serve` runs `rag.backfillChats()` at start.
* **Severity is high because the direction of the error is dangerous:** the document tells
  a user that a working feature does not work. Anyone tuning retrieval will read this and
  stop.
* **Fix:** rewrite §1's state to *"live; populated by the API message routes, by the
  desktop window's index worker, and backfilled at every `serve` start."*

### D-07 — `docs/context-and-retrieval.md` mechanisms 5, 6, 7 are marked "Web UI only" and two of them are not · severity: high

* **Claim:** `docs/context-and-retrieval.md:18-20` and the section headings at `:194`,
  `:221`, `:230`.
* **Source:**
  * **Mechanism 5, workspace context** — `src/jenova/workspace.nim` is a server-side
    module; `src/jenova/gui.nim:1818-1823` calls `workspace.contextFor(folderId,
    projectId, workspaceId)` for the active conversation and passes it into
    `pipeline.chatBody`. It is **not** Web UI only.
  * **Mechanism 6, per-message attachments** — the desktop window has a full attachment
    path: file picker (`src/jenova/gui.nim:1859`), drag-and-drop (`DropZone`,
    `src/jenova/gui.nim:2585`), clipboard image paste (`src/jenova/gui.nim:2559`), PDF text
    extraction (`src/jenova/pdf.nim`), thumbnails, an image preview panel
    (`src/jenova/gui.nim:4359`), and `messages.extra` written in the Web UI's own shape
    (`src/jenova/gui.nim:1923`). It is **not** Web UI only.
  * **Mechanism 7, MCP tools** — this one *is* still Web UI only. Correct as written.
* **Fix:** re-mark 5 and 6 as *"both surfaces"*, rewrite §5 and §6 to describe the
  server-side and GTK paths, and keep §7 as-is.

### D-08 — "Conversation history — sent whole, never trimmed" is false · severity: medium

* **Claim:** `docs/context-and-retrieval.md:21` — `| 8 | Conversation history | client | Sent whole, never trimmed |`.
* **Source:** `src/jenova/pipeline.nim:330` defines `trimHistory(messages, budgetBytes)`
  and `src/jenova/pipeline.nim:422` calls it inside `prepare`, recording the count in
  `Prepared.trimmed` (`src/jenova/pipeline.nim:51`, *"T-3: oldest turns dropped to fit the
  context budget"*).
* **Fix:** document the budget, where it comes from, and that the oldest turns are dropped
  first. A user hitting silent history loss has no way to discover this today.

### D-09 — README model discovery vs. what the GUI model list actually shows · severity: medium

* **Claim:** `README.md:114-115` — *"`src/jenova/models.nim` discovers whatever `.gguf`
  files are in `~/Jenova/models/`."* `docs/usage.md:99-101` documents the resolution order
  including *"otherwise `models/*.gguf` in the flat root"*.
* **Source:** discovery is as documented, but the **GUI's Models panel** draws from
  `models.available` (`src/jenova/models.nim:268-288`), which walks only
  `SourceRoles = ["instruct", "thinking"]` (`src/jenova/models.nim:250`).
* **Consequence for a user following the README:** a `.gguf` placed in `~/Jenova/models/`
  or `~/Jenova/models/agent/` **is used for inference and never appears in the Models
  panel**, which shows an empty list with no explanation. The restriction is deliberate
  (ruling D-CB, quoted at `src/jenova/models.nim:251-253`) but is documented nowhere the
  user will look.
* **Fix:** document in both README and `docs/usage.md` that the switcher's *sources* are
  `models/instruct/` and `models/thinking/`, distinct from discovery's search path, and
  make the GUI panel say so when it finds nothing (see parity finding P-C4).

### D-10 — Install instructions call `jenova-core` unqualified before it is on `PATH` · severity: low

* **Claim:** `docs/install.md:17` — `jenova-core hardware apply --best`, immediately after
  a build that puts binaries in `bin/` (`docs/install.md:20`: *"Both binaries land in `bin/`"*).
  Repeated at `docs/install.md:119-124`, `:129`, `:196`.
* **Fix:** use `./bin/jenova-core …` in the install flow, or add an explicit "put `bin/` on
  your `PATH`" step before the first bare invocation.

---

## Part C — Stale statements (true once, not now)

### S-01 — `settings.nim`'s `awaiting` reasons point at work that has since shipped

`src/jenova/settings.nim` marks four settings as not-yet-effective via the `awaiting`
field (`src/jenova/settings.nim:76`, `:82`, `:126`, `:157`), all with the reason
*"attachments — PLANS.md Step 7b (G-30)"* or *"audio capture — PLANS.md Step 7b (G-30)"*.

Attachments (G-30) have shipped in full. The three attachment-linked settings —
`pasteLongTextToFileLen`, `copyTextAttachmentsAsPlainText`, `pdfAsImage` — are still
unwired, but the reason shown to the user now names a completed step. See parity finding
P-C1; this is tracked there as behaviour and here as text.

### S-02 — Stale code comment: the composer claims drag-and-drop and paste are not implemented

`src/jenova/gui.nim:4956-4957`, on the paperclip button:
*"A file picker only — drag-and-drop and paste are the Web UI's other two routes and are
not here yet."* Both landed: the paste button is **eleven lines below the comment**
(`src/jenova/gui.nim:4964-4972`) and `DropZone` wraps the chat column at
`src/jenova/gui.nim:4838`. Delete the second clause.

### S-03 — `jca_web/README.md` already self-documents one stale area; a second remains

`jca_web/README.md` correctly flags that `src/lib/services/index.ts` still describes a
Dexie/IndexedDB layer that no longer exists. A second instance is undocumented:
`jca_web/src/lib/services/sync.service.ts:100` — *"Pushes current IndexedDB state to the
backend as a JSON snapshot"* — describes the same removed layer, on a feature that is a
visible sidebar button. See parity finding P-C3.

### S-04 — `docs/context-and-retrieval.md` header asserts a verification date that no longer holds

`docs/context-and-retrieval.md:3` — *"Verified against the source tree on 2026-08-31."*
Findings D-06, D-07 and D-08 are all in this file. The date should move only when the
claims are re-checked; the current one is a false assurance.

---

## Part D — Documented nowhere (gaps, not errors)

| # | Undocumented behaviour | Where it lives |
|---|---|---|
| G-01 | The response cache: 256-entry cap, 1 MiB per entry, oldest-first eviction, `X-Cache: HIT` header | `src/jenova/pipeline.nim:439-496`, `src/jenova/server.nim:210-215` |
| G-02 | The five intent prefixes a user can type (`Visual Rewrite:`, `Open File Chat:`, `Chatbot:`, `Web Search:`, `Editor:`) | `src/jenova/pipeline.nim:53-59` — a user-facing feature with no user-facing documentation |
| G-03 | FOCUS notes escaping to the whole workspace tree | `src/jenova/workspace.nim`, `src/jenova/gui.nim:3335-3350` |
| G-04 | The `/debug/*` endpoints and the flag that enables them | `src/jenova/server.nim:279-300` |
| G-05 | Attachment size ceiling and the refusal message | `src/jenova/pipeline.nim:811`, `:873-883` |
| G-06 | Backend log files grow without rotation | see report 03, finding M-04 |
| G-07 | The GUI's only keyboard shortcut is `F11` | `src/jenova/gui.nim:3151` |

---

## Tracker

| ID | Finding | Severity | State |
|---|---|---|---|
| A-1 | README banners are Web UI screenshots | high | **partly done** — both are now captioned as the Web UI, with alt text describing what they show and a pointer to the desktop section. The remaining half is A-2 |
| A-2 | No GUI screenshot exists | high | **open — blocked.** Capturing one needs a FreeBSD host with GTK4 and the GUI built; neither exists in the audit environment |
| A-3 | Adopt surface-labelled presentation model | high | **partly done** — captions and an anchor to `#desktop-application` are in. Reordering so the window leads waits on A-2 |
| D-01 | `GET /api/workspaces` does not exist | high | **fixed** — row removed; `docs/usage.md` now says workspaces are listed through `/api/db/workspaces` and that anything else under `/api/` is a 404 |
| D-02 | "forwarded unchanged" fallback does not exist | high | **fixed** — replaced with the explicit prefix table from `routes.classify`, and a note that there is no catch-all relay |
| D-03 | `/infill` is not augmented; tools are stripped not injected | medium | **fixed** — the augmented list is now `/v1/chat/completions` alone, with `/infill` and `/completion` documented as forwarded verbatim, and "tool results injected" corrected to "tools stripped" |
| D-04 | Build does shell out to project scripts | medium | **fixed** — the claim is narrowed to the running product, with the Web UI build named as the exception |
| D-05 | Two `#!/bin/bash` scripts exist | low | **fixed as documentation.** The scripts are in `jca_web`, which is frozen, so the claim was narrowed to "every script the product builds or runs" and both bash scripts are named |
| D-06 | Retrieval index *is* populated | high | **fixed** — §1 now lists all four writers and what a query costs |
| D-07 | Workspace context and attachments are not Web-UI-only | high | **fixed** — §5 and §6 retitled "both surfaces" and rewritten; §7 (MCP) correctly stays Web UI only |
| D-08 | History *is* trimmed | medium | **fixed** — §8 rewritten, and the silence itself fixed in code: a trimmed request now carries `X-Jenova-Trimmed` |
| D-09 | Model discovery vs. Models-panel sources | medium | **fixed** — both README and `usage.md` now state that discovery and the switcher read different directories, and why |
| D-10 | Bare `jenova-core` before `PATH` is set | low | **fixed** — the install step uses `./bin/`, with a note that the rest is written bare for readability |
| S-01 | Stale `awaiting` reasons | low | **fixed** — see report 03, W-01. One is now wired; the other three name what they actually wait on, and a self-test refuses any reason that blames the finished step again |
| S-02 | Stale composer comment | low | **fixed** |
| S-03 | Stale IndexedDB comment in `sync.service.ts` | low | **won't fix — `jca_web` is frozen** (ruling, session 2) |
| S-04 | False verification date | low | **fixed** — the date is removed rather than moved; a date is only worth printing if something re-checks it |
| G-01…G-07 | Undocumented behaviour | medium | **fixed** — see below |

### Undocumented behaviour, now documented

| # | Behaviour | Where it went |
|---|---|---|
| G-01 | Response cache: 256 entries, 1 MiB each, oldest-first, `X-Cache: HIT` | `docs/architecture.md` § The response cache |
| G-02 | The five intent prefixes | `docs/usage.md` § Intent prefixes |
| G-03 | FOCUS notes escaping to the whole workspace tree | already in `docs/context-and-retrieval.md` §5; now correctly marked as applying to both surfaces |
| G-04 | `/debug/*` endpoints, off unless enabled | `docs/architecture.md` § Diagnostics |
| G-05 | Attachment size ceiling and the refusal | `docs/usage.md` § Attachments |
| G-06 | Backend logs and the attachment cache | `docs/usage.md` § Disk that Jenova manages itself — **and both are now actually bounded**, see report 03 M-02 and M-04 |
| G-07 | `F11` is the only keyboard shortcut | `docs/usage.md` § The desktop application |

Also added: the response headers the pipeline emits (`docs/usage.md`), and how to run the
self-tests including the one whose assertion is timing-sensitive (`docs/usage.md`).

---

## Coverage gap found in session 4 — documentation I claimed to audit and did not

Ask 1 was "the readme and all documentation". Session 1 audited `README.md` and the five files
under `docs/`. It did not open:

| Never audited | Result of auditing it now |
|---|---|
| `hardware-profiles/README.md` (308 lines) | Profile tables **verified correct** against all six `jenova.conf` files, including the Drafter column, which I had suspected was wrong and is not — `JENOVA_DRAFT` is read at `lifecycle.nim:120` and all six values match |
| `docs/privacy.md`, second half | **Defect found** — see D-14 |
| `jca_web/README.md` claims | Reviewed; the one stale statement it contains it already flags itself |
| `jca_web/docs/**` (10 files) | **Still unaudited.** Frozen tree, but user-facing |

### D-14 — privacy.md's self-audit command does not support its own claim · severity: medium · **fixed**

The document says *"The outbound calls are the only `http` URLs in the runtime"* and hands the
reader `grep -rn 'https\?://' src/` to check it. Running that returns **ten distinct URLs**, of
which two are real: about a dozen `x.example` / `img.example` / `rfc.example` fixtures in
`src/jenova_core.nim`'s self-tests, plus one example inside a comment in `src/jenova/markdown.nim`.

For a privacy document that invites verification, teaching a check whose output the reader cannot
interpret is worse than not offering one. The section now names every extra the command returns,
says what each is, and gives a narrowed command that yields exactly the two real hosts.

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
file — which is the thing #113 reverted. Re-applying the profile resolves it.

---

## Findings added in session 2

### D-11 — `PLANS.md` is referenced from ten places and does not exist · severity: low

`src/jenova_core.nim:20` named `.devdocs/PLANS.md` in the FreeBSD guard's **user-facing error
message**; that one is fixed to point at `docs/install.md`. Nine further references remain in code
comments as provenance markers (`settings.nim:2`, `convmd.nim:2`, `composer.nim:6`,
`pipeline.nim`, `gui.nim:280`, `gui.nim:3149`, `api.nim:688`, `api.nim:832`, `fssync.nim:378`).

The file is not in the repository — `.gitignore:61` says `.devdocs/` is deliberately tracked, so
it was removed rather than ignored. The comments are historical rather than instructional, so they
were left alone rather than mass-edited; but a reader following one finds nothing.

**Decide:** restore `PLANS.md` to `.devdocs/`, or strip the references in a single pass.

### D-12 — `db-selftest` carries a wall-clock assertion that fails under load · severity: low

`db-selftest` measures what fraction of a reader's run overlapped a concurrent writer and fails
below a 25% floor. Observed failing at 23.3% and 23.6% on a loaded container, passing on re-runs of
the same binary, with `src/jenova/db.nim` untouched.

The property it tests is real and worth testing. The **threshold** is not robust: it is a
wall-clock ratio on a machine whose scheduling the test does not control, so it will fail on a
single-core or busy host with nothing wrong. Documented in `docs/usage.md` so a failure there is
not mistaken for a database defect; the assertion itself should be re-shaped (compare against a
serialized baseline measured in the same run, rather than against a fixed percentage).
