# PLANS

Forward-looking only. Superseded plans are in git history at `349a9b5b~1`, path
`.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md` — *corrected 2026-09-03: that directory was deleted by
the USER and does not exist, see **D-CE***.

**Last updated:** 2026-09-03 11:45 (Session 026c)

> ## ORDERING, as it stands 2026-09-03 11:45 — **the defects first, the parity backlog next (D-CI).**
>
> **This supersedes the ordering written in the Step 12 and Step 13 blocks below**, both of which
> were written at 09:48 when the parity backlog was the current work. **They are left in place as
> the record of what was planned; this note is what is being built.**
>
> **D-CI, 11:40 — the USER's ruling.** `12e-1` (A-26) → `12f-1` (A-17) → `12e-2` (A-48) → `12f-2`
> (A-16/A-18) → `12d` (A-7), then **13c**. Smallest and most assertable first, and **12d last
> because it is the only one of the five that touches `upstream.forward`'s verbatim relay** — the
> path every chat turn takes. The other four are contained and are inert-or-wrong in place; 12d is
> currently *inert*, and **D-CD's own warning is that wiring the writer without also fixing the hit
> response makes cached turns render blank.** It is the one change here that can make the product
> worse than it is today, so it goes in last, against a tree the other four have been proven green
> on.
>
> **Step 12c (A-3, A-4) is in flight and is NOT in D-CI's list.** It was given separately, in a
> different terminal, and is being built now (`BRIEFING.md` §0a). **That is a gap in the ordering,
> not a decision against 12c** — recorded so a later session does not read D-CI's five-item list as
> a closed set and delete 12c as superseded.
>
> **A-69 is built and gone from `TODOS.md`** (`PROGRESS.md` 11:38). **A-68 is unaffected: test and
> check work is still last.**
>
> **Read `BRIEFING.md` §0a before opening a file in `src/`.** Five sessions were live in this
> checkout when this was written and three held source files.

---

## Step 12d — the response cache (A-7, ruled **D-CD**). **THREE parts, not two.**

**Written by the PLANNER 2026-09-03 12:00; every claim below re-verified against the source by the
`.devdocs` session before it was recorded.** Builder is **CODING PEER 1**. Touches `upstream.nim`,
`server.nim`, `pipeline.nim`, `gui.nim` and **needs the `jenova_core.nim` token**. `pipeline.nim`
and `server.nim` carry the released 12c edits — compiled and green, so no conflict, **but read them
before writing.**

**The defect.** `pipeline.prepare` sets `cacheKey` from a SHA-256 of the rewritten body;
`server.handle` consults `cacheLookup` on every completion and answers `200 application/json` with
`X-Cache: HIT`. **`cacheStore`'s only caller is `pipeline-selftest`**, and `upstream.forward`
relays verbatim, capturing nothing. **The table is empty by construction, the HIT branch is
unreachable, and every turn pays a SHA-256 for a key that cannot hit.**

**Three things A-7 does not say. All three verified here, not taken on report:**

- **(a) There is a second writer, and it bypasses `cacheStore`.** `POST /api/db/cache` does its own
  inline `INSERT OR REPLACE INTO llm_cache` (`api.nim:1030`), separate from `pipeline.nim:442`.
  **Any policy put into `cacheStore` — a cap, a TTL, eviction — is bypassed by that route on day
  one.** **A-7's "written by nothing" is true of `cacheStore` and false of the table.**
- **(b) Nothing ever deletes from `llm_cache`.** No `DELETE` exists anywhere in `src/`; `timestamp`
  is written by both writers and read by nothing but the GET route. Entries are whole model
  replies. **Wiring the writer converts a table that is empty by construction into one that grows
  without bound in the USER's database.** A cap and an eviction rule are **part of 12d**, not a
  follow-up.
- **(c) The window cannot see `X-Cache` at all** — the EXAMINER PEER's Finding 3, confirmed:
  `server.nim:199` sends it and `gui.streamOnce` discards every header in a bare skip loop before
  reading the body (the loop **A-32** already documents).

### The decision that makes the whole thing coherent

**Store the relayed bytes, not a parsed response.** The GUI posts `"stream": true` and `streamOnce`
acts only on lines beginning `data:`, stopping at `[DONE]`. **A hit answered as
`application/json` carries no `data:` lines, so the reader renders nothing and saves a blank
assistant turn — D-CD's warning, exactly.**

So the stored value is **the upstream response as it went down the wire, head included**, and a hit
replays those bytes. A hit is then byte-identical to a live reply, `streamOnce` needs no change to
consume it, and chunked and SSE framing survive because nothing parses them. **The relay stays
verbatim: capture is a tee, not a parse.** *That is the property that keeps 12d from being the
change that breaks every chat turn.*

### The units, in build order

**12d-1 — capture** (`upstream.nim`, `server.nim`). `forward` takes an optional capture buffer and
appends each chunk **after** it is fully written to the client; `rcEmbed` passes nothing.
`server.handle` passes a buffer on a miss and calls `cacheStore` **only on a clean completion**.
**`forward` currently returns `relayed > 0` (`upstream.nim:106`) both when upstream closed cleanly
and when the client went away mid-stream — it needs a third state**, because storing a truncated
stream and replaying it later as a whole answer **is D-BQ's truncated attachment again: confident,
and about a fragment.** Refuse to store; never store short.

**12d-2 — the hit response** (`server.nim`). Replace the `application/json` send with a raw write of
the stored bytes, inserting `X-Cache: HIT\r\n` immediately after the status line — **one insertion
at a known offset, not a parse**, and the comment must say so. `sendResponse` is untouched for
every other route. **12d-1 must not land without 12d-2:** a writer with the old hit response *is*
the state D-CD warns about.

**12d-3 — the window learns a hit happened** (`gui.nim`). The skip loop already reads the headers
and throws them away; test each for `X-Cache: HIT`, carry the flag through `UiMsg` as `umModel` and
`umTimings` are carried, and surface it in `statsLine`. The Web UI's `ChatMessageStatistics` Cache
Hit badge is the parity target. **Without this the step is unfalsifiable** — no USER and no screen
run can tell a hit from a miss.

**12d-4 — the cap, the eviction, and the second writer.** A cap on what is stored; eviction by
`timestamp`, **which finally gives that column a reader**; and `POST /api/db/cache` routed through
`cacheStore` so one policy governs both writers.

### What proves it worked

1. **A truncated relay is not stored** — driven through `cacheStore`'s caller condition **by
   varying the data, never by damaging code** (**D-BX**).
2. **Round-trip is byte-identical**, `data:` lines and trailing `[DONE]` included.
3. **A stored entry has the shape the reader requires** — at least one `data:` line and a `[DONE]`.
   **This is the assertion that encodes D-CD's warning:** a stored JSON object fails it.
4. **The two writers agree** — the API route and `cacheStore` produce the same row for one input.
5. **The cap holds**, and nothing truncated is stored. 6. **Eviction holds** — N+1 stores against a
   cap of N leave N rows, oldest gone.

### Deliberately not in 12d

**No change to `cacheKeyFor`** — a different algorithm orphans every existing entry, and
`sha256.nim`'s justification for being hand-written rests on this cache. **And no tuning for hit
rate:** the key covers the RAG context and the persona, so hits will be rare. **12d's job is to make
the mechanism honest, not to make it hit often** — said here so a later session does not find the
low hit rate and think something is broken.

### Risk

**The only unit in Step 12 that can make the product worse than it is today.** Inert now; wired
wrong it serves a stale or truncated reply as a fresh one, or blanks a turn. **Build last, on a tree
the other four are green on.**

---

## Step 12f-3 — **A-19, and it is now ahead of A-18-2/3 rather than behind them.**

**Reordered 2026-09-03 12:35 because a fix that shipped this morning falsified A-19's recorded
bound.** The row said `restoreTrash` was bounded by having only an HTTP caller. **A-16 is a second
caller and it is behind a button** — `gui.restoreFromTrash` → `api.restoreEntity` → `restoreItem` →
`fssync.restoreMirror` → `restoreTrash`, **with the destination read out of a JSON sidecar on disk**
— and **A-18-2 will add a third, more direct route, with the path taken from a list the USER
clicks.**

**Scope: a port, not a design.** `restoreTrash` validates containment **lexically** (`underRoot`,
`normalizedPath` + prefix test), which a symlink defeats; `resolveStoragePath` was hardened by
**T-4** to resolve then compare resolved against resolved, walking to the deepest existing ancestor.
**Port that pattern. Do not invent a second containment standard** — that instinct is what made
A-16 right, and `fssync.nim:564-566` already carries the comment admitting the lexical check was
only *"tolerable while `restoreTrash`'s only caller was the HTTP route."*

> **The lesson, and it generalises past this row: a finding's own remedy is what makes it
> dangerous.** A-19 was deprioritised *because* A-18 was open. Closing A-18 is what promotes it.
> **Check the bound on every deferred finding whose bound is another open finding.**

**Build order for that file: A-70 (done) → A-19 → A-18-2 + A-18-3.**

---

## Step 12i — **bound every subprocess.** A-44 and A-47, justified by the fix and not the symptom.

**Retitled 2026-09-03 12:45, and the retitle is the point.** It was scoped as *"unbounded blocking
on the GTK thread"* — **and that title would have misdirected the builder.** Verified here:
`gui.nim:877-884`'s docstring states hardware work runs *"on a worker of their own… this is not on
`ctlReq`, and that is the whole point"*. **So A-47's five unbounded `execCmdEx` probes hang a
background worker and leave the hardware screen never updating — they do not freeze the window.**
**Only A-44 freezes the window:** `fssync.gitRun` is `startProcess` + `waitForExit`, reached from
`saveNote` → `putEntity` **on the GTK thread**, on every note save and every filed attachment.

**A builder told "stop freezing the GTK thread" would have fixed `gitRun` and deprioritised all
five.** Hence the title: **the unit is bounding subprocesses**, and **the bounded runner already
exists** — `hardware.runBounded` — **applied to exactly one probe, the one that had already hung.**
Porting it to `gitRun` and the other five is one change behind one shared helper.

> **A fourth member of the stale-precondition class, and the sharpest: a fix that never
> propagated.** That same docstring already says `hardware.detect` *"initialises Vulkan and is
> unbounded"*. **The unboundedness was diagnosed, the mitigation chosen was to move it off the UI
> thread rather than bound it, and the bounded runner was then written anyway — for one probe out of
> six.** *The tree contains the diagnosis, the workaround and the fix, applied once.*

---

## A-56 — **a CONSTRAINT, not a unit. Attach it to rows; do not schedule it.**

**"Add unicode awareness" is not scopable** — verified, **zero hits** for `std/unicode`, `Rune`,
`runeLen` or `toRunes` anywhere in `src/`. **But it is an input to at least three rows already
held**, and a builder who does not know that will re-introduce it:

- **A-26's `text.len` stamp** — a byte length.
- **`websearch`'s `text[0 ..< 80]` title cut** — can split a UTF-8 sequence and hand Pango invalid
  markup, which it refuses to render.
- **The sidebar's `toLowerAscii` filters** — non-ASCII search is case-sensitive.

**Attach the constraint to each, so a builder fixing A-26's stamp does not reach for `text.len`
again.**

---

## Two groupings DISSOLVED — recorded so they are not re-proposed

**"D-BQ violated" was never a group; A-61 stands alone.** It had been paired with A-35. **Verified
at `pipeline.nim:350-355`:** `prepare` sets `result.body = rawBody`, then `try: parseJson` /
`except: return` — **so a truncated body is malformed JSON**, `prepare` returns it untouched,
llama-server rejects it, and the USER gets a classified refusal through G-35. **The reusable
distinction: D-BQ's hazard is a fragment that READS AS WORKING while meaning something the USER did
not write.** *A 70%-decoded PDF is plausible text; a truncated JSON body is not plausible, it is
broken.* **A-35 belongs to the A-4/G-35 diagnosability family**, and grouping it here would have
sent a builder hunting a truncation to refuse where there is none.

**"LAN exposure" was never a group, and the claim that A-19 reduced it was wrong — recorded
explicitly, because that is the kind of line that defers a finding twice.** A-55 is a **posture**:
no authentication on any route, `--lan` binding `0.0.0.0`, full `/api/db/*` and `/api/fs/*`. A-19
was **one primitive on that surface**, and **the exposure inside the tree was already total**, so
removing the ability to symlink *out* of it does not make full read/write on every conversation,
note and workspace safer. **A-55's severity is UNCHANGED by A-19's fix.**

---

## Step 12h — **retrieval gets a health signal the window can show.** A-9, A-10 and A-45 are one unit.

> **DEPENDENCY, not a merge (settled 2026-09-03 12:45).** A-57 — the logger — was going to be
> bundled with this and with `ChatError.detail` as "observability". **Both merges were wrong.**
> `ChatError.detail` is **not unlogged**: it is computed, carried to the channel boundary and
> **dropped one field short of the screen** — a logger would not fix it and fixing it would log
> nothing. **What is real is an ORDERING: build the logger first, and the retrieval failures become
> diagnosable, and so do the ~50 silent discards.** A-57 stays **one unit on its own.**

**Scoped from the `[A]` sweep, 2026-09-03 12:30. All three rows verified `[V]`.** They were filed
as three defects and **they all end in the same sentence: semantic retrieval stops working and
nobody is told.** So the unit is the signal, and the three rows become its justification rather than
three separate fixes.

- **A-9 is the silence itself.** `rag.embed` returns `@[]` on every failure path; `query` sets
  `haveSemantic = false` and ranks on BM25 alone. **`rag.formatContext` emits the identical
  `--- REPOSITORY CONTEXT ---` header either way.**
- **A-10 is a permanent trigger.** `rag_chunks` has **no dimension column and no model stamp**;
  `dot` returns `0.0` on a width mismatch rather than erroring; every chunk then falls below
  `SemanticFloor` and is skipped. **Nothing re-indexes, because nothing knows the model changed.**
- **A-45 is an intermittent trigger.** `embedHost`/`embedPort` are `{.threadvar.}` and **`server.nim`
  contains no `configureEmbed` call at all** — verified, zero hits — so the HTTP completion workers
  fall back to a hard-coded `127.0.0.1:8082`.

**They are invisible by construction because `rag.available()` reports FTS5 and nothing about
embeddings.**

> **A-45's severity is LOWER than its row reads, and that affects scheduling.** The fallback is
> `127.0.0.1:8082` and `etc/jenova.conf:41` ships `LLAMA_EMBED_PORT` defaulting to **8082**, so the
> defect is **latent on a default install and bites only when the port is overridden.** Real, not
> urgent.

**A-12 stays a separate unit.** The vector side of `rag.query` has **no `LIMIT` while the BM25 side
carries `LIMIT 200`** (verified: `rag.nim:464` against `:477`), so every stored vector is unpacked
and dotted on every semantic query. **That is performance, not silence** — merging it here would
blur what each proves.

---

## Runtime probes — claims that cannot be settled by reading

**Opened 2026-09-03 12:30. A list, because there will be more.** These need code *run*, which Rule 0
governs, so they are neither confirmed nor refuted and **must not be counted as swept.**

1. **A-51 — the GtkSourceView language-id list.** `/usr/local/share/gtksourceview-5/language-specs/`
   holds **no `.lang` files**, only `language.dtd` and two `.rng` schemas — the specs are compiled
   into a GResource. Settling which fence labels resolve needs
   `gtk_source_language_manager_get_language_ids()`. **The session that found this refused to upgrade
   the marker on a guess, which is the behaviour the list exists to encourage.**

---

## Step 12g — `content-render`. **The largest single cause found today, and it now absorbs A-49 and A-50.**

> **A-49 is DELETED and merged here** (2026-09-03 12:30). It was confirmed and then recognised as
> **the same finding as this step arrived at from the other direction** — "block constructs beyond
> the six handled render their own source syntax" *is* the content-render root cause. **A-49 =
> 12g-1 + 12g-2.** Leaving both would give one file two owners, **which is the collision that costs
> most.**
>
> **A-50 is confirmed and folded into 12g-1**, which is therefore three things, not two:
> ordered lists, horizontal rules, **and `inlineSpan`'s unbounded pairing** — it does `find(delim)`
> then `find(delim, start + delim.len)` and wraps whatever lies between **with no flanking test**,
> so `2 * 3 and 4 * 5` renders as `2 <i> 3 and 4 </i> 5` and `foo_bar and baz_qux` italicises the
> middle. **Record the bound with it, because it is what makes this scopable and what must not
> regress: code spans are safe, because A-48's placeholder lift runs before the emphasis passes.**

**The EXAMINER PEER's Finding 9, scoped by the PLANNER, verified here before recording.**

**The cause.** `markdown.lineMarkup` opens with `let t = line.strip(trailing = false)`, **so leading
whitespace is discarded before any branch decides anything — and indentation is the only thing
markdown uses to encode nesting.** And the sharpening is the useful part: **the `else` branch passes
`line` *unstripped* while every other branch uses `t`.** So indentation survives exactly for the
lines that do not need it and is destroyed exactly for the bullets that do. **The defect is not that
the renderer is line-oriented; it is that one strip at the top serves branches with opposite
needs.**

> **STATUS 2026-09-03 12:28: 12g-1 and 12g-2 are SCOPED, NOT APPROVED for any builder** (**D-CO**).
> A ruling relayed from a planning session's terminal is a proposal, not a sanction — the builder's
> own USER must approve it in the builder's own terminal. **The narrowing below is the valuable part
> and stands on its reasoning.**

**12g-1 — two defects. No architecture.** An ordered list (`1. `) falls
through to `else` and renders as plain text; a horizontal rule (`---`) renders literally. **Each is
one `elif` in the existing chain.** No indent, no nesting, no new `BlockKind`, **no `gui.nim`** —
`markdown.nim` only, assertable in `markdown-selftest`. **Half of what the examiner found is this
cheap, and the finding as written does not separate it out.**

**12g-2 — indent survival. GATED, awaiting a USER ruling.** Nested lists flatten and a fenced block
inside a list item splits the surrounding text block; both need indent to survive the entry point.
**This is a renderer change beyond anything in the A-series, so it takes the same gate 12d-4 took**
— *"necessary to reach parity" is an argument to put to the USER, not a licence past Directive 1.*
**Do not start it.**

**Two things recorded with it, because they are the whole reason it is buildable at all:**

1. **G-40 does not block it.** Step 7c's rule is that nothing called from `view` may do work
   proportional to a payload, which is why `parse` has been kept cheap. **But `blocksFor` memoises
   on `id` plus `text.len`, so a heavier `parse` runs once per message, not once per frame.**
   Without that in the record **a later session will refuse 12g-2 on G-40 grounds and be wrong.**
2. **Nesting does not need nested `Block`s.** `gui.mdBlock` renders a text block as one Pango
   `Label`, and **leading spaces survive in a Label** — so preserving indent depth as leading spaces
   closes nested lists with **no new `BlockKind` and no `gui.nim` change at all.** An AST is needed
   only for *semantic* nesting, i.e. real list widgets, which nothing here requires. **That takes
   12g-2 down to `parse` and `lineMarkup` in one file.**

**12g-3 — recorded divergence, not built.** Setext headings, multi-line blockquotes as one quoted
block rather than N independent lines, and full CommonMark. **Named so silence is not read as
coverage.**

**It wants a D-number either way:** *the renderer gains bounded indent awareness, scoped to lists
and fences, with CommonMark out of scope* — the PLANNER's recommendation — **or** *line-oriented
rendering is a permanent divergence*.

**Recorded from the same pass, uncounted:** the GUI escapes everything in `markdown.escape` and is
**stricter than `rehype-sanitize`**, not merely equivalent; syntax highlighting, code-block copy and
the height cap are built; **KaTeX is G-34's existing open half, not a new finding.**

---

## 13c — the counting rule. **This is where the 866 came from, and re-deriving the same way reproduces it.**

**Set by the PLANNER 2026-09-03 12:00.** `data-services` collapsed **147 counted features to
three** real gaps; the model-metadata finding collapses **eleven rows to one cause**. The verdicts
are gone and re-deriving them is the work — **but not the same way.**

1. **Root-cause first, count second.** *A cause is the unit. A component row is not.*
2. **A producer with no consumer is one gap, at the boundary** — not one per consumer.
3. **Different but equivalent is not a gap.** Sidebar search is **built and ahead of the Web UI**.
4. **Continuous is not missing.** `handlePush` has no button because `fssync.syncNote` writes the
   mirror on every save. The button would be a no-op.
5. **Excluded by a standing decision is named, not counted** — MCP, `VFSExplorer` (**D-AW**), audio
   (**D-BZ**), API-key and `serverUrl` (**D-BL**).
6. **Output shape:** cause → what the USER cannot do → the one change that closes it → files.
   **Never a row per Svelte component.**
7. **Present but unreached is not a feature on either side.** A component, method or route that
   exists in the frozen `jca_web` source, is complete and correctly wired internally, and is
   **invoked by nothing anywhere in `jca_web/src`.** It shipped; no user of the Web UI could ever
   reach it. **Record it, name it, do not count it and do not build it.** It is evidence about the
   frozen tree's quality, not about ours. *It cannot fold into rule 5 — those are capabilities the
   Web UI genuinely offers and we chose not to build — nor rule 3, which presumes both sides offer
   the thing. **This is a capability nobody built for anyone**, and the failure it prevents is a
   parity gap derived from an unreached component, which looks perfectly justified in review because
   the component is right there in the source.*

   **The test, and the three traps are the substance — a rule without them produces false members:**
   **(i) search the symbol or component name, never an assembled path** — the base path lives in the
   fetch wrapper, `` apiFetch = fetch(`/api/db/${path}`) ``, so a call site *cannot* contain
   `db/cache`, and **a zero-hit grep on the URL means nothing**; this trap already cost a correct
   claim a retraction today. **(ii) Exclude barrel files** — `index.ts` re-exports everything, and a
   barrel hit is not a caller. **(iii) Exclude type-only references** — `app.d.ts` names types;
   in the attachments hunt one component showed five non-barrel hits of which **two were type
   declarations**, so a raw count was wrong in both directions.
   **`callers = hits − its own file − index.ts − *.d.ts − type-position imports`. Only zero after
   all four subtractions is a member.**

   **A thing can be both this and rule 2 at once, with opposite consequences** — and `setCache` is.
   **The two are separated by which tree:** a capability complete in `src/` that our window cannot
   reach is **work**; one complete in `jca_web/` that their own UI never called is **not work**.

   **MEMBERSHIP: ONE.** `DatabaseService.getCache`/`setCache` is the **sole known member**;
   `attachments` was hunted deliberately for more and all four of its components have real callers.
   **The count belongs in the rule** — without it the next session hunts these everywhere, hits
   traps (ii) and (iii), and reports a column of false members. **The category is real and it is
   rare, and the rule must say both.**

**Already present — do not re-derive:** attachment preview (`app.previewAtt`), conversation rename
(`commitRename`'s conversations branch), the fork (13b).

**13c-5 — forking is capability-complete and unreachable from the window.** `api.forkConversation`
honours `atMessageId` (`api.nim:709`) and its only caller passes `""` (`gui.forkConversationRow`),
so **the window can only fork from the read position**; the Web UI forks from a chosen message via
`ChatMessageActions`. **G-51 does not apply to the message action row** — that trap is confined to
`gui.fullscreenButton` in the header row.

**Examiner coverage — ALL NINE AREAS EXAMINED as of 2026-09-03 12:25. Twelve findings, every one
`[V]`, none skipped.** `views-dialogs`, `models-server`, `sidebar-workspace`, `chat-messages`,
`content-render` (held until A-48 landed, deliberately, so it did not catalogue gaps being closed as
it wrote), `chat-form`, `attachments`, `settings`, `data-services`.

### The negative results, recorded because they are results

**A pass that finds nothing has found something, and this project has twice built against a gap
that was not there.**

- **`attachments` was expected to be add-only and was refuted on every point.** Individual removal,
  thumbnails on **both** surfaces, the preview scrim and drag-and-drop are all built. What survives
  from that area is **A-74** (neither strip can overflow) and **A-75** (a stale comment), and both
  are small.
- **`accept` filtering is not a gap in either direction.** `ChatFormFileInputInvisible` carries no
  `accept` attribute and `gui.attachDialog` carries no `FileFilter` — **so a "the GUI lacks type
  filtering" row would score against something the Web UI does not do either.** That is rule 3.
- **`chat-form` is effectively closed**, 13a having taken six of its thirty. **Its examiner's own
  caveat travels with it:** that pass examined the area's components and actions and **did not
  enumerate the thirty verdict rows**, so "almost nothing left" is a statement about causes and
  **must not be recorded as a row count.**
- **HTML safety is a strength, not a gap:** the GUI escapes everything in `markdown.escape` and is
  **stricter than `rehype-sanitize`**, not merely equivalent.
- **KaTeX is G-34's existing open half**, not a new finding.

**The `[A]` sweep is the largest remaining blockage** — 34 findings that **D-CG** bars from being
scoped until verified, roughly a third of the audit. **Record refutations as prominently as
confirmations:** the A-series was written in one pass and the tree has moved a long way since.

> ## Step 12 — the audit's findings. This is the current work and it is ahead of the parity list.
>
> **Ordering, and why it is this order.** Steps 1-11 are built. The 2026-09-03 audit put two
> findings in front of everything else, and they are not features. **Both are now built and the
> live work is 12c → 12f**, all of it product code.
>
> **Test and check work is left until last** — the USER's instruction, 2026-09-03 09:05,
> `TODOS.md` **A-68**. It comes up every session while the main work is unfinished, and the suites
> are likely to keep failing until that work is done. **12a and 12b were built before that
> instruction and stay built.**
>
> **12a — BUILT 2026-09-03 09:02 (`TODOS.md` A-1).** `task suites` now runs every
> `X-selftest` subcommands before the shell suites, from a `SelfTests` const beside the task.
> **Proven:** `nimble suites` exited 1 on a failing assertion and 0 once corrected. *The failure was
> observed through a shell suite; making a self-test fail would mean damaging code (D-BX), so the
> last step — that a self-test propagates identically through the same `exec` — is reasoning.*
>
> **12b — BUILT 2026-09-03 09:02 (`TODOS.md` A-2).** Every `SKIP … exit 0` guard is now
> `FAIL … exit 1`, `test_nvimctl.sh`'s missing-`nvim` skip included, which makes `nvim` a
> prerequisite of a green run. **Proven:** each guard was fired by running the suite under a scratch
> `PATH` lacking the prerequisite — nothing on the USER's machine was renamed or moved. *The plan
> said to rename `nc` out of `PATH`; that alters the USER's system and was not done.*
>
> **T-12 was fixed in the same pass**, and the one-line fix recorded for it was wrong for one of the
> two scripts: `test_lifecycle.sh` asserts the *default* ports back out of the argument vector, so a
> global `JENOVA_LLAMA_PORT` export would have turned two passing assertions red. Its override is
> scoped to the single `backends health` probe. **The record for all three is `PROGRESS.md`.**
>
> **12c — the two data-losing defects in the chat path.** **A-3:** `trimHistory` measures base64
> payloads against a byte budget of a few kilobytes, so attaching an image silently drops the whole
> earlier conversation from what the model is sent. **A-4:** the 25 MiB attachment cap and the
> 32 MiB body cap cross over at 24 MiB, so a 24–25 MiB attachment produces the untyped 500 that
> G-35 exists to prevent. Both are in `pipeline.nim` and `http.nim`, below the widget layer, so
> both are assertable — **which is only worth saying once 12a is done.**
>
> **12d — the response cache (`TODOS.md` A-7, ruled **D-CD**).** The USER has ruled it a defect to
> fix rather than remove. The writer must be wired on the completion path, **and the hit response
> must be fixed with it** — a hit currently answers plain JSON to a client that only reads `data:`
> lines, so wiring the writer alone would make cached turns render blank.
>
> **12e — the two silent renderer defects.** **A-26:** a note edit that preserves character count
> renders as the pre-edit text, because `BlockMemo` stamps on `text.len` and the note key is stable
> across edits — sound for messages, false for notes, and 8c-3 pointed the same memo at both.
> **A-48:** markdown links and images are not rendered at all; a model's citation renders as raw
> `[text](url)`. A link pass must carry an http/https allowlist with it.
>
> **12f — the trash is write-only from the window (`TODOS.md` A-16, A-17, A-18).** Deletion mirrors
> to disk with care and a sidecar written so a restore can put it back; **restore never reads it**,
> and `/api/fs/trash/*` is reachable only over HTTP. Under D-BC that is a defect, not a limitation.
>
> **What is deliberately NOT in Step 12:** the `[A]`-marked findings. Per **D-CG** a session picks
> one up by verifying it first and upgrading the marker. Scoping unverified findings into a plan is
> how a session builds the wrong thing.

> ## Step 13 — the parity backlog (`TODOS.md` **A-59**). **This is the current work**, chosen by the USER 2026-09-03 09:10 and scoped 09:48.
>
> **What it is.** 1,095 Web UI features enumerated against the window. It is the largest body of
> work in the project and it is what "the GUI is missing Web UI features" actually means.
>
> **How it is worked, and this is the whole method.** The 866 verdicts produced by the audit were
> made by one agent each with no adversarial re-check, so **they are leads, not facts** (**D-CG**).
> A row is picked up by verifying it against the source first and upgrading its marker. **Nothing
> below was taken from a verdict** — every item is a root cause read out of the source directly.
>
> **"Missing" is not a feature count.** The granularity is deliberately fine and rows collapse:
> six chat-form gaps are one widget, and the 147-feature `data-services` area resolves to three
> real gaps. Work the root cause, not the row count.
>
> **13a — BUILT 2026-09-03, then repaired twice from the USER's screen and finally REBUILT at
> 11:14 as `DraftView`.** The six gaps downstream of the one-line `Entry` are closed together.
>
> **The rebuild is the part worth reading, because three separate defects had one cause.** The
> first version used owlkettle's `TextView`, **which declares no events at all** — so nothing
> re-ran `view` when the user typed. Everything followed from that: the placeholder never cleared,
> the widget could only be configured by walking the tree to find it, and the draft had to live in
> a `TextBuffer` where no change could be observed. **`Entry` worked because it fed state back on
> every keystroke; dropping that is what cost three runs.**
>
> **The rule, and it is general:** a widget this program needs to *observe* must be a renderable it
> owns, exposing its GTK signals as owlkettle events the way `Entry` does. Reaching around the
> toolkit — walking to a child, or configuring one from a `property` hook — fails silently.
>
> **Five traps found on the way, all worth keeping.** owlkettle's **`addOverlay` defaults to
> `AlignFill`** on both axes, so an overlay child covers its parent and a targetable one swallows
> every click; `xAlign`/`yAlign` align text *inside* a Label and do not size it. **A `property`
> hook is overwritten by `afterBuild`**, which runs last (`genBuild`) and is not re-run on update
> unless the value changes. **`ContentScroll` must not be reused for an input field** — its
> `halign = START` and natural-width propagation are deliberate for tables and collapse an empty
> view to nothing. **GTK4 CSS has no `max-height`**. And the one that crashed the program:
> **a raw pointer into an owlkettle `EventObj` may only be held for one update cycle** —
> `genUpdateState` replaces every event object on every update and ARC frees the old one, so a
> handler bound in `afterBuild` rather than `connectEvents` is dereferencing freed memory by the
> second frame.
>
> **And a process rule, because it cost the most time here: on a SIGBUS, read the core first.**
> `gdb -batch -ex "bt 40" bin/jenova /var/coredumps/<core>` named the faulting frame in one
> command and disproved a theory several paragraphs long. Cores land in `/var/coredumps`. The send-or-newline rule is
> `composer.nim`, below the widget layer, asserted by `composer-selftest`. **Three things worth
> carrying forward:** owlkettle's `TextView` has **no key hook at all**, so the controller is a
> `GtkEventControllerKey` on a wrapper renderable in the **capture** phase — a bubble-phase
> controller sees Enter only after the newline has been inserted. **GTK4 CSS has no `max-height`**;
> the cap is `gtk_scrolled_window_set_max_content_height`, and it was `bin/jenova --check` that
> caught the CSS version. And the placeholder is kept (Directive 3) as an overlay gated on
> `charCount`, which is O(1) where reading the text would copy the draft on every canvas frame.
> **A long line wraps** — `GTK_WRAP_WORD_CHAR`, set by walking to the view through the real child
> accessors, because owlkettle exposes no wrap property and `TextBufferObj.gtk` is private.
>
> **`--check` cannot see any of this, and that is the lesson of the 10:41 repair.** It builds the
> tree and exits: it allocates no sizes and routes no events, so a widget of zero width under a
> click-swallowing overlay passes it cleanly. **A widget is a USER run** (**D-AR**), and this is the
> sharpest instance the project has: the assertions were green, `--check` was green, and the feature
> was completely unusable.
>
> **13b — BUILT 2026-09-03 10:21.** All three gaps, each asserted rather than screenshotted:
> markdown export/import (`convmd.nim`, `convmd-selftest`), the conversation fork
> (`api.forkConversation`, 15 assertions in `pipeline-selftest`), and the mirror's `pull` half
> (`fssync.readNoteMirror` + `api.pullNotes`, 10 assertions in `workspace-selftest` over real
> files). **One limit stated plainly:** `pullNotes` reconciles notes that **already have rows**. A
> brand-new `.md` appearing on disk does not become a note, because `fssync.physicalPath` requires
> a UUID in the filename and a hand-made file has none — closing that would mean minting an id and
> renaming the user's file, which is a different decision and was not taken.
>
> **The area, as checked first-hand 2026-09-03 09:48** — all fourteen service modules against
> `src/`:
>
> | Gap | What is missing | Verified against |
> |---|---|---|
> | **Markdown export/import of a conversation** | `MarkdownService.toMarkdown` / `fromMarkdown` have **no counterpart in `src/`**. `gui.exportConversations` writes `pretty(api.exportAll())` — JSON only. G-32 built the JSON pair and nothing else | `gui.nim:3207-3224`; zero hits for `toMarkdown`/`fromMarkdown` |
> | **Forking a conversation** | `DatabaseService.forkConversation` copies a branch into a new conversation. **The column exists and delete maintains the fork tree — nothing ever creates a fork** | `api.nim:46`, `:303`, `:335-337`; `db.nim:325` |
> | **The `pull` half of sync** | `SyncService.pull` walks `.md` off disk and writes notes and conversations back. **Every `fssync.sync*` proc is one-way, DB → disk.** The only `readFile`s are the trash sidecar and `storageGet`, and neither writes a row. **So an external edit — including one made in the embedded Neovim — never returns to the database** | `fssync.nim:339-412`, `:552`, `:771` |
>
> **The rest of the area is present or ruled out**, and is recorded so it is not re-derived:
> `PropsService` and `ParameterSyncService` are built (`gui.nim:420`, `:3290-3309`);
> `WorkspaceService` was ported as `workspace.nim` (D-BU); `ChatService` and `DatabaseService` are
> otherwise covered by `pipeline.chatBody` and `api.nim`'s `Entities`; `FilesystemService` and
> `StorageService` exist over HTTP and are unreachable from the window, **which is already A-18 and
> is Step 12f, not new work**; `MCPService` is deferred by the USER and `AudioService` is D-BZ.
>
> **13c — the remaining eight areas, and this is what is left of Step 13.** 866 leads. Not scoped
> here, deliberately: each is verified on pickup per D-CG. **`TODOS.md` A-59 carries the inventory
> table**; check a scope claim against it (rule 11) and never against a summary of it.
>
> > **CORRECTED 2026-09-03 11:45 — there are no 866 leads to pick up. They were never written
> > down.** The sentence above says each is "verified on pickup", which reads as though there is a
> > list to pick from. **There is not.** A-59's pointer to "the session record" was checked by
> > search: `views-dialogs`, `models-server` and `sidebar-workspace` appear **nine times in the
> > whole of `.devdocs/`**, every one inside A-59's nine-row summary table or the sentence naming
> > them as where to start. Session 023's per-feature verdicts were produced by agents, counted
> > into a table, and lost.
> >
> > **What survives is the nine-row count table and nothing else.** So **13c's first unit is
> > re-deriving one area's inventory from `jca_web/src` first-hand** — the same way `data-services`
> > was done at 09:48, which is the only area that was ever read rather than sampled, and which
> > collapsed from 147 counted features to **three** real gaps. **Expect that ratio, not the row
> > count.** Budget the re-derivation as the work; do not plan around a list that does not exist.
> >
> > **This is rule 9 at its most expensive:** a derived number was written into a tracker, the
> > thing it was derived from was discarded, and for three sessions the number was planned against
> > as though it were an inventory.
>
> ### 13c's real work list, first instalment — examined 2026-09-03 11:55, all `[V]`, re-verified here
>
> **This is what re-deriving an area produces, and it is the answer to "866 leads".** A session read
> `views-dialogs`, `models-server` and `sidebar-workspace` first-hand in both trees. **Four findings.
> Two of them collapse whole columns; one is a deletion from the backlog.**
>
> **13c-1 — the program has no model metadata at all. This is the root cause behind most of
> `models-server`'s 61.** `gui.fetchProps` reads exactly four things out of `/props` — `n_ctx`,
> `model_alias`, `default_generation_settings.params` and the vision modality — and discards the
> document. **Nothing in `src/` has ever called `/v1/models`**: a search for `v1/models`,
> `n_ctx_train`, `n_params`, `n_embd`, `n_vocab`, `vocab_type`, `build_info`, `chat_template` and
> `total_slots` returns **nothing across the tree** *(one incidental hit in `settings.nim`, which is
> a settings key name, not a metadata read)*. `models.InstalledModel` carries path, name and role —
> **filesystem discovery, not model metadata.** So `DialogModelInformation`'s entire table has no
> data source: Training Context, Model Size, Parameters, Embedding Size, Vocabulary Size, Vocabulary
> Type, Parallel Slots, Build Info, Chat Template — **nine rows, one cause** — plus `BadgeModality`
> (the window keeps only the vision boolean, so it cannot show a list) and `ModelsSelectorOption`'s
> per-model detail. **The work is one fetch and one record, not eleven features.**
>
> **13c-2 — `views-dialogs`: a complete producer with no consumer, the fourth this project has
> found.** `pipeline.ChatError.detail` — whose own docstring says *"the server's own words, when it
> gave any"* — is populated by `classifyError` at both GUI call sites and then **dropped at the
> channel boundary**: `UiMsg(kind: umError, …)` carries `text` and `retryable` and nothing else.
> **Verified here:** both sends read `text: ce.message, retryable: ce.retryable`. So the Web UI's
> `DialogChatError`, which shows the underlying detail beneath the friendly message, cannot be built
> until `UiMsg` carries the field. **One enum field, one channel field, one expander.** *(The
> `.detail` hits in `gui.nim` are `TrashItem.detail`, a different type — do not mistake them.)*
>
> **13c-3 — this belongs to Step 12d and 12d does not currently say so.** The Web UI's
> `ChatMessageStatistics` shows a **Cache Hit** badge driven by the `X-Cache` header. **`server.nim`
> already sends `X-Cache: HIT`** — verified, `extraHeaders = "X-Cache: HIT\r\n"` — **and the window
> cannot see it**, because `gui.streamOnce` takes the status line and discards every header before
> reading the body (the same bare skip loop **A-32** documents). **So wiring the cache writer would
> produce hits that are silent and indistinguishable from an ordinary reply.** **12d is three parts,
> not two: the writer, the hit-response shape, and the header read.**
>
> **13c-4 — two things NOT to schedule, both of which would have been scheduled off a verdict row.**
> **(a) Sidebar search is built and is *ahead of* the Web UI.** `app.search` filters conversations
> and, separately, notes and file assets — two filter sites in `gui.nim`. `ChatSidebar.svelte`
> filters **conversations only**; `allNotes()` is iterated unfiltered in every branch. **If a verdict
> says "search: Missing" it is wrong.** **(b) `ChatSidebarActions` carries `handlePush` and
> `handlePull`, and only pull is a button (13b) — but push is not missing, it is *continuous*:**
> `fssync.syncNote` writes the mirror on every save, so a Push button would have nothing to do.
> **Record it N/A with that reason or someone will build a no-op button.** Also confirmed present,
> so do not re-derive them: the attachment preview, conversation rename, and the fork.
>
> **Coverage, stated so silence is not read as a clean result.** `chat-messages`, `content-render`,
> `settings` and `chat-form` were **not** examined. MCP dialogs excluded per the USER's deferral,
> `VFSExplorer` per **D-AW**, audio per **D-BZ**, API-key and `serverUrl` per **D-BL**.
>
> **Build order, on the 13a/13b evidence that root causes collapse columns:** 13c-1 first (largest
> fan-out, one fetch), then 13c-2 (cheap, and it closes a dialog), and **fold 13c-3 into 12d's scope
> before anyone opens a file.** 13c-4 is a backlog deletion, not work.
>
> **Where to start, from what 13a and 13b showed.** Both turned out to be one root cause each
> behind a column of "Missing" rows, and the largest remaining counts are `views-dialogs` (65),
> `models-server` (61) and `sidebar-workspace` (47). **Read those three for their root causes
> before scoping any of them as features** — the rows are fine-grained on purpose and the fan-out
> is the point.

**Write plans in plain English, then cite the ID** (**D-BA**). A step that reads
"resolve G-23" tells the reader nothing. Say what the thing is first.

**Cite the symbol. Do not cite the line.** Seventh sweep, 2026-09-01 18:07: every
finding in this file and in `TODOS.md` is **still true**, and the addresses split
cleanly by file. Every citation into `db.nim`, `fssync.nim`, `pipeline.nim`,
`theme.nim` and `lifecycle.nim` was **correct**; every citation into `gui.nim` and
`api.nim` was **wrong**, because G-40's fix and G-41 took `gui.nim` from 3,916 to
**4,019** lines. **Seven sweeps have now corrected the same two files' addresses and
all seven rotted.** The bare numbers into those two files are therefore deleted rather
than re-derived an eighth time; a reference names the symbol and stops.

---

## What the program is

A native FreeBSD desktop application written in **Nim**, using **`llama-server`** from
llama.cpp as the inference engine. Those are the only two things in it.

- `bin/jenova` — the desktop application: window, tray, chat, backend control.
- `bin/jenova-core` — the same program without the GUI, for serving over LAN.

Build with `nimble`. **There is no Makefile, no shell script, no Lua and no C in the
product** (**D-AM**, **D-AZ**). Any reference suggesting otherwise is a leftover
pointing at the archived old build, and the fix is deletion or a port to Nim — never a
repair. **As of 2026-09-01 the product tree has no shell script left at all** — the last six were archived by Step 6.

**Finished, working and confirmed on screen:** configuration, database, threaded HTTP
server, the whole `/api/*` surface, the filesystem mirror, the retrieval *engine*, the
prompt pipeline (intents, RAG injection, personas, tool stripping — **but not the response
cache**; it is read on every turn and written by nothing, `TODOS.md` A-7 / **D-CD**),
backend supervision and watchdog, model discovery and switching, the GTK4 window,
theme and canvas, the tray, conversation persistence, the workspace tree, notes,
markdown with syntax-highlighted code blocks, the embedded Neovim page, and the
`Editor:` intent that feeds the live Neovim buffer to the model.

---

## Where the work stands

**The 2026-08-31 23:28 build has been run by the USER.** The four items built that day
— the Neovim page transparency fix, the right-hand document panel, the editor-page
framing and the colour work — are run. **No appearance defect was reported from that
run.** The report was that the GUI is missing a large number of Web UI features.

**So the outstanding work is functional, not visual.**

**The parity scope carried since Session 010 was wrong by omission.** It named six
items (a file browser, an editor, file awareness, Neovim, a model selector, a trash
view) and was written from a summary rather than from the Web UI. Re-derived
2026-09-01 by reading `jca_web/src/lib/components/app/*/index.ts` — the barrel files
that name and describe every shipped component. The real list is three times larger and
is `TODOS.md` G-17, G-20, G-21 and G-28 … G-36. G-28 … G-33 and G-39 are built.

> **Corrected 2026-09-02 10:00.** This table said PDF was "gated: needs zlib" and audio
> capture was to be "raised first". **Both were ruled on 2026-09-02** — libz approved
> (D-BY), PDF built and confirmed on screen; **audio not needed, not gated, and not to be
> raised again (D-BZ).** It also listed the trash view as missing (built 2026-09-01 19:05).
> `BRIEFING.md` §4 carried the same three errors and is corrected with it.

> **Corrected again 2026-09-03.** The "Missing entirely" column still listed **a real note editor
> (G-17)**, which was built on 2026-09-02 11:53 and confirmed on screen. **This is the third
> correction to this one table** — it has now outlived the PDF ruling, the audio ruling, the trash
> view and the note editor. The durable fix is that it stops being a feature ledger: the ledger is
> `TODOS.md`, and the table below is kept only as the short orientation for a reader who has never
> seen the product.
>
> **The parity scope sentence above it is also stale** — it names "`TODOS.md` G-17, G-20, G-21 and
> G-28 … G-36" as the real list, and every one of those IDs is closed and gone from that file. The
> current inventory is **1,095 Web UI features**, enumerated 2026-09-03, recorded as `TODOS.md`
> **A-59**. That is what rule 11 should be checked against from now on.

| Works today | Missing entirely |
|---|---|
| Send a message, stream a reply | **LaTeX maths** |
| **A real note editor** (G-17) — markdown view, Edit/Cancel, unsaved-changes guard, delete, FOCUS | **Markdown links and images** — not rendered at all (A-48) |
| Copy, edit, delete, regenerate and continue a message | **Multi-line composer** — it is a one-line `Entry` (A-59) |
| Branching — alternative versions, with a counter | **Model information** — needs `/props` + a GGUF header read; never built |
| Generation statistics, context usage, model name | — |
| A reasoning view for thinking models | — |
| **PDF attachments become text** (D-BY) · **a trash view** (G-21) | — |
| **A model switcher** (G-20, G-48, D-CB) — confirmed on screen | — |
| Conversations: create, rename, delete, search | — |
| **Stop a generation · tables · typed errors · delete confirmations** | — |
| **Attachments: picker, drag-and-drop, paste, thumbnails, preview** | — |
| Renaming a container keeps its files | — |
| Markdown text and highlighted code blocks | — |
| Recall of past chats — the index is fed | — |
| **Settings: every sampling and penalty parameter** | — |
| **Hardware profiles: detection, scoring, a screen** | — |
| **Import / export of conversations** | — |
| Theme, canvas, Neovim page, AI reads the buffer | — |
| Tray, LAN toggle, backend start/stop | — |

**Almost all of it is GUI work over backend that is already implemented and has
assertions behind it.**

---

## Standing constraint: the GUI has no test coverage

All six suites and every self-test exercise `jenova-core`. **Nothing tests `gui.nim`.**
*(Read the self-test list out of `src/jenova_core.nim`. A count written here has been
wrong repeatedly — rule 9.)* Every GUI defect in this project's history was found by the USER looking
at the screen, and that is the loop the steps below are meant to stop repeating.

The work ahead is mostly *logic* — branching trees, message mutation, parameter
plumbing — not layout. **Every step below names what would prove it worked**, and where
that can be an assertion rather than a screenshot, it must be. A new suite is not
believed until it has been shown to go red (**this project has twice shipped a suite
that reported PASS while asserting nothing**).

---

## Step 1 — **BUILT 2026-09-01.** Renaming a container no longer loses its files

Done and out of this plan. Renaming a workspace, project or folder now moves its
directory, a move that cannot be done rolls the row back, and a rename onto an occupied
path is refused rather than merged (**D-BE**). Proven by 17 new assertions in
`tests/test_api_fs.sh`, shown going red against the unfixed source first. The record is
`PROGRESS.md` 2026-09-01 09:58.

**The step numbers below are deliberately unchanged.** `TODOS.md`, `TESTS.md` and
`BRIEFING.md` all cite them, and renumbering to close a gap would silently re-point
every one of those references.

**Steps 1 to 7 are built, and Step 7c has repaired the defect Step 7 shipped with
(G-40, the window froze on any attachment). Step 8 is the next work.** Step 7d —
where attachment payloads are stored — is a decision for the USER, not scoped work.

---

## Step 2 — **BUILT 2026-09-01.** A message carries its actions again

Done and out of this plan. Copy, edit, delete, regenerate and continue, over a `Message`
that now carries its row id — which was the change the other four rested on. The record
is `PROGRESS.md` 2026-09-01 10:17; the scoping call is **D-BF**.

**The two restrictions it shipped under were lifted the same day by Step 3** (D-BF →
D-BG): edit resends, regenerate works on any reply. Continue stays on the last turn, and
is additionally hidden on a turn carrying reasoning (**D-BH**).

**Continue shipped broken twice and was repaired the same day.** The request has to carry
**both** `continue_final_message` and `add_generation_prompt: false` — the first alone is
refused with HTTP 400. See `PROGRESS.md` 2026-09-01 11:37 and **D-BH**. The request body
now lives in `pipeline.chatBody`, below the GUI, so a self-test can see it.

---

## Step 3 — **BUILT 2026-09-01.** Conversation branching

Done and out of this plan. `App.messages` is the active path and `App.allMessages` is the
tree; `messages.parent` holds the shape and `conversations.currNode` holds the branch
being read. Prev/next arrows and a "2/3" counter appear on any turn that has more than
one version. The record is `PROGRESS.md` 2026-09-01 10:50; the behaviour is **D-BG**.

**It released both of D-BF's restrictions:** edit now resends, and regenerate works on
any reply rather than only the last.

**The tree walk went into `api.nim` as three pure functions**, not into `gui.nim`, so it
could be asserted at all — a wrong tree walk draws a plausible transcript with the wrong
turns in it. `jenova-core tree-selftest`, **26 assertions** — 15 over a hand-written fork
shape, and 11 added after the USER found that the first 15 covered only the shape
branching *creates* and never the flat shape it *inherits*.
**That makes six self-tests, not five.**

**Also built in the same pass, out of order and on the USER's instruction:** the
generation statistics half of **Step 7a** (G-33) and a **reasoning view** (G-39). See
`PROGRESS.md`. Step 7a survives, reduced to the stop button.

---

## Step 4 — **BUILT 2026-09-01.** The search index has chats in it, so the AI remembers

Done and out of this plan. **`indexContent` had no caller outside its own self-test**,
so the index was always empty, `rag.query` short-circuited on its second line, and
`pipeline.prepare` — which asks it a question on every chat turn — always got nothing
back. The engine was finished and starved. It is fed now: a completed exchange is
indexed from both surfaces, existing history is backfilled once the embedding server
answers, and a deleted turn is forgotten. The record is `PROGRESS.md` 2026-09-01 12:08;
the calls taken inside the scope are **D-BI**.

**A message occupies `chat/<convId>/<role>/<id>`**, which makes the `pathFilter` the
query path already had do the scoping — `chat` is every conversation, `chat/<convId>` is
one — with no change to `query`.

**Three things this step decided that the plan above had not** (all in D-BI): an
exchange is indexed when the **reply** lands rather than each message as it is written,
because a question indexed at save time is in the index before its own request is
answered and comes back as its own top-ranked context; the backfill waits for the
**embedding server** rather than running at startup, because indexing while it loads
stores chunks with no vector and leaves all of history keyword-only; and deletion
**forgets**, because an index that keeps answering with removed turns honours the
deletion everywhere except where the user would notice.

**Proven by 14 new assertions** — 10 in `rag-selftest` and 4 in `pipeline-selftest`,
each shown going red first. The `pipeline-selftest` four are the *wiring*, which is the
half a unit check cannot see: an indexed turn is retrieved and lands in the body sent to
the model. See `TESTS.md` §0e.

**The step numbers below are deliberately unchanged**, for the reason Step 1 records.

---

## Step 5 — **BUILT 2026-09-01.** A settings screen, and with it the sampling parameters

Done and out of this plan. There was no settings surface at all, so every sampling
and penalty parameter was *absent* from the request rather than defaulted badly.
There is one now — a floating panel over the window, six sections, 1:1 with the
Web UI's `ChatSettings` minus API Key and MCP (excluded by the USER) and minus the
fields whose feature does not exist here yet (**D-BK**). Import/export (G-32)
landed in the same screen. The record is `PROGRESS.md` 2026-09-01 12:55.

**The new module is `src/jenova/settings.nim`** — fields, store, validator and the
merge, all below the widget layer, which is what made the whole feature assertable
without a window. `pipeline.chatBody` takes the settings and merges them last.

**Two things this step decided that the plan above had not**, both in D-BK: **an
empty value is not sent at all** rather than sent as a zero, because a typed store
cannot tell "the user asked for 0.0" from "the user never touched it" and a
defaulted 0 on every parameter would silently override the server's own preset
while looking like a working screen; and the source indicator was worth copying
because it reuses the `/props` call already being made.

**Step 5a followed on 2026-09-01 13:52**, from the USER running the build: the
panel was transparent and unreadable, the tuneables needed real guidance, and the
field set was to be **1:1 with the Web UI's, skipping API and MCP** (**D-BL**,
superseding D-BK's narrower rule). Twelve fields added, eight of them with the
behaviour they govern built in the same pass — a light palette, a following
transcript, conversation auto-titling, a code-block cap, a raw-output toggle. The
four that need attachments are drawn, stored and marked *"not yet in effect"*
with the step that turns them on. The record is `PROGRESS.md` 2026-09-01 13:52.

**D-BH's deliberate divergence is closed here as planned:** Continue is a setting
now, off by default, matching the Web UI.

**Proven by 25 assertions**, each shown going red first, by seven independent
corruptions producing seven different sets of red. **One of them initially
passed, and that found a hole in the assertion set rather than in the code** —
nothing asserted that `custom` JSON can override the fields the body sets for
itself, which is the whole point of an escape hatch. **The parity claim is itself
asserted**, so a field dropped or renamed later goes red and names itself. See
`TESTS.md` §0g.

**The step numbers below are deliberately unchanged**, for the reason Step 1
records. **Step 6 is the next step.**

---

## Step 6 — **BUILT 2026-09-01.** Hardware profiles in Nim, driven from the window

Done and out of this plan. Choosing a profile was two shell scripts that had not run
since their `lib/` was archived, so there was no way to detect hardware or change
profile at all. There is now: **`src/jenova/hardware.nim`** — detection, the
`profile.conf` reader, the scorer and apply — a **Hardware screen** in the window, and
**`jenova-core hardware detect|list|apply`** for headless hosts. The record is
`PROGRESS.md` 2026-09-01 15:13.

**The scoring ladder was ported from `match_profile` against the script**, not against
this plan's own summary of it — which had lost the detail that a `MATCH_OS`, `MATCH_CPU`
or `MATCH_SWAP` mismatch **disqualifies** a profile rather than merely scoring it zero.

**Kernel tuning was deliberately not ported (D-BN).** Jenova applies no `sysctl` and
never writes `/etc/sysctl.conf`. All six shell scripts were removed from the tree and
survive in git history at `349a9b5b~1` *(corrected 2026-09-03: this said "archived to
`.devdocs/ARCHIVE/hardware-profiles/`" — that directory was deleted by the USER, **D-CE**)*;
nothing replaces them. **The product tree contains no shell script outside `tests/`**
*(the earlier wording, "no shell script at all", overstated it — `tests/*.sh` are the six
sanctioned suites)*. S-2's two Linux filesystem strings were fixed in the
same pass, and the doc references telling the USER to `sudo` a `jenova-setup` were
deleted rather than repaired.

**Proven by 13 assertions in a seventh self-test, `hardware-selftest`**, with three
independent corruptions giving three different sets of red. **One corruption initially
passed** — removing the `-8` left the two candidate profiles tied at 35, and the right
one still won because it sorts first and the sort is stable. That is rule 16 working:
the hole was in the assertion set, which checked the winner's *name* and not the
*margin*. Fixed, and the corruption then went red naming the tie. See `TESTS.md` §0i.

**Two things worth carrying forward:**

1. **A green self-test said nothing about detection against a real machine.** The first
   real run reported **no GPU at all** and matched the wrong profile, because
   `llama-server` cannot load without `LD_LIBRARY_PATH` pointing at `paths.llamaLibDir`
   — `lifecycle.start` sets it and `detectGpu` did not. **An unloadable binary and a
   machine with no GPU produce the same empty string**, so it failed silently. This is
   rule 15 in a new costume: the parts were asserted, the *join* to the environment was
   not.
2. **`applyProfile` never writes `jenova.local.conf`**, and that is asserted, because
   silently discarding the USER's machine file is the one way this feature could do real
   damage.

**Not verified: the screen itself.** `--check` builds the widget tree, but the panel's
contents are drawn only when open — the same as the settings panel. That is a USER run.

**The step numbers below are deliberately unchanged**, for the reason Step 1 records.
**Step 7 is the next step.**

---

## Step 7 — **BUILT 2026-09-01.** The rest of the chat surface

**All five parts are built.** The stop button (G-33),
markdown tables and task lists (G-34), typed errors with Retry (G-35) and delete
confirmations (G-36). The record is `PROGRESS.md` 2026-09-01 15:46.

**Two calls taken inside the scope, recorded as D-BO and D-BP.** Attachments
(7b) are built too, with two formats left that are each gated on a decision
rather than on work — see below.

**7b. Attachments *(G-30)* — built, except two formats that are each gated.**
**All three of the Web UI's routes in work**: a file picker, drag-and-drop onto
the chat column (`DropZone`, a renderable, because owlkettle exposes no way to
reach a `GtkWidget` from a `gui:` block), and paste of an image from the
clipboard. Chips carry **real thumbnails**, clicking one opens a **full-size
preview**, and a sent turn shows what was attached to it.

**The classifier moved below the widget layer** — `pipeline.readAttachment`,
`looksTextual`, `mimeForImage`, `uriToPath` — which is what made it assertable,
and was forced anyway: the drop drain runs inside the window's own timer, where a
proc taking the GUI's state type does not yet exist.

**Both remaining items are settled — 2026-09-02, and 7b is closed.**

1. **PDFs — BUILT.** **libz is an approved dependency (D-BY)**, ruled by the USER
   after they had given the same answer across several sessions. New
   `src/jenova/zlib.nim` (bound as `uncompress`/`compress` only, so no versioned
   struct is mirrored — D-V) and `src/jenova/pdf.nim` (content streams and the
   four text-showing operators). `readAttachment` attaches a PDF as its extracted
   text in the Web UI's own PDF shape. **A PDF with no readable text is refused,
   never attached empty.**
2. **Audio capture — NOT BUILT and not gated (D-BZ).** Ruled by the USER: they do
   not need it. **It is not to be put to them again.** The `input_audio` *send*
   path stays under Directive 3 — it carries imported Web UI conversations, and
   not building capture is not licence to delete what already sends.

**Proof:** `attach-selftest`, **27 assertions**, five clean reds across two
rounds. The part order is asserted, so a divergence from the Web UI names itself;
so are the URI decode, the NUL-byte text test and the vision refusal in both
directions. What is *not* asserted, and cannot be from here: the picker, the
chips, the thumbnails, the drop target and the paste button are widgets.

**LaTeX maths is deliberately still open** under G-34. Tables were the half that
bites; KaTeX has no GTK equivalent and rendering maths is its own project.

---

## Step 7c — **BUILT 2026-09-01 17:51.** Attachments no longer freeze the window (G-40)

Done and out of this plan. The record is `PROGRESS.md` 2026-09-01 17:51; the cap
and the refusal are **D-BQ**.

**What was actually wrong, kept because it is the general lesson:** the thumbnail
cache built its key as `sha256(payload)` **on the line above the lookup that key
served**. The decode was cached and the key was not, so the expensive half ran on
every frame — a cache that guaranteed the cost it existed to avoid. Alongside it,
`view` re-parsed every attachment's JSON and every message's markdown per frame,
and `postConversation` re-parsed every payload again on every send.

**The rule this step establishes, and it is the durable part:** *nothing inside
`view` may do work proportional to a payload.* `view` runs on every frame; a proc
called from it may look things up and must not parse, hash, decode or copy.

**One thing the plan had wrong, recorded rather than quietly dropped.** 7c-4 said
the body build should move off the GTK thread to the stream worker. **It should
not, and the reason is worth keeping:** the worker would need the message history,
so the payloads would cross the channel instead — the same copy, in the other
direction. The real waste was that `postConversation` *re-parsed* every payload,
not that it ran where it ran. Routing it through the memo removed that; the string
build and the single channel copy stay on the GTK thread deliberately.

**A second thing worth carrying:** the memo keeps **both** the original node and
the reduced attachment list from one parse. The reduced form drops `AUDIO` and
flattens `PDF` because this window cannot draw either — so building the outbound
request from it, which was the obvious implementation, would have silently stopped
sending audio and PDF page images that an imported Web UI conversation carries
(D-BP). That is asserted in both directions now.

**Proof: 17 new assertions in `attach-selftest`, three independent corruptions,
three clean reds** — one of them (deriving the key from the payload) re-creating
the original defect exactly. **Two real bugs were caught by the new assertions as
they were written:** `for i, e in` over a `JArray` resolves to `pairs` and aborts
the process, and truncating division reported a 25.001 MB file as *"is 25 MB and
the limit is 25 MB"*. Ten self-tests pass, both binaries build ELF 64-bit FreeBSD,
`bin/jenova --check` exits 0.

**Not verified, and it is the whole point of the step:** whether the window is
actually responsive with a document attached. There is no GUI test coverage,
`--check` presses nothing, and the parse counters prove the work is not repeated
but cannot prove the frame budget is met. **That is a USER run.**

---

## Step 7c, as planned — kept for the record

**Reported by the USER 2026-09-01:** attaching a document locks the GUI up
completely and the only way out is to kill it. **This outranks Step 8.** Step 8
adds views; this one makes a feature that already shipped usable at all.

**The full mechanism, with all four contributing sites, is `TODOS.md` G-40.** In
one sentence: `view` re-parses every attachment's JSON and re-hashes every base64
payload **on every frame**, `postConversation` rebuilds and re-inlines the whole
history **on the GTK thread on every send**, nothing caps the input, and every
payload is held two or three times over.

### The rule this step establishes

**Nothing inside `view` may do work proportional to a payload.** `view` runs on
every frame; a proc called from it may look things up and must not parse, hash,
decode or copy. That is the general form of the rule the comment at
`gui.nim:3624-3627` already stated for thumbnails and that the thumbnail work then
broke. **Writing it down here is the point of the step** — G-40 is the third time
this project has shipped a per-frame cost (the canvas `redraw` at `gui.nim:1035`
and the code-block cap were the first two).

### The work, in order, smallest and most assertable first

**7c-1 — Give an attachment an identity that is not its content.**
`pipeline.Attachment` (`pipeline.nim:542`) gains a `key` field, set **once** by
`readAttachment` from the file's name, size and mtime — never from the payload.
`gui.attachmentPixbuf` then keys `thumbCache` on `$size & ":" & a.key` and the
per-frame SHA-256 disappears. A stored attachment read back from `extra` gets its
key from the row: `m.id & ":" & $index`, which is stable and already unique.

**7c-2 — Parse `extra` once per message, not once per frame.**
`gui.attachmentsOf` moves below the widget layer as `pipeline.parseAttachments`,
and behind it goes a small memo keyed by message id. `view` gets a lookup.
**The memo carries a `parses` counter**, which is what makes the fix itself
assertable rather than merely believed — see the proof section.

**7c-3 — Cap the input, and refuse rather than truncate.**
A size limit in `pipeline.readAttachment`, refused with a reason naming the limit
and the actual size. **Refusal over truncation** because a silently shortened
document changes what the model was asked about while looking like it worked —
the same class of defect as D-BK's "unset value sent as a zero". *This is the one
open product question in the step; see the bottom.*

**7c-4 — Get the body build off the GTK thread.**
`postConversation` currently builds the whole outbound body, inlining every image,
in the Send handler. The body build moves to the stream worker: the job carries
what the worker needs to build it, not the built string. This also stops the
multi-megabyte channel deep-copy at `gui.nim:1637`.

**7c-5 — Memoise `markdown.parse` for completed messages.**
Same shape as 7c-2, same memo, keyed by message id. **The live streaming turn is
excluded** — its text changes every token, so memoising it would show a stale
transcript. That exclusion is the part to get right and the part to assert.

### What proves it worked

**The honest split first: the freeze itself cannot be asserted from here.** There
is no GUI test coverage (`BRIEFING.md` §6), `--check` presses nothing, and a
timing assertion would be flaky. **Only the USER running it settles the report.**

**But the fix is not therefore unprovable** — the rule-15 move is to assert the
*join*, and here the join has a natural counter:

| | What is asserted | Where |
|---|---|---|
| 7c-1 | A key is set at read time, is stable across calls, differs for different files, and **is unchanged when only the payload differs** | `attach-selftest` |
| 7c-2 | Calling `parseAttachments` for one message id **100 times increments `parses` exactly once** — this is the fix, stated as an assertion that bites | `attach-selftest` |
| 7c-3 | A file over the cap is refused, the reason names both sizes, and one under it is accepted | `attach-selftest` |
| 7c-4 | The body the worker builds is **byte-identical** to the one `postConversation` built before the move | `pipeline-selftest` |
| 7c-5 | A completed message parses once; **a message whose text changed re-parses** | `attach-selftest` |

**Every one of the above is to be shown going red first**, against the unfixed
source where that is possible and against a deliberate corruption where it is not.
The 7c-2 and 7c-5 counters are the two that matter: they are the only assertions in
this project that would catch a per-frame cost being reintroduced, and **that is
exactly how G-40 got in.**

**`bin/jenova --check` must still exit 0** before this is handed over (rule 17).

### What is deliberately not in this step

**The storage shape (mechanism D).** Payloads live inline in `messages.extra` by
D-BP, so they are copied into `allMessages`, again into `messages`, and again into
the body. The real answer is to store the bytes beside the row and keep a reference
in `extra` — but that **changes the D-BP shape the frozen Web UI reads**, and D-Z
makes `jca_web` unreadable-and-unwritable, so a conversation would stop moving
between the two surfaces unconverted. **That is a decision for the USER, not a
session**, and it is written up as **Step 7d** below rather than folded in here.

**T-3 is adjacent and stays where it is.** Untrimmed history is what makes B
unbounded, but trimming is Step 9 work with its own proof and should not be
smuggled into a defect fix.

---

## Step 7d — **CLOSED 2026-09-01 18:41.** Attachment storage: parity, inline stays

**Ruled: parity with the Web UI (Q-34, amended into D-BV).** The inline payload stays
exactly as D-BP stores it and the `fileAssets` artefact of 10b is written **in addition**,
so nothing about the message row changes and a conversation still moves between the two
surfaces unconverted. The memory and per-turn upload cost is accepted deliberately; Step
7c is what makes it tolerable and the USER has run and confirmed that. **T-3 is what
makes the per-turn cost unbounded and it is still Step 9.** The original write-up follows.

Inline payloads in `messages.extra` (D-BP) are why
a single conversation holds each image three times in memory and re-uploads it on
every turn. Storing the bytes beside the row and keeping a reference would fix all
of that — **and would diverge from the frozen Web UI's shape**, which D-BP chose
deliberately so conversations move between the surfaces without conversion.

**The trade is:** parity with `jca_web`'s storage, against memory and per-turn
upload cost. Both are real. **Raise it after Step 7c is run and seen to work** —
7c may well make the inline shape acceptable, which would settle this at no cost.

---

## Step 8 — The remaining views

**Every reference in this step was re-verified against the source on 2026-09-01 at
18:07, and is written as a symbol with no line number** — the seventh sweep found
every `gui.nim` and `api.nim` address in this file stale while every address into the
stable modules held. The policy, and the evidence for it, is the sweep note at the top
of `TODOS.md`.

**Recommended order: 8b, then 8a, then 8c.** 8b is the smallest, it is the one the
codebase already argues for in a comment of its own, and it closes a data-loss-shaped
hole that G-36 half-opened by making deletion easy and confident.

---

### 8b. **BUILT 2026-09-01 19:05.** Trash view *(G-21)*

Everything deleted is soft-deleted and currently invisible from the desktop
application. **`gui.nim` has no trash surface at all** — its only `trash` matches are
the `user-trash-symbolic` icons on four delete buttons, and a comment stating that
with no trash view a soft delete is indistinguishable from data loss. That comment is
the case for this step.

**The backend exists and is asserted. Do not write a route.** Inside **`api.handleFs`**:
`GET /api/fs/trash` over `fssync.getTrash`, `POST /api/fs/trash/restore` over
`fssync.restoreTrash`, `DELETE /api/fs/trash/empty` over `fssync.emptyTrash`. Inside
**`api.handleDb`**: `/<entity>/deleted` and `/<entity>/<id>/restore` on every table,
over **`api.restoreItem`**, which walks parents to a depth of 8 and revives a
conversation's messages with it.

**The one piece of real logic in the step, and it is below the widget layer where it
can be asserted: restoring a message does not put it back in the retrieval index.**
Confirmed by reading `api.restoreItem` on 2026-09-01 18:07 — it flips `is_deleted`,
walks its parents, returns, and contains no `rag.*` call, while the delete path calls
`rag.forgetMessage`. Deletion forgets (D-BI) and nothing undoes it, so a restored turn
comes back everywhere except in what the model recalls — until the next start, when
`rag.backfillChats` silently repairs it, **which is exactly the shape of bug that hides
for weeks** (rule 15). `restoreItem` should call `rag.indexExchange` for a restored
message.

**What proves it worked:** the re-index is a `db-`/`rag-selftest` assertion — index an
exchange, delete it, assert `rag.query` no longer returns it, restore it, assert it
comes back **without** a `backfillChats` call. Shown going red against the unfixed
source first. The view itself is widgets and is a USER run.

---

### 8a. **BUILT and CONFIRMED ON SCREEN 2026-09-02 10:53.** Model selector *(G-20, G-48)*

Done and out of this plan. Reshaped to D-CB at 10:43 — the enumeration is
`models/instruct` and `models/thinking` only, a displaced symlink is removed rather than
renamed (only a real file is still preserved as `.old`), and the window's two named menu
items are gone with the tray keeping its pair. **22 assertions in `models-selftest`**;
twelve self-tests pass, both binaries ELF 64-bit FreeBSD, `bin/jenova --check` exits 0.
**The USER ran it: switching and folder resolution work as intended.** The record is
`PROGRESS.md` 2026-09-02 10:43 and 10:53.

**Two honest notes.** **Which of the three changes fixed the reported failure was never
diagnosed**, because the symptom was never known — the reshape was D-CB's shape, not a
repair aimed at a mechanism, and no session should later write one in. And **loading a
switched model into the backend was not exercised**, the USER not having started it; that
is unobserved, not suspect, and lives in `BRIEFING.md` §8. **Do not re-add an unverified
label to the two halves that were confirmed** (rule 12).

The write-up that produced this follows.

Recorded as built at 08:43; the USER ran it and it does not work. **The symptom is not
known** and is not to be guessed at (rule 1, D-AN).

**The shape is also wrong, and that is settled — D-CB.** It must draw from
`models/instruct` and `models/thinking` only, swap `models/agent`, and stop accumulating
`.old` copies. What shipped scans every subdirectory, so it offers embed and draft models
as the agent model.

**The work — four parts, scoped against the source 2026-09-02 10:00. Three of them are
D-CB's shape and need no symptom; only the fourth waits on one.**

**G-48-1 — narrow the enumeration to the two source folders.** `models.available` walks
**every** subdirectory of `models/` *and* the flat `models/` directory itself (its `dirs`
seed is `(modelsDir, "")` before the subdirectory walk). **That is two deletions, not one**
— every tracker so far has named only the subdirectory scan. It becomes `models/instruct`
and `models/thinking`, and nothing else. `models/agent` stays excluded for the reason it
already is: its entries are symlinks to rows listed under their own role.

**G-48-2 — stop accumulating copies.** The `.old`/`.old.N` chain is in `switchToPath`.
**A displaced entry that is a symlink is removed, not renamed** — the real `.gguf` still
lives in `instruct/` or `thinking/`, so a `.old` link preserves nothing and only fills the
directory. **A displaced entry that is a real file is still preserved as `.old`**, because
deleting a `.gguf` the user put in `models/agent` by hand is data loss and D-CB rules on
duplicate *copies*, not on the safety.

> **Two consequences nothing recorded, both of which this part reaches:**
>
> 1. **`switchModel` calls `switchToPath`**, so this changes the tray's two quick-switches
>    and `jenova-core models switch`, whose output prints the `preserved:` lines
>    (`jenova_core.nim`, the `models`/`switch` case). Directive 3: the subcommand must keep
>    working — its *output* changes, its contract does not.
> 2. **`models-selftest` asserts the old behaviour.** `TESTS.md` §0r records "the displaced
>    model is **preserved as `.old`, not deleted**" as covered. That assertion is superseded
>    by D-CB and is rewritten with this part, not left to fail.

**G-48-3 — one switch surface in the window.** The two named literals are in the window's
app menu (`gui.nim`, the `Popover` under the `open-menu-symbolic` `MenuButton`, directly
below the `Models…` item). They go; the Models panel stays.

> **The tray's two are kept, and this is a reading, not a ruling.** D-CB says one switch
> surface **in the window**. The tray's items are `TrayItem` rows built in `gui.nim` — not
> in `tray.nim` — dispatching the same `switch_instruct`/`switch_thinking` jobs. A D-Bus
> menu cannot host a searchable list, so removing them leaves the tray with no way to
> change model and nothing in its place. **Stated so the USER can overrule it in one word.**

**G-48-4 — fix the reported failure.** Not started until the symptom is known (rule 1,
D-AN). `models-selftest` passes throughout, which says the parts work and nothing about
the window (rule 15) — **and the join from the panel to `models.available` is exactly what
is untested.**

**In the tree now:** `models.available`, `activeAgentPath`, `switchToPath` in
`models.nim`; `gui.openModels` / `switchToModel` / `modelsPanel`, the `switch_path` job in
`gui.ctlWorker`, and the `drive-multidisk-symbolic` header button; `models-selftest`.
**`switchModel` and `jenova-core models switch` are untouched and still work.**

#### What proves each part worked

| | What is asserted | Where |
|---|---|---|
| 48-1 | A fixture tree with `instruct`, `thinking`, `embed`, `draft` **and** a flat `models/*.gguf` lists **only** the first two folders' models — both sides of one tree, so the narrowing cannot pass by listing nothing | `models-selftest` |
| 48-2 | Switching **α → β → α** leaves exactly one entry in `models/agent` and **no `.old*` at any point** — a transition, per D-BX. A real file placed in `models/agent` **is** still preserved | `models-selftest` |
| 48-3 | Nothing — it is a widget deletion. **`bin/jenova --check` must exit 0** (rule 17): removing a menu block is precisely the change that compiles and then fails to build a window | — |
| 48-4 | Depends on the symptom | — |

**Every assertion bites by varying the DATA, never the code (D-BX, rule 16).**

**Model information was never built** — context size, quantisation, vocabulary, chat
template need `/props` plus a GGUF header read. Separate work.

The original write-up follows.

---

### 8a as planned — kept for the record. **Rewritten 2026-09-02 08:01 against the source**

Replace the two hardcoded menu items — the literals **"Switch to instruct model"** and
**"Switch to thinking model"**, which appear **twice each**: once in the window's model
menu and once again in **`gui.trayMenu`** — with a searchable list carrying per-model
status and capabilities, plus a details dialog (context size, parameter count,
quantisation, vocabulary, slots, modalities, chat template).

**The previous revision of this step was wrong about the backend, and the correction
is the whole shape of the work.** It said `discover` is a finished engine with nothing
feeding it — T-17's shape — so 8a's first job was to call it. **It is not.** Read out of
`src/jenova/models.nim` on 2026-09-02:

| What the plan assumed | What `models.nim` actually does |
|---|---|
| `discover` lists the models on disk | **`discover(jcaHome, kind)` returns ONE path** for one of three fixed roles — agent, draft, embed. An env override, else the first `.gguf` in sorted order under `models/<role>`. There is no enumeration in it; `findModel` walks a directory and throws away everything but `found[0]` |
| It is called and merely unused in the GUI | **It has no caller anywhere in the product.** Not `gui.nim`, and not `jenova-core models list`, which echoes three `config` values and never asks `models.nim` anything. It is dead code |
| `switchModel` activates a chosen model | **`switchModel` refuses any target that is not the literal `"instruct"` or `"thinking"`.** It resolves `models/<target>`, validates a temporary symlink, preserves displaced entries as `.old`, and renames into place. The safety is real and must be kept — the *target vocabulary* is what is two items wide |

**So the backend does not exist for this feature; two thirds of it has to be written.**
That is the opposite of Steps 4, 8b and 10a, where the engine was finished and starved.

**The one thing that genuinely does already exist is the information half.** `gui.nim`
already reads `/props` for the context window and the loaded model's name (G-33), for
`default_generation_settings.params` (G-31) and for `modalities` (G-30), and
`routes.nim` already forwards `/props` upstream. **The details dialog is mostly a
second reader of a call the window is already making** — the same reuse that made the
settings panel's "Custom" badge free (D-BK).

#### The work, in order, smallest and most assertable first

**8a-1 — Give `models.nim` an enumerator.** A proc that walks `models/` and returns
every `.gguf` with its role directory, filename, size and whether it is the active
symlink target — the loop `findModel` already contains, without the `found[0]`. Skip
`.old`/backup entries the way `targetModel` does (`isBackup` exists). **This is new
code in `models.nim` and it is where the whole step's assertability lives.**

**8a-2 — Decide what "switch" means for a model that is neither instruct nor thinking.**
`switchModel`'s four-step safety (validate before touching, relative link target,
preserve rather than delete, atomic rename) is the part worth keeping, and its
two-literal gate is the part in the way. **The change is to take a resolved model path
rather than a role name**, with the existing two-target entry point kept as a caller of
it — Directive 3, total feature retention: `jenova-core models switch instruct` must
keep working unchanged.

**8a-3 — Rows, not widgets.** Whatever turns the enumeration plus `/props` into rows —
sorting, active/loaded status, capability badges — belongs in `models.nim`, for the
reason `settings.nim`, `hardware.nim` and `workspace.nim` are where they are. `gui.nim`
gets a list to draw and a details dialog to fill.

**8a-4 — Replace the four literals.** Two in the window's model menu, two in
`gui.trayMenu`. Search the strings; no line numbers are recorded for `gui.nim` (rule 9).

#### What proves it worked

| | What is asserted | Where |
|---|---|---|
| 8a-1 | A fixture tree of role directories yields **every** `.gguf` and **not** the `.old` backups; an empty tree yields an empty list, not an error; the active symlink is identified as active | `models-selftest` (new) |
| 8a-2 | Switching to a path outside `models/` is **refused**; a switch preserves the displaced entry rather than deleting it; **`switch "instruct"` still resolves and behaves exactly as before** | `models-selftest` |
| 8a-3 | Rows carry the loaded model marked as loaded when `/props` names it, and the same list with `/props` absent still renders every model as not-loaded rather than empty | `models-selftest` |
| 8a-4 | Nothing — it is widgets. The list, the search box and the dialog are a **USER run** | — |

**Every assertion is to be shown biting by varying the DATA — a fixture tree with and
without the backup, a `/props` payload naming a different model — never by editing the
source (D-BX, rule 16).** `bin/jenova --check` must exit 0 before handover (rule 17).

**Not in this step:** downloading or deleting models, and per-model *loading* (the Web
UI's load/unload). `llama-server` holds one model and `lifecycle` restarts it; a
load/unload surface implies a model server this program does not have. Raise it if the
USER wants it — do not infer it from the Web UI's button.

---

### 8c. Make the notes editor good *(G-17)* — rescoped **again**, 2026-09-01 18:41 by **D-BW**

**Rescoped twice in one session and it is now the smallest it has ever been.** It began
as "build a real writing surface", became "point the embedded Neovim at the workspace"
(D-BT), and the USER has now ruled: **keep the existing notes editor, do not replace it
with Neovim, and keep Neovim on its own page.**

> *"lets keep the default notes editor and dont replace it with neovim"* … *"instead we
> should make the notes system work well and keep the neovim and neovim config to its own
> page - the editor page - as it currently exists."*

**So 8c is: make `gui.saveNote` and its `TextView` a good notes editor.** Not a second
Neovim, not a document panel. **Q-35 is answered and T-11 is not touched** — with notes
in their own editor and Neovim on its own page there is no second writer against an
authoritative row at all, which is the outcome Q-29 was trying to protect.

#### Scoped 2026-09-02 11:05, against the source on both sides

**The Web UI's surface, read out of `jca_web/src/routes/notes/[id]/+page.svelte` and
`notes/+page.svelte`** (rule 11 — the barrel files do not carry `notes`; the routes do):

1. A note **renders as Markdown** and drops to a plain `textarea` only on **Edit**.
2. **Cancel** leaves edit mode and restores the stored title and content.
3. **Delete** behind a confirmation dialog — and **a FOCUS note has no delete button.**
4. A **FOCUS note is pinned and coloured** in the header; a regular one gets a file icon.
5. The list page has a **title search**, a **New Global Note**, sorting by `updatedAt`
   newest-first, and a **container badge** (workspace / project / folder / Global).
6. An empty note says so rather than showing a blank pane.

**This window has:** an `Entry` for the title, a `TextView` for the content, Save, and
Close. Nothing else. **And two defects, both found 2026-09-02 and both inside this step:**
**G-49** — Save and rename write the row without `isFocusNote`, so a FOCUS note stops being
one — and **G-50** — nothing in `gui.nim` can set the flag in the first place.

**Order — the two defects first, because they are correctness and the rest is comfort.**

### 8c-1 and 8c-2 — **BUILT 2026-09-02 11:21**

**8c-1 — the flag is no longer wiped (G-49).** **The fix went one level up from where this
plan put it.** The plan said to resend `isFocusNote` where the node is built, the way the
rename branch already resends a file asset's `content`. **That repairs the instance and
leaves the class** — and the class had already bitten once (T-13) and been repaired the
same way, which is how it came back. `api.putEntity` now **merges a partial node onto the
stored row** before handing it to `upsert`, so any column the window omits is carried
forward. It is the only function every in-process window write passes through and nothing
else calls it, so `upsert`, `writeRow` and the whole HTTP contract are untouched — the Web
UI still posts partial objects and still means them (**D-CC**).

**The explicit resends in the window stay**, and the reason is worth keeping: they carry
the *open editor's* value, not the stored one. A note renamed with unsaved text in the
buffer must keep that text, so the same rule now applies to an unsaved FOCUS toggle.

**8c-2 — the window can set the flag (G-50).** A `view-pin-symbolic` `ToggleButton` **beside
the note title**, bound to new `AppState.noteFocus`, read by `gui.loadNote` and written by
`gui.saveNote` as `1`/`0`. `workspace.contextFor` did the rest, exactly as this plan said.
New **`workspace.isFocusValue`** is the single truth test both the context builder and the
window read, so the toggle cannot disagree with the behaviour it controls.

> **It shipped in the button row below and crashed the application, and where it sits now
> is the fix, not a preference (11:35, `TODOS.md` G-51).** owlkettle diffs a `Box`'s
> children **by index** and `Button.shortcut` has **no update path** — it installs a
> `GtkShortcutController` in `build` and its `update` hook only asserts the value never
> changed. `gui.fullscreenButton` (`"F11"`) is the only widget here that sets one, and a
> fourth child in that row moved it onto the Send button's state: `assert "" == "F11"`,
> process aborted on opening a note. **Nothing may change the child count of a container
> holding a shortcut-carrying `Button`**, and `--check` cannot catch it — it builds each
> branch once and the assertion fires only on an update.

**Proof: 18 assertions added to `workspace-selftest`, and they go through
`api.putEntity` itself** — the call the Save button makes — rather than through an INSERT,
because every existing assertion in that suite supplies its own rows and that is precisely
why none of them could see G-49 (rule 15, a fourth time). Written as a **transition**
(D-BX): a FOCUS note is written, survives a partial save carrying no flag, is cleared and
stops escaping its level, is still present at its own level, and comes back when the flag
is set again. **No single wrong behaviour passes all of them** — ignoring the flag fails
the third, always-carrying it fails the clear, and `isFocusValue` is asserted from both
sides. **Twelve self-tests pass, both binaries are ELF 64-bit FreeBSD, `bin/jenova --check`
exits 0.**

**Two things stated plainly.** **No red was produced and none was attempted** — the
assertions were not shown failing against a damaged tree, because D-BX forbids corrupting
the source and a `git stash`-and-rebuild has the same failure mode the ruling was written
about. The discrimination argument above is structural, and the previous revision is in
git if the USER ever wants the red. And **the toggle itself is unseen** — `--check` builds
the widget tree and presses nothing.

**One thing the self-test needed and it is worth carrying:** writing through `putEntity`
mirrors the row to disk, so `workspace-selftest` now points `JENOVA_WORKSPACES` at a
scratch directory **before `paths.resolve()`** — `fssync.roots` caches the first value it
resolves, so a block added above that line would silently move the files into the USER's
own `Workspaces`.

### 8c-3 … 8c-6 — **BUILT 2026-09-02 11:53. Step 8 is complete and G-17 is closed.**

**8c-3 — a note reads as markdown and edits as text.** The transcript's block renderer was
**extracted as `gui.mdBlock`** and both surfaces call it, so a note's tables, capped code
blocks and copy buttons *are* the transcript's rather than a second copy that drifts.
`messageBody`'s child structure is unchanged — one widget per block, same order — so
nothing about how owlkettle diffs a transcript moved. Cancel restores the stored row.

**8c-4 — unsaved work cannot be dropped in silence, through any of its three doors.**
Close was the one the plan named; **the other two are worse and the plan had missed them** —
clicking a different note in the tree and creating a new one both replace the buffer, and
each is a single click with no warning. All three now go through `confirmLoseNoteEdits`
(Cancel / Discard / Save), and **a failed save refuses to proceed**, because carrying on
would lose exactly what the dialog was protecting. The guard on *create* runs before the
row is written, or a cancelled dialog would leave an orphan "New note" behind.

**8c-5 — delete is on the note**, over G-36's existing cascade dialog. **A FOCUS note is
refused rather than hidden** — a deliberate divergence from the Web UI, which omits the
button: a disabled control carrying the reason says why, and one that vanishes reads as a
bug. The protection is the same either way.

**8c-6 — mostly already built, and recorded instead of rebuilt** (rule 5). `listNotes`
already orders newest-first, and **the tree's search already filtered notes and files by
title** — `leavesIn` has always done it. Its placeholder said *"Search chats"*, so a
working feature was denied by its own label; that string is the only thing that needed
changing. **The container badge is not built and should not be:** the tree nests a note
under its container, so a badge would restate the row's own position. The empty-note
affordance is new.

> **One rule this step had to obey and it is Step 7c's.** The rendered view reads
> **`noteOrigContent`, never `noteBuffer.text()`** — `view` runs on every frame and
> reading a `TextBuffer` copies the whole note out of GTK each time, which is the defect
> that froze the window on an attachment (G-40, D-BQ). It is also exactly correct: view
> mode is only reachable with the buffer equal to the stored text, because edit mode's
> only exits are Cancel (restores) and Save (writes, then re-baselines).

#### What proves each part worked

| | What is asserted | Where |
|---|---|---|
| 8c-1 | **DONE.** A note written FOCUS through `putEntity` **still is one after a partial save carrying no flag**, and a node omitting the content leaves the content intact — the class, not the instance | `workspace-selftest` |
| 8c-2 | **DONE.** Setting the flag through `putEntity` makes `contextFor` reach a folder chat from the workspace root; clearing it stops that **while the note stays at its own level**; setting it again restores it — a **transition**, per D-BX. `isFocusValue` asserted from both sides | `workspace-selftest` |
| 8c-3 | **Already covered.** Both surfaces call `markdown.parse` through the *same* `mdBlock`, so "the same blocks as the transcript" is now true by construction rather than by assertion | `markdown-selftest` |
| 8c-4 | **Not assertable, and this is the honest answer the plan asked for.** `noteDirty` and `confirmLoseNoteEdits` take `AppState`, which is the type owlkettle's `viewable` macro emits inside `gui.nim`, and `gui.nim` does not link into `jenova-core`. **It is a USER run** | — |
| 8c-5 | **Already covered:** `cascadeCount("notes", …)` is asserted. The FOCUS refusal is a widget condition | `db-selftest` / — |
| 8c-6 | **Already covered by construction:** the sort is `listNotes`' `ORDER BY updatedAt DESC` and the filter is `leavesIn`, both of which predate this step. The placeholder is a string | — |

**Every assertion bites by varying the DATA, never the code (D-BX, rule 16).**
**`bin/jenova --check` must exit 0 before handover** (rule 17).

**Not in this step:** anything that makes Neovim the notes editor (D-BW ruled against it),
and LaTeX in a note (that is G-34's open half, and it has no GTK equivalent).

---

## Step 10 — **NEW, 2026-09-01 18:29.** The workspace becomes a working context

Three USER instructions given together, and they are one feature: **a workspace should
carry its own notes, its own files, and an editor that works on them with the AI.**
Rulings **D-BS**, **D-BT**, **D-BU**, **D-BV**.

**Everything below was verified against the source on 2026-09-01 at 18:29** before it
was written down.

---

### 10a. **BUILT 2026-09-01 19:05.** Workspace artefacts reach the model *(D-BU)*

**`pipeline.nim` contains no reference to notes at all.** Meanwhile the `notes` table
carries `isFocusNote`, `fileAssets` carries `content` and `type`, `conversations`
carries `folderId`/`projectId`/`workspaceId`, and `api.nim` round-trips `isFocusNote`.
**The entire data model exists and nothing reads it.** That is T-17 for the third time:
a finished, tested store with nothing feeding it, and every test green because each
supplies its own data (rule 15).

**The insertion point already exists.** `pipeline.injectSystem` appends `webContext`,
`editorContext` and `ragContext` to the persona. **Workspace context is a fourth of
identical shape** — so it lives below the widget layer and is provable with no window,
the same move that made settings, hardware and the attachment classifier provable.

**Parity is taken from the source, not a summary** (rule 11):
`jca_web/src/lib/services/workspace.service.ts`, `WorkspaceService.getWorkspaceContext`,
injected by `chat.service.ts` under the heading `[CURRENT WORKSPACE ARTIFACTS (Notes &
Files)]`. The behaviour a summary loses, and which **is** the step:

1. Scope is the conversation's **deepest** set id — folder, else project, else workspace,
   else *global*, which selects only artefacts with **no** container.
2. Regular notes at **folder** level are **strictly isolated to that folder**. At project
   level they include child folders; at workspace level, everything nested.
3. **A FOCUS note escapes its level** and applies across the whole workspace tree. This is
   the part every summary drops and it is why the flag exists.
4. **Files follow regular-note scoping and have no FOCUS concept.**
5. The format is **literal**: `--- FOCUS / RULES ---` with `[Folder|Project|Workspace] Title`,
   `--- NOTES ---` with `Title:`/`Content:`, `--- FILES ---` with
   `File: <name> (Type: <type>)` and either `Content:` or exactly
   `(Binary file, content not available for direct reading)`.
6. A FOCUS note with blank content contributes nothing.

**Carried over knowingly:** the upstream has a standing `TODO` that there is **no token
budget**, so a large workspace can overflow the context by itself. Jenova inherits that
by taking parity. **Not fixed here — it is T-3's problem** and fixing either alone buys
nothing.

**What proves it worked:** a `pipeline-selftest` section over a hand-built tree —
workspace, two projects, two folders, regular and FOCUS notes at every level, plus files.
Assert **scope isolation** (a folder chat does not see its sibling's notes), **FOCUS
escape** (a workspace-root FOCUS note reaches a folder chat), **the global fallback**,
the **exact** output strings, and the **join** — that the text lands in the system message
of the body actually sent (rule 15; this is the assertion T-17 proved a project can go
weeks without). Every one shown going red first.

---

### 10b. **BUILT 2026-09-02 07:51.** An uploaded file becomes a workspace artefact *(D-BV)*

Done and out of this plan. `gui.fileAttachmentsAsArtefacts` writes a `fileAssets` row per
attachment through `api.putEntity`, so `fssync.syncFileAsset` mirrors the bytes and the
same cascades apply as on the HTTP surface. The inline base64 in `messages.extra` is
untouched (Q-34, parity). A chat with no workspace, project or folder files nothing —
a global artefact would be visible to every unassigned chat. The record is `PROGRESS.md`
2026-09-02 07:51. The original write-up follows.



**Nothing in the program has ever written a `fileAssets` row** — verified: the table is
created in `db.nim`, cascaded in `api.nim`, trashed and restored in `fssync.nim`, and
**never inserted into**. So an attachment is invisible to the workspace it was dropped
into, and invisible to 10a's context builder.

**The work:** attaching a file to a chat that belongs to a workspace/project/folder also
writes a `fileAssets` row at that level and mirrors the bytes through `fssync`, so it
appears in the tree and trashes and restores with its container.

**Q-34 is ANSWERED — parity with the Web UI (2026-09-01 18:41).** `messages.extra` keeps
the inline base64 exactly as D-BP stores it and the artefact is written **in addition**.
Nothing about the message row changes, so a conversation still moves between this window
and the frozen `jca_web` unconverted. **Step 7d is closed** — it existed only to ask this.
**Nothing in 10b is gated any more.**

**Proof:** an `attach-selftest`/`db-selftest` assertion that an attachment on a scoped
conversation produces a `fileAssets` row at the right level, that it is picked up by
10a's context, and that deleting the container cascades it.

---

### 10c. **BUILT 2026-09-01 19:05.** The editor page's Neovim loads `jvim` *(D-BS)*

**Scope narrowed 2026-09-01 18:41 by D-BW:** there is **one** embedded Neovim now, the
editor page's. The document panel and its second instance are removed by Step 11, so
`vte.configureDoc`/`newDocTerminal` are not wired to anything — they are deleted.

**`vte.nim` spawns `nvim --listen <socket> --cmd <TransparentBackground>` with
`envv = nil`.** So `NVIM_APPNAME` is never set, jvim's configuration is never loaded,
and `JENOVA_ROOT`, `JENOVA_PORT` and `JENOVA_LAN_MODE` — which
`jvim/lua/jenova/endpoints.lua` reads, and which its own `has_jvim_env` tests for — are
never passed. **The editor page runs stock Neovim today.** Passing an environment to
`vte_terminal_spawn_async` is the whole of it.

**Nothing needs building on the server.** `endpoints.lua` wants `/v1/chat/completions`
and `/infill` on port 8080 and `/api/storage/<path>`; `routes.nim` already routes
`/infill` and `server.nim` already handles `/api/storage`. Verified, not assumed.

**What this unlocks is the reason it is worth doing:** `jvim/lua/jenova/` already ships
FIM completion, a chat drawer, LAN discovery, backend telemetry, and an `agent/` tree
with buffer read/write/edit/grep/glob/ls, LSP, shell and `vim_cmd` tools plus memory and
context compaction. **10c is the line of wiring that turns 8c's panel into that.**

**Proof:** the spawn's environment is built by a proc that can be asserted without a
terminal — assert `NVIM_APPNAME=jvim` and the three `JENOVA_*` values are present and
correct. Whether jvim actually loads is a USER run.

---

---

## Step 11 — **BUILT 2026-09-01 19:05.** The document side panel is removed *(D-BW)*

**The USER called it a gimmick and instructed its removal.** Directive 3 permits this
because it was explicitly instructed; that is recorded so it is never cited as licence to
remove anything else.

**Footprint, read out of the source 2026-09-01 18:41 — it is well bounded:**

| Where | What |
|---|---|
| `gui.nim` state | `AppState.panelOpen`, `panelDoc`, `panelDir`, `panelDocs` |
| `gui.nim` procs | `docDir`, `refreshDocs`, `openDoc`, `newDoc`, `closePanel`, `isNoteMirror` |
| `gui.nim` widgets | the panel block and its `sizeRequest` swap, the toggle button, the `DocTerm` renderable |
| `vte.nim` | `configureDoc`, `newDocTerminal`, and the `docSockPath`/`docCwd`/`docFile` triple |
| `nvimctl.nim` | `docSocketPath` |
| `theme.nim` | `.doc-panel` and `.doc-panel-closed` |

**The per-chat `document.md` stops being created.** Existing ones on disk are **not**
deleted — they are the USER's files in their own workspace tree, and removing a Jenova
surface is not licence to delete user data.

**Two simplifications fall out and both are the point:**

1. **`pipeline.configureEditor` is set once in `gui.run` and never re-aimed.** The re-aim
   in `openDoc` and the restore in `closePanel` go with the panel. **Q-30 is moot** — it
   asked which of two instances `Editor:` reads, and there is one.
2. **`isNoteMirror` goes, but its reasoning does not.** It existed to keep `fssync`'s note
   mirrors out of the panel switcher so no file had two writers. `fssync` still mirrors
   notes and the editor page can still open them — that is the USER's own editor, not a
   surface Jenova built. **Do not add the exclusion back somewhere else.**

**What proves it worked:** `nimble core` and `nimble gui` build, every self-test passes,
and **`bin/jenova --check` exits 0** — which is exactly the check rule 17 exists for,
because removing a widget block is precisely the change that compiles and then fails to
build a window. Nothing else here is assertable; it is deletion.

---

## What Session 019 built — 2026-09-01 19:05

**Step 11, 10c, 10a and 8b are done**, in that order, which is the order set at 18:41.
Both binaries build, **twelve self-tests pass**, `bin/jenova --check` exits 0.

| Step | What landed |
|---|---|
| **11** | The document panel is gone — four `AppState` fields, six procs, the widget block, the toggle, the `DocTerm` renderable, `vte.configureDoc`/`newDocTerminal`, `nvimctl.docSocketPath`, two `theme.nim` rules. `pipeline.configureEditor` is now set **once**, in `gui.run`, and never re-aimed — **Q-30 is moot**. No `document.md` on disk was touched |
| **10c** | `nvimctl.editorEnv` builds the editor's environment; `vte.configure` takes it and the spawn passes it. **New self-test `nvim-env-selftest`** |
| **10a** | **New module `src/jenova/workspace.nim`** — the scoping ladder and the format, ported from `WorkspaceService.getWorkspaceContext` by reading it. `pipeline.chatBody` injects it; `gui.postConversation` supplies the scope. **New self-test `workspace-selftest`, 32 assertions** |
| **8b** | `api.restoreItem` re-indexes a restored message; `api.restoreEntity` and `api.deletedRows` added; a **trash panel** in the window over both. Three new assertions in `pipeline-selftest` |

### Three things worth carrying forward

1. **`editorEnv` returns the WHOLE environment, and that is not a detail.** VTE's `envv`
   *replaces* the child environment rather than extending it, so returning only the
   `JENOVA_*` keys spawns an editor with no `PATH` — which fails as "nvim: not found"
   and reads as a missing dependency rather than as the function's bug. Same class as the
   `detectGpu` `LD_LIBRARY_PATH` failure: an unreachable thing and an absent thing
   produce the same silence.
2. **`XDG_CONFIG_HOME` and `NVIM_APPNAME` are both needed, and it was verified rather
   than assumed** — `stdpath('config')` was read back under them. `NVIM_APPNAME` alone
   sends Neovim to `~/.config/jvim`, a symlink the user would have to make by hand, which
   is D-BC's defect.
3. **A self-test assertion that could not fail was written and caught.**
   `check("no key is duplicated", true)` is unconditionally true — the exact defect this
   project has shipped twice. It was replaced with an exact count derived from
   `envPairs()`, and a second assertion (`env.len > 8`) that also could not bite was
   replaced for the same reason.

---

## Ordering — set 2026-09-01 18:41

**Done: Step 11, 10c, 10a, 8b, and — 2026-09-02 — Step 7b (PDF), confirmed on screen.**
What remains, in order:

**Step 8 is complete.** 8b, 8a and 8c are all built; **G-17 is closed** (11:53) and 8c-1
and 8c-2, the two correctness defects found inside it, were confirmed on screen at 11:43.

**Step 9 is complete too, and so is G-42** (2026-09-02 12:19). **Every numbered step in
this plan is now built.**

**What remains is one undiagnosed defect and three things nobody has scheduled:**

- **G-47** — the editor page's Neovim truncated at the bottom on a resize. **Still not
  diagnosed**, and looked at properly on 2026-09-02 rather than guessed at: two candidates
  are recorded in `TODOS.md` and neither can be settled without the running widget, because
  VTE's size allocation is in `libvte` and not in this tree.
- **LaTeX maths**, the open half of G-34. KaTeX has no GTK equivalent; it is its own
  project.
- **Model information** — context size, quantisation, vocabulary, chat template. Needs
  `/props` plus a GGUF header read. Never built, and said so.
- **The three parked product decisions**, none on the critical path: the filesystem as the
  source of truth (T-11), deployment (T-7), a CLI (T-8).

**G-51 is a constraint to respect, not work:** nothing may be inserted before
`gui.fullscreenButton` in its row.

> **Superseded 2026-09-02 12:19.** This ordering block ended here with "the two open
> defects, then Step 9's four stability items". **G-42 and all four of Step 9 are built**;
> **G-47 alone survives** and is undiagnosed. The current list is at the top of this
> section.

## Step 9 — **BUILT 2026-09-02 12:19.** Stability

Done and out of this plan. All four in the planned order, plus **G-42** alongside them.
The record is `PROGRESS.md`.

| | What was built | What proves it |
|---|---|---|
| **T-5** | `gui.run`'s `defer` stops the embed backend after the joins. **Not `stopAll`** — the agent model stays loaded deliberately. **`lifecycle.stop` already cleared a dead pidfile**, so the second half of T-5 needed nothing new (rule 5) | `stop`'s own behaviour was already asserted. **The call site is not assertable** — `gui.nim` links into no test binary — and that is said rather than papered over |
| **T-2** | A cap in `db.nim` plus finalize-on-evict, **before** the new statement is prepared. **Flush-all, not LRU:** the real working set never reaches the cap, so the ordering bookkeeping would cost the hot path to bound something only `api.updateMessage`'s combinatorial SQL grows | `pipeline-selftest`: more than a cap of distinct statements leaves the cache bounded, **still caching**, and — the one that matters — **still able to answer a query**, which a dangling finalized handle would not |
| **T-4** | `fssync.resolveStoragePath` resolves the **deepest existing ancestor** against a **resolved** base. One change closes both holes: the unresolved tail cannot hide a symlink because it does not exist, and `..` was already refused lexically | **New `fs-selftest`, 10 assertions**, over a real tree with real symlinks: a symlinked *root* accepts its own paths (new and existing), and an escaping symlink refuses both an existing file and a **new** one |
| **T-3** | `pipeline.trimHistory`, called from `prepare` — **one call covers the window and the Web UI**, since the window posts to the same local :8080. Never the system message, never the final turn, **never shortened content** (D-BQ's rule) | `pipeline-selftest`: both sides of the budget, the two survivors asserted **separately from the count**, oldest-not-newest, an impossible budget still leaving a sendable request, and a zero budget trimming nothing |
| **G-42** | `ContentScroll` propagates natural width and aligns to the start. G-41 turned propagation off so a table could not widen the transcript, which left the scroller with no width of its own and `GTK_ALIGN_FILL` stretched it | Not assertable — widget behaviour (D-BR). **A USER run.** The enclosing `AutoScroll` does not propagate natural width either, so G-41's concern cannot return |

**The one thing to carry forward, because it is a limit rather than an achievement.** The
history budget converts `CTX_SIZE / NUM_SLOTS` at four bytes per token and halves it.
**That is an approximation and is written into the code as one.** An exact count needs the
model's own tokenizer — an HTTP round trip per turn on the hot path — and a rough bound
that always leaves headroom beats an exact one nobody can afford. The failure it prevents,
a conversation that grows until every request is refused, is not subtle.

### The plan that produced it, kept for the record

In this order, smallest first:

| | Work | Proof |
|---|---|---|
| **T-5** | Stop the embedding server on exit. **`gui.run`** starts both backends and its `defer` only sends the three workers the quit sentinel, joins them and closes the channels — **`lifecycle.stopAll`** (`lifecycle.nim:329`, verified 18:07) already exists and is reached only from the control worker's stop/restart jobs, never from exit. Leaving the *agent* model loaded is deliberate — reloading gigabytes into VRAM every start is worse — so stop only the embed backend, and clear a pidfile whose process is dead | `jenova-core backends status` after a GUI exit: agent up, embeddings down, no stale pid |
| **T-2** | Cap the database's prepared-statement cache. It is a plain `Table` that never evicts — `Conn.cache` (`db.nim:46`) filled by `db.prepared` (`db.nim:165-174`) — and the only `sqlite3_finalize` is the shutdown loop in `db.closeConn` (`db.nim:415-419`), while `api.updateMessage` builds a different SQL string per field combination. **The fix belongs in `db.nim`** — a cap plus finalize-on-evict — not in the caller | A suite issuing many distinct field combinations, asserting the cache stays capped. Prove it can go red first |
| **T-4** | Both directions of the file-containment check, both inside `fssync.resolveStoragePath` (`fssync.nim:694`). The symlink check runs only on paths that already exist (`fssync.nim:713`), so a *new* file written through a symlinked parent escapes; and the base is compared lexically (`fssync.nim:700`), so a symlinked workspaces root rejects legitimate paths. Resolve the deepest existing ancestor and compare against a resolved base | `test_api_fs.sh`: a write through a symlinked parent is refused **403**; a legitimate write under a symlinked root succeeds |
| **T-3** | Trim chat history. The whole conversation is resent every turn — `pipeline.prepare` (`pipeline.nim:223`) has no trim step and neither does anything else in the file — so a long chat eventually exceeds the context. Needs a byte budget from `CTX_SIZE`, dropping oldest first, never dropping the system message | A unit check on the trim function at a small budget — not a live generation |

---

## Waiting on a decision from the USER

**Nothing in Steps 1-9 is blocked.** Q-31 and Q-32 were answered on 2026-09-01 (D-BD,
D-BC) and became Steps 4 and 6.

Three product decisions remain parked, none of them on the critical path:

- **Filesystem as the source of truth** (`TODOS.md` T-11, D-AQ). The expensive half
  already exists. Must not be entangled with the GUI work above.
- **How the binaries get installed** (T-7).
- **A CLI** (T-8), gated by D-AI.

---

## Standing rules for whoever picks this up

- **If it was not executed, it is not stated — and if it was executed, do not deny it.**
  A "not yet run" label lasts until the first evidence against it. Carrying one past
  that point has cost two sessions.
- **Explain, then cite.** Never hand over a plan whose steps are bare IDs (**D-BA**).
- **Everything is driven from the GUI** (**D-BC**). A feature that needs a terminal, a
  shell script or a hand-edited file is not finished.
- **The archived shell/Lua build is not work.** Delete the reference or port it to Nim
  (**D-AZ**). Do not put "archive or port?" to the USER — both sit inside the standing
  ruling and the choice is the session's.
- **Check whether it already exists before writing it.** `std/json`, `upstream.nim`,
  `paths.nim`, and — repeatedly — an API route that is already implemented and tested.
- **Verify a scope against the source, not a summary.** The old six-item parity list is
  why this plan had to be rewritten.
- **A compile is not verification for layout** (**D-AR**). `nimble gui` exiting 0 says
  the widget tree is valid, never that it is right.
- **A new suite must be proven able to fail** before it is believed.
- **Sizing APIs are minimums.** `min-width`, `sizeRequest` and a flap's `width` each set
  a floor. To make something small, make the thing itself small.
- **`Box`'s adder defaults to `expand: true`**, and in a vertical Box that is `vexpand`.
  Annotate every child.
