# PLANS

Forward-looking strategy for implementations that are scoped but not yet built.

**Last updated:** 2026-08-31 — REMAINING WORK corrected by **D-AH**; re-sequenced by **D-AI** (CLI last, behind the total-conversion gate); toolchain probed

---

## Codebase Integrity Standard

> **Provenance corrected 2026-08-31.** This section was authored under the belief that
> `AGENTS.md` **Directive 6** mandated a per-session pass against it. **There is no Directive 6.**
> `AGENTS.md` has four directives, and the devdocs cite a superseded numbering in 14 places. The
> standard is **retained on its merits** — it caught B-35 … B-38 and the `chatPrompt` stub before
> either shipped — but it stands as **workspace practice, not governance**. `D-J` and `C-10`, which
> were built on the same false premise, are qualified by this note. Read every "Directive 6"
> reference below as "this standard".

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

## N-S7a — the audit remediation plan. **2026-08-31 14:53**

**22 defects (B-44 … B-65). Six of them are one architectural fault**, and the fix for it is
*less* code than what is there now. Ordered by structural leverage, not by severity, so the same
line is not touched twice.

### The rule this plan is written against

**Three ways to get this wrong, all named by the USER, all things this project has already done
once:**

| Trap | What it would look like here | Guard |
|---|---|---|
| **Bottleneck on one thread** | Putting streaming *and* supervision on a single worker, so a generation blocks a "stop backend" | **Two workers with distinct roles**, which is `routes.nim`'s per-class isolation (D-U) applied to the GUI — not a new pattern |
| **Rebuild a defect from the old design** | A status poll that forks (B-17) · a supervisor owned by the UI as a child process (B-13) · a command builder that quotes shell strings (`ui.lua`'s `shell_quote`) | No fix below introduces a fork, a child supervisor, or a shell string |
| **Fix something we are cutting** | Restructuring `api.nim`'s dynamic SQL, or rewriting static file serving | **Both serve `jca_web` only and die at N-S9.** Verified: the GUI references neither. They get a *bound*, not a redesign |

### Fix 1 — the GUI concurrency model. **One change, six defects: B-44, B-45, B-46, B-47, B-53, B-57**

**The fault:** `gui.nim` creates a thread per generation and never joins it, and runs supervision
inline on the GTK loop. Two mistakes, one root — **no owned execution context**.

**The fix, and it removes code:**

| | |
|---|---|
| **Two persistent workers, started once, joined at shutdown** | `stream` (one generation at a time — that *is* the bound, exactly as `rcCompletion` is sized) and `control` (start/stop/restart/health — serialised among themselves, which is correct: concurrent start and stop is not a thing anyone wants) |
| **Requests in by channel, results out by one channel** | The GTK drain already exists and works; it stops being the only part that is right |
| **Explicit shutdown** | quit sentinel → `joinThread` → *then* `close`. Kills B-45 and B-46 outright, because the close can no longer race a live worker |
| **`isNil` guard before `sock.close()`** | B-44. **`except CatchableError` never protected it**, so every `finally` that closes a `ref` needs the same treatment |
| **`waitForExit` in `runCapture`** | B-53. It moves to the control worker, so `xdg-open` stops running on the GTK thread too |
| **`streaming` owned by the drain, never set speculatively** | B-57 |

**Why two and not one:** a generation runs for tens of seconds. Sharing its thread with supervision
means "stop the backend" waits for the model to finish talking. **That is the bottleneck the USER
named**, and it is the shape of `proxy.lua` serialising every client behind one event loop.

**Why not more than two:** there is no third kind of work. Adding threads for their own sake is how
`routes.nim` came to provision 34 before D-T cut it to 14.

**Acceptance:** a `restart` issued *during* a generation is serviced without waiting for it, and the
window keeps painting throughout. One test, and it is the whole point of the change.

### Fix 2 — tray protocol conformance. **B-48, B-49, B-50**

Self-contained in `tray.nim`. **A wrong D-Bus reply produces a missing icon rather than an error**,
so none of this is provable by reading — it lands together and is verified against a live panel.

- `Properties.Get` returns a **variant**, not `a{sv}` (B-48). The `GetAll` path is already correct.
- Add `Introspectable.Introspect`, and dbusmenu `GetGroupProperties` / `GetProperty`; honour
  `GetLayout`'s `parentId` (B-49).
- Set the icon's initial status from a real probe, and move `setStatus` out of the
  `if newStatus != st.status` branch that currently hides the first one (B-50).

### Fix 3 — bound what is unbounded. **B-51, B-52, B-54**

| Defect | Fix | Why this shape |
|---|---|---|
| **B-51** statement cache | **Cap it in `db.nim`, finalize on evict** | Fixes the *class*, in the layer that survives N-S9. **`api.nim`'s dynamic `SET` is deliberately not restructured — it dies with `jca_web`** |
| **B-52** conversation history | Trim to a byte budget derived from `CTX_SIZE` before sending | The number belongs to the model's context, so it comes from config rather than a constant someone picked |
| **B-54** static `readFile` | A size cap and a clear refusal, **not** a streaming rewrite | It serves `jca_web` only. A cap is honest and cheap; a chunked sender is work on a path being cut |

### Fix 4 — correctness. **B-55, B-56, B-58, B-59, B-60**

- Decode `\uXXXX` to UTF-8 and stop dropping `\r` (B-55, B-56). Non-ASCII currently renders as an
  escape in the chat view — visible on the first accented character a model emits.
- `models.nim`: remove the temp symlink on every failure path, and exclude dangling links from
  `targetModel` as `[ -f ]` did (B-58, B-59). **Both are fidelity gaps against the shell original.**
- `fssync.resolveStoragePath`: resolve the **parent** directory's real path so a new file cannot be
  written through a symlinked parent, and compare against the resolved root so a symlinked
  `$JENOVA_WORKSPACES` stops rejecting legitimate files (B-60). **Both directions get an assertion**
  — the suite covers traversal today but neither symlink case.

### Fix 5 — integrity. **B-61, B-62, B-63, B-64, B-65**

Delete the dead (`dbus_message_new_error`, `get_interface`, `get_member`, `val`), correct the two
comments that contradict their own code, move the watchdog `Thread` to module scope and join it,
and drain queued jobs on `inference.stop`.

**B-61 and B-62 are mine and they are the most instructive items in the audit**: `dbus.nim`'s header
claims the binding never mirrors an ABI while `DBusMessageIter` mirrors it in 14 dummy fields, and
`lanAddress` claims an argument vector over code that runs `sh -c`. **A comment describing what the
code should have done reads exactly like a comment describing what it does** — the `startProcess`
pipe failure (D-AG) in a different costume.

### Fix 6 — **stop the devdocs rotting.** *(The USER's standing complaint, addressed structurally)*

> "i dont want to be stuck in this loop of rewriting devdocs every session"

**The loop has a mechanical cause and it is not forgetfulness.** The trackers record **facts
derivable from the code** — subcommand counts, module lists, test counts, file inventories — and
those rot on the next commit. Every session then spends its first hour rediscovering the drift.
B-41 was five instances of exactly this in one pass; the subcommand count alone has been wrong
three times (three → eight → thirteen).

**Three changes, and the first is the one that matters:**

1. **`make devdocs-check` — drift becomes a failing command, not an archaeology session.** A script
   verifying the derivable claims against the tree: the subcommand list, the module and test
   inventories, `lib/` and `bin/` contents, and the total-conversion gate (no Lua, no C, no project
   shell script). **A session runs one command instead of re-reading eleven files**, and drift is
   caught when it is introduced.
2. **Stop writing derivable facts into prose.** `ARCHITECTURE_MAPPING.md` should say what each
   module is *for* and why it is shaped that way — which does not rot — and point at
   `jenova-core --help` for the list, which does. **Rationale is durable; inventories are not.**
3. **Cap the narrative.** `SESSION_HANDOFF.md` and `SUMMARIES.md` have grown past 1,000 lines of
   process history. **This one needs the USER, because `AGENTS.md` mandates their format** — the
   proposal is a hard length cap per entry and archival at 20 entries rather than 40.

**This plan's own footprint is one `PLANS.md` section and one `TODOS.md` table.** No other tracker
is touched until the work lands, and then only `PROGRESS.md` gets a line.

### Sequence

**Fix 1 first** — six defects, and the only one that changes structure, so everything else lands on
a stable base. Then **2** and **3** (independent of each other), then **4**, then **5**.
**Fix 6 runs in parallel with any of them** and is the one that pays back every future session.

**Nothing here needs a new dependency. Nothing here touches `jca_web/`, the shell installer, or
anything else being cut.**

---

## REMAINING WORK — corrected 2026-08-31 13:21 by D-AH

> **The 13:07 revision of this section is withdrawn. It planned three stages of rebuilding the old
> program.**
>
> N-S6b (the shell installer), N-S6c (the shell-era documentation) and N-S6d (the shell test
> scripts) were scoped as the next three stages, ahead of the GUI. **Every one of them is
> scaffolding around a system that is being replaced.** Under **D-O** — fix only what survives the
> rewrite — none of it is work at all, and I had that ruling in front of me.
>
> The USER: *"why are we getting bogged down into rebuilding the old broken version - I specifically
> chose the redesign and rewrite so we weren't making a million entry points, a million processes on
> one thread and a million things to pass through one proxy … we are not rebuilding llama as nim and
> we are not rebuilding the same faulty lua system - we are taking the good and enhancing the parts
> missing."*
>
> **The frame that section should have used, and the one below does: what is missing from the Nim
> core, not what is broken in the shell tree.**

### What actually remains — **re-sequenced 2026-08-31 by D-AI**

**The CLI moves behind the total-conversion gate.** The USER: *"the cli is an added tool for another
time after we have confirmed the total conversion and that there is no more lua c or shell scripts
relied on (aside from configs)."*

| # | Stage | Scope | Subtracts | Risk |
|---|---|---|---|---|
| **1** | **N-S7 — the desktop application** | Native Nim GUI **and** the tray/TUI control surface it must retain under Directive 3 | `jenova-ui/src/main.c` (C), `lib/ui.lua` (Lua), `bin/jenova-term`, GTK3 + libappindicator + LuaJIT + ncurses | **high** |
| **2** | **N-S7b — the last shell reliance** | `jenova-model.sh` and `jenova-model-switch` ported to Nim | 2 shell scripts | low |
| **3** | **GATE — total conversion confirmed** | Enumerate that no Lua, C or shell script is relied on by the running product, configs excepted | — | — |
| **4** | **N-S9 — retire `jca_web/`** | **D-Z lifts here; B-01's live privacy leak closes with it** | `jca_web/`, and the shell installer/updater/uninstaller | medium |
| **5** | **N-S8 — `jenova-cli`** | Terminal agentic loop with tool execution. **An added tool, after the gate** | — | medium |

**Deployment is one decision at the end, not a stage.** The product is a single Nim binary — **not a
repair to `install.sh`**, which deploys the old program and which D-Y prohibits exercising anyway.

### The total-conversion inventory — **enumerated, not taken from the trackers**

**What the running `jenova-core` actually relies on, by reverse-dependency search:**

| Language | File | Relied on by | Dies at |
|---|---|---|---|
| **Lua** | `lib/ui.lua` (257 lines) | `jenova-ui/src/main.c` via embedded LuaJIT | **N-S7** |
| **C** | `jenova-ui/src/main.c` (695 lines) | the tray and TUI binary | **N-S7** |
| **shell** | `lib/jenova-model.sh` | `etc/jenova.conf:27` → `config.nim`'s `/bin/sh` evaluation → `MODEL_PATH`/`MODEL_DRAFT`/`MODEL_EMBED` at `lifecycle.nim:82,115,130` | **N-S7b** |
| **shell** | `bin/jenova-model-switch` | `lib/ui.lua:125`, the tray's model-switch action | **N-S7b** |

**That is the whole list.** Three previously-recorded items are **not** on it:

- **`lib/detect-env.sh` and `lib/jenova-conf.sh` are NOT relied on by the core.** The trackers said
  all three shell modules were load-bearing; **only `jenova-model.sh` is.** Their callers are
  `scripts/*.sh` and `detect-hardware.sh` — setup-time tooling the running product never invokes.
- **`scripts/*.sh` and `hardware-profiles/detect-hardware.sh` are setup-time tools**, not runtime
  reliances. They go with N-S9's tree, not the conversion gate.
- **`/bin/sh` itself is FreeBSD base, not a project script.** `config.nim` evaluates the conf files
  with it, and `websearch.nim` shells to base `fetch(1)` by deliberate design. **The configs are
  exempt by the USER's own parenthetical**, and evaluating a shell-format config requires a shell.

**Why `etc/jenova.conf` keeps its format.** It is a config, and configs are exempt. It is also real
shell — a `return 1` guard, a `JENOVA_LAYOUT` branch, a `.` source, and `${X:-default}` expansion
throughout. `config.nim:54-60` already argues, correctly, that a partial parser for a shell subset
"would silently mishandle all three and report a plausible wrong answer". **N-S7b removes the
*script* from the chain, not the shell format** — model discovery moves into Nim, and the conf's
source line stops being what supplies `MODEL_*`.

### Verified toolchain baseline — **probed 2026-08-31, mechanism stated per D-AB**

`pkg info` and `pkg-config` read the real FreeBSD package database; `pkg search` and `fetch(1)`
reached the network. None of this routes through the emulation layer.

| Component | State | Consequence |
|---|---|---|
| `nim 2.2.10` | Present, `/usr/local/nim/bin/nim`, off `PATH` | The `Makefile` already probes both locations |
| **`owlkettle`** | **ABSENT.** Not in `~/.nimble/pkgs2`; **no FreeBSD port** — `pkg search owlkettle` empty | **`nimble install` only.** Network confirmed reachable |
| `gtk4` | **4.20.4 installed**, pkg-config resolves | The one major dependency already satisfied |
| **`libadwaita-1`** | **ABSENT**, available as `libadwaita-1.8.5.1` | `pkg install` |
| **`gtksourceview-5`** | **ABSENT**, available as `gtksourceview5-5.18.0` | `pkg install`. **Code-block highlighting only — deferrable** |
| `dbus` | **1.16.2 installed**, pkg-config resolves | **Makes an SNI tray feasible at all** — see below |
| Session | `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0`, `XDG_RUNTIME_DIR=/var/run/xdg/orpheus497` | A live graphical session exists to test against |

### N-S7's real scope — **larger than "a chat window", and one part is unsolved**

**Directive 3 forbids losing features.** The current tray/TUI is not decoration; it is the control
surface, and `lib/ui.lua` defines it exactly:

| Feature | Today | In Nim |
|---|---|---|
| Tray icon reflecting active/inactive, polled 3 s | appindicator + `jenova-ca status` | **UNSOLVED — see below** |
| Menu: Open Web UI · System Control · Start/Stop/Restart · Switch Instruct/Thinking · Toggle LAN · Quit | `ui.get_menu`, `ui.on_action` | Direct — `lifecycle.nim` already owns every verb **in-process** |
| LAN state persisted at `$JENOVA_STATE/lan_mode` | `ui.lua:12-37` | Direct |
| Status string `LOCAL (127.0.0.1)` / `LAN (<ip>)` | `route -n get default` + `ifconfig` | Direct, base tools |
| ncurses TUI with the same menu | `main.c:486` `run_tui` | **A GUI window replaces it.** Confirm rather than assume |
| Chat view, streaming, code blocks | **does not exist** | New — the actual desktop application |

**One structural simplification lands for free.** `ui.lua:69` spawns `jenova-ca proxy-serve` as a
child of the tray — **that is B-13's mechanism**, the reason `--daemon` started no `:8080`. In the
Nim core the server and the supervisor are already one process, so **the tray stops owning a proxy
altogether**; it calls `lifecycle` in-process. The `proxy-serve` verb has no `jenova-core`
equivalent and needs none.

**The unsolved part — N-10, and it is an architecture problem, not a task.** GTK4 dropped
`libappindicator`. **owlkettle provides no tray of any kind.** A StatusNotifierItem tray is a
**D-Bus protocol** (`org.kde.StatusNotifierItem` + `com.canonical.dbusmenu`), and `dbus-1.16.2` is
present — so it is *possible*, but it is an implementation against a D-Bus binding Nim does not
ship, not a widget call. **Three honest options; this is the USER's call:**

| | Option | For | Against |
|---|---|---|---|
| **A** | **Implement SNI over D-Bus in Nim** | Keeps the tray, keeps the single binary, no C | The largest unbudgeted piece of work in the rewrite |
| **B** | **Drop the tray; the GUI window is the application** | Simplest, and a real desktop app arguably needs no tray. Removes N-10 entirely | **Removes a shipped feature — Directive 3 requires explicit instruction** |
| **C** | **Ship the window first, tray after** | Unblocks the stage now; the window is the valuable half | Leaves `jenova-ui` alive, so C and Lua survive past N-S7 — **which defers the conversion gate** |

**No recommendation without the USER**, because B trades a feature away and C trades the gate away.

### Gates on N-S7 — Directive 1

1. **`nimble install owlkettle`** — a new Nim dependency, MIT, the toolkit D-P chose.
2. **`pkg install libadwaita`** — D-P names it. *(owlkettle builds against bare GTK4 without it, so
   this is separable.)*
3. **`pkg install gtksourceview5`** — code-block highlighting only. **Deferrable.**
4. **N-11 — add `nim` to `install-dependencies.sh`'s `DEPS`.** Still unapproved, still true.

**The owlkettle spike D-Q always allowed for is now cheap and specific:** install it, build one
window against GTK4 4.20.4, and confirm it runs in this session. That answers "unproven on this
host" before any Jenova code is written against it.

### The parts missing from the core — "taking the good and enhancing"

The backend is complete as a **harness**: routing, thread-per-class isolation, SQLite, the
filesystem mirror, RAG, the completion pipeline, backend lifecycle and the watchdog. **What is
thin is the engine wiring**, and this is where enhancement belongs rather than reconstruction.
`llama-server` is the engine (**D-AF**) — none of this rebuilds it.

| Surface | State today | The missing part |
|---|---|---|
| **agent** — `llama-server` :8081 | `upstream.forward` relays verbatim, streaming SSE without stalling. Argument vector built from the profile, 31 assertions | Proven |
| **embed** — `llama-server --embedding` :8082 | `rcEmbed` class, forwarded; `rag.embed` parses `data[].embedding`; verified against a live embedder, `chunks with vectors` 0 → 3 | Proven |
| **FIM** — `/infill` | Classified to completion and forwarded; `llama-server` is built `--spm-infill`. **Under D-AF that classification is the whole requirement** | Proven by classification. Only the Neovim client's own behaviour is unexercised |
| **lifecycle** | `start\|stop\|restart\|status\|health\|args`, `fork`/`dup2`/`execv` straight to the log file, watchdog thread at 30 s / 3 / 60 s | Proven |
| **CLI** | **Absent.** This is N-S8 | The agentic loop and tool execution — **the one stage that adds rather than ports** |
| **GUI** | **Absent.** This is N-S7 | Everything |

**N-21 is the one contract decision to take at N-S7 rather than inherit.** Restoring a conversation
revives every message, including ones deleted individually beforehand — faithful to
`db.restore_item` and therefore correct for the frozen client. **The GUI need not reproduce it.**

**N-11 gates N-S7 and is a genuine Directive 1 item:** `nim` is not in
`install-dependencies.sh`'s `DEPS`, and `libadwaita` and `gtksourceview5` are in ports but not
installed on this host. `make core` works only because a compiler is already present.

**The owlkettle risk is unchanged and so is its mitigation:** D-Q put the toolkit last deliberately,
so the surprises arrive after the backend is committed. A throwaway spike before N-S7 is cheap and
does not disturb the order.

### Independent, cheap, and genuinely surviving

`hardware-profiles/` is **data, not code, and it outlives the rewrite** (`BLUEPRINT.md §10`).
Three defects live there and nothing depends on them: **B-10** (`CPU/generic/jenova-setup` is
entirely Linux — `cpupower`, `/sys`, `numactl` — and is the only CPU-only profile), **B-20**
(`profile.conf`'s `PROFILE_*` block contradicts the `jenova.conf` beside it; informational, so sync
or delete), **B-05**'s non-CUDA half (header comments naming the wrong model).

### Not work — recorded so it is not re-raised

**The shell tree's defects die with the shell tree.** B-11 (`jenova-term`, whose only caller is
`lib/ui.lua:104`), B-27, B-28, B-29, B-35, the 33 dangling `jenova-ca` references, and
**N-34/N-35** in their entirety. **The documentation defects — B-39, and B-32/B-33/B-34 with it —
defer until the rewrite is complete**, because documentation describes a product and the product is
not finished.

**One thing does resolve, and by deletion:** `tests/test-health.sh` is the last shell health test
for the archived proxy, it shells to `python3`, and it starts no server so it aborts the suite on
line 1. **`jenova-core` covers health in-binary** — `backends health` probes the port, and five
self-test subcommands cover the rest. **Archive it and drop it from `tests/Makefile`; B-24 then dies
by subtraction the way B-23 did.** No rewrite, no `python3` in `DEPS`.

### Devdoc accuracy — hygiene, not a stage

**B-41**, **B-42**, **B-43**. The four count and invocation errors found at 13:07 were corrected in
place. What remains is `BRIEFING.md` staying honest, and moving `CONCURRENCY_ANALYSIS.md` and
`REMEDIATION_PLAN.md` — both outside `AGENTS.md`'s eleven-file table, both analysing archived
`lib/proxy.lua` in the present tense — into `ARCHIVE/`. **Archive, not delete: their diagnosis is
what motivated the rewrite.**

---

## Superseded — the 13:07 plan, kept legible

> Retained per the standing rule that a false claim is corrected in place with the original visible.
> **Read nothing below this line as current.** Its stage table put N-S6b/c/d ahead of N-S7 on the
> reasoning that "a GUI on a product that cannot be installed is a GUI on nothing" — which took the
> old shell installer as the definition of "installed" for a product that is being replaced by a
> single binary.

## ~~REMAINING WORK — the whole of it, 2026-08-31 13:07~~

**Scoped from a cross-reference of every tracker claim against the source, not from the trackers.**
The backend is done and it holds up: `N-S0 … N-S6` were checked against the files they cite and the
core matched its map on every functional claim tested. **What does not hold up is everything around
the core** — the way it is built, installed, launched and documented still describes `bin/jenova-ca`
and fourteen archived Lua modules.

> **The finding that reorders the plan.** `BRIEFING.md` says the next stage is N-S7, the GUI.
> But **`make install` does not build `jenova-core` and `install.sh` does not deploy it** (N-35), so
> the product currently cannot be installed by any documented route, and the documented route tells
> the user to run a binary that is not in `bin/` (B-39). **N-S7 would add a GUI to a product that
> cannot be delivered.** The recommendation below puts the deployment path first. **That reorders
> D-Q's "GUI last" only in the sense of inserting a backend stage ahead of it — it does not move the
> GUI earlier, and D-Y is not touched: writing the install path is not exercising it.**

### Stage order — recommended

| # | Stage | Closes | Risk | Gate |
|---|---|---|---|---|
| **1** | **N-S6b — the deployment path** *(new; N-34 + N-35 done properly)* | N-34, N-35, B-11, B-27, B-28, B-29, B-35 | low | Directive 1 |
| **2** | **N-S6c — documentation to the shipped architecture** | B-39, and with it B-32, B-33, B-34 | low | Directive 1 |
| **3** | **N-S6d — the test surface** | B-40/B-24, B-22, B-25, B-26, B-42 | low | Directive 1 · **D-AG per run** |
| **4** | **N-S7 — the GUI** | N-10, B-02's live instance, `lib/ui.lua`'s 14 dangling calls, the GTK3 dependency | **high** | Directive 1 · N-11 |
| **5** | **N-S8 — `jenova-cli`** | — | medium | Directive 1 |
| **6** | **N-S9 — retire `jca_web/`** | B-01 *(a live privacy leak until then)*, B-03, B-04 | medium | D-Z lifts here |
| **7** | **V-1 … V-6 — post-refactor acceptance on native FreeBSD** | B-06 | — | **D-Y lifts here** |

**Independent of all of the above, and cheap:** the `hardware-profiles/` data defects — **B-10**
(the only CPU-only profile, entirely Linux), **B-20** (`profile.conf` contradicts the `jenova.conf`
beside it), **B-05**'s non-CUDA half. Data files; no stage depends on them; they can land any time.

### 1 · N-S6b — the deployment path. **The product cannot currently be installed.**

Two defects, and fixing only the recorded one leaves it broken.

| | Change | Why |
|---|---|---|
| a | **`Makefile:33` — add `core` to `all`** | `all: deps llama jenova-ui web` and `install: all`, so **`make install` never builds `bin/jenova-core`**. This is N-35 and it is not in any tracker before today |
| b | **`install.sh:240,294` — deploy and symlink `jenova-core`, drop `jenova-ca`** | Both loops name a binary that is in `.devdocs/ARCHIVE/bin/` |
| c | `install.sh:7,25,450` — header, step list and next-steps text | `:450` prints *"Start the backend: `jenova-ca --daemon`"*. **The replacement is `jenova-core serve`, one command, no `--daemon`** — which is the whole point of the N-S6 restructure |
| d | `install.sh:19-26` — the header's step numbering | Documents a model-download step that does not exist and skips 4, 6, 7 (**B-29**) |
| e | **`install.sh` — decide `jenova-term`** | `lib/ui.lua:104` invokes it for the tray's "System Control" item; it is deployed by nothing (**B-11**). Either deploy it or drop the menu item at N-S7. **A USER decision, not mine** |
| f | `uninstall.sh` — 10 sites, incl. **`:85`'s `"$JENOVA_CA" stop`** | It *invokes* the archived binary, so uninstall cannot stop a running system. Also parse `--purge` (**B-27**) and remove the `jenova-model-switch` symlink `install.sh` creates |
| g | `update.sh` — 5 sites; `$SKIP_JVIM` dead code; `make` without `-C` at `:199,210` | **B-28** |
| h | `cleanup.sh:95` hint; **and the B-35 path guard** | Refuse to operate on any path that does not resolve inside `$JCA_HOME`. Disclosed at Session 004 and never done |
| i | `build-llama.sh:308` restart hint | One line |

**Acceptance, and it must not be `sh -n`.** `sh -n` is what let a syntactically perfect Linux script
survive S-6 (constraint **C-9**). The check here is a **dry enumeration**: `grep -rn 'jenova-ca'`
over `bin/ lib/ scripts/ Makefile` returns only the harmless pidfile-name sites, and
`make -n install` shows `jenova-core` being built and deployed. **Neither runs the installer** —
D-Y stands until stage 7.

### 2 · N-S6c — documentation. **22 references to a binary that no longer exists.**

`README.md` (4) · `docs/usage.md` (11) · `docs/install.md` (2) · `docs/privacy.md` (1) ·
`docs/architecture.md` (4). The README quickstart is `jenova-ca --daemon`. Separately, **eight
archived `lib/*.lua` modules are cited as live implementation** across `docs/architecture.md` and
`docs/context-and-retrieval.md` — `proxy`, `search`, `embed`, `fs_sync`, `db`, `http`, `prompts`,
`indexer_runner`.

**B-32, B-33 and B-34 are three symptoms of this and should be fixed as part of it, not separately.**
B-32's claim (*"inbound storage writes queue re-indexing"*, *"the proxy's retrieval pipeline"*) is
now describable **truthfully** for the first time, because `rag.nim` and `pipeline.nim` exist — the
prose was aspirational for `proxy.lua` and is merely mis-attributed for the core.

**One thing this stage must not quietly do:** `docs/privacy.md:43` claims the default binds
loopback. That is still true (`--lan` moves only the client port, asserted both ways in
`test_lifecycle.sh`), so it is a naming fix, not a claim retraction. **Say which sentences are
renames and which are corrections** — the B-01 lesson is that a live defect must not be reclassified
by a rewrite.

### 3 · N-S6d — the test surface

| | Item | Note |
|---|---|---|
| a | **`test-health.sh`** — B-40 | Rewrite on base `fetch(1)`, starting and stopping its own server like the other four. **Closes B-24 by subtraction rather than by adding `python3` to `DEPS`** — the S-2/S-4 pattern. It is currently the *first* line of `check` and aborts the suite |
| b | **B-22** — `test_validate_arg.sh:62` still rewrites `etc/jenova.conf` | **The highest-value cheap fix left.** Confirmed unchanged today. It is the true origin of commit `eee557e` |
| c | **B-42** — no `check` target at the repository root | Either add `check: ; @$(MAKE) -C tests check` or correct every doc that says `make check`. **The former, and then the docs become true** |
| d | B-25 — three orphans | `test_validate_arg.sh`, `test_gpu.sh`, `test_gpu_single.sh`. Both GPU tests need a `llama-cli` that `build-llama.sh` never copies, so they fail unconditionally: wire in, fix, or archive |
| e | B-26 — `download-draft-model.sh` | Wrong directory, wrong model, false closing message. A utility, not a test |

**D-AG governs every run here.** Each execution that starts a process is asked for individually,
stating what, why and for how long. Permission to run one suite is not permission to run the next.

### 4 · N-S7 — the GUI. **Unchanged in scope; now genuinely next after 1–3.**

owlkettle GTK4 + libadwaita, chat view, streaming, tray on StatusNotifierItem (**N-10**). Replaces
`jenova-ui/src/main.c` and `lib/ui.lua`, which is where **14 of the dangling `jenova-ca` calls live**
and where **B-02's last load-bearing instance** sits (`main.c:324`'s `$HOME/.jenova/ui.lock`, a
fourth spelling of the state directory).

**Two things gate it and neither is written down as a gate today:**

1. **N-11 — the dependency change.** `nim` is not in `install-dependencies.sh`'s `DEPS`, and
   `libadwaita` and `gtksourceview5` are in ports but **not installed** on this host. `make core`
   works only because a compiler is already present. **Directive 1 gates the `DEPS` edit.**
2. **owlkettle is unproven on this host**, and D-Q put it last deliberately. The mitigation named
   when that order was set is still available and still cheap: **a throwaway spike before committing
   the stage.** It does not disturb the order.

**N-21 is the one contract decision to take here, not to inherit.** Restoring a conversation revives
every message, including ones deleted individually beforehand. It is faithful to `db.restore_item`
and therefore correct for the frozen client — **the GUI need not reproduce it.**

### 5–7 · CLI, `jca_web/` retirement, acceptance

**N-S8** `jenova-cli`, a terminal agentic loop with tool execution — the one stage that adds a
feature rather than porting one. **N-S9** retires `jca_web/`; **D-Z lifts here and B-01's live
privacy leak closes with it** — until then a browser with network access contacts
`fonts.googleapis.com` on every page load. **V-1 … V-6** are the post-refactor acceptance phase and
**D-Y lifts at their gate, not before**; B-06's `gmake` naming is corrected as part of writing them
up.

### Latent items — recorded, none scheduled

**N-16** no HTTP keep-alive (revisit before the Web UI is served in anger; every response is
`Connection: close`, confirmed at `http.nim:139,152`) · **N-18** compile-time class thread counts
(`routes.nim`'s `ClassTable` is `const` — deliberately, for GC-safety across worker threads) ·
**N-13** the eventual conf-format change that stops `config.nim` shelling out to `/bin/sh` ·
**N-12**, **N-14**, **N-15** integrity-pass notes · **B-30**, which changed shape rather than
closing: `MAX_TURNS`/`MAX_ACTIONS`/`TIMEOUT` are now in `config.nim:49`'s key list, so
`jenova-core config` reports them — **and nothing acts on them.**

### Devdoc hygiene — free, and it is what makes the rest of this readable

**B-41** and **B-43**. `BRIEFING.md §5` contradicts `BRIEFING.md §1` three times over (N-S6
"outstanding", N-24 "cheap and independent", N-31 "not blocking" — all three closed);
`BRIEFING.md §1` says the tree is uncommitted when `git status --porcelain` is empty;
`ARCHITECTURE_MAPPING.md` said "eight subcommands" where thirteen exist and contradicted itself two
paragraphs apart on the test count; `Directive 6` is now cited **22 times**, not the 14 recorded.
**`CONCURRENCY_ANALYSIS.md` and `REMEDIATION_PLAN.md` are outside `AGENTS.md`'s eleven-file table
and analyse archived code in the present tense** — `REMEDIATION_PLAN.md:7-9` still publishes
"Phases 2–4 are not started" for `lib/proxy.lua`. **Archive them, do not delete: their diagnosis is
what motivated the rewrite.**

*The four items corrected in place today — the subcommand count, the two test-count paragraphs and
the `make check` invocation — are done. The rest are listed under B-41/B-43 and await Directive 1.*

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
| **N-S5a** | **Reordered in 2026-08-31.** `fs_sync` port + the four `/api/fs/*` routes | `lib/fs_sync.lua`, and **the last of `lib/proxy.lua`**. **Fixes N-27, N-20** | medium |
| **N-S5b** | `jca_rag.nim` — embeddings and search, wired to the ingest path | `lib/embed.lua`, `lib/search.lua`. **Fixes B-14, B-15** | medium |
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

---

## N-S5 — scoped 2026-08-31. **Three design questions gate it.**

Read first-hand this session: `lib/search.lua` (871 lines), `lib/embed.lua` (202),
`lib/fs_sync.lua` (454), and the `/api/fs/*` and `/api/db/*` route bodies in `lib/proxy.lua`.

### N-S5a — `fs_sync` and `/api/fs/*`, before RAG

**Why it moved ahead of RAG.** N-27: `api.nim` reproduces only the database half of `/api/db/*`.
`proxy.lua` calls `fs_sync` at ten sites inside those routes to mirror creates and deletes onto
real directories and a trash tree. **RAG indexes files, and these are the files.** Porting the
retrieval layer onto a core that never writes them would index an empty tree — a more elaborate
version of the B-15 defect N-S5 exists to fix. It is also the same module `/api/fs/*` needs, so
N-20 and N-27 are one stage.

**Surface, enumerated:** 13 `fs_sync` functions; 4 routes (`GET /api/fs/trash`,
`POST /api/fs/trash/restore`, `DELETE /api/fs/trash/empty`, `GET /api/fs/tree`); 10 call sites
inside `/api/db/*`. **This retires `lib/proxy.lua` completely** — it is the last thing holding it
alive.

**Two defects not to reproduce**, both already recorded: `get_fs_tree` forks `test -d` per entry
(B-16/B-17 — Nim stats directly, no fork), and three blocking `io.popen` sites in `fs_sync` exist
only because Lua had no threads (B-16 — the worker pool makes them ordinary blocking calls).

**Acceptance:** the filesystem assertions specified in `TESTS.md §5b`, **run against `proxy.lua`
first and then the Nim core, and compared.** `jca_web` is frozen under D-Z and must keep working
unchanged, so the standard is identical, not sensible.

### N-S5b — RAG. What the Lua implementation actually does

`search.lua` is a hybrid retriever: BM25 (`k1=1.5`, `b=0.75`) weighted **0.4**, cosine similarity
over embeddings weighted **0.6**, chunked at **300 words with 50-word overlap**, embedded in
batches of 8. `embed.lua` talks HTTP to a `llama-server --embedding` subprocess on **:8082**.

**Three structural defects in that design, found by reading it rather than by reading the
trackers.** These are why N-S5b is a redesign, not a transcription:

| # | Defect | Consequence |
|---|---|---|
| 1 | **The BM25 index is process-global memory only** — `bm25_index`, `df`, `total_docs`, `avg_dl` are module-level Lua tables, and **nothing persists them** | Every restart loses the entire keyword index. This is *why* B-15's `total_docs == 0` is so total: even with callers wired up, the index would not survive a restart |
| 2 | **The vector index is one JSON blob** at `$JENOVA_STATE/vectors.json`, read whole into memory, merged under a hard **20 MB** cap | Above the cap it silently stops merging. It is a whole-file rewrite on every save |
| 3 | **Chunk text is not persisted** — `load_vectors` sets `text = ""` with the comment *"text not persisted"* | After a restart, semantic hits can be scored but **cannot produce a snippet**. Retrieval half-works in a way that looks like a ranking problem |

**And the concurrency constraint that decides the design.** Both indexes are mutable shared state.
Under D-S there is no event loop — there are 14 worker threads. **Shared refcounted globals are not
GC-safe in Nim across threads**, which is exactly what bit `api.nim` at N-S3b (`let` → `const`) and
what the N-S2 write-once path buffer exists to avoid. A direct transcription would not compile, and
if forced to compile with `{.gcsafe.}` it would be a data race. **This is the reason the storage
question below must be answered before any code is written, not during.**

---

## The plan, rebuilt on D-AF and the 2026-08-31 inventory

> **D-AF changed the shape of everything below.** `llama-server` is the inference engine; the Nim
> core is the harness. `upstream.nim` is the primary inference path. In-process inference is kept
> as `JENOVA_INPROC=1` but is no longer the default, and **nothing new is built on it.**
>
> **This deletes work rather than adding it.** N-25, N-26 and D-W are closed by the ruling. FIM
> becomes route classification instead of an implementation on `llama_vocab_fim_*`.

### Stage N-S4c — invert the inference default *(new, small, first)*

1. `JENOVA_INPROC` default flips from `1` to `0` in `src/jenova_core.nim:78`.
2. Route `/infill` to the completion class in `routes.nim` so it reaches `upstream.forward` —
   **this is the whole of the USER's Neovim FIM requirement** under D-AF.
3. Route `/v1/health` to the health class; it currently 400s because the completion class tries to
   parse a body.
4. The core must **supervise** `llama-server` rather than assume it is up — this is the piece D-N's
   single-binary ruling deferred and N-S6 owns. Until then a 502 naming the unreachable upstream is
   the honest answer, which `upstream.nim` already gives.
5. `llama.nim` and `inference.nim` stay compiled and reachable. **No new work lands on them.**

**Acceptance:** with `llama-server` up, `/v1/chat/completions`, `/completion` and `/infill` stream
through the proxy; sampling parameters that N-25 recorded as ignored now take effect, because
`llama-server` parses them. That last check is the one that proves the ruling did what it claims.



The inventory changed the shape of the remaining work. **The surface is nearly reproduced; the
behaviour is not.** What remains is not "finish porting modules" — it is one missing surface
(N-29), one missing pipeline (N-30), and the RAG engine that feeds it (N-S5b).

### Stage N-S5a-2 — finish the surface (N-29). *Unblocks retiring `lib/proxy.lua`.*

| Item | Detail | Decided by |
|---|---|---|
| `/api/storage/*` — 4 routes | **Live**, `storage.service.ts` calls all four. `POST` save, `GET` fetch (`application/octet-stream`), `GET /api/storage/` list (recursive, depth 4, skipping dotfiles/`node_modules`/`build`), `DELETE` trash | Investigation, 2026-08-31 |
| `fs_sync.trash_path` | The 13th function; `DELETE /api/storage/<path>` needs it | — |
| `/api/workspaces` | **Do not port.** No caller in `jca_web/src`; `tests/proxy-concurrency/README.md:34` records it never worked. Subtract it (D-D) | Investigation |
| `/infill` | Classify to the completion class. **Required — the USER's Neovim configuration depends on FIM** | USER, 2026-08-31 |
| `/v1/health` | Currently 400 — classified to completion, which then fails to parse a body. Route it to the health class | — |

**Path containment is the risk here, not the routes.** `/api/storage/*` takes a client-supplied
path and reads, writes and deletes under `$JENOVA_WORKSPACES`. `proxy.lua` guards with a `..` check
plus `resolve_safe_path`. The Nim port must contain by resolved real path, not by string matching,
and it must be asserted — `http.resolveStatic` already has the pattern.

### Stage N-S5b — RAG, rebuilt per Q-24 and Q-25

Both indexes in SQLite (**FTS5 + BLOB**), embeddings **in-process on CPU**. This kills all three
`search.lua` storage defects and the GC-safety problem together. **First action is the FTS5 probe
against the native build** — if absent, fall back to Q-24 option B and say so (D-AB).
`llama.LoadSpec` needs a per-context device override so the embedding context requests CPU while
the agent context keeps its Vulkan devices; **C-14 is the standing warning that a new binding must
honour every configured value.**

### Stage N-S5c — the completion pipeline (N-30). **The stage that makes it Jenova.**

Seven behaviours, in dependency order. RAG (N-S5b) must land first because steps 2–3 consume it.

1. **Intent detection** — four prefixes, stripped from the message after matching.
2. **RAG retrieval** — per-intent limits; the large-payload query rewrite (basename + trailing
   prose when a `Path:` is embedded and the message exceeds 2000 chars).
3. **RAG injection** — `--- REPOSITORY CONTEXT ---`, `[n] path`, snippets truncated at 1000 chars.
4. **Web search** — DuckDuckGo HTML with an Instant Answer fallback, via `fetch`. Two distinct
   failure messages, because "no results" and "no HTTPS client" tell the model different things.
5. **Persona injection** — three modes, and they are not interchangeable: agent (never override a
   client system prompt; inject the CORE MANDATE only when absent), conversational (persona-first),
   and no-intent (persona prepended, RAG appended).
6. **Tool stripping** — `visual` and `websearch` clear `tools` and set `tool_choice = "none"`.
7. **Cache intercept** — SHA-256 of the **rewritten** body, `X-Cache: HIT` on a hit.

**Fold N-25 in here.** Sampling parameters are ignored today because the sampler chain is built
once at load; this stage rebuilds the request path and is where per-request sampling belongs.

**Note the ordering trap in step 7:** the key is the SHA-256 of the body *after* rewriting, so
caching must sit at the end of the pipeline. Hashing the client's original body would produce a
different key and silently break cache compatibility with existing entries.

### Then

**N-S6** lifecycle parity — deletes `bin/jenova-ca`, closing B-12, B-13 and N-23 · **N-S7** GUI ·
**N-S8** CLI · **N-S9** retires `jca_web/`, closing B-01, B-03, B-04.

**Cheap and independent of all of the above:** N-24 (`jenova.local.conf` names a `Vulkan2` that does
not exist), B-22 (a test that rewrites `etc/jenova.conf`), N-26 (no cancellation on disconnect for
non-streaming requests).

---

## N-28 — a guard so the core cannot write to `~/JCA`. **USER decision, nothing written.**

**D-AC prohibits anything that affects `~/JCA`.** The binary currently defaults into it
(`paths.nim:71`), and N-S5a widened what a bare run does there from one database file to
directories, git repos, file writes and trash moves. The test suites are contained; the binary is
not, and the gap is closed by a guard rather than by remembering — remembering is what failed.

**Q-27 — which guard?**

| | Option | For | Against |
|---|---|---|---|
| **A** | **Refuse to start when `JCA_HOME` is unset.** No default at all; the caller must name a home | Impossible to touch `~/JCA` by accident, because nothing is implicit. Smallest change — one guard in `paths.resolve` | Changes behaviour for the eventual real deployment, which *will* want the default. Needs removing or inverting at N-S6 |
| **B** | **Refuse when the resolved `JCA_HOME` is the deployed one**, unless `JENOVA_ALLOW_DEPLOYED=1` is set | Keeps the default working for the real product; blocks exactly the case D-AC names; the override documents intent at the call site | Needs a definition of "the deployed one" — simplest is `$HOME/JCA` literally, which is what `jenova-conf.sh:39` uses |
| **C** | **A build-time flag** — `-d:jenovaRewrite` compiles a core that refuses any `JCA_HOME` under `$HOME` | Cannot be bypassed at runtime; disappears cleanly when the flag is dropped at N-S6 | Two binaries with different behaviour is its own hazard, and the one you test is not the one you ship |
| **D** | **No code change; rely on the suites' `mktemp` isolation** | Nothing to unwind later | **This is the status quo that already failed.** A bare `jenova-core serve` typed to check something still writes to the protected tree |

**Recommendation: B**, with the deployed home defined as `$HOME/JCA` to match `lib/jenova-conf.sh:39`.
It protects the exact folder named in D-AC, survives into the real product instead of needing to be
unwound at N-S6, and makes any deliberate exception visible in the command that requests it.

**Not written. Awaiting the USER.**

---

### The three questions — all USER decisions

**Q-24 — Where do the two indexes live?**

| | Option | For | Against |
|---|---|---|---|
| **A** | **SQLite, both** — BM25 via FTS5, vectors in a BLOB table | One store, one lifecycle, already per-thread and concurrent (N-S2), survives restart, no cap, snippets recoverable. Kills defects 1–3 **and** the GC-safety problem in one move | Needs FTS5 in the linked `libsqlite3` — **unverified, and under D-AB I will not assert it from a Linux-side check**; must be confirmed by the native build |
| **B** | **SQLite for vectors, in-memory BM25 rebuilt at startup** | No FTS5 dependency | Startup cost proportional to corpus; keeps defect 1's rebuild; still needs a thread-safe in-memory structure |
| **C** | **Port the files as-is** (`vectors.json` + in-memory BM25) | Smallest diff, bit-identical behaviour | Carries all three defects forward and hits the GC-safety wall immediately |

**Recommendation: A**, contingent on FTS5 being present in the native build — which is a check, not
an assumption. Fallback to B if absent.

**~~Q-25~~ — WITHDRAWN 2026-08-31. It was never an open question.**

**D-E settled the ports** (":8080 is the port; :8081/:8082 internal") **and the embedding path was
already built** before I asked: `routes.nim:38,54,87` define the `rcEmbed` class and classify
`/embed*` to it, `server.nim:200-201` forwards to the embedding server, `jenova_core.nim:108` reads
its port. **Embeddings go to :8082 through `upstream.nim`. They already do.**

I invented this question while scoping N-S5b without checking the standing rulings or the code —
both of which answered it — and then re-asked it as Q-28 when D-AF changed its premise. **Two
rounds of decision-making on something already compiled into the binary.** The options table below
is retained only so the error stays legible.

**Superseded original question:**

N-S4 proved direct `libllama` linkage, so the `:8082` subprocess is no longer forced.

| | Option | For | Against |
|---|---|---|---|
| **A** | **Second in-process `llama_context` for the embedding model** | One process (D-N), no HTTP hop, no port, no lifecycle to supervise; `upstream.nim`'s embed path and the whole `:8082` surface disappear | **VRAM.** This is a 4 GB GTX 1650 Ti already running the agent model at `CTX_SIZE=32768` across Vulkan0+Vulkan1. Two contexts may not fit |
| **B** | **Keep `llama-server --embedding` on :8082**, proxied as today | Known-working; embedding memory is a separate process the OS can page | Contradicts the single-binary direction; keeps a subprocess N-S6 must supervise |
| **C** | **In-process, CPU-only for embeddings** | No VRAM cost at all; embedding is throughput-tolerant background work | Slower; needs a per-context device override the `LoadSpec` does not currently carry |

**No recommendation — this is a hardware judgement about your machine, and C-14 is the standing
reminder of what happens when I guess at its limits.** C looks attractive on paper because
`embed.lua` already disables Vulkan for the embed server (`GGML_VULKAN_DISABLE=1`), which suggests
the existing deployment reached the same conclusion — but that is inference from one line, not
evidence, and it is your call.

**Q-26 — Does the ingest path index automatically, or on demand?**

B-15's root cause is that `index_dir` and `reindex_file` have **zero callers repo-wide**. Wiring
them up is the fix, but *where* is a product decision: index on every `fs_sync` write (fresh, but
embedding work on the write path), on an explicit request, or on a periodic sweep. **Recommendation:
index on write, queued to a background worker thread** — never on the inference thread (C-13) and
never inline in the request. But the trade-off is yours.

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

**Why early.** It is self-contained, and it removes an unstated `pkg install bash` that no install
path mentions — a dependency FreeBSD base makes unnecessary. *(Corrected 2026-08-31: this
previously read "removes a GPL-3.0 dependency (AGENTS.md rule 2)". **D-X** rules that clause dead
letter — the project is AGPL-3.0 and copyleft is permitted. The removal was always justified as
subtraction of an unnecessary dependency, never as licence compliance.)*

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
