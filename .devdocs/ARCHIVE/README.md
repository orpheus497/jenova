# ARCHIVE

Components retired from the product tree. **Nothing here is deleted** — it is moved, so the
implementation it was replaced by can be checked against it, and so a decision can be reversed
without going through git history.

Retained under Directive 3: features are never removed without explicit instruction. Everything
below was moved on the USER's instruction after its replacement was built and tested.

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
| `proxy-concurrency/` | The acceptance harness for `proxy.lua`'s event loop. **B-23** (the fd assertion is vacuous on FreeBSD because `/proc` is not mounted) and **B-24** (undeclared `python3` dependency) die with it |

Replaced by `test_api_db.sh` (23), `test_api_fs.sh` (46), `test_routes.sh` (13),
`test_lifecycle.sh` (31), plus `rag-selftest`, `pipeline-selftest`, `sha256-selftest`,
`db-selftest` and `serve-selftest`.

---

## What deliberately stayed in `lib/`

| Kept | Why |
|---|---|
| `detect-env.sh`, `jenova-conf.sh`, `jenova-model.sh` | **Load-bearing.** `config.nim` evaluates `etc/jenova.conf` with `/bin/sh`, and that file sources `jenova-model.sh` for model discovery. Archiving these would break configuration resolution in the Nim core |
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
