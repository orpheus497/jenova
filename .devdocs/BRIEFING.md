# BRIEFING

**Last updated:** 2026-08-31 14:13
**Branch:** `bsd`
**Phase:** 3 — Execution. **N-S7 complete. The total-conversion gate is passed.**

---

## 1. Current state

| Item | Value |
|---|---|
| Architecture | **`llama-server` is the inference engine; the Nim core is the harness around it (D-AF).** Never a standalone — this is permanent |
| Stage | **N-S0 … N-S7 COMPLETE.** Config, database, threaded server, the full `/api/*` surface, filesystem mirror, RAG, the completion pipeline, backend lifecycle — and now **the desktop application**: a GTK4/libadwaita window, a StatusNotifierItem tray implemented over D-Bus, and model discovery/switching in Nim |
| **Total conversion** | **PASSED, by enumeration.** Zero `*.lua` and zero `*.c`/`*.h` outside `.devdocs/`, `external/` and `jca_web/`. **No project shell script is executed by the running product** |
| Binaries | **Two, one program.** `bin/jenova` — the desktop application (`make gui`). `bin/jenova-core` — the headless server (`make core`). Split because **N-7 requires LAN mode to serve whether or not the GUI runs**, so the server must build where there is no GTK. Both link the same core modules |
| Next | **N-S9** — retire `jca_web/`, closing B-01's live privacy leak, B-03 and B-04, and taking the shell installer tree with it. **Then N-S8**, the CLI (D-AI put it last, behind the gate) |
| Tests | `test_api_db` 23 · `test_api_fs` 46 · `test_routes` 13 · `test_lifecycle` 31 · **`test_models` 15** · `pipeline-selftest` 15 · `rag-selftest` 7 · `sha256-selftest` 4 · `db-selftest` · `serve-selftest` — **all PASS**. **`make check` now exists at the repository root** (B-42), and builds are warning-free |
| Runtime home | **`$HOME/Jenova`.** `~/JCA` is the legacy deployment and is permanently untouchable (D-AE) |
| **Unverified** | **The window has never been displayed and the tray has never been seen by a watcher.** Both build, link and pass their non-graphical paths — but D-AG reserves each process start to the USER, and a tray whose D-Bus signature is wrong shows *no icon* rather than an error. **This is exactly the kind of claim that must not be made from reading** |
| Commits | The USER commits. HEAD was `c5af653` at the start of this stage; everything since is uncommitted (C-11) |

## 2. Rulings in force — not to be reopened

| Ruling | Decision |
|---|---|
| **D-AL** | **The ncurses TUI is replaced by the GUI window.** The explicit Directive 3 instruction to remove it. `bin/jenova-term` and `bin/jenova-tui` go with it |
| **D-AK** | **owlkettle + libadwaita + gtksourceview5 approved.** The full N-S7 toolkit D-P named |
| **D-AJ** | **The tray is retained, as StatusNotifierItem over D-Bus in Nim.** Chosen with its cost stated: the largest unbudgeted unit of work in the rewrite |
| **D-AI** | **`jenova-cli` is last, behind the total-conversion gate.** "Relied on by the running product" is the test, not "present in the tree" |
| **D-AH** | **Do not rebuild the program being replaced.** The shell installer, the shell-era docs and the shell test scripts are scaffolding around a system that goes. **N-34 and N-35 are withdrawn as work; B-39 is deferred** |
| **D-AG** | **Testing is per-instance and permissioned.** Permission to test once is never permission to test again |
| **D-AF** | **`llama-server` is the inference engine. Jenova is the harness.** In-process inference is retained behind `JENOVA_INPROC=1` but nothing new is built on it |
| **D-AE / D-AD / D-AC** | `~/JCA` permanently off limits; the runtime home is `$HOME/Jenova`; `paths.resolve` refuses the legacy tree unless `JENOVA_ALLOW_DEPLOYED=1` |
| **D-AB** | A detection is not evidence until its mechanism is shown not to route through the Linuxulator — **state the mechanism with the claim** |
| **D-Z / D-Y** | `jca_web/` frozen until N-S9 · no deployment or install *testing* until the rewrite is complete |
| **D-X** | AGPL-3.0; copyleft dependencies permitted. Closed permanently |
| **D-S / D-T / D-U** | Worker-thread pool, not `asyncdispatch`. Two-device personal product. `static:4 health:2 api:3 completion:3 embed:1 debug:1` |
| **C-11** | No git writes, ever |

## 3. What the product is today

**`bin/jenova-core`** — the headless server. `/health`, `/v1/health`, `/api/db/*`, `/api/fs/*`,
`/api/storage/*`, static assets, and `/v1/chat/completions`, `/completion`, `/infill`, `/embed*`
proxied to `llama-server` and the embedding server. Every chat request is rewritten first: intent
detected and stripped, RAG injected, web search run, a persona chosen, tools stripped, and the cache
consulted on the **rewritten** body's key. `serve` brings up the HTTP server *and* both backends in
one command, with a watchdog thread at 30 s / 3 failures / 60 s cooldown.

**`bin/jenova`** — the desktop application. Chat with streaming; backend start/stop/restart; model
switching; the LAN toggle and its persisted state; a 3 s status poll; and the tray. **Chat goes over
HTTP to `127.0.0.1:$PORT` deliberately**, so the desktop client exercises the same pipeline the Web
UI does and a bug cannot appear in one and not the other. Control actions call `lifecycle`
in-process.

**`lib/` holds two shell modules and the core needs neither** — they serve `scripts/*.sh` and
`detect-hardware.sh`, and leave with that tree at N-S9.

## 4. What the core still executes, and why the gate holds

| Executes | Standing |
|---|---|
| `/bin/sh` | Evaluates the shell-format **config files**. Configs are exempt by the USER's own parenthetical; `/bin/sh` is FreeBSD base |
| `llama-server` via `execv` | The inference engine (D-AF). Not a script |
| `git` | A declared dependency, invoked with an argument vector |
| `fetch` | FreeBSD base HTTPS client — chosen over linking OpenSSL |
| `xdg-open`, `route`, `ifconfig` | Base/desktop tools, for opening a browser and reading the LAN address |

**No project shell script is among them.** `lib/jenova-model.sh` was the last, and `models.nim`
replaced it — proven equivalent against the original on the same scratch trees before it was
archived.

## 5. Outstanding

**1. Run the window and the tray.** The one thing N-S7 cannot claim. D-AG gates it.

**2. N-S9 — retire `jca_web/`.** D-Z lifts; **B-01's live privacy leak closes** (a browser contacts
`fonts.googleapis.com` on every page load until then), with B-03 and B-04. The shell
installer/updater/uninstaller go with it, and deployment of the single binary is settled once, then.

**3. N-S8 — `jenova-cli`.** The added tool, after the gate (D-AI).

**Independent and cheap, genuinely surviving:** `hardware-profiles/` is data and outlives the
rewrite — **B-10** (the only CPU-only profile, entirely Linux), **B-20** (`profile.conf`
contradicts its `jenova.conf`), **B-05**'s non-CUDA half. **B-22** (`test_validate_arg.sh` still
rewrites `etc/jenova.conf`) is the highest-value cheap fix left in the suite.

**Not work (D-AH):** the shell tree's defects die with the shell tree — B-27, B-28, B-29, B-35, the
dangling `jenova-ca` references, **N-34 and N-35 entirely**. Documentation (**B-39**, with
B-32/33/34) defers until the rewrite is complete.

**Disclosed:** `gtksourceview5` is installed under D-AK and **not yet consumed** — code blocks
render as plain text until the chat view uses it.

## 6. Standing process notes

- **Enumerate, do not assert.** Counts and completion claims get checked against the thing itself.
- **Cross-reference the devdocs against the codebase; never treat them as truth.** The claim that
  all three `lib/*.sh` modules were load-bearing survived in three files and was wrong in two thirds.
- **A stage that archives files must re-read what points at them.**
- **Prove a new suite can fail.** Two suites have reported PASS while asserting nothing.
- **A ruling records only what the USER said.** Any inference drawn from it is a separate question.
- **C-11:** no git writes. **D-AB:** state the mechanism. **D-AG:** every process start is asked for.
