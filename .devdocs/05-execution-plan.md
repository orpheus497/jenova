# Report 05 — Execution Plan

**Status:** the plan the other four reports feed. Sequential, one phase per session.
**Rulings in force:** `jca_web` is **frozen**. Push/Pull is **out of scope for the GUI**.
**MCP and TTS are deferred.**
**Baseline:** branch `claude/gui-webui-parity-audit-avmj8w` against `main` at `c5111ce`.

---

## 0. Where the work actually stands

Four sessions of audit and repair have closed every **high**-severity finding in reports 01 and
03 and roughly a third of report 02. What remains is not cleanup — it is the parity work itself,
which was never started, plus one structural repair that gates a third of it.

| Report | Findings | Closed | Open | Parked by ruling |
|---|---|---|---|---|
| 01 — documentation | 25 | 22 | 2 (A-2, A-3 · both blocked on a screenshot; D-15) | 1 |
| 02 — parity | 27 | 6 | 17 | 4 |
| 03 — error/memory/wiring | 21 | 17 | 0 | 4 |
| 04 — comment standard | 6 classes | 18 files of 37 (batches 1–2) | 19 files | — |

**Verification standing:** 17 self-tests, `tests/test_lifecycle.sh`, and a `gui.nim` differential
type-check all pass. `nimble suites` runs the 17 plus `serve`. Nothing in this branch has been
built on FreeBSD or run against a GPU.

---

## 1. The single fact that shapes everything below

**`gui.nim` cannot be type-checked in any environment available so far.** It imports owlkettle,
which needs GTK4 and libadwaita, which need FreeBSD. Every other module — 30 of 35 — type-checks
against a scratch tree with the FreeBSD guards neutralised, and `jenova-core` builds and runs its
whole suite. `gui.nim` gets a differential check against empty owlkettle stubs: identical error
signatures at HEAD and in the tree means no *new* error, and a clean parse to EOF catches syntax.
That is real, and it is not a type check.

Every phase below is ordered by that constraint. Work that can be proven off-GUI comes first;
work that only a FreeBSD build can prove is grouped so one build session validates all of it.

**Phase 1 exists to remove this constraint.** Until it lands, GUI work is written blind.

---

## Phase 1 — Establish a FreeBSD build (1 session)

**Nothing else in this plan is fully verifiable until this is done.** Twenty commits of GUI
changes are currently defended by a differential parse, and the parity work ahead is almost
entirely `gui.nim`.

| Step | Detail |
|---|---|
| 1.1 | Build both binaries on the target FreeBSD host: `nimble core`, `nimble gui`, `nimble suites` |
| 1.2 | Fix whatever the real compiler rejects in this branch's `gui.nim` edits — the `appInt` call, `attachPastedText`, `forkFrom`, `clearRenderMemos`, the `runCapture` timeout, the `umLanAddr` drain branch |
| 1.3 | Run the window. Exercise: long paste → attachment; fork from a message; conversation switch (memo clearing); LAN toggle; backend start/stop/restart |
| 1.4 | **A-2** — capture a GUI screenshot into `png/`, then **A-3**: reorder the README so the window leads and the Web UI is shown as the secondary surface |
| 1.5 | Record in report 03 what the first real build changed, so the differential harness's blind spots are known rather than assumed |

**Exit:** `nimble suites` green on FreeBSD, the window runs, `png/` has a desktop screenshot,
README leads with it.

**Risk:** `--mm:arc` on the GUI and the `Button.shortcut` hazard are both documented but only
ever exercised on the author's machine. This session may surface latent breakage from earlier
work, not just this branch's.

---

## Phase 2 — The shortcut mechanism, then keyboard parity (1 session)

**P-B12 is gated, and the gate is structural.** `owlkettle`'s `Button.shortcut` builds a
`GtkShortcutController` once and its update hook asserts the value never changed
(`gui.nim:3336-3340`). Two crashes have already come from changing the child count of a container
holding the one shortcut-carrying button. The window has **exactly one** shortcut today: F11.

| Step | Detail |
|---|---|
| 2.1 | Replace `Button.shortcut` with a **window-level `GtkShortcutController`**, so shortcuts are owned by the window and not by whichever button happens to hold one |
| 2.2 | Delete the child-count hazard notes that the new mechanism makes obsolete — and only those |
| 2.3 | Add the Web UI's bindings: new chat, focus composer, toggle sidebar, search, settings, stop generation |
| 2.4 | **P-E1** becomes cheap once 2.1 lands: a command palette over conversations, notes, files, settings and backend actions. This is the first "beyond parity" feature and it is unlocked by the same work |

**Why second:** it removes a hazard that constrains every later GUI change, and it converts the
single largest structural blocker into the foundation for the strongest beyond-parity feature.

**Exit:** shortcuts are window-owned, six bindings work, the container hazard is gone.

---

## Phase 3 — Retrieval and pipeline made visible (1 session)

**The cheapest high-value work left, and no other surface can do it.** `pipeline.Prepared` already
carries the intent, RAG hit count, web hit count, editor-document flag and trimmed-turn count;
`rag.query` already returns paths and scores. Both were being discarded until this branch put the
diagnostics on response headers. The data exists; only the panel is missing.

| Step | Detail |
|---|---|
| 3.1 | **P-E5** — pipeline inspector: what the model was actually sent. The rewritten body, the intent, how many turns were trimmed to fit |
| 3.2 | **P-E4** — retrieval inspector: which chunks the last turn retrieved, with scores and source paths |
| 3.3 | **P-B2** — replace the status subtitle with real processing state, fed by the same channel |
| 3.4 | **P-B1** — error dialog carrying the server's own detail instead of one truncated notice line |

**Why third:** it is off-critical-path for parity but it is the highest ratio of user value to
risk in the whole plan, it touches no widget-tree invariants, and 3.3/3.4 close two Class B gaps
as a side effect of building the channel.

**Exit:** a user can see what the model was sent and what retrieval found. Two Class B gaps close.

---

## Phase 4 — File assets and rendering (1–2 sessions)

The GUI writes `fileAssets` rows it cannot then read — the most visible incoherence left.

| Step | ID | Detail |
|---|---|---|
| 4.1 | **P-A8** | Open, preview and export a file asset. The window creates these rows on every attachment and offers no way back to them |
| 4.2 | **P-B5** | Attachment "view all" surface |
| 4.3 | **P-B4** | Per-code-block copy button and preview dialog |
| 4.4 | **P-A5** | Math rendering — the last remaining gap in the markdown path, and the only one not closed in session 2 |
| 4.5 | **P-A7 / P-C1** | PDF viewing, which also unblocks `pdfAsImage` — the one setting still honestly marked pending because it needs a rasteriser |

**Split point:** 4.1–4.3 are one session; 4.4–4.5 are the second if the rasteriser proves
non-trivial. **P-A5 needs a decision**: KaTeX is a browser library with no GTK equivalent. The
options are a Pango-drawn subset (limited, native, no dependency), shelling out to a TeX
renderer (heavy, correct), or declaring math out of scope for the window. **Decide before
starting 4.4.**

**Exit:** attachments are a two-way surface; the markdown path is complete or math is formally
scoped out.

---

## Phase 5 — Remaining Class B parity (1 session)

The long tail. Each is small; together they are the difference between "mostly there" and 1:1.

P-B6 (dedicated Files/Trash pages vs overlay panels · M) · P-B7 (model information detail) ·
P-B8 (favourite models) · P-B9 (show system message in transcript) · P-B10 (`useThinking`
toggle) · P-B11 (selective export) · **P-A3** (audio capture — `pipeline.contentFor` already
emits `input_audio` parts, so the wire format is done and only the recorder is missing; this
also unblocks `autoMicOnEmpty`, the last pending setting).

**Exit:** Class B is empty. The GUI is at 1:1 with the Web UI on everything not parked by ruling.

---

## Phase 6 — The comment standard (2–4 sessions)

Report 04's own plan, unchanged, executed in its own batches. **It must come last among code
work**: it touches 37 files and would collide with every phase above.

**Batches 1 and 2 are already done** — 18 files, 8033bdd and 63a7440, −793 lines of comment
against +511. That is report 04's own recommended stopping point, so **batch 3 should not start
until you have reviewed the shape those two produced.** If it is not what you meant, 18 files is
cheap to redo; 37 is not.

`gui.nim` is batch 8, alone, last, and only after Phase 1 gives it a compiler.

Target: 7,106 comment lines → ~1,850; top-level routine coverage 54% → 100%.

**Batch 0 is not optional and should happen at the start of Phase 1, not Phase 6**: write the
standard into `CLAUDE.md` so every phase above is written to it rather than retrofitted.

---

## Phase 7 — Deferred, pending your ruling

Not scheduled. Listed so the parking is deliberate rather than forgotten.

| ID | Item | Note |
|---|---|---|
| P-A1 | MCP client | Parked. If revisited, the finding in P-C2 argues for a **server-side** client: `/cors-proxy` is called by the frozen Web UI and not served, which silently disables remote MCP servers there |
| P-A2 | Agentic tool loop | Downstream of P-A1. `toolCalls` (W-04) is written by one surface and read by neither until this exists |
| P-A4 | Speech synthesis | Parked |
| P-C3 / W-05 | Push/Pull | Out of scope by ruling. Vestigial and can move data backwards; the honest end state is removal, which requires a Web-side change and `jca_web` is frozen |
| P-E2, P-E3, P-E6, P-E7, P-E8 | Beyond-parity proposals | Unscheduled; P-E1 is absorbed into Phase 2 |

---

## Open decisions

Three, and only the first blocks a phase.

1. **Math rendering (P-A5)** — Pango subset, external TeX renderer, or out of scope. Blocks 4.4.
2. **D-15** — `etc/jenova.conf` sets `JENOVA_DRAFT=0` while its source profile and the README say
   the drafter is on. Drift from commit `7b859f5` updating the profile without re-applying it.
   **Not changed here on purpose**: it alters inference behaviour and the correct fix is
   `hardware apply`, not a hand-edit — which is exactly what `eee557e` reverted once already.
3. **Where the comment standard lives** — `CLAUDE.md`, `docs/`, or `.devdocs/`. It has to be
   somewhere a future session reads by default, or it will not survive.

---

## Sequencing rationale

| Phase | Why here |
|---|---|
| 1 | Everything after it is written blind otherwise |
| 2 | Removes the structural hazard that constrains every later GUI change |
| 3 | Highest value-to-risk; the data already exists and is thrown away |
| 4 | The largest coherence gap — rows written and never read |
| 5 | The long tail, cheap individually, only meaningful in bulk |
| 6 | Touches every file; must not collide with 1–5 |
| 7 | Awaiting rulings |

Phases 1 and 2 are strictly ordered. Phases 3, 4 and 5 can be reordered freely. Phase 6 is last.
