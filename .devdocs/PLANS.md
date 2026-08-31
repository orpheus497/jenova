# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-08-31 19:02

---

## Where the program is

A native FreeBSD desktop application in Nim. `llama-server` is the engine; this is the harness.
`bin/jenova` is the app, `bin/jenova-core` the headless server. Build with `nimble`. Architecture
is `BLUEPRINT.md` (rewritten 2026-08-31; the pre-rewrite audit record is archived).

**Done:** config, database, threaded HTTP server, the `/api/*` surface, filesystem mirror, RAG, the
completion pipeline, backend lifecycle and watchdog, model discovery and switching, the GTK4 window,
the StatusNotifierItem tray, conversation persistence. No Lua, no C, no shell scripts.

**Verified 2026-08-31 (Session 007) by reading every file the trackers name:** T-1 … T-10 are the
complete and accurate outstanding set. **No new defect was found.** Cross-referencing the trackers
against the tree produced corrections to three *documents* and none to the code inventory — which
is the first time that has been true, and it is the point of the exercise.

---

## The live workstream — GUI parity (D-AP)

**This is what is actually being built.** The USER's direction, 2026-08-31: the GUI becomes the
product; `jca_web` becomes the ephemeral single-device LAN client. **This closed T-6**, and it
re-ordered everything below — the four stages that follow are still correct, but stage 1 is no
longer the front of the queue.

| | State |
|---|---|
| G-1/G-2 theme + canvas | **Done, run, confirmed** |
| G-3 side panel, G-3b rename/delete | **Done** |
| G-4 workspace tree | **Run. Functional, unstyled** (G-9). Notes and fileAssets still missing — they need an editor view |
| G-5 markdown + code blocks | **Run. Text renders; code blocks collapse** (G-11). No syntax highlighting (G-7) |
| G-6 remaining surface | Unscoped: notes/files/trash views, models selector, settings, attachments, MCP |
| G-7 syntax highlighting | `gtksourceview5` FFI |
| ~~G-8 … G-11~~ | **CLOSED 18:55 — fixed and confirmed on screen.** Panel slab, unstyled tree, one-word wordmark, collapsing code blocks. Record in `PROGRESS.md` 18:42/18:55 |
| **G-12, G-13a** | **In-app Quit and a way out of fullscreen. Compiled 19:02, unrun** |
| **G-13b** | **Fullscreen does not fill; glitches or freezes. OPEN, no mechanism** — three hypotheses checked and disproven. Next step is a terminal capture from a fullscreen run, not a patch |

**How this work goes wrong, and the rule that came out of it (D-AR).** Four consecutive rounds
shipped a broken window because a scripted bulk edit was followed by `nimble gui` and nothing else.
**A compile proves the tree is valid, never that it is right.** Layout changes are rewritten as a
block through the harness's edit tooling, read back, and the widget tree shown before building.
Sizing APIs (`min-width`, `sizeRequest`, flap `width`) are **minimums** — check the semantics before
reaching for one.

**LAN gets no further investment.** Built, works, retained under Directive 3.

---

## The standing plan

Four stages. **They are ordered by dependency, not by preference**, and stages 2–4 each open with a
decision that is the USER's to make. A session does not start stage 2 by choosing for them.

### Stage 1 — Make it stable *(actionable now; no decision required)*

`TODOS.md` **T-2 … T-5**. A session can execute all of it unaided. **Nothing blocks it** — T-1 was
corrected on 2026-08-31 and is an unexplained core, not a gate.

| Step | Item | Shape of the work | Proof it worked |
|---|---|---|---|
| **1.1** | **T-1 — one unexplained core.** *Not a blocker* | **No work to do.** If the program dies again, capture the core **on the FreeBSD host** and read the signal before writing a cause down. The previous entry's cause was narrative with no artifact behind it | A signal, from a real core, read on the host |
| **1.2** | **T-5 — backends survive exit** | `gui.run`'s `defer` joins the worker threads and stops nothing. Leaving the *agent* loaded is deliberate — reloading multiple gigabytes into VRAM on every restart is worse — but the **embedding** server is left with nothing attached, and a backend that dies during start leaves its pidfile behind. Fix: stop the embed backend on exit; clear a pidfile whose process is not alive | `jenova-core backends status` after a GUI exit reports the agent up, embeddings down, and no stale pid |
| **1.3** | **T-2 — unbounded statement cache** | `db.nim`'s cache is a plain `Table` and finalizes only at connection close, while `api.nim`'s message update builds its `SET` clause from whichever fields the client sends. Distinct SQL accumulates without bound. **The fix belongs in `db.nim` — a cap plus finalize-on-evict — not in `api.nim`**; constraining the caller leaves the cache still unbounded for the next caller | A new suite that issues many distinct field combinations and asserts the cache stays capped. **It must be proven able to fail** before it is believed |
| **1.4** | **T-4 — `resolveStoragePath` containment** | Two directions, one fix. The symlink check is gated on `fileExists or dirExists`, so a **new** file written through a symlinked parent escapes the root; and `normBase` is lexical, so a symlinked `$JENOVA_WORKSPACES` makes the check reject **legitimate** paths. Resolve the deepest existing ancestor and compare against a resolved base | Extend `test_api_fs.sh`: a write through a symlinked parent is refused **403**, and a legitimate write under a symlinked root succeeds |
| **1.5** | **T-3 — chat history is never trimmed** | The whole conversation is resent every turn. Needs a byte budget derived from `CTX_SIZE`, dropping oldest-first and never dropping the system message | A unit check on the trim function at a small budget; not a live generation |

**Sequencing note.** 1.2–1.5 are independent of each other and of 1.1, and all four are queued
behind the GUI parity workstream above.

### Stage 2 — The workspace question — **ANSWERED, and now the live workstream**

`TODOS.md` T-6 is closed by **D-AP**: option A (build it natively) **plus** a retained option C
(`jca_web` survives as the LAN client). Not a decision any longer — it is the GUI parity work
above.

### Stage 3 — Deployment *(USER decision, then work)*

`TODOS.md` **T-7**. The product is two Nim binaries plus `etc/`, `public/`, `png/` and
`hardware-profiles/`. **How they get installed is one decision, taken once.**

**The shell installer is archived and is not the answer** (D-AH, D-AM) — it has been raised as
outstanding work three separate times and it is not. The realistic candidates are a FreeBSD port /
package, or `nimble install` plus a documented data-directory layout. Service integration (`rc.d`,
`rcvar`, `sysrc jenova_enable=YES`) was cancelled at D-H **specifically so it could be written once
against the Nim program** — it belongs in this stage, not before it.

### Stage 4 — The CLI *(after stages 2 and 3)*

`TODOS.md` **T-8**, gated by **D-AI**. `jenova-core` already has an operational subcommand surface;
`jenova-cli` is a distinct, user-facing tool and it is explicitly the last thing built.

### Independent of all four — profile data hygiene

`TODOS.md` **T-9** and **T-10**. Neither blocks anything and neither is on the critical path.

- **T-9:** `hardware-profiles/CPU/generic/jenova-setup` is entirely Linux (`cpupower`, `/sys`,
  `numactl`) and is the only CPU-only profile — so a FreeBSD host with no working Vulkan ICD lands
  on tuning that does nothing. Rewrite on FreeBSD sysctls or delete the script and let the profile
  be data-only, as the two generic fallbacks already are (Q-11).
- **T-10:** each `profile.conf`'s tuning `PROFILE_*` block contradicts the `jenova.conf` beside it
  (for `Vulkan/dgpu-i5-1135g7`: FIT 256 vs 128, CTX 8192 vs 16384, NGL 16 vs `all`, DRAFT 0 vs 1).
  Nothing reads those tuning values. Sync or delete them.

---

## Standing rules for whoever picks this up

From `BRIEFING.md`, and both were paid for:

- **If it was not executed, it is not stated.** A defect list written from reading unrun code is
  speculation with line numbers; it generates a plan, devdoc edits and a correction pass. "I don't
  know" is the correct answer for anything unrun.
- **Check whether it already exists before writing it.** `std/json`, `upstream.nim`, `paths.nim`.
- **Do not re-raise what is settled.** `DECISIONS_LOG.md`'s SETTLED FACTS table first: the engine,
  the devices, the startup model, `~/JCA`, the licence, the build system, the shell tree.
- **Adding a suite includes proving it can go red.** This project has twice shipped a suite that
  reported PASS while asserting nothing.
