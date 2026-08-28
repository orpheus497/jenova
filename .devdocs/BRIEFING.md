# BRIEFING

**Last updated:** 2026-08-28 20:45
**Branch:** `bsd`
**Phase:** 3 — Execution. **Plan B (Nim native desktop application) is the active workstream.**

---

## 1. Current state

| Item | Value |
|---|---|
| Active plan | **Plan B — Nim native FreeBSD GUI application** (D-L). Approved backend-first, N-S0 … N-S9 |
| Stage | **N-S0 … N-S3 complete; N-S4a verified generating in-process at the full deployed config.** N-S4b unblocked by D-W (serial inference) |
| Plan A (FreeBSD migration) | Code complete, S-0 … S-7. The foundation Plan B builds on |
| Open defects | **37** — B-01 … B-38, less B-07. **Triaged by D-O**: only 7 are to be fixed |
| Open decisions | **Q-10 only.** Q-23 answered by D-W (serial). Q-9, Q-11, Q-12 superseded or reframed by the rewrite |
| Destructive defects | **None outstanding** |
| Commits | **None.** Commit boundaries are the USER's alone (C-11) |

## 2. The rewrite, settled

| Ruling | Decision |
|---|---|
| **D-L** | Native FreeBSD GUI desktop application. Not a web wrapper. `jca_web/` retained, deprecated |
| **D-M** | Project is **AGPL-3.0** — copyleft dependencies permitted. **Q-4 closed**; it was never a violation |
| **D-N** | **Single binary** — GUI links the core in-process; `llama.cpp` linked directly |
| **D-O** | Fix only what survives the rewrite |
| **D-P** | **GTK4 + libadwaita via owlkettle**; `gintro` as escape hatch |
| **D-Q** | Backend first, GUI last. Source in a new `src/` at the root |
| **C-11** | I run no git writes. Read-only inspection permitted |

**Stage order:** N-S0 skeleton ✅ → N-S1 config ✅ → N-S2 database ✅ → N-S3a threaded server ✅ →
N-S3b `/api/db/*` ✅ → N-S4a `libllama` linkage ✅ → **N-S4b inference thread + `/v1/*` wiring**
→ N-S5 RAG → N-S6 lifecycle parity → N-S7 GUI + tray → N-S8 CLI → N-S9 WebUI retirement.

**C-14 — a rule bought the hard way.** I claimed the deployed `CTX_SIZE=32768` could not be served
on this GPU. It can; my binding was ignoring `DEVICES` and `KV_CACHE_TYPE`. **When a new binding
fails on input the existing implementation handles fine, the binding is wrong until proven
otherwise.** `LoadSpec` now carries every backend value the profile exposes, with no silent
defaults.

**N-24 — a latent config bug, surfaced by fixing B-12.** `etc/jenova.local.conf` sets
`DEVICES="Vulkan0,Vulkan1,Vulkan2"`; **there is no Vulkan2** on this machine. It never failed
because the shell discarded the local conf entirely, so `llama-server` ran on the profile's
`Vulkan0,Vulkan1`. The Nim core honours the documented precedence and is the first component to
read the bad value. **Expect more of these as the shell path retires.**

**`lib/proxy.lua` is not retired yet.** `/api/fs/*` remains unported (N-20) and is the last thing
holding it alive. Required before N-S6.

**D-R / C-13 / D-S — concurrency, settled and measured.** The Lua proxy's defect was never
SQLite; WAL was already on. It was that every blocking call ran on one single-threaded event
loop. **Nim's `asyncdispatch` is the same kind of loop**, so adopting async would have relocated
the defect, not removed it — one missed dispatch anywhere reintroduces the global stall with no
compile-time signal.

**The server therefore uses a worker-thread pool, not async** (D-S) — no shared loop exists, so
there is nothing for a blocking call to stall. Proven: an SSE stream held its 40 ms cadence
(max gap 40.1–47.6 ms) while four clients pushed 400,000-row recursive CTEs through SQLite.
**This deviates from `jenova_refactor_analysis.md` and is flagged for review** — the cost of
revisiting it grows once handlers are written against blocking I/O.

**D-T — scale is settled: this is a personal, single-user product.** The host plus at most one LAN
device. Not a multi-user server; that niche is already served. **Every capacity number derives
from two devices.** Handler threads: `static:4 health:2 api:3 completion:3 embed:1 debug:1` — 14
total, plus 2 acceptors. An earlier 34-thread sizing was server intuition and was corrected.

**D-U — every service surface owns its own routine and threads.** Acceptors classify with
`MSG_PEEK` without consuming the socket, then hand the descriptor to a per-class queue; each class
has its own pool. This fixed a real defect: with one shared pool, long-lived completion streams
occupy every worker and health checks and static serving go dark — normal operation, not an edge
case. Verified: with the debug class saturated 3:1, `/health` answered in **0.2 ms**.

**Seven defects get fixed by construction rather than patched:** B-12 (N-S1 ✅), B-13 and B-19
(N-S3), B-14 and B-15 (N-S5). That is D-O working as intended.

**Live finding from N-S1, worth acting on independently:** this host's `etc/jenova.local.conf`
declares three Vulkan devices and 8 threads, and the shell path discards all of it — every run
so far has used the profile's 2 devices and 4 threads. The Nim core honours it. The shell keeps
the bug until `bin/jenova-ca` is deleted at N-S6, so **anything launched through `jenova-ca`
today is still mistuned.**

## 3. Verified toolchain

`nim-2.2.10` and `gtk4-4.20.4` installed. `libadwaita-1.8.5.1` and `gtksourceview5-5.18.0` are in
ports but **not installed — not needed until N-S7** (D-Q). The `lang/nim` port installs to
`/usr/local/nim/bin`, off the default `PATH`; `make core` probes for it, so no PATH change is
needed.

## 4. Blockers

| # | Blocker | Type |
|---|---|---|
| **N-11** | **Dependency change awaiting approval** — add `nim` to `install-dependencies.sh` DEPS so `make core` can depend on `deps`. Until then a pre-installed compiler is required | decision |
| **N-8** | **USER governance action** — `AGENTS.md` Directive 2 contradicts the AGPL-3.0 licence, and Directive 7 governs `.dbc` cartridges and `test_roms/` that do not exist here | decision |
| **B-1** | Full `make` build, `make install` and a live daemon start still unexercised | verification |
| **Q-10** | `verify-install.sh` — retire or rewrite. D-O points at retire | decision |

## 5. What C-12 changed

The standing rule that *"nothing run in this environment is evidence"* was **too strong and is
corrected**. `sysctl kern.ostype` returns FreeBSD, `pkg` reaches the real package database, and
FreeBSD ELF binaries — including the one built this session — execute here. Session 001 reached
this conclusion and retracted C-3 for it; Session 003's trackers reinstated the stricter rule
anyway.

**The accurate rule is narrower:** anything depending on `uname -s`, `/proc`, or Linux-emulated
syscalls is not evidence (B-23 is exactly that case). Native builds and binaries are.

**Consequence:** B-1's verification is runnable from here rather than blocked on the USER.

## 6. Defects still to fix under D-O

Only these seven. Everything else stays recorded so the Nim implementation does not reproduce it.

| ID | What |
|---|---|
| **B-22** | A test that rewrites `etc/jenova.conf` — the real origin of commit `eee557e`. Cheap; protects the tree during the rewrite |
| **B-01** | The Web UI fetches webfonts from Google on every load. A live privacy leak, fix even while deprecating |
| **B-09, B-10** | `jenova-setup` broken for 3 of 6 profiles, incl. the GPU fallback and the only CPU-only profile |
| **B-05, B-20, B-21** | Hardware-profile data contradicting itself; `CUDA/dgpu-generic` ships a third-party "Uncensored" model as its default |

`hardware-profiles/` is data and survives the rewrite (`BLUEPRINT.md §10`), which is why its
defects are worth fixing and the Lua/shell ones are not.

## 7. Next steps

1. **N-S1** — config and path resolution in Nim, one precedence rule stated once.
2. **N-11** — approve adding `nim` to the dependency list.
3. **N-8** — amend `AGENTS.md` Directives 2 and 7 (USER).
4. **B-22 and B-01**, the two cheap survivors from the triage.
5. `jca_web/src/` full read, still outstanding since Session 003.

## 8. Standing process notes

- **Directive 1 is per-item.** A general "proceed" is not a ruling on an open question.
- **C-11:** no git writes, ever. Branch creation for Plan B is the USER's action.
- **C-12:** native FreeBSD execution here *is* evidence; Linux-emulation-dependent results are not.
- **D-J:** the Codebase Integrity Standard in `PLANS.md` is my wording. Correct it if the intent
  was different.
