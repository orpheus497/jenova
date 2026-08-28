# PLANS

Forward-looking strategy for implementations that are scoped but not yet built.

**Last updated:** 2026-08-28 19:49 — Codebase Integrity Standard added (Session 004)

---

## Codebase Integrity Standard

**Referenced by `AGENTS.md` Directive 6, which mandates a pass every session, proportional to
the area touched.** The directive pointed at this file from the outset; the section did not
exist until Session 004, so the mandated pass had never been runnable. See `DECISIONS_LOG.md`
D-J.

### What the pass looks for

Seven classes. Each is a Directive 6 violation whether it appears in product code or in
`.devdocs/`:

| # | Class | Test |
|---|---|---|
| 1 | **Placeholder / stub** | Does a function promise behaviour it does not implement? |
| 2 | **Simulated stand-in** | Is a value hardcoded that should be produced by the real system — a faked return, a duplicated copy of state another component owns? |
| 3 | **Dead / orphaned code** | Does this have callers? Is this branch reachable? Is this variable ever read? |
| 4 | **Unverified logic** | Is anything claimed to work that was never executed or read? Does a static check stand in for a runtime one? |
| 5 | **False completion record** | Does a tracker mark something "Completed" that the source contradicts? |
| 6 | **Contradiction between shipped artifacts** | Do two files that must agree disagree — a conf and its metadata, a document and the code it describes? |
| 7 | **Platform foreignness** | Does the code assume a kernel this project does not target? |

### How to run it

1. **Scope it to the area touched.** A one-line fix in `scripts/` means a pass over `scripts/`,
   not the whole tree. A stage that moves files means re-reading every moved file *at its
   destination* — see constraint **C-9**.
2. **Read, do not infer.** A tracker entry is not evidence for its own claim. Evidence is the
   source, cited `file:line`.
3. **`sh -n` is not a pass.** It proves the text parses, never that the logic suits the target
   platform. C-9 exists because a syntactically perfect Linux script survived exactly this.
4. **Record everything found**, in `TODOS.md` (defect) or `DECISIONS_LOG.md` (decision or
   constraint) — *even when fixing it is out of scope for the current step*. Leaving a known
   instance undocumented is itself the violation.
5. **Retract rather than edit away.** A false completion claim is corrected in place with the
   original visible, as `PROGRESS.md` does. The failure mode has to stay legible.

### Standing exclusion

`external/` is out of scope by policy. `jca_web/node_modules/` and build outputs are not
project code.

---

## Plan B — Nim native FreeBSD desktop application  *(D-L · ACTIVE)*

**Status: drafted 2026-08-28 20:37, NOT approved.** Plan A is complete as code and stands as the
foundation this builds on.

### Settled by ruling

| | Decision |
|---|---|
| **D-L** | Native FreeBSD GUI desktop application. Not a web wrapper. `jca_web/` retained, deprecated |
| **D-M** | AGPL-3.0 — copyleft dependencies permitted. Q-4 closed |
| **D-N** | **Single binary** — GUI links the core in-process; `llama.cpp` linked directly |
| **D-O** | Fix only what survives the rewrite |
| **D-P** | **GTK4 + libadwaita via owlkettle** (Nim binding, MIT) |

### Verified toolchain baseline

Probed on the host through the Linuxulator, 2026-08-28. `pkg` reaches the real FreeBSD package
database; `sysctl -n kern.ostype` returns `FreeBSD` while `uname -s` returns `Linux` (C-8).

| Component | State |
|---|---|
| `nim-2.2.10`, `nimble-0.20.0` | **Installed.** But `nim` is not on `PATH` in the Linuxulator container while `nimble` is — resolve before N-S0 |
| `gtk4-4.20.4` | **Installed** |
| `libadwaita-1.8.5.1` | In ports, **not installed** — `pkg install libadwaita` |
| `gtksourceview5-5.18.0` | In ports, **not installed** (only `gtksourceview4` is) — `pkg install gtksourceview5` |
| `gtk3-3.24.52` | Installed — the current tray. Retired at N-S3 |

### End state

One compiled binary, `jenova`, that:

1. Opens a native GTK4/libadwaita window on FreeBSD — its own widgets, its own theme integration.
2. Hosts the HTTP server as an internal subsystem, serving `jca_web/` for as long as it is
   retained, and serving LAN mode **whether or not the GUI is running** (N-7, Directive 3).
3. Links `libllama` directly, with inference isolated on its own thread so a GUI fault cannot
   kill a generation (N-7).
4. Replaces `lib/*.lua`, `bin/jenova-ca`, the shell orchestrators and `jenova-ui/src/main.c`.
5. Keeps `hardware-profiles/` — data, not code, and it survives (`BLUEPRINT.md §10`).

### Sequencing — **APPROVED 2026-08-28: backend first, GUI last (D-Q)**

Source lives in a **new `src/` at the root**, alongside the retained `lib/` and `bin/`, which
shrink as stages land. Matches Directive 4 and keeps the two eras visibly separate.

| Stage | Scope | Subtracts | Risk |
|---|---|---|---|
| **N-S0** | Toolchain + skeleton. Resolve the `nim` PATH; `src/` layout, `.nimble` file, `make` target; a binary that builds, starts and exits cleanly on FreeBSD | — | low |
| **N-S1** | Config + path resolution in Nim. One precedence rule, stated once | **Fixes B-12 by construction** — the inverted hierarchy cannot be reproduced | low |
| **N-S2** | `jca_db.nim` — SQLite against the existing schema, so `jca_web` keeps working through `/api/db/*` | `lib/db.lua` | medium |
| **N-S3** | Async HTTP server + SSE; serve `jca_web` static; unify the three ports behind one router; basic daemon lifecycle | `lib/proxy.lua`, `lib/http.lua`, `lib/json.lua`. **Fixes B-19, B-13** | **high** — the concurrency-sensitive core |
| **N-S4** | Direct `libllama` linkage; inference isolated on its own thread (N-7) | the `llama-server` subprocess | high |
| **N-S5** | `jca_rag.nim` — embeddings and search, wired to the ingest path | `lib/embed.lua`, `lib/search.lua`. **Fixes B-14, B-15** | medium |
| **N-S6** | Full lifecycle parity: `start`/`stop`/`status`, LAN mode without the GUI (Directive 3), `hardware-profiles/` consumption | `bin/jenova-ca` and the shell orchestrators | medium |
| **N-S7** | **GUI** — owlkettle window, chat view, streaming, GtkSourceView code blocks, tray on StatusNotifierItem | `jenova-ui/src/main.c`, `lib/ui.lua`, the GTK3 dependency | **high** — owlkettle risk lands here, late |
| **N-S8** | `jenova-cli` — terminal agentic loop with tool execution | — | medium |
| **N-S9** | WebUI deprecation, once the GUI reaches parity | `jca_web/` | — |

**One consequence of backend-first worth banking:** `libadwaita` and `gtksourceview5` are not
needed until **N-S7**. N-S0 installs nothing — `nim-2.2.10` is already present. The only
dependency change in the near term is whatever `jca_db.nim` needs at N-S2.

**The risk this ordering accepts:** owlkettle is unproven on this host and its stage is last, so
toolkit surprises arrive after the backend is committed. If that proves uncomfortable, the
mitigation is a throwaway spike at any point before N-S7 — cheap, and it does not disturb the
order.

### What this plan does not do

- **No migrators, no compatibility shims** (Directive 7). The SQLite schema is matched at N-S4 to
  keep `jca_web` alive during deprecation; that is interoperation with a live component, not
  backward compatibility with a dead format.
- **No new features.** This is a rewrite of what exists. Feature parity with the current WebUI is
  the N-S9 gate, not an expansion.
- **No commits.** C-11 — commit boundaries are the USER's alone.

### Open before N-S0

1. **Sequencing** — GUI early (as above) or backend-first?
2. **Repository layout** — `src/` at the root alongside the retained `lib/`, or a separate tree?
   Directive 4 says product code lives under `src/` and `bin/`.
3. **The `develop/nim` branch** holds the spec and no source, and is behind `main` (C-7). Does
   Plan B land on `bsd`, on `develop/nim`, or on a new branch? **The USER creates branches, not
   me** (C-11).

---

## Plan A — FreeBSD-Only Migration

**Status:** Drafted, not approved. Three questions remain: **Q-1** (profile layout), **Q-3**
(vestigial variables), **Q-5** (`rc.d` scope). Q-2, Q-6, Q-7, Q-8 closed by ruling; Q-4
de-prioritised.

### Governing principle — subtract, do not rewrite

Ruling **D-D** sets the long-term target: a Nim-native backend and desktop app replacing the
Lua proxy, the SQLite/search/embed modules, the shell orchestrators, and the GTK3 tray.

That fixes the shape of this migration. **Deletion is banked** — it is less code to port.
**Restructuring is thrown away** — the file is replaced anyway. So:

- Delete foreign branches; do not redesign the scripts that contain them.
- Invest in `lib/ffi_defs.lua` deletion (highest value: it removes the exact defect class the
  Nim analysis cites as its motivation, and FreeBSD-only kernel constants are what a Nim/kqueue
  backend needs).
- Spend the minimum on `jenova-ui/src/main.c` — it is scheduled for replacement.
- Additive work must target **interfaces** (`jenova-ca`'s verbs), not implementations, so it
  survives the cut-over.

### Objective

Jenova is a FreeBSD program — not a portable program that happens to run on FreeBSD.
Measurable end state:

1. No `linux`, `darwin`, `macos`, `apple`, `metal`, `wsl`, or foreign-package-manager reference
   in project code, except where naming a dependency FreeBSD also uses.
2. No runtime OS branch. One ABI in `ffi_defs`. One OS in `detect-env`, refusing to run
   elsewhere.
3. `hardware-profiles/` holds **6 deduplicated profiles** in one coherent, uniform-depth tree.
4. Every dependency instruction is a single `pkg install` line.
5. **Every script is `#!/bin/sh` POSIX. No bash. No GPL dependency to build, install or run.**
6. Base-system tools (`fetch`, `realpath`, `lockf`, `stat -f`, `sysctl`, `swapinfo`) used
   directly, not behind GNU-first probes.
7. **:8080 is the only port any client touches.** :8081 and :8082 bind loopback
   unconditionally.
8. CUDA is opt-in only — never auto-detected, never auto-selected.
9. `external/` untouched.

---

### Stage S-0 — Close the port exposure  *(est. 30 min)*  **NEW — do first**

Bind :8081 and :8082 to `127.0.0.1` unconditionally, including under `--lan`
(`bin/jenova-ca:239,708,804,823`). Correct the firewall guidance to :8080 only
(`scripts/install.sh:562`).

**Why first.** It is the smallest change in the plan, it is security-relevant, and it makes the
code match the architecture the USER stated (D-E). Today `--lan` publishes two unauthenticated
inference endpoints to the network. The intent is already half-encoded — `jenova-ca:332` sets
`_INT_HOST="127.0.0.1"` for the proxy's upstream URLs; only the bind fails to follow.

It is also the one stage that is *pure gain under D-D*: the Nim backend unifies these ports
anyway, so closing them now costs nothing and removes exposure in the interim.

**Scope note.** This is only the *binding* half of remediation-plan WP-8. WP-8's routing-table
half is unnecessary — embeddings never traverse the proxy's HTTP surface; `embed.lua` is an
in-process call.

**Risk: low.** Four `--host` arguments and one string.

**Acceptance.** On FreeBSD with `jenova-ca --daemon --lan`: `sockstat -4l` shows :8080 on
`0.0.0.0` and :8081/:8082 on `127.0.0.1`. The WebUI still works from another host on the LAN.

---

### Stage S-1 — Collapse the runtime ABI  *(est. 1 h)*

Delete the Linux arms of `lib/ffi_defs.lua` — ~50 lines of struct definitions (`:11-104`) and
24 constants (`:215-263`) — plus `AF_INET6`'s conditional (`:198`) and the `IS_LINUX` export
(`:195`). Collapse its five consumers (`lib/proxy.lua:553,1424,1516`, `lib/http.lua:189,277`)
to their unconditional BSD arms. Add a startup assertion refusing to load off FreeBSD.

**Why this is the highest-value stage.** The two arms are not cosmetic variants:

| | Linux | FreeBSD |
|---|---|---|
| `sa_family_t` | 2 bytes | 1 byte |
| `sockaddr_in/in6/sockaddr` | no length byte | `sin_len` / `sin6_len` / `sa_len` |
| **`addrinfo` field order** | `ai_addr; ai_canonname;` | `ai_canonname; ai_addr;` |

Reading the wrong arm silently swaps a `struct sockaddr *` with a `char *`. WP-15
(`remediation-plan.md:324-340`) already concluded the LuaJIT C ABI surface is the source of
three of four Phase 1 defects. Under D-D this file disappears entirely at the Nim cut-over —
so every line deleted now is a line that never needs porting.

**Risk: medium.** It touches the async I/O path WP-1 switched on for the first time in
`d2afac0`. That code is young.

**Acceptance.** `sh tests/proxy-concurrency/all.sh` green on FreeBSD. Then on hardware:
streaming works end-to-end in the WebUI, an agentic run with tool calls completes, and
`lsof -p <proxy>` is flat across a session (`remediation-plan.md:173-183`).

---

### Stage S-2 — Eliminate bash  *(est. 45 min)*  **per ruling D-A**

Two sites, both required — fixing one alone leaves the dependency:

1. `bin/jenova-model-switch:1` — `#!/usr/bin/env bash` → `#!/bin/sh`, converting any bashism in
   its 106 lines. It does symlink swapping; nothing needs bash.
2. `lib/ui.lua:121` — `sys_exec_sync("bash " .. …)` hard-codes the interpreter. Invoke the
   script directly.

Then confirm the repository holds exactly zero non-`/bin/sh` shebangs outside the three
intentional `#!/usr/bin/env luajit` files.

**Why early.** It is self-contained, it removes a GPL-3.0 dependency (AGENTS.md rule 2), and it
removes an unstated `pkg install bash` that no install path mentions.

**Risk: low**, but it is a behavioural rewrite of a working script — verify model switching
still works before moving on.

**Acceptance.** `sh -n bin/jenova-model-switch` passes; model switching works from both the CLI
and the tray on FreeBSD; `grep -rn '^#!' bin lib scripts` shows only `/bin/sh` and luajit.

---

### Stage S-3 — Collapse environment detection  *(est. 1.5 h)*

Rewrite `lib/detect-env.sh` around `sysctl` (`hw.model`, `hw.ncpu`, `hw.physmem`), `swapinfo`
and `ldconfig -r`; hard-fail on any other `uname -s`. Delete the WSL probe (`:51-54`), the
distro/package-manager matrix (`:60-130`), the `/proc` and macOS arms (`:143-185`), and the
Linux/macOS Vulkan paths (`:196-203`).

Delete `lib/linux-tune.sh`, `tests/test_linux_tune_regex.sh`, and the caller branch at
`scripts/jenova-setup:124-137`.

**Why here.** Every install and build script sources this file; settling its contract first
means S-4 edits consumers once.

**Design note — refuse, do not degrade.** A hard failure on a non-FreeBSD host is the honest
expression of the directive; falling through to `JENOVA_OS="unknown"` is what produced the
tri-state.

**Risk: low.** The `linux-tune.sh` deletion is provably behaviour-neutral (C-6): its only
guard reads `$JENOVA_OS` in a script that never sources `detect-env.sh`, so it has never
executed. ~206 lines go with zero risk. FreeBSD tuning is elsewhere — the per-profile
`jenova-setup` scripts and `hardware-profiles/common-setup.sh`, which writes
`/etc/sysctl.conf`; `linux-tune.sh` wrote `/etc/sysctl.d/`, which FreeBSD ignores.

**Acceptance.** Sourced on FreeBSD, every `JENOVA_*` variable is correct; sourced elsewhere it
fails clearly. `sudo scripts/jenova-setup` completes.

---

### Stage S-4 — Excise foreign branches from shell  *(est. 2.5 h)*

**Deletion, not redesign** (D-D). Twelve files.

| File | Excise |
|---|---|
| `scripts/install-dependencies.sh` | five of six package-manager blocks (`:117-271`) and install arms (`:312-370`); apt index-update (`:421-429`); cargo `install_special` (`:373-396`); `realpath:coreutils` (`:104`, D-3). Add `node`/`npm` per D-C. |
| `scripts/install.sh` | OS gating + `_OS` alias (`:38-43,105-128`); four hint matrices (`:229-238,280-289,306-315`); Homebrew probe (`:297`); ELF/Mach-O arms (`:348-352`); `*.dylib*` (`:372`); desktop-entry gate (`:437`); `make`→`gmake` (`:264`, D-5) |
| `hardware-profiles/detect-hardware.sh` | `lspci` (`:117-120`), `/proc/mounts` (`:143-146`), `/proc/swaps`+`lsblk` (`:157-159`) |
| `scripts/preflight-check.sh` | macOS/Linux arms (`:73-75`); multi-distro node names (`:173-175`); `realpath`→base (`:148`). **Keep node/npm required** (D-C). Network check via `fetch` (D-7). |
| `scripts/verify-install.sh` | non-FreeBSD ELF arms (`:104-106`) |
| `scripts/build-desktop.sh` | apt/pacman hints (`:40-54`); header (`:7`) |
| `bin/build-llama-jenova` | **all Metal machinery** (`:72,81-83,91-99,133,152-153,218-220,286-289`); `*.dylib*` (`:234`); non-`pkg` glslc hints (`:120-124`); **CUDA auto-detect (`:104-106`) per D-B — keep `JENOVA_BACKEND=cuda`** |
| `bin/jenova` | `Darwin` arm (`:15`) |
| `bin/jenova-term` | `osascript` arm (`:6-8`) |
| `bin/jenova-ca` | GNU-first `stat` (`:68,624`); `.dylib` probe (`:206-207`); `flock`→`lockf` (`:604-656`); `$OLD_PROXY_PID` (`:670`, D-10); prefer bundled healthcheck over curl (`:256`) |
| `scripts/jenova-manager.sh` | header (`:3`) |
| `lib/{search,ui,proxy}.lua` | GNU-stat probe (`search.lua:143-164`); opener + `ifconfig` framing (`ui.lua:93-97,186-195`); probe ordering (`ui.lua:48-52`); comment (`proxy.lua:257`) |

**`flock` note.** `flock(1)` is not FreeBSD base; `lockf(1)` is. Today `jenova-ca:608` probes
for `flock`, fails on stock FreeBSD, and silently takes a weaker mkdir lock with hand-rolled
stale-timeout logic.

**Design note.** Expect this stage to *delete* far more than it edits.
`install-dependencies.sh` is ~498 lines existing almost entirely to abstract six package
managers; reduced to `pkg` it is a short table.

**Risk: low per file, moderate in aggregate** — this is the install path, and mistakes surface
only on a clean FreeBSD machine.

**Acceptance.** `sh -n` and shellcheck clean on every modified file. On FreeBSD:
`preflight-check.sh --verbose` passes, `gmake install` completes, `verify-install.sh --full`
passes.

---

### Stage S-5 — `jenova-ui` minimum viable  *(est. 30 min)*

Reduce `get_jenova_root()` (`jenova-ui/src/main.c:56-74`) to the `sysctl KERN_PROC_PATHNAME`
arm; delete the `__APPLE__` arm and `mach-o/dyld.h` (`:20-22`) and the `/proc/self/exe`
fallback; make `sys/sysctl.h` unconditional; `#error` elsewhere. Verify the FreeBSD pkg-config
name for the indicator library — `appindicator3-0.1` (`jenova-ui/Makefile:5-6`,
`install-dependencies.sh:113,284`) is the Linux name; FreeBSD ships the ayatana fork.

**Scope deliberately minimal (D-D).** This file is scheduled for replacement by a Nim desktop
app. Do the `#ifdef` collapse and the package name; nothing further. Q-4's licence question is
deferred for the same reason.

**Risk: low** for path resolution; **unknown** for the pkg-config rename until built on FreeBSD.

**Acceptance.** `gmake -C jenova-ui` compiles warning-free on FreeBSD; the tray starts and
resolves `JENOVA_ROOT` from an installed symlink.

---

### Stage S-6 — Deduplicate and restructure the profile tree  *(est. 2 h)*

**Blocked on Q-1 (layout only — the content decisions are settled).**

Delete: `hardware-profiles/macOS/` (6 files), `Linux/AMD/apu/ryzen7-5700u-3b` (proven
byte-identical duplicate), `Linux/Vulkan/dgpu/gtx-1650ti` (same physical machine as
`FreeBSD/dgpu/i5-1135g7-9b`).

Retain and re-key the three survivors: `CPU/generic`, `Vulkan/dgpu/full-offload-9b`,
`CUDA/dgpu/nvidia-generic`. **10 → 6 profiles.**

Three things must land with the move:

- **WP-13 fix (mandatory).** `Linux/CPU/generic/jenova.conf:57-63` uses `JENOVA_CTX_SIZE` /
  `JENOVA_NUM_SLOTS` / `JENOVA_THREADS`; `bin/jenova-ca:228-233` reads `CTX_SIZE` /
  `NUM_SLOTS` / `THREADS`. Relocating it unfixed makes a broken profile FreeBSD's **only** CPU
  fallback, launching `llama-server` with `-c "" -np "" -t ""`.
- **CUDA excluded from auto-detection** (D-B). Today `MATCH_OS="Linux|FreeBSD"` plus a broad
  `MATCH_GPU_0="NVIDIA|GeForce|Quadro|RTX|GTX"` lets it out-score a Vulkan profile on the very
  hardware that should default to Vulkan. Deployable via `--apply-profile` only.
- **Uniform depth.** Whatever Q-1 chooses, fix `scripts/jenova-setup:107` — its fixed
  `*/*/*/profile.conf` glob silently omits every 4-deep profile. Layout B fixes this
  structurally; A and C need the glob replaced with `find`.

**Risk: low.** Data files.

**Acceptance.** `detect-hardware.sh --list` shows exactly 6 profiles at uniform depth;
`--info` on FreeBSD matches one with a positive score; CUDA never auto-matches; `jenova-setup`
lists all 6; the CPU profile launches `llama-server` with real `-c/-np/-t` values.

---

### Stage S-7 — Documentation  *(est. 2.5 h)*

Delete `docs/installation/{linux,macos}.md`. Rewrite `docs/installation/dependencies.md` as a
single FreeBSD `pkg` table — **adding `sqlite3`** (D-1: `lib/db.lua:39` does
`ffi.load("sqlite3")`; omitting it produces a broken install) and **moving `node`/`npm` to
required** (D-C). Promote `freebsd.md` to primary; reconcile the FreeBSD version claim
(checklist says 15+, README 14/15, freebsd.md 15); correct its flag table (D-11).

Rewrite: `README.md:133-141,157-159`; `docs/architecture/overview.md:10`; `docs/README.md`
rows and the Known-drift profile list (`:127-132`, `:187-188`);
`hardware-profiles/README.md` — including the **two stale rows** where the prose contradicts
the confs (`:70-74`, `:82-87`, §6.5); `docs/architecture/remediation-plan.md:297-301` (WP-13
names macOS profiles being deleted); `.clangd.example:17-18,30-31`; the residual sweep across
`docs/installation/{STREAMLINED,checklist,CHANGELOG-install}.md` and `docs/hardware/`.

**Also document the architecture correctly** (D-E): :8080 is the port; :8081/:8082 are
internal. Today `docs/architecture/overview.md` and `backend.md` present three ports as peer
services — the same error this workspace made.

Tests: repoint `tests/test_validate_arg.sh:54,62` fixtures; update `tests/test_bin_jenova.sh`
for the removed Darwin arm.

**Risk: low.**

**Acceptance.** Every documented profile path resolves; no document names a dropped platform
except as history; the port topology is described as one front door.

---

### Stage S-8 — `rc.d` integration  *(est. 1 h + WP-9)*  — **only if Q-5 says yes**

Write `rc.d/jenova` with `rcvar`, delegating `start`/`stop`/`status` to `jenova-ca`. Install
it; document `sysrc jenova_enable=YES`.

**Why it survives D-D.** It calls verbs, not internals — when `jenova-ca` becomes a Nim binary
exposing the same verbs, the rc script is unchanged. It is the one piece of additive work that
outlives the rewrite.

⚠️ **It inherits WP-9.** `bin/jenova-ca:13` declares `PROXY_PID` and never assigns it;
`--daemon` starts only llama-server and embed, so **a headless start has no :8080** — and
under D-E, :8080 *is* Jenova. `_probe_health` watches :8081, so a wedged proxy reads green.
Q-5 option A folds in the fix (assign `PROXY_PID`, add it to the pidfile, report it in
`status`, stop it in `stop`, repoint `_probe_health` at :8080).

**Acceptance.** `service jenova start` brings up :8080 and serves the WebUI; `service jenova
status` reports all three processes; `service jenova stop` leaves none behind.

---

### Stage S-9 — Verification  *(est. 1 h + USER time)*

Local (static only, per C-3): `sh -n` every modified script; shellcheck clean; `luajit -bl`
parses every modified Lua file; confirm zero non-FreeBSD platform references in project code;
confirm zero non-`/bin/sh` shebangs and no GPL dependency.

On the USER's FreeBSD host: full build, `gmake install`, `service`/daemon start, WebUI on
:8080, streaming completion, `sockstat` confirms :8081/:8082 are loopback-only,
`tests/proxy-concurrency/all.sh` green.

---

## Effort Summary

| Stage | Scope | Est. | Blocked by |
|---|---|---|---|
| S-0 | Close port exposure | 30 m | — |
| S-1 | Runtime ABI collapse | 1 h | — |
| S-2 | Eliminate bash | 45 m | — *(D-A)* |
| S-3 | Env detection | 1.5 h | Q-3 |
| S-4 | Shell branch excision | 2.5 h | Q-3 |
| S-5 | `jenova-ui` minimum viable | 30 m | — |
| S-6 | Profile dedupe + restructure | 2 h | **Q-1** |
| S-7 | Documentation | 2.5 h | Q-1 |
| S-8 | `rc.d` (+WP-9) | 1 h | **Q-5** |
| S-9 | Verification | 1 h | all |
| | | **~13 h** | |

Plus USER verification on FreeBSD after S-0, S-1, S-2 and S-5 — each touches the runtime I/O
path, process startup, or the network surface.

**S-0, S-1, S-2 and S-5 are unblocked and can start on approval alone.**

---

## Deferred — explicitly not in this migration

| Item | Why |
|---|---|
| The Nim rewrite itself | Long-term goal (D-D). This migration prepares for it by subtracting; it does not begin it. |
| `remediation-plan.md` Phases 2–4 (WP-4…WP-7, WP-10…WP-12) | Independent of platform. WP-8 (binding half) → S-0; WP-9 → S-8 if Q-5=A; WP-13/14 → S-6/S-7. |
| WP-15 (Lua vs Nim) | **Decided by D-D.** Its C-shim middle path is moot; its diagnosis is what S-1 acts on. |
| Q-4 licence resolution | De-prioritised — the GTK3 dependency likely disappears in the Nim rewrite. |
| `jca_web/` | Zero OS coupling (C-5). In scope for the Nim rewrite, not for this migration. |
| `bin/jenova-swap-mount` | Already FreeBSD-native (`mdmfs`, swap-backed). Nothing to do. |
| D-13 (`/api/fs` missing from vite dev proxy) | Dev-server config, not platform. Fix opportunistically or leave to WP-13. |
