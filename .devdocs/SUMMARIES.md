# SUMMARIES

One paragraph per session, pointing at the matching `SESSION_HANDOFF.md` entry.
Newest first.

---

**2026-09-30T04:36Z (session 10, continued).** Built everything for Linux with the nimble tasks and
deployed to `~/Jenova` with the USER's models (Nemotron 4B in `models/instruct/`, Qwen3.5 9B in
`models/thinking/`, nomic embeddings); `nimble suites` passes, and chat, retrieval and the Web UI
work headless and through the window. Replies that arrived only as thinking were traced to the
Nemotron build and fixed with a new `JENOVA_REASONING` setting that defaults to off for instruct
models; the updated llama.cpp's `-lm` replaced refused flags. `.gitignore` stopped hiding nvim-cmp's
`core.lua`; `jvim/`'s repository leftovers were removed after a wrongful deletion of its config was
reversed. The deployment test's findings are in `PLANS.md` 4.6–4.11 and 5.7–5.16. See
`SESSION_HANDOFF.md` → *Linux build and deployment tested*.

**2026-09-30T03:15Z (session 10, continued).** Built the approved Stages 1 and 2. The window
compiles under gcc 16 and clang 22; a missing library says how to find its package on each OS;
`nimble llama` builds one static `llama-server` with no download; libadwaita's warning, which came
from KDE's settings, is gone; stale messages are fixed. Detection names the built-for OS and reads
Linux's `/proc` and `/sys`; profiles match both OSes and name their GPUs, resolved against
`--list-devices`; the LAN address needs no subprocess. `CPU/generic`'s `DEVICES=CPU` and the 12 GB
profile's A770 pattern were broken and are fixed. Four reviewers' findings were checked in the code
and acted on; all 22 self-tests, six suites and both GUI harnesses pass. A test harness edited
`gui.nim` through a scratch symlink; it was restored and disclosed. See `SESSION_HANDOFF.md` →
*Stages 1 and 2 built*.

**2026-09-30T02:07Z (session 10, continued).** Recorded the USER's 23:30Z answers and the approved
`AGENTS.md` amendment, then checked every flagged claim in the devdocs and the seven product docs
against the code — the lead reading the code behind each, taking no agent's correction as given — and
corrected them: reports 01–08 and the trackers; README, the five `docs/*.md` and
`hardware-profiles/README.md`, now presenting FreeBSD and Linux as supported. Corrected the lead's own
comment census (91 lines in nine files, not 87 in seven) and added four defects and eight wrong
comments found in passing to `PLANS.md`. No code or git change. See `SESSION_HANDOFF.md` → *every
devdoc and product doc checked against the code and corrected*.

**2026-09-29T23:06Z (session 10, continued).** The USER rejected the 22:35Z plan. The lead found the
installer the Nim rewrite deleted in `7b859f59`, read it and the Nim code it still fits, and rewrote
`PLANS.md` around restoring that deployment design: implementation first, tests and CI last, every
finding tagged by how it was established, fifteen plain decisions. Corrected three claims that had
rested on agent reports or comments. See `SESSION_HANDOFF.md` → *plan withdrawn and rebuilt on the
existing deployment design*.

**2026-09-29T22:39Z (session 10).** Validated on bare-metal Arch Linux: the core builds and all 22
self-tests and six shell suites pass; the GUI is blocked only by `vte.nim` under gcc 16 and clang 22;
llama.cpp builds with Vulkan and relocates with `$ORIGIN`; hardware detection is FreeBSD-only. Recorded
the USER's rulings — FreeBSD and Linux first-class, GPL allowed, no OS-specific build folders, the
deployed build outside the repository, separation of concerns — then audited all eighteen devdocs
against the code and git with eight parallel agents, corrected them, reconstructed sessions 8 and 9,
and wrote the plan of record into `PLANS.md`. See `SESSION_HANDOFF.md` → *Linux validation, devdocs
congruence audit, platform rulings, and the plan of record*.

**2026-09-10T03:15Z (session 9; reconstructed from git on 2026-09-29T22:31Z).** Answered the PR #118 review: an edited reply's indexing role comes from the merged row; the maths font resolves at startup and a missing font is explained beside the formula; oversize, malformed-chunked and non-`chunked` request bodies are drained under byte, deadline and quiet bounds before the refusal; empty display fences stay text; zero-advance combining marks are not padded; the workspace context stops reading bodies once its budget is spent; and display maths draws the font's own size variants by glyph index through FreeType. Suites green on the FreeBSD host; PR #118 squash-merged as `4acedfa0`. See `SESSION_HANDOFF.md` → *PR #118 review round: indexing role from the merged row, maths font at startup, drained body refusals, and variant glyphs drawn by index; PR #118 merged*.

**2026-09-10T01:12Z (session 8; reconstructed from git on 2026-09-29T22:31Z).** Memoised display-maths layout per formula, rendered formulas as source text when no maths font exists instead of drawing the synthetic default font, and fixed HarfBuzz size-variant retrieval, inert since session 7. No tracker was updated at the time. See `SESSION_HANDOFF.md` → *display-maths layout memo, source text when no maths font exists, and HarfBuzz size-variant retrieval*.

**2026-09-10T00:18Z (session 7).** Display maths (M-3) end to end: `bkMath` blocks for `$$...$$` and `\[...\]` fences in `markdown` (half-open streaming fences stay text), HarfBuzz metrics bridged into `mathtex.MathFont` by `mathfont`, and Cairo drawing in `gui` inside a scrollable `DrawingArea`, falling back to the literal LaTeX. Gated by six `markdown-selftest` and two live-font `math-selftest` assertions and `gui_check.sh`; both binaries built and the 21 socket-free self-tests passed. [2026-09-29T22:31Z: corrected — the size-variant query was inert until session 8; variants are drawn by glyph index since session 9.] See `SESSION_HANDOFF.md` → *M-3 display math rendering: markdown delimiter parsing, HarfBuzz font metrics bridge, and Cairo screen drawing*.

**2026-09-09T23:22Z (session 6).** Hardened the chunked-body parser in `http.nim`: a declared chunk size beyond the remaining body allowance is refused before its data arrives, the delimiter bounds test no longer risks integer overflow, and consumed bytes are pruned after each `feed` while unconsumed framing is kept. Four new `routes-selftest` assertions (36 in all); the 21 socket-free self-tests green. See `SESSION_HANDOFF.md` → *chunk parser hardening: early size validation, overflow protection, and buffer pruning*.

**2026-09-09T23:14Z (session 5).** Resolved seven review findings: `AGENTS.md` timestamps made canonical UTC with an explicit `Z` and its approval step made direct; `rag.query` preloads container scopes once per query and tests similarity before scope; CRLF stripped from the scope header in `gui` and in `rag.formatScope`; `http.nim` reads chunked bodies through an incremental `ChunkParser` that caps decoded payload bytes and bounds chunk headers. Four new `routes-selftest` assertions; the 21 socket-free self-tests green. See `SESSION_HANDOFF.md` → *review findings resolved: AGENTS.md governance, RAG scope preloading & vector scan order, GUI header sanitization, and streaming ChunkParser*.

**2026-09-09T23:00Z (session 4).** Built the three ruled items: D6 moved the partial-node merge into `api.upsert`, so HTTP updates preserve omitted columns (two `workspace-selftest` assertions); D5 scoped retrieval down the container tree, carried by `X-Jenova-Scope` from the GUI through `http`, `server` and `pipeline` (16 `rag-selftest` assertions); D9 added a pure chunked-body parser under `MaxBodyBytes` and streamed chunked bodies from the socket (nine `routes-selftest` assertions). The 21 socket-free self-tests pass. See `SESSION_HANDOFF.md` → *executed D6 partial-node merge, D5 retrieval scoping hierarchy, and D9 chunked request body parsing*.

**2026-09-09T22:35Z (session 3).** Architectural rulings confirmed and documented across the devdocs corpus: D5 established the authoritative RAG retrieval scoping hierarchy (strict down-tree container scoping, with non-workspace chats and unfiled artifacts strictly isolated from workspace folders), D6 resolved to merge omitted row fields inside `api.upsert` to protect existing data from blanking, and V-17 banned all citation and tracking labels inside source code comments. See `SESSION_HANDOFF.md` → *architectural rulings confirmed: D5 retrieval scoping hierarchy, D6 partial-node merge, V-17 citation policy*.

**2026-09-09T22:23Z (session 2).** Audited `.devdocs/` against the Nim source rather than its comments and corrected the trackers: `relay-selftest` tests `upstream.spliceHeaders` in memory and binds nothing, so 21 of the 22 self-tests bind no listener; `AGENTS.md` was confirmed committed (on `nimby` in `5606d418`, reflog-only; on `main` since `4acedfa0`); executed plans D1, D2/D3, D4, D7 and D8 were cleared from `PLANS.md`; M-3 and the chunked decoder were confirmed missing. It also recorded the workspace as a Linux container inside a FreeBSD system. [2026-09-29T22:31Z: corrected — that description was false when written: the host was FreeBSD 15.1 with the agent under the Linuxulator, and the workspace is now bare-metal Arch Linux. The cleared plans read "D1–D8", but D5 and D6 had not yet been built.] See `SESSION_HANDOFF.md` → *devdocs audit against active code and correction of false claims*.

**2026-09-09T05:48Z (session 1).** Audited the request path against the eight `.devdocs`
reports by reading `src/` rather than searching it, after a first pass that did the latter.
Nine defects no report records were found, the largest being that any turn carrying an
attachment bypassed the whole pipeline — no persona, no retrieval, no intent detection —
because `prepare` read an OpenAI content array with `getStr`. Six were repaired in five
changes, two held for a ruling on contracts they would change, and one backlogged.
[2026-09-29T22:31Z: corrected — this read "five repaired, two held, two backlogged", which the
handoff's own list of nine does not support.] Eight report claims were found false, including
that the maths engine was not linked into the window at all — three documents had called it
merely unpainted — and that the FreeBSD build guards the reports work around no longer exist.
The "blocked on a FreeBSD host" framing was retired, this workspace then being that host
[2026-09-29T22:31Z: it has since moved to bare-metal Arch Linux]. The same session restored
`AGENTS.md` on instruction, added the socket-free `routes-selftest` that closed the gap the
routing defect lived in, applied the report-hygiene corrections, made retrieval drop hits whose
row is flagged deleted, created `BLUEPRINT.md`, `ARCHITECTURE_MAPPING.md` and `TESTS.md`, and
recorded the UTC timestamp rule and the comment standard in `AGENTS.md`. See
`SESSION_HANDOFF.md` → *source audit against the eight reports, and five repairs*.
