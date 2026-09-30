# ARCHITECTURE MAPPING

What lives where, and why: every tracked path, and every untracked item present in the
working tree, with its class. Update when a file is added, removed or relocated. This is the
current state; the target structure is in `PLANS.md`, and the runtime paths outside the
repository are in `BLUEPRINT.md` → Runtime layout.

**No line numbers and no counts, deliberately.** A citation nothing re-derives is a
citation that rots, which is the defect report 07 tracks as V-17. Files are named; their
contents are not pinned to positions.

**Current as of 2026-09-29T22:34Z.**

**Classes:**
- SOURCE
- BUILD-OUTPUT
- RUNTIME-STATE
- DEPLOYMENT-ASSET — read from `JENOVA_ROOT` at run time
- GOVERNANCE-DOCS
- VENDORED
- ORPHAN — referenced by nothing
- LOCAL — a developer's own files, never shipped

*(ignored)* marks an untracked item that `.gitignore` excludes. Every tracked file is mode
100755 since `154e0cf9`.

---

## Root and governance

| Path | Role | Class |
|---|---|---|
| `AGENTS.md` | Binding operational rules for AI assistants; the one root-level governance file | GOVERNANCE-DOCS |
| `.devdocs/` trackers: `BRIEFING.md`, `SESSION_HANDOFF.md`, `SUMMARIES.md`, `PROGRESS.md`, `DECISIONS_LOG.md`, `TODOS.md`, `PLANS.md`, `BLUEPRINT.md`, `ARCHITECTURE_MAPPING.md`, `TESTS.md` | The trackers `AGENTS.md` defines | GOVERNANCE-DOCS |
| `.devdocs/` reports: `01-documentation-audit.md`, `02-gui-webui-parity.md`, `03-error-memory-wiring.md`, `04-nim-comment-standard.md`, `05-execution-plan.md`, `06-owlkettle-capability-audit.md`, `07-build-verification.md`, `08-math-rendering.md` | Numbered audit reports; not in `AGENTS.md`'s tracker table | GOVERNANCE-DOCS |
| `README.md` | Project overview, repository layout, documentation index | SOURCE (docs) |
| `LICENSE` | AGPL-3.0 text | SOURCE (legal; ships) |
| `NOTICE`, `UPSTREAM-COPYRIGHT` | Attribution for llama.cpp. Their SPIRV-Headers section names `external/SPIRV-Headers`, removed in `4a302f43` | SOURCE (legal; ships) |
| `jenova_core.nimble` | Package definition, owlkettle pin, compile flags, the `SelfTests` list, and the tasks `core`, `gui`, `web`, `suites`, `llama`, `clean` | SOURCE (build) |
| `.gitignore` | Ignore rules, including `jvim/`'s Neovim runtime noise (folded in from `jvim/.gitignore`). Crash dumps are `core` and `core.[0-9]*`, so nvim-cmp's `core.lua` is tracked | SOURCE (VCS) |
| `.gitmodules` | The `external/llama.cpp` submodule | SOURCE (VCS) |
| `.coderabbit.yaml` | Review-bot configuration; excludes `.devdocs/**` | SOURCE (tooling) |
| `.clangd.example` | clangd template for an autoconf C project; the repository has no `configure.ac` and no C sources of its own (the only C is vendored, in `jvim/pack/` and `external/llama.cpp`) | ORPHAN |
| `.vscode/` *(ignored)* | Personal editor settings | LOCAL |

## Entry points

All SOURCE.

| Path | Role |
|---|---|
| `src/jenova_core.nim` | The headless binary. CLI verbs `serve`, `backends`, `models`, `hardware`, `paths`, `config`, `db-init`, `db-capabilities`, `version`. `serve` runs the server, starts the backends and adds the watchdog/backfill thread. Also dispatches every `<name>-selftest`: most bodies live here, `db` and `serve` delegate to their own modules. Scratch databases go under `$JENOVA_STATE`; several self-tests (PDF extraction, workspace, models) use the system temp directory instead |
| `src/jenova_gui.nim` | The desktop binary. Parses `--no-tray` and `--check`, then hands off to `gui.run` |

## The request path

All SOURCE. Ordered as a request travels it.

| Path | Role |
|---|---|
| `src/jenova/http.nim` | HTTP/1.1 request parsing and response writing: `Content-Length` and `chunked` bodies under `MaxBodyBytes`, SSE, content types. Owns `resolveStatic`, which checks containment resolved against resolved |
| `src/jenova/routes.nim` | Route classes and their thread counts. `classify` decides from the path alone, so the acceptor can peek without consuming. Pure |
| `src/jenova/server.nim` | Acceptor threads (poll, peek, classify) and per-class worker pools. The completion handler parses the scope header, runs `prepare`, builds the diagnostic headers, then answers from the cache or relays and stores. Also `/api` dispatch, static files and the debug endpoints |
| `src/jenova/pipeline.nim` | Everything done to a completion request between client and backend: intent, tool stripping, scoped retrieval, web search, editor document, persona, history trim, cache key. Also the response cache, `chatBody`, the error classifier and the attachment readers |
| `src/jenova/upstream.nim` | The streaming relay to `llama-server`. Splices headers after the status line, tees a bounded copy of the upstream's own head, and reports complete, truncated or unavailable |
| `src/jenova/prompts.nim` | The personas and the `Intent` enum |
| `src/jenova/inspect.nim` | The `X-Jenova-*` diagnostic headers: encoded by the server, parsed and labelled for the window |

## Persistence and the workspace

All SOURCE.

| Path | Role |
|---|---|
| `src/jenova/db.nim` | SQLite through `dlopen` of libsqlite3. One connection per thread, WAL, a bounded prepared-statement cache, the FTS5 probe. Holds the entity and `llm_cache` schema; the retrieval tables are `rag`'s |
| `src/jenova/api.nim` | The `/api/db`, `/api/fs` and `/api/storage` handlers, plus the in-process entry points the window uses for the same operations. Covers generic entities, merge-on-upsert, cascade deletes, restore, fork, import and export; triggers the mirror and indexing |
| `src/jenova/fssync.nim` | The disk mirror under `$JENOVA_WORKSPACES`: one git repository per workspace, created by spawning `git`, and workspace creation fails without it. Also the trash: deleted notes, files, projects and folders go to their workspace's `.trash` and deleted workspaces to `$JCA_HOME/.trash`, each with a `.metadata.json` sidecar; storage-route deletions go to `$JENOVA_WORKSPACES/.trash/<epoch>/<path>` with no sidecar. And the storage-path resolver |
| `src/jenova/workspace.nim` | The scoped notes-and-files block for the system message, bounded. Depends only on `db`, which keeps the scoping ladder assertable |
| `src/jenova/rag.nim` | Hybrid retrieval: BM25 over FTS5 plus vectors in a BLOB column. Owns the retrieval schema, chunking, indexing, backfills and the scoped query. Also the `X-Jenova-Scope` wire format and the embedding client for `127.0.0.1:8082` |

## Backend supervision and configuration

All SOURCE.

| Path | Role |
|---|---|
| `src/jenova/lifecycle.nim` | Starting, stopping and watching the `llama-server` children. Builds their argument vectors from the config — resolving GPUs named in `DEVICES`/`DRAFT_DEVICE` against `llama-server --list-devices` before the start lock — and owns the fork/exec handshake, the cross-process start lock, pid files in `$JENOVA_STATE`, log rotation in `LOG_DIR` and the health-probing watchdog |
| `src/jenova/models.nim` | Discovers `.gguf` files under `$JCA_HOME/models` and switches the agent slot (a link into `models/instruct/` or `models/thinking/`; displaced real files kept as `.old`). `roleOf` names the folder the active model lives in, which sets the default for thinking |
| `src/jenova/hardware.nim` | Machine detection, the OS chosen at compile time: `sysctl`, `swapinfo`, `zpool`, `nvmecontrol` on FreeBSD; `/proc` and `/sys` on Linux. GPUs come from `llama-server --list-devices` (`probeDevices`), and `resolveDevices` turns a named GPU into its device id. Scores profiles under `<root>/hardware-profiles`. `apply` copies the winner's `jenova.conf` to `$JCA_HOME/etc/`, never `jenova.local.conf`. Its `std/re` import loads PCRE2 |
| `src/jenova/config.nim` | The precedence rule, and `/bin/sh` evaluation of `jenova.conf` and `jenova.local.conf` from `$JCA_HOME/etc/` if that holds a `jenova.conf`, else `<root>/etc/`. `Keys` lists what can be set, including `JENOVA_REASONING` (thinking on, off or auto); a key read elsewhere but not listed is dead. Fills model keys the conf leaves empty |
| `src/jenova/paths.nim` | Every runtime path, derived once from `JENOVA_ROOT` and `JCA_HOME`. Detects installed versus source layout, refuses `~/JCA`, and sweeps the attachment cache |

## The window

All SOURCE.

| Path | Role |
|---|---|
| `src/jenova/gui.nim` | The owlkettle window: chat and control surfaces. Runs the server and the tray in-process and starts the backends at launch; its control worker starts, stops and restarts them on request and polls the agent backend's health, reporting one that exited, but never restarts a backend itself (only `serve`'s watchdog does). Stream, control and hardware worker threads. Spawns `xdg-open`; reads the LAN address from the kernel (`getPrimaryIPAddr`, `getifaddrs`). Clears GTK's legacy dark-theme setting before `adw_init`. Writes `jenova.db`, `lan_mode`, `styles/` and `settings.json` under `$JENOVA_STATE` |
| `src/jenova/theme.nim` | The palette and the stylesheet generated from it, shared with the canvas, the terminal and the code views |
| `src/jenova/canvas.nim` | The animated particle field, drawn with Cairo |
| `src/jenova/sourceview.nim` | GtkSourceView 5 binding for fenced code. Installs the `jenova-dark` scheme into `$JENOVA_STATE/styles` |
| `src/jenova/vte.nim` | VTE (gtk4) binding hosting `nvim` on the editor page. `GdkRGBA` is GDK's own C struct |
| `src/jenova/nvimctl.nim` | Reads the live buffer through `nvim --server --remote-expr` for the `Editor:` intent. Builds the editor's environment (`XDG_CONFIG_HOME=<root>`, `NVIM_APPNAME=jvim`) and names its socket, `$JENOVA_STATE/nvim.sock` |
| `src/jenova/tray.nim` | The StatusNotifierItem and its dbusmenu, dispatched from the GTK main loop |
| `src/jenova/dbus.nim` | The minimal libdbus-1 binding the tray uses |
| `src/jenova/shortcuts.nim` | One window-level `GtkShortcutController` |
| `src/jenova/settings.nim` | Setting definitions, defaults, validation and persistence (`$JENOVA_STATE/settings.json`), and the merge of sampling fields into a request body |
| `src/jenova/composer.nim` | The composer's send-or-newline and long-paste decisions, kept out of the widget |
| `src/jenova/assetview.nim` | Which viewer can show a stored file asset |

## Rendering

All SOURCE.

| Path | Role |
|---|---|
| `src/jenova/markdown.nim` | Splits a reply into text, code, table and maths blocks. Turns inline markdown into Pango markup, with the `markupBalanced` guard |
| `src/jenova/mathtex.nim` | Maths parser and box layout over TeXbook Appendix G. Pure; drawn by `gui.nim`'s `bkMath` path |
| `src/jenova/mathfont.nim` | Chooses the maths font and reads its OpenType MATH constants and variants through HarfBuzz. Imported by both binaries, which is why `jenova-core` links HarfBuzz |
| `src/jenova/convmd.nim` | Conversations to and from markdown, for export and import |
| `src/jenova/pdf.nim` | Text extraction from a PDF; no rasteriser |

## Support

All SOURCE.

| Path | Role |
|---|---|
| `src/jenova/sha256.nim` | The hash the cache key and attachment names are built on |
| `src/jenova/zlib.nim` | `inflate` and `deflate` through `-lz`, for PDF streams |
| `src/jenova/websearch.nim` | DuckDuckGo HTML search, then the Instant Answer API, through `fetch(1)` or `curl`. The runtime's only outbound connection to a host other than `127.0.0.1` (LAN mode listens on the network but connects out to nothing) |
| `src/jenova/pkgconfig.nim` | Compile-time `pkg-config` that names a missing package and how to find it: the FreeBSD port, or `pacman -F`, `dnf provides` or `apt-file search` |
| `src/jenova/version.nim` | Version, copyright and project URLs |
| `src/jenova/dbselftest.nim` | The database concurrency-overlap self-test |
| `src/jenova/serverselftest.nim` | The server self-test: class isolation, stream cadence under load, and the relay against a fake upstream, on kernel-assigned ports |

## Tests

All SOURCE. What each verifies, and its side effects, are in `TESTS.md`.

| Path | Role |
|---|---|
| `tests/test_api_db.sh` | `/api/db/*` contract, against a scratch `jenova-core serve` |
| `tests/test_api_fs.sh` | Disk-mirror and `/api/fs/*` contract, against a scratch server |
| `tests/test_routes.sh` | Route inventory by status code, against a scratch server |
| `tests/test_lifecycle.sh` | Backend argument vector, bind addresses and refusal paths, through the CLI and short `serve` runs |
| `tests/test_models.sh` | Model discovery and switching, through the CLI only |
| `tests/test_nvimctl.sh` | Drives `tests/nvimctl_check.nim` against a headless `nvim` |
| `tests/nvimctl_check.nim` | The assertions behind `test_nvimctl.sh` |
| `tests/gui_check.sh` | `nim check` of the window with the `.nimble`'s switches |
| `tests/gui_build.sh` | Builds both binaries in a temporary directory, runs `--check`, then maps and drives the window |

## Deployment assets and configuration

| Path | Role | Class |
|---|---|---|
| `hardware-profiles/` — `CPU/generic`, `CUDA/dgpu-generic` (opt-in), `Vulkan/apu-ryzen7-5700u`, `Vulkan/dgpu-generic-12gb`, `Vulkan/dgpu-i5-1135g7`, `Vulkan/dgpu-igpu-i5-1135g7`, each a `profile.conf` plus `jenova.conf`; and `README.md` | Profiles read from `<root>/hardware-profiles`. All set `MATCH_OS="FreeBSD\|Linux"`; the i5-1135G7 and 12 GB profiles name their GPUs in `DEVICES` | DEPLOYMENT-ASSET |
| `etc/jenova.conf` | Configuration fallback, used while `$JCA_HOME/etc/jenova.conf` is absent. Tuned for one machine (i5-1135G7, dual GPU) and drifted from its source profile. `hardware apply` never writes it | DEPLOYMENT-ASSET |
| `etc/jenova.local.conf` *(ignored)* | This machine's overrides, generated by the removed `bin/build-llama-jenova`. Read by every run whose config directory is `<root>/etc`, including the test suites | RUNTIME-STATE |
| `bin/jenova.desktop` | Desktop entry (`Exec=jenova`, `Icon=jenova`); nothing installs it | DEPLOYMENT-ASSET, inside a build-output directory |
| `png/jenova.jpg` | The window's logo, read from `<root>/png` | DEPLOYMENT-ASSET |
| `png/splash_top.png`, `png/splash_bottom.png` | README images | SOURCE (docs) |
| `png/jca.jpg`, `png/jca_grey.jpg`, `png/jvim.jpg`, `png/jenova.png` | Desktop icons the pre-rewrite installer deployed (`jenova`, `jca`, `jca_grey`); no Nim code references them | DEPLOYMENT-ASSET |
| `docs/architecture.md`, `docs/context-and-retrieval.md`, `docs/install.md`, `docs/privacy.md`, `docs/usage.md` | User documentation | SOURCE (docs) |

## Web UI — `jca_web/`

Once frozen (session 2); the 2026-09-29T23:30Z ruling 4 lifts that wherever parity needs a Web-side
change — the Web UI and the GUI are the two points of access and behave the same.

| Path | Role | Class |
|---|---|---|
| `jca_web/package.json`, `package-lock.json`, `svelte.config.js`, `vite.config.ts`, `tsconfig.json`, `eslint.config.js`, `components.json`, `vitest-setup-client.ts`, `.gitignore`, `README.md` | Build configuration. `adapter-static` writes to `../public` | SOURCE |
| `jca_web/playwright.config.ts` | e2e configuration; builds `../public` and serves it on `:8181` | SOURCE |
| `jca_web/src/` | The SvelteKit application | SOURCE |
| `jca_web/static/` | Assets copied into `public/` | SOURCE |
| `jca_web/tests/` | vitest (unit, client), Storybook stories and fixtures, Playwright e2e | SOURCE |
| `jca_web/docs/` | Upstream architecture and flow notes | SOURCE (docs) |
| `jca_web/scripts/finalize-build.js`, `post-build.sh` | Post-process `../public` into the single-bundle build | SOURCE (build) |
| `jca_web/scripts/dev.sh`, `install-git-hooks.sh` | Developer tools (bash): Vite dev server on `0.0.0.0`; writes `.git/hooks/pre-commit` | SOURCE (tooling) |
| `jca_web/node_modules/`, `jca_web/.svelte-kit/` *(ignored)* | Installed dependencies; SvelteKit cache | BUILD-OUTPUT |
| `jca_web/build/` *(ignored)* | A stale copy of the bundle; the current build writes to `../public`, not here | ORPHAN (build output) |

## Embedded editor — `jvim/`

| Path | Role | Class |
|---|---|---|
| `jvim/init.lua`, `jvim/lua/`, `jvim/plugin/`, `jvim/colors/`, `jvim/doc/`, `jvim/README.md` | Jenova's own Neovim configuration, under Jenova's licence. The editor page loads it from `<root>/jvim` (`NVIM_APPNAME=jvim`), and it can be used standalone the same way. Its repository leftovers (`LICENSE`, `.gitattributes`, `.gitignore`, `nvim.log`) were removed on 2026-09-30; its configuration is kept whole | DEPLOYMENT-ASSET |
| `jvim/pack/` | Vendored Neovim plugins (`pack/jenova/start/`) and `pack/dist/opt/`, shipped so the editor needs no package manager and no network | VENDORED |

## Vendored code and build outputs

| Path | Role | Class |
|---|---|---|
| `external/llama.cpp` | Inference engine, git submodule. Recorded and checked-out commits differ | VENDORED |
| `external/llama.cpp/build/` *(ignored by llama.cpp)* | `nimble llama`'s CMake build tree; `bin/llama-server` there is the static build it copies. Holds a Linux build from 2026-09-30 | BUILD-OUTPUT |
| `external/ext_bin/` *(ignored)* | Where `nimble llama` copies the static `llama-server` — since 2026-09-30 a Linux build. The FreeBSD 15.1 shared libraries from before are still beside it; nothing loads them (a cleanup candidate) | BUILD-OUTPUT |
| `bin/jenova`, `bin/jenova-core` *(ignored)* | `nimble gui` and `nimble core` outputs; Linux builds since 2026-09-30 | BUILD-OUTPUT |
| `nimcache/core/`, `nimcache/gui/` *(ignored)* | Per-task Nim caches | BUILD-OUTPUT |
| `public/` *(ignored)* | The Web UI bundle from `nimble web`, served from `<root>/public` | BUILD-OUTPUT (served at run time) |

## Runtime leftovers in the repository

Nothing in `src/` reads any of these; runtime state lives in `$JCA_HOME`.

| Path | Role | Class |
|---|---|---|
| `.system/` *(ignored)* — `lan_mode`, `status.out` | State from the Lua UI, which fell back to `<root>/.system`; that UI was removed in `7b859f59` | RUNTIME-STATE (leftover) |
| `var/log/.gitkeep` | Placeholder from when `LOG_DIR` was `$JENOVA_ROOT/var/log` (moved to `$JCA_HOME` in `4a302f43`) | RUNTIME-STATE (leftover) |
| `var/jenova.db` *(ignored)* | Empty database from the pre-Nim design | RUNTIME-STATE (leftover) |
