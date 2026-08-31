# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-08-31 15:49

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

## The plan

Four stages. **They are ordered by dependency, not by preference**, and stages 2–4 each open with a
decision that is the USER's to make. A session does not start stage 2 by choosing for them.

### Stage 1 — Make it stable *(actionable now; no decision required)*

`TODOS.md` **T-1 … T-5**. This is the only stage a session can execute unaided, and T-1 gates it.

| Step | Item | Shape of the work | Proof it worked |
|---|---|---|---|
| **1.1** | **T-1 — the redraw SIGBUS.** **BLOCKER** | **Already built. The work is to run it.** `view` no longer has conditionally-present siblings: the empty-state Label and the notice Label are always emitted, with only `text`/`margin` varying, so owlkettle's positional Box matching cannot shift | Use the window past the ~90 s mark that crashed it. Cores land in `/var/coredumps/`; `gdb -batch -ex "bt 25" ./bin/jenova <core>`. **Until it is run, its status is "unknown", not "fixed"** |
| **1.2** | **T-5 — backends survive exit** | `gui.run`'s `defer` joins the worker threads and stops nothing. Leaving the *agent* loaded is deliberate — reloading multiple gigabytes into VRAM on every restart is worse — but the **embedding** server is left with nothing attached, and a backend that dies during start leaves its pidfile behind. Fix: stop the embed backend on exit; clear a pidfile whose process is not alive | `jenova-core backends status` after a GUI exit reports the agent up, embeddings down, and no stale pid |
| **1.3** | **T-2 — unbounded statement cache** | `db.nim`'s cache is a plain `Table` and finalizes only at connection close, while `api.nim`'s message update builds its `SET` clause from whichever fields the client sends. Distinct SQL accumulates without bound. **The fix belongs in `db.nim` — a cap plus finalize-on-evict — not in `api.nim`**; constraining the caller leaves the cache still unbounded for the next caller | A new suite that issues many distinct field combinations and asserts the cache stays capped. **It must be proven able to fail** before it is believed |
| **1.4** | **T-4 — `resolveStoragePath` containment** | Two directions, one fix. The symlink check is gated on `fileExists or dirExists`, so a **new** file written through a symlinked parent escapes the root; and `normBase` is lexical, so a symlinked `$JENOVA_WORKSPACES` makes the check reject **legitimate** paths. Resolve the deepest existing ancestor and compare against a resolved base | Extend `test_api_fs.sh`: a write through a symlinked parent is refused **403**, and a legitimate write under a symlinked root succeeds |
| **1.5** | **T-3 — chat history is never trimmed** | The whole conversation is resent every turn. Needs a byte budget derived from `CTX_SIZE`, dropping oldest-first and never dropping the system message | A unit check on the trim function at a small budget; not a live generation |

**Sequencing note.** 1.2–1.5 are independent of each other and of 1.1. But **1.1 is the blocker for
believing any of them**: a program that dies after 90 s cannot demonstrate the others in use.

### Stage 2 — The workspace question *(USER decision, then work)*

`TODOS.md` **T-6**. `jca_web` still owns workspaces, projects, folders, notes and fileAssets. The
native GUI has chat and persistence only. **The core already serves the whole `/api/*` surface those
features use** — this is a *client* gap, not a server gap, which is what makes it a clean decision.

Three options, with their honest costs:

| | Option | Cost |
|---|---|---|
| **A** | Build the workspace surface natively in the GUI | The largest unit of remaining work. Retires `jca_web`, `node`/`npm` and the `web` nimble task |
| **B** | Drop the workspace features | Removes shipped functionality. **Directive 3 forbids this without an explicit instruction from the USER** |
| **C** | Keep `jca_web` as the workspace client | Zero work now. The product stays two front ends, and the `public/` bundle stays a build artifact of a Node toolchain |

**A session does not pick.** Whichever is chosen goes to `DECISIONS_LOG.md` first.

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
