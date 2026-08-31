# TODOS

**Last updated:** 2026-08-31 15:49

Only what is actually outstanding. Everything closed lives in `PROGRESS.md`; everything retired
lives in `.devdocs/ARCHIVE/`. **Do not re-add defects about archived files** — that loop cost a day.

> **Re-verified 2026-08-31 (Session 007) against the tree, item by item.** Every one of T-1 … T-10
> was checked by reading the file it names. **All ten hold. No new defect was found, and nothing
> here is speculative.** The evidence is in `SESSION_HANDOFF.md` Session 007; the sequenced plan for
> working through them is `PLANS.md`. **T-1's fix is compiled into `bin/jenova` — the outstanding
> work on it is to run it, not to write it.**

---

## Blocking

| ID | Item |
|---|---|
| **T-1** | **SIGBUS in the GUI redraw.** Crashed after ~90 s of use. Backtrace: `gtk_widget_set_margin_top` inside owlkettle's widget diff, reached from a timer calling `redraw`. Cause: conditionally-present sibling widgets in `view` — owlkettle matches Box children positionally, so a Label that appears and disappears shifts the rest. **Fix is built and NOT yet run.** Cores land in `/var/coredumps/`; `gdb -batch -ex "bt 25" ./bin/jenova <core>` |

## Real, verified by reading the code

| ID | Item |
|---|---|
| **T-2** | **`db.nim`'s prepared-statement cache never evicts.** `api.nim`'s message update builds its `SET` clause from whichever fields the client sends, so distinct SQL strings accumulate, each holding a `sqlite3_stmt`. Fix belongs in `db.nim` (a cap plus finalize-on-evict), not in `api.nim` |
| **T-3** | **Chat history is never trimmed.** The whole conversation is resent every turn. Needs a byte budget derived from `CTX_SIZE` |
| **T-4** | **`fssync.resolveStoragePath` only resolves symlinks for paths that already exist.** A new file written through a symlinked parent escapes the workspace root; separately, a symlinked `$JENOVA_WORKSPACES` makes the check reject legitimate paths. Both directions need an assertion |
| **T-5** | **`bin/jenova` leaves `llama-server` running on exit.** Deliberate for the agent model (not discarding a multi-gigabyte load), but the embedding server is also left with nothing attached, and a stale pidfile points at a dead process after a failed start |

## Product decisions — not mine to make

| ID | Item |
|---|---|
| **T-6** | **`jca_web` still owns the workspace side** — workspaces, projects, folders, notes, fileAssets. The native GUI has chat and persistence only. Retiring `jca_web` therefore means either building that surface in the GUI or dropping it. **A product call** |
| **T-7** | **Deployment.** The product is two Nim binaries. How they get installed is one decision, taken once. The shell installer is archived and is not the answer |
| **T-8** | **CLI.** After the above |

## Data, independent of everything

| ID | Item |
|---|---|
| **T-9** | `hardware-profiles/CPU/generic/jenova-setup` is entirely Linux — `cpupower`, `/sys`, `numactl`. It is the only CPU-only profile |
| **T-10** | Each `profile.conf`'s **tuning** `PROFILE_*` block contradicts the `jenova.conf` beside it — for `Vulkan/dgpu-i5-1135g7`, FIT 256 vs 128, CTX 8192 vs 16384, NGL 16 vs `all`, DRAFT 0 vs 1. Nothing reads those tuning values. Sync or delete them. **Not the whole prefix:** `PROFILE_OPT_IN` and `PROFILE_DESC` *are* read, by `detect-hardware.sh:166,302` — this item said "nothing reads them" until 2026-08-31, which would have made deleting the block look safe |

---

## Closed by the 2026-08-31 rewrite — do not reopen

The audit series B-44 … B-65 was written against `gui.nim` and `tray.nim` before either had been
run. **Most of it is void**, and the reason matters:

- **B-44, B-45, B-46, B-53, B-55, B-56, B-57** — fixed, and mostly by *deleting* the code that had
  them. The hand-rolled HTTP client, SSE parser, JSON escape decoder and JSON serialiser are gone;
  `std/json` was already imported three modules away.
- **B-47** ("the UI freezes 2–4 s") — **never measured, asserted from reading.** Control work did
  move off the GTK thread, but the defect as stated was speculation.
- **B-48, B-49, B-50** (tray protocol) — **asserted from reading the D-Bus spec, then asserted to be
  disproven from a claim the USER never made.** The tray registers and renders. Unknown, not open.
- **B-61, B-62, B-63, B-64, B-65** — dead code and comments that contradicted their own code.
  Partly gone with `llama.nim`/`inference.nim`.
- **Everything about the shell tree** — N-34, N-35, B-11, B-27, B-28, B-29, B-35, B-39, B-42, B-54,
  and the dangling `jenova-ca` references. **Archived, not pending.**

**The lesson, recorded as D-AN:** a defect list produced by reading unrun code is speculation with
line numbers. It generates a plan, which generates devdoc edits, which generates the next session's
correction pass. **If it was not executed, it is not stated.**
