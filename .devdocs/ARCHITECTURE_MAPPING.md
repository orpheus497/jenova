# ARCHITECTURE MAPPING

File-by-file map of the codebase: what lives where, and why. Mandated by `AGENTS.md`
§ WORKSPACE ARCHITECTURE. Update whenever a file is added, removed or relocated.

**Created:** 2026-08-28 (Session 004). This file was mandated from the outset and did not exist
for Sessions 001–003 — including Session 001, which moved or deleted 31 files. See
`DECISIONS_LOG.md` C-10.

> **Provenance.** Every entry below is first-hand: each file was enumerated on disk this session
> and its role taken from its own header comment, its opening lines, or `file(1)`. Where a role
> could not be established first-hand it is marked **`(unread)`** rather than guessed —
> per Directive 6, an invented description is a fabrication.
>
> `jca_web/src/` is mapped **to directory level only**. A full read of that tree has been
> outstanding since Session 003 and is not claimed here.

---

## 1. Root

| Path | Role |
|---|---|
| `AGENTS.md` | Governance. The only process document permitted outside `.devdocs/` (Directive 4) |
| `Makefile` | Top-level build/install/verify entry points; builds with base `make(1)` |
| `README.md` | User-facing entry document |
| `LICENSE`, `NOTICE`, `UPSTREAM-COPYRIGHT` | Licensing; upstream attribution |
| `.clangd.example` | Editor config template for the C sources |
| `.gitmodules` | Declares `external/` submodules |
| `.gitignore` | Excludes build artifacts, incl. `/bin/jenova-ui` and `/jenova-ui/jenova-ui` |
| `.coderabbit.yaml`, `.jules/`, `.vscode/`, `.system/` | Third-party tooling config |
| `proxy.log` | Runtime artifact in the source root. Untracked and gitignored (`*.log`), so not committed — but the proxy writes it here rather than to `$LOG_DIR`, which is where `cleanup.sh` looks. See `TODOS.md` B-37 |

## 1a. `src/` — the Nim core (Plan B, ruling D-L)

New tree, created 2026-08-28 at stage N-S0. Grows as `lib/`, `bin/` and `scripts/` shrink.

| Path | Role |
|---|---|
| `src/jenova_core.nim` | Entry point for `jenova-core`. Carries the FreeBSD-only compile guard (`{.error.}` when `freebsd` is undefined), mirroring the `#error` in `main.c`. **Eight subcommands** (corrected 2026-08-31, was listed as three): `version`, `paths`, `config`, `db-init`, `db-selftest`, `serve`, `llama-selftest`, `serve-selftest`. `JENOVA_INPROC=0` reverts completions to proxying `llama-server` |
| `src/jenova/paths.nim` | Layout detection and runtime path resolution — replaces the path half of `lib/jenova-conf.sh`. Every path derives from one place, so no module re-derives one from a possibly-unset variable (the B-07 defect class) |
| `src/jenova/server.nim` | The HTTP server, replacing `lib/proxy.lua`. **A fixed pool of worker threads each block in `accept(2)` on one shared listening socket**; each connection is served start-to-finish on its own thread. No shared event loop exists to stall. `/debug/*` endpoints are off unless explicitly enabled |
| `src/jenova/inference.nim` | The inference worker — **one dedicated thread that owns the llama context and is the only thread that ever touches it** (D-W: serial). Takes ownership of the client socket so the HTTP worker is freed immediately rather than sitting through a generation. Chat templating happens here, because it needs the loaded model |
| `src/jenova/llama.nim` | Direct binding to `libllama`, replacing the `llama-server` subprocess. **Bound through `llama.h` itself, not by mirroring the ABI** — Nim compiles to C, so the C compiler owns every struct layout and a moved field is a compile error rather than a wrong pointer. This is the defect class S-1 deleted `ffi_defs.lua`'s Linux arm to remove |
| `src/jenova/api.nim` | The `/api/db/*` routes, replacing `lib/proxy.lua:687-1005`. Seven entity tables described **as data** and served by generic handlers, rather than twenty hand-written routes. Soft deletes throughout; set-based cascades; declared integer columns so timestamps stay JSON numbers. The entity table is `const`, not `let`, because a shared refcounted global is not GC-safe across worker threads. **Incomplete — see N-27 (2026-08-31):** `proxy.lua` calls `fs_sync` at ten sites *inside these same routes* to mirror creates and deletes onto the filesystem and a trash tree; `api.nim` has none of it. **Closed 2026-08-31 at N-S5a** — the ten mirroring call sites and the four `/api/fs/*` routes are now here, covered by `tests/test_api_fs.sh` |
| `src/jenova/fssync.nim` | The filesystem mirror behind `/api/db/*` and the `/api/fs/*` routes, replacing `lib/fs_sync.lua`. Every workspace, project, folder, note and asset has a real counterpart under `$JENOVA_WORKSPACES`; deletes move into a trash tree beside a `.metadata.json` sidecar rather than unlinking, which is what makes restore possible. **This is the half of the contract `api.nim` was missing (N-27)** — and it is load-bearing for RAG, which indexes these files. Path layout, `<epoch>_<name>` trash naming and sidecar shape are reproduced exactly, because the frozen client reads them. Three `find`/`test -d`/`rm -rf` fork storms replaced with native walks (B-16, B-17); `git` takes an argument vector, not a quoted shell string |
| `src/jenova/routes.nim` | Route classification and the per-class thread table. Six classes — static, health, api, completion, embed, debug — each with its own queue and threads. **Sized for a two-device personal product (D-T), 14 handler threads total** |
| `src/jenova/upstream.nim` | Streaming reverse proxy to `llama-server` (:8081) and the embedding server (:8082), replacing the forwarding half of `lib/proxy.lua`. Verbatim byte relay with partial-write handling, so SSE reaches the client as the model produces it |
| `src/jenova/http.nim` | HTTP/1.1 request parsing and response writing over blocking sockets, replacing `lib/http.lua`. Blocking is deliberate — one connection per thread. Includes SSE framing and static-path containment |
| `src/jenova/serverselftest.nim` | Evidence the server does not serialize: measures SSE inter-event gaps idle, then again while other connections are inside real SQLite work, and compares |
| `src/jenova/db.nim` | SQLite persistence, replacing `lib/db.lua`. Binds `libsqlite3` directly (no new package dependency). **One connection per thread** in a threadvar — no shared handle, no global lock. WAL, `busy_timeout`, per-connection prepared-statement cache (fixes B-18's prepare-and-finalize-per-call). `SQLITE_OPEN_NOMUTEX`, valid only because a handle never leaves its thread |
| `src/jenova/dbselftest.nim` | Evidence that the layer is concurrent rather than merely described as such. Runs a writer against four readers and measures **time-window overlap** — completion alone would prove nothing, since serialized work also completes |
| `src/jenova/config.nim` | Configuration loading with **one precedence rule**: builtin < `etc/jenova.conf` < `etc/jenova.local.conf` < environment. **Fixes B-12 in the Nim core.** Evaluates the conf files with `/bin/sh` rather than parsing them, because they are shell — with a guard clause, a layout branch and a `.` of `lib/jenova-model.sh`. Temporary shell dependency, lasting until the conf format itself changes |
| `jenova_core.nimble` (root) | Package metadata and dependency declaration. `AGPL-3.0-or-later`. `namedBin` keeps nimble's output path identical to the Makefile's |
| `bin/jenova-core` | Build artifact. FreeBSD ELF, untracked and gitignored |

Built by `make core`, which probes `PATH` then `/usr/local/nim/bin` — the FreeBSD `lang/nim` port
does not install onto the default `PATH`.

## 2. `bin/` — user-facing launchers

All POSIX `sh` (verified `file(1)`), per ruling D-A. Six are deployed and symlinked by
`install.sh:240`; `jenova-term` is not (B-11).

| File | Role |
|---|---|
| `jenova` | Full-environment launcher — starts the Jenova UI |
| `jenova-ca` | **Central orchestrator.** Launches `llama-server` + the Intelligence Proxy; owns `start`/`stop`/`status`/`--daemon`. Sources `detect-env.sh` → `jenova-conf.sh` → `jenova-model.sh` → `etc/jenova.conf` (`:44-48`) — the order that inverts the config hierarchy (B-12) |
| `jenova-model-switch` | Switches the active agent model by symlink |
| `jenova-swap-mount` | Swap-backed memory filesystem for models. FreeBSD-native (`mdmfs`) |
| `jenova-term` | Launches a command in a terminal emulator. Called by `lib/ui.lua:104`; **never deployed** (B-11) |
| `jenova-tui` | Wrapper launching `jenova-ui` in TUI mode |
| `jenova.desktop` | Desktop entry |
| `jenova-ui` | **Build artifact, not source.** FreeBSD x86-64 ELF, untracked and gitignored. Produced from `jenova-ui/src/main.c` |

## 3. `lib/` — runtime modules

Shell modules are sourced; Lua modules run under LuaJIT.

### Shell

| File | Role |
|---|---|
| `detect-env.sh` | FreeBSD environment detection. Reads `kern.ostype`, never `uname -s` (constraint C-8) |
| `jenova-conf.sh` | **Single owner of path resolution.** Detects installed-vs-source layout; exports `LLAMA_SERVER`, `LLAMA_LIB_DIR`, `JCA_HOME`, `JENOVA_STATE`, `JENOVA_WORKSPACES`, `LOG_DIR`, `CACHE_DIR`, `PID_FILE` (`:25-44`), then sources `etc/jenova.local.conf` under a realpath containment check (`:53-74`) |
| `jenova-model.sh` | Model path/selection helpers |

### Lua

| File | Lines | Role |
|---|---|---|
| `proxy.lua` | — | The Intelligence Proxy; the client-facing HTTP surface and event loop |
| `ffi_defs.lua` | 236 | Centralised FFI definitions. **FreeBSD-only since S-1** — the Linux ABI arm was deleted, removing a silent struct-corruption class. Disappears entirely at the Nim cut-over (D-D) |
| `db.lua` | 934 | SQLite persistence via FFI `ffi.load("sqlite3")`. Largest module |
| `search.lua` | — | Hybrid BM25 + semantic vector search. **Inert** — `index_dir`/`reindex_file` have zero callers (B-15) |
| `embed.lua` | — | Persistent embedding interface via `llama-server --embedding`. `init()` returns true without setting `initialized` (B-14) |
| `http.lua` | — | Minimal HTTP client on LuaJIT FFI, no external dependencies |
| `daemon.lua` | 176 | Process lifecycle via FFI fork/exec; child reaping |
| `fs_sync.lua` | 454 | Filesystem synchronisation over `db` + `git`; three blocking `io.popen` sites remain (B-16) |
| `git.lua` | 58 | Git command wrapper; shell-quotes `cwd` and prefers `async_popen_read` |
| `ui.lua` | 257 | Tray/TUI behaviour called from `main.c`; spawns the proxy (`:69`) and `jenova-term` (`:104`) |
| `json.lua` | — | Minimal JSON encoder/decoder |
| `sha256.lua` | 87 | Pure-Lua SHA-256 |
| `prompts.lua` | — | System prompts for the interaction modes |
| `healthcheck.lua` | — | Standalone LuaJIT health probe |
| `indexer_runner.lua` | — | Standalone LuaJIT indexer entry point |

## 4. `scripts/` — install / build / maintenance

| File | Role |
|---|---|
| `install.sh` | System installation. Sets `JENOVA_ROOT="$JCA_HOME"` (`:279`), deploys six launchers, icons, `lib/`, `scripts/`, profiles, `public/` |
| `install-dependencies.sh` | Single FreeBSD `pkg` dependency list. **Omits `python3`** (B-24) |
| `build-llama.sh` | Vulkan `external/llama.cpp` build + runtime tuning. Generates `jenova.local.conf` using names the hierarchy discards (B-12) |
| `update.sh` | Update/redeploy. Gates on `$SKIP_JVIM`, never set (B-28) |
| `uninstall.sh` | Removal. Documents a `--purge` flag it does not parse (B-27) |
| `cleanup.sh` | Runtime artifact cleanup. **Fixed 2026-08-28** — now sources `jenova-conf.sh` instead of deriving paths (B-07) |
| `jenova-setup` | One-time system configuration; dispatches to the per-profile `jenova-setup` |
| `model_dl.sh` | Hardware-profile-aware model downloader; reads `RECOMMENDED_*_URL` from `profile.conf` |

## 5. `hardware-profiles/` — 6 profiles, uniform depth 2

Layout `<backend>/<config>` per ruling D-F. Each directory holds `jenova.conf` (consumed by
`jenova-ca`, unprefixed names), `profile.conf` (metadata + match scores), and **optionally** a
`jenova-setup` kernel-tuning script — absent for the two generic fallbacks since Q-11, which is a
supported state, not a defect.

| Profile | Tuning status |
|---|---|
| `Vulkan/dgpu-igpu-i5-1135g7` | Real FreeBSD sysctls ✅ |
| `Vulkan/apu-ryzen7-5700u` | Real FreeBSD sysctls ✅ |
| `Vulkan/dgpu-i5-1135g7` | Real sysctls, but `:94` resolves one level too deep post-S-6 |
| `Vulkan/dgpu-generic-12gb` | **No tuning script — deleted 2026-08-31 (Q-11).** It was a config symlinker with a root five `dirname` calls too high, not a tuning script. Data files only; `scripts/jenova-setup` reports "no tuning defined" and exits 0. This is the GPU fallback |
| `CUDA/dgpu-generic` | Same — script deleted 2026-08-31 (Q-11). Opt-in only via `PROFILE_OPT_IN` (D-B) |
| `CPU/generic` | **Entirely Linux** — `cpupower`, `/sys`, `numactl` (B-10). The only CPU-only profile |

Supporting: `detect-hardware.sh` (scoring ladder + `--apply-profile`), `common-setup.sh`,
`README.md`.

## 6. `etc/`

| File | Role |
|---|---|
| `jenova.conf` | The deployed hardware profile, mirrored here by `--apply-profile`. Sourced **last** by `jenova-ca`, so it wins every tuning variable (B-12). Rewritten as a side effect of `tests/test_validate_arg.sh` (B-22) |
| `jenova.local.conf` | Intended user overrides. **Ineffective for bare names** (B-12) |

## 7. `jenova-ui/` — GTK3 tray + ncurses TUI

| Path | Role |
|---|---|
| `src/main.c` | Resolves root via `KERN_PROC_PATHNAME`, embeds LuaJIT, calls `ui.init()`. Carries the `#error` guard refusing non-FreeBSD builds (S-5) |
| `Makefile` | Probes both indicator libraries; names FreeBSD packages |
| `jenova-ui` | Build artifact; untracked and gitignored |

Links GTK3 / libappindicator (LGPL) — the open Q-4 licence exposure, deferred under D-D.

## 8. `tests/`

Specs and status live in `TESTS.md`. Files: `Makefile`, `test-health.sh`, `test-launcher.sh`,
`test_api_db.sh` (added at N-S3b), `test_bin_jenova.sh`, `test_validate_arg.sh`, `test_gpu.sh`,
`test_gpu_single.sh`, `download-draft-model.sh`, and `proxy-concurrency/` (`all.sh`, `run.sh`,
`test_reaper.sh`, `stub_backend.py`, `probe_streams.py`, `test_ffi_flags.lua`, `README.md`).
**Nine scripts; `make check` runs four** — corrected 2026-08-31 from a stale "3 of 8".

## 9. `jca_web/` — SvelteKit Web UI

Directory-level only; a full read remains outstanding.

`src/lib/{actions,assets,components,constants,contexts,enums,hooks,markdown,services,stores,types,utils}`,
`src/routes/`, `src/app.css` (the Google Fonts leak, B-01), `src/service-worker.js`, `static/`,
`docs/flows/` (two Mermaid diagrams depicting an impossible path, B-04), `tests/`, plus the
Vite / Svelte / Playwright / ESLint / TS configs. Zero OS coupling (C-5).

## 10. Supporting trees

| Path | Role |
|---|---|
| `public/` | Prebuilt static client bundle (`bundle.js`, `bundle.css`, `index.html`, icons) |
| `png/` | Source icons. Ships `jca.jpg`, `jca_grey.jpg`, `jenova.jpg/png`, `jvim.jpg`, splash art |
| `external/` | Submodules — `llama.cpp` and `ext_bin`. **Untouched by policy** |
| `var/` | Runtime logs/cache within the source tree |
| `docs/` | User-facing documentation, consolidated to 8 files in Session 002. Empty `architecture/`, `installation/`, `usage/` directories remain (B-38) |
| `.devdocs/` | This workspace. Trackers + `ARCHIVE/` (pre-consolidation reference). **Fully tracked in git — corrected 2026-08-31.** This entry previously claimed `.gitignore:54` ignores `/.devdocs/` and that the trackers were therefore local-only. **That was false in both halves:** `.gitignore` contains no `devdocs` entry at all, and `git ls-files .devdocs/` lists the entire tree. **The process record is committed and public in repository history.** `PROGRESS.md`'s 2026-08-28 16:29 entry carries the same false claim and is corrected there |
