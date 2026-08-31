# ARCHIVE

Components retired from the product tree. **Nothing here is deleted** — it is moved, so the
implementation it was replaced by can be checked against it, and so a decision can be reversed
without going through git history.

Retained under Directive 3: features are never removed without explicit instruction. Everything
below was moved on the USER's instruction after its replacement was built and tested.

---

## 2026-08-31 — the C tray, the Lua UI and the last shell scripts (N-S7)

**This move completes the total conversion (D-AI): no Lua, no C, and no project
shell script is executed by the running product.** Verified by enumeration after
the move, not asserted — `find` reports zero `*.lua` and zero `*.c`/`*.h` outside
`.devdocs/`, `external/` and `jca_web/`.

### `jenova-ui/` — the C tray and ncurses TUI

| Archived | Replaced by | Closes |
|---|---|---|
| `src/main.c` (695 lines) | `src/jenova/gui.nim` + `src/jenova/tray.nim` | **B-02's last load-bearing instance** — `main.c:324`'s `$HOME/.jenova/ui.lock`, a fourth spelling of the state directory |
| `Makefile` | the `gui` target in the root `Makefile` | The GTK3 / libappindicator / LuaJIT / ncurses dependency set |

### `lib/` and `bin/`

| Archived | Replaced by | Closes |
|---|---|---|
| `ui.lua` (257 lines) | `gui.nim`'s control surface and `trayMenu` | The last Lua in the product |
| `jenova-model.sh` | `models.nim` `discover` | **The last shell script the core relied on** (N-36) |
| `bin/jenova-model-switch` | `models.nim` `switchModel`, and `jenova-core models switch` | N-37 |
| `bin/jenova-term` | nothing — it existed only to open a terminal for the TUI | **B-11**, which was never a real defect once its only caller went |
| `bin/jenova-tui` | the GUI window (**D-AL**) | — |
| `bin/jenova` (shell launcher, kept as `jenova.sh`) | `bin/jenova`, now the compiled desktop application | — |

**`switchModel` was proven equivalent before the original was archived**, not
after: the same scratch tree was switched by both implementations and the
resulting `models/agent` compared, including relative symlink targets. Identical.
`tests/test_models.sh` pins it at 15 assertions.

### `tests/test-health.sh`

Archived under **D-AH**. It was the last shell health test for the archived Lua
proxy: it shelled to `python3` — which `make deps` does not install — and it
**started no server**, so it aborted `make check` on its first line unless
something happened to be listening. `jenova-core` covers health in-binary
(`backends health` probes the port; five self-test subcommands cover the rest).
**B-24 dies with it, by subtraction rather than by adding a dependency.**

### What stayed, and why

`lib/detect-env.sh` and `lib/jenova-conf.sh` remain — **not because the core
needs them**, which was the long-standing and incorrect claim, but because
`scripts/*.sh` and `hardware-profiles/detect-hardware.sh` still call them. They
are setup-time tooling and go with that tree at N-S9.

---

## 2026-08-31 — the Lua runtime and `bin/jenova-ca` (N-33, after N-S6)

Superseded by `src/jenova/*.nim`. Moved once the Nim core reached **full parity with
`bin/jenova-ca`** at N-S6 and every route and completion behaviour of `lib/proxy.lua` was
reproduced and tested.

### `lib/` — 14 modules

| Archived | Replaced by | Defects that die with it |
|---|---|---|
| `proxy.lua` | `server.nim`, `routes.nim`, `api.nim`, `upstream.nim`, `pipeline.nim` | **B-19** unreachable header timeout · **B-18** hot-path defects |
| `search.lua` | `rag.nim` | **B-15** RAG inert — `index_dir`/`reindex_file` had zero callers |
| `embed.lua` | `rag.nim` (embeddings via :8082) | **B-14** `init()` returned true without setting `initialized`, so `/health` reported embeddings alive while every call failed |
| `fs_sync.lua` | `fssync.nim` | **B-16** blocking `io.popen` · **B-17** fork storms |
| `db.lua` | `db.nim` | **B-18** prepare-and-finalize per call |
| `http.lua` | `http.nim` | — |
| `json.lua` | `std/json` | — |
| `sha256.lua` | `sha256.nim` (asserted against FIPS 180-4 vectors) | — |
| `prompts.lua` | `prompts.nim` (verbatim) | — |
| `git.lua` | `fssync.nim` (argument vector, not a quoted shell string) | — |
| `daemon.lua` | `lifecycle.nim` | — |
| `ffi_defs.lua` | `llama.nim` bound through `llama.h` | The whole ABI-mirroring defect class S-1 existed to remove |
| `healthcheck.lua` | `lifecycle.healthy` | — |
| `indexer_runner.lua` | `rag.nim` | — |

**`daemon.lua`, `ffi_defs.lua`, `healthcheck.lua` and `indexer_runner.lua` are here because their
only callers are here** — nothing outside this directory required them once the four above moved.
That was checked by reverse-dependency search, not assumed.

### `bin/jenova-ca`

Superseded at N-S6. The Nim core has every one of its verbs and flags —
`start stop status restart --port --llama-port --embed-port --watch --lan` — except `--daemon`,
which is **deliberately absent**: self-daemonising is an anti-pattern, D-H deferred service
integration to this cut-over, and N-S7's tray owns the process.

**B-13 dies with it** — `PROXY_PID` declared at `:13` and never assigned, so `--daemon` started no
`:8080`. In the Nim core the HTTP server and the backend supervisor are one process, so that
disagreement cannot exist.

### `tests/`

| Archived | Why |
|---|---|
| `test-launcher.sh` | Every check targets `jenova-ca` and `proxy.lua` |
| `test_bin_jenova.sh` | Validates `bin/jenova` against a running `jenova-ca`. Orphaned (B-25) |
| `proxy-concurrency/` | The acceptance harness for `proxy.lua`'s event loop. **B-23** (the fd assertion is vacuous on FreeBSD because `/proc` is not mounted) dies with it. ~~**B-24** (undeclared `python3` dependency) dies with it~~ — **RETRACTED 2026-08-31 13:07, and the retraction is the instructive part** |

> **B-24 was closed on half its evidence.** It cited **`tests/test-health.sh:14` *and*** the
> `proxy-concurrency` harness. Archiving the harness removed one of the two and the defect was
> marked dead. **`tests/test-health.sh` is still in `tests/` and still requires `python3`**, which
> is still absent from `install-dependencies.sh`'s `DEPS` — and it is the **first line** of
> `tests/Makefile`'s `check` target. Reopened as **B-40** in `TODOS.md §6`, along with a second
> defect in the same file found at the same time: **it starts no server**, so the suite aborts on
> line 1 unless something is already listening.
>
> **The lesson for future archival: a defect dies with a file only if every site in its evidence
> went with that file.** Check the evidence list, not the headline.

Replaced by `test_api_db.sh` (23), `test_api_fs.sh` (46), `test_routes.sh` (13),
`test_lifecycle.sh` (31), plus `rag-selftest`, `pipeline-selftest`, `sha256-selftest`,
`db-selftest` and `serve-selftest`.

---

## What deliberately stayed in `lib/`

| Kept | Why |
|---|---|
| ~~`detect-env.sh`, `jenova-conf.sh`,~~ `jenova-model.sh` | **CORRECTED 2026-08-31 by reverse-dependency search: only `jenova-model.sh` is load-bearing.** `config.nim` evaluates `etc/jenova.conf` with `/bin/sh`, and that file sources **`jenova-model.sh` alone**. **No `.nim` file references `detect-env.sh` or `jenova-conf.sh`** — their callers are `scripts/*.sh` and `detect-hardware.sh`, setup-time tooling the running core never invokes. They stayed for the shell tree's sake, not the core's |
| `ui.lua` | The GTK3 tray, called from `jenova-ui/src/main.c`. Replaced at N-S7, not before |

---

## Known dangling references — **disclosed, not hidden**

Moving these leaves references behind. None affects `jenova-core`, which builds and passes every
suite with `lib/` reduced to four files. **None affects the USER's deployment either**, which runs
from its own copy under `~/JCA` (D-AE).

| Site | Effect |
|---|---|
| `lib/ui.lua:69,109,111` | The tray spawns `bin/jenova-ca`. **The GTK3 tray path is now inert in the source tree** until N-S7 replaces it |
| `scripts/install.sh:240` | Deploys `jenova-ca` in its symlink loop — will not find it. **The install path needs updating to deploy `jenova-core`**, which is N-S6 follow-through not yet done |
| `scripts/{update,uninstall,cleanup,build-llama}.sh` | Reference it in restart hints, symlink cleanup and warnings |
| `lib/jenova-conf.sh:44` | `PID_FILE` still named `jenova-ca.pid`. Harmless — a filename |
| `tests/test_gpu.sh` | Orphaned already (B-25) |

**The install path being broken is the one that matters.** It is recorded rather than patched
because rewiring `install.sh` to deploy the Nim core is its own change, and D-Y prohibits exercising
the install path during the rewrite anyway.

---

## Earlier archive (2026-08-28, Session 002)

`docs/`, `scripts/` and `root/` hold the documentation consolidation and the superseded installer
scripts. **Those 17 files are tracked in git but absent from the working tree** — a pre-existing
state, not created by the 2026-08-31 move. `git show HEAD:.devdocs/ARCHIVE/<path>` recovers any of
them.
