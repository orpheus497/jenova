# PROGRESS

Milestone ledger. One line per completed, superseded or removed feature or bug.
Newest first.

- 2026-09-30T04:36Z — Built for Linux with the nimble tasks: `nimble llama` (the static `llama-server` now in `external/ext_bin/bin/`), `core`, `gui`, `web`; `nimble suites` passes end to end. Deployed to `~/Jenova` (profile `Vulkan/dgpu-igpu-i5-1135g7`, models in `models/instruct/` and `models/thinking/`, nomic embeddings) and tested headless and through the desktop window: chat, embeddings, retrieval, Web UI serving and every CLI verb work.

- 2026-09-30T04:36Z — Thinking setting: `JENOVA_REASONING` → `--reasoning`, defaulting to off for a model in `models/instruct/` (`models.roleOf`); fixes replies that arrived only as reasoning. `JENOVA_MLOCK`/`JENOVA_MMAP` now become llama.cpp's `-lm`, which replaced the refused `--mlock`/`--no-mmap`; the device probe skips a draft device that will not be used.

- 2026-09-30T04:36Z — `.gitignore`: crash-dump rule narrowed to `core.[0-9]*`, so nvim-cmp's `core.lua` is tracked; stale header and labels removed; `jvim/.gitignore`'s rules folded in. `jvim/` repository leftovers removed (`LICENSE`, `.gitattributes`, `.gitignore`, `nvim.log`); its configuration kept whole.

- 2026-09-30T04:36Z — `jca_web/README.md` and `jvim/README.md` corrected against the code (report 01 B48–B56); `docs/privacy.md`'s unused pid file and the confs' unread watchdog knob and `D-AI` label corrected.

- 2026-09-30T03:15Z — Stage 2, OS detection when running: `hardware.nim` names the OS the binary was built for and reads Linux's `/proc` and `/sys` beside FreeBSD's `sysctl` probes; every profile matches `FreeBSD|Linux`; GPUs are named in `DEVICES`/`DRAFT_DEVICE` and resolved against `llama-server --list-devices` before the start lock, so the i5-1135G7 profiles pick the GTX 1650 Ti on both OSes; `CPU/generic` uses `none`, which llama-server accepts where it refused `CPU`; `dgpu-generic-12gb` matches `Arc(tm) A770`; the window's LAN address comes from the kernel with no subprocess. `hardware-selftest` 24 assertions, one new in `lifecycle-selftest`.

- 2026-09-30T03:15Z — Stage 1, build on FreeBSD and Linux: `vte.nim` binds GDK's `GdkRGBA`, so the window builds under gcc 16.2 and clang 22.1; a missing library names the FreeBSD port or the `pacman -F` / `dnf provides` / `apt-file search` that finds it; `nimble llama` builds one static `llama-server` (no web-UI download, no tests, bounded jobs, `JENOVA_BACKEND=vulkan|cuda|cpu`) and copies it with its execute bit; the window clears the desktop's legacy dark-theme setting before `adw_init`, ending libadwaita's warning; "make llama", "or use FreeBSD", the header's `--version` claim and the nimble description corrected, and `help` lists `models`. All 22 self-tests, the six suites and both GUI harnesses pass on Arch.

- 2026-09-30T03:15Z — Product docs brought to the Stage 1 and 2 code: `README.md`, `docs/install.md`, `docs/architecture.md`, `hardware-profiles/README.md`.

- 2026-09-30T02:07Z — Product docs corrected against the code: `README.md`, `docs/architecture.md`, `docs/context-and-retrieval.md`, `docs/install.md` (FreeBSD, Arch and Debian/Fedora sections), `docs/privacy.md`, `docs/usage.md`, `hardware-profiles/README.md`; FreeBSD and Linux presented as supported targets, with the FreeBSD-only paths stated. `jca_web/README.md` and `jvim/README.md` remain.

- 2026-09-30T02:07Z — Devdocs reconciled with the code: every claim a code verification flagged in reports 01–08 and the trackers re-read in the code and corrected in place; comment census re-measured at 91 comment lines in nine files, correcting the lead's own 87-in-seven; four defects and eight wrong comments found in passing, added to `PLANS.md`.

- 2026-09-29T23:30Z — `AGENTS.md` rules 2 and 4 amended at the USER's approval: copyleft licences allowed (AGPL-3.0-or-later project); product code under `src/` and `jca_web/`, build output git-ignored, the installed application outside the repository in `$JCA_HOME`.

- 2026-09-29T23:06Z — `PLANS.md` of 22:35Z superseded: rebuilt on the pre-rewrite deployment design (read from git history and checked against `paths.nim`, `config.nim` and `hardware.nim`), implementation first with tests and CI last, findings tagged by evidence, fifteen plain decisions.

- 2026-09-29T22:39Z — Devdocs congruence: all eighteen `.devdocs/` files audited against the code at `4acedfa0`, the product docs and git history, and corrected; sessions 8 and 9 of 2026-09-10 reconstructed from git; `PLANS.md` holds the plan of record (Stages 0–9) and supersedes report 05; `TODOS.md` rebuilt in `AGENTS.md`'s Backlog-then-Active shape.

- 2026-09-29T22:09Z — Arch Linux validation: `jenova-core` builds; all 22 self-tests and the six shell suites pass; the GUI fails under gcc 16.2.1 and clang 22.1.8 only at `vte.nim`'s `GdkRGBA`, and with that error downgraded builds and passes `--check`; `gui_check.sh` passes; llama.cpp `a6ea155d3` builds with Vulkan and runs relocated with `$ORIGIN`; Linux enumerates the two GPUs in the reverse of the order the i5-1135G7 profiles encode in `DEVICES`/`DRAFT_DEVICE` (that the order is FreeBSD's is stated only in comments, never measured); `hardware detect` is FreeBSD-only.

- 2026-09-10T03:15Z — Display maths draws the font's own size variant instead of a vertically scaled base character: `mathtex.MathVariant` and `MathBox` carry the face's glyph index, `mathfont` fills it from HarfBuzz, and `gui` opens the measured font file as a Cairo face through FreeType and draws by index, falling back to the text path wherever the face cannot be opened. FreeType flags come through `pkgconfig`. Gated by 3 new math-selftest assertions on the index carry, and proved against `DejaVu Math TeX Gyre` on an image surface: the chosen variant draws at 2.88x the base parenthesis height. [2026-09-29T22:31Z: corrected — stamped 2026-09-10T03:18Z when written, later than the commit that carries this line (`3a02d715`, 2026-09-10T03:15Z, reflog-only; in `4acedfa0`).]

- 2026-09-10T02:59Z — Full suite run on this host: twenty-two self-tests, the six shell suites and `gui_check.sh` all pass. Only the mapped-window tier remains unrun, for want of `Xvfb`, `xdotool` and `xclip`. [2026-09-29T22:31Z: "this host" was the FreeBSD 15.1 host; the workspace is now bare-metal Arch Linux.]

- 2026-09-10T02:59Z — Review round on PR #118 answered: empty display-math fences kept as text in markdown, glyph resolution separated from advance width in mathfont so a zero-advance combining mark is not padded, workspace context stops reading bodies once the budget is spent, and chunked and unsupported-transfer-encoding refusals drain the peer under a byte cap, a total deadline and a quiet-peer stop before answering. Gated by 3 new markdown assertions and a live 413-under-send check; full self-test set, six shell suites, `serve-selftest` and `gui_check` green. [2026-09-29T22:31Z: the 413 check is in no suite — no committed assertion covers `drainBody` or the transfer-coding refusal.]

- 2026-09-10T02:41Z — Message role for chat indexing resolved from the merged row rather than the posted node, so a partial assistant edit re-indexes; maths font resolved once at startup instead of on the render path, with the unavailability reason rendered beside the formula rather than written to the notice line from `view`; `transfer-encoding` parsed as coding tokens with only `chunked` accepted.

- 2026-09-10T01:12Z — Display maths laid out once per formula and memoised (`mathLayoutFor`, 64 entries, emptied with the other render memos) instead of on every redraw; with no usable maths font a formula renders as source text rather than being drawn with the synthetic default font; `mathfont` reads a font's real OpenType MATH size variants — the total had been read from a zero-capacity in/out count, so every font fell to the synthetic stretch. No assertion added. (Reconstructed from git on 2026-09-29T22:31Z: `8a2a2e15`, reflog-only; in `4acedfa0`.)

- 2026-09-10T00:18Z — M-3: display math rendering pipeline implemented across markdown (bkMath delimiter parsing), mathfont (HarfBuzz font metrics and variant bridge), and gui (Cairo screen drawing and DrawingArea with styled fallback). Gated by 6 new markdown assertions, live font assembly assertions in math-selftest, and gui_check. [2026-09-29T22:31Z: corrected — the variant half of the bridge was inert until 2026-09-10T01:12Z.]

- 2026-09-09T23:22Z — Chunk parser hardening in http.nim: validated declared chunk size before body reads, subtracted dataEnd to avoid 64-bit overflow, and pruned consumed bytes from raw after each feed call. Gated by 4 new assertions in routes-selftest (36 total).
- 2026-09-09T23:13Z — Review fixes applied: AGENTS.md canonical UTC timestamp and approval text cleanup, rag.nim preloaded container scopes and vector scan reordering, gui.nim CRLF sanitization on scopeHeader, and http.nim incremental ChunkParser with decoded payload byte accounting. Gated by 4 new assertions in routes-selftest.
- 2026-09-09T22:59Z — D9: pure chunked request body parser implemented in http.nim with MaxBodyBytes cap and streaming socket reader in parseRequest. Gated by 9 new assertions in routes-selftest.
- 2026-09-09T22:57Z — D5: hierarchical retrieval scoping and X-Jenova-Scope wire contract implemented across rag, pipeline, server, and gui. Non-workspace isolation and down-tree folder/project/workspace ladder enforced. Gated by 16 new assertions in rag-selftest.
- 2026-09-09T22:50Z — D6: partial-node merge moved into api.upsert. HTTP POST /api/db/* updates omitting columns now preserve existing stored data (e.g. content), unifying in-process and HTTP update semantics. Gated by two new assertions in workspace-selftest.
- 2026-09-09T22:35Z — Architectural rulings established: D5 retrieval scoping hierarchy (non-workspace isolation down to folder scope), D6 partial-node merge in `upsert`, and V-17 strict ban on citations in code comments.
- 2026-09-09T22:23Z — `.devdocs/` audit and hygiene: corrected false claim that `relay-selftest` binds a listener (it asserts `spliceHeaders` on pure strings in memory), clarified Linux-container-on-FreeBSD environment context, confirmed `AGENTS.md` tracked and committed in `5606d418`, and cleared executed items from `PLANS.md`. [2026-09-29T22:31Z: corrected — the container description was false when written: the host was FreeBSD 15.1 with the agent under the Linuxulator, and is now bare-metal Arch Linux (see `DECISIONS_LOG.md`). `5606d418` is a reflog-only commit of the deleted branch `nimby`; `AGENTS.md` is on `main` since `4acedfa0`.]
- 2026-09-09T05:43Z — `AGENTS.md`'s budget rule states what it requires. The sentence ended
  in an elliptical "and has", which pointed at a measurement recorded elsewhere and named no
  rule; the budgets are now stated as a ceiling to cut to, binding in both directions.
- 2026-09-09T05:31Z — `.devdocs/BLUEPRINT.md`, `ARCHITECTURE_MAPPING.md` and `TESTS.md`
  created, completing the ten trackers the Workspace Architecture mandates. Written from
  the source traced this session, and deliberately carrying no line numbers or counts.
  [2026-09-29T22:31Z: corrected — read "eleven"; `AGENTS.md`'s tracker table has ten rows.]
- 2026-09-09T05:31Z — Phase 0.2 closed: the comment standard's budgets — 1–4 lines for a file
  header, 1 for a function, 1–3 for a block — plus the no-labels and no-history prohibitions
  are recorded in `AGENTS.md`, where a future session reads them.
- 2026-09-09T05:31Z — `rag.query` filters hits whose source row is flagged deleted. Every
  `forget*` call runs inside a guard that swallows failures by design, so a skipped unfile
  left deleted content answering queries with nothing anywhere to show it. Only an explicit
  `is_deleted` flag drops a hit; an absent row stays live, which is what keeps a synthetic or
  hard-removed path retrievable. Three assertions, one proven to fail with the filter disabled.
- 2026-09-09T05:14Z — `pipeline.prefixedTextPart` replaces `firstTextPart`: the strip edits the
  text part that actually carries the intent prefix, not the first one. `userText` joins every
  text part and `detectIntent` strips leading whitespace off the join, so an empty leading part
  left the marker in the second and sent it to the model. Four assertions, one proven to fail
  with the fix reverted.
- 2026-09-09T05:14Z — `AGENTS.md` documentation standard resolved to one scope and one format:
  new and touched code only, never retroactive, and the three prefixes required rather than
  optional. The two paragraphs previously contradicted each other on both axes.
- 2026-09-09T05:14Z — `AGENTS.md` Command Laws now require UTC timestamps carrying an explicit
  `Z`. The host is +1000, so every local stamp already written was ten hours ambiguous; the
  existing `.devdocs/` entries are converted.
- 2026-09-09T04:49Z — Report hygiene: V-15 closed in report 07, Phase 5.1 closed in report 05,
  the maths phase restated in reports 02 and 05 as unlinked rather than unpainted, report 04 §4.3
  retired with the OS guards it describes, and the census, widget-count, module-size and
  self-test-count figures re-derived across reports 02, 03, 04, 06 and 07.
- 2026-09-09T04:49Z — `AGENTS.md` restored to the repository root, byte-identical to the version
  deleted in `c5111ce3`.
- 2026-09-09T04:49Z — New `routes-selftest`: nineteen assertions over `routes.classify` and
  `pathFromHead`, registered in `jenova_core.nimble` and `usage()`. Closes the coverage gap that
  let `/v1/embeddings` reach the wrong backend — the property is decidable with no socket, and
  nothing decidable that way was checking it. Proven to fail with the fix reverted.
- 2026-09-09T04:33Z — `mathfont.chooseFont` walks each font root once and probes the
  collected basenames in preference order, replacing thirty recursive walks of the
  system font tree with one per root.
- 2026-09-09T04:33Z — `db.queryBlob` raises on a step error instead of breaking, so a
  failing database can no longer return a truncated vector scan as a complete one.
- 2026-09-09T04:33Z — `routes.classify` tests the embed prefixes before `/v1/`, so
  `/v1/embeddings` reaches the embedding backend rather than the chat backend.
- 2026-09-09T04:33Z — `workspace.contextFor` reads bodies one at a time for the rows the
  scoping kept, and bounds the assembled block at `MaxContextBytes`, naming what it
  omitted. Gated by five assertions in `workspace-selftest`.
- 2026-09-09T04:33Z — `pipeline.prepare` reads a turn's text through `userText`, so a turn
  carrying an attachment is enriched like any other; the prefix strip edits the first
  text part rather than replacing the content array. Gated by six assertions in
  `pipeline-selftest`, four proven to fail with the fix reverted.
- 2026-09-09T04:24Z — `.devdocs/` trackers created per the Workspace Architecture:
  `TODOS.md`, `PLANS.md`, `DECISIONS_LOG.md`, `PROGRESS.md`, `BRIEFING.md`,
  `SESSION_HANDOFF.md`, `SUMMARIES.md`.
