# BLUEPRINT

Authoritative system architecture: what the product is, what it depends on, and how data
moves through it. `ARCHITECTURE_MAPPING.md` is the file-by-file companion, `TESTS.md` the
validation record, `PLANS.md` the forward design.

**Current as of 2026-09-29T22:32Z.** Rewritten against the code by the devdocs congruence
audit; it describes the system as it stands.

---

## What this is

Two binaries built from one module set under `src/jenova/`:

- **`jenova`** — the GTK4/libadwaita window. The same process runs the HTTP server on
  `:8080`, supervises the two `llama-server` children (agent `:8081`, embeddings `:8082`),
  owns the database, and publishes the tray item on the GTK main loop.
- **`jenova-core`** — the same server, supervisor and database with no GTK (`serve`), plus the
  CLI verbs and every self-test. `serve` adds a watchdog thread the window does not have.

The browser client (`jca_web`, built into `public/`) is the LAN surface.

**The central property:** both surfaces use the same database and the same
`pipeline.prepare` for completions. The window builds its chat body with `pipeline.chatBody` but
sends every completion over HTTP to its own `:8080`, so the pipeline runs once, in the server,
for both surfaces. For storage the Web UI goes through `/api/db/*`; the window calls `api.nim`
in-process for notes, file assets, containers, deletes, restores, forks, import and export, but
writes conversations and messages with its own SQL (`newConversation`, `saveMessage`) and reads
its sidebar lists directly (`listWorkspaces` … `listFiles`). Server, supervisor and
window sharing one process is what makes "the daemon is up" and "the client port answers"
incapable of disagreeing.

## Requirements

- **Supported platforms: FreeBSD and Linux (Arch, Debian, Fedora), both first-class** (user
  ruling, `DECISIONS_LOG.md` 2026-09-29T22:29Z). Building and detection meet it since
  2026-09-30T03:07Z: `hardware.nim` chooses its probes with `when defined(freebsd)` /
  `defined(linux)`, `pkgconfig.nim` names the package for the OS being built on, the LAN address
  comes from the kernel, every profile matches `FreeBSD|Linux`, and profiles name their GPUs.
  `websearch.httpsClient` tries `fetch`, then `curl`. What remains is the install step (Stage 3).
- **The build detects the OS; no OS-specific build folders** (same ruling).
- **The deployed build is separate from the repository** (same ruling). `paths.nim` already
  models an installed layout; no build task produces one.
- **Clear structural separation of concerns in the repository** (same ruling).
- The design meeting the last three rulings is in `PLANS.md`.
- **Licence:** AGPL-3.0-or-later. GPL-licensed code and tools are allowed (same ruling);
  nothing proprietary. The window already links LGPL libraries (GTK4, libadwaita,
  GtkSourceView, VTE).
- **Offline-first.** Inference, embeddings and storage are local, and both backends bind
  loopback only. The runtime's only non-loopback requests are the DuckDuckGo web-search
  lookups, made through `fetch(1)` or `curl` and only for a `Web Search:` turn.
  `docs/privacy.md` covers the rest: the Web UI's optional MCP servers and build-time
  network use.
- **No authentication.** The client port binds loopback unless LAN mode is on — the window's
  toggle, `serve --lan`, or `HOST=0.0.0.0` in the conf. `:8081` and `:8082` never leave
  loopback.
- **Soft deletion for entity rows.** Rows are flagged, which is what makes trash and restore
  possible. A first write whose disk mirror fails is rolled back by deleting the row; the
  response cache and the retrieval index are derived data and are hard-deleted; emptying the
  trash deletes files for good.
- **A client that must keep working.** `jca_web` was frozen in session 2, so the server's route
  shapes, query parameters and response bodies were fixed around it. The 2026-09-29T23:30Z ruling 4
  lifts the freeze wherever the two surfaces must behave the same, so the Web UI may now change to
  match the GUI — it does not yet send `X-Jenova-Scope` (`PLANS.md` 4.1).

## Dependencies

"Best knowledge" marks a package name not verified on that OS.

### Build time

| Need | For | Notes |
|---|---|---|
| Nim ≥ 2.2.10, nimble | both | floor enforced by `jenova_core.nimble` |
| C compiler, `pkg-config` | both | both binaries build under gcc 16.2 and clang 22.1 (`TESTS.md`) |
| owlkettle, pinned to commit `ac61ecf` | `jenova` | a range such as `>= 3.0.0` matches two different trees; brings gtk4, libadwaita-1 and cairo |
| GTK ≥ 4.10, libadwaita ≥ 1.4 | `jenova` | from `-d:gtkminor=10 -d:adwminor=4` and the hand-bound `AdwBreakpoint`. Debian 12 is below it; Debian 13, Fedora, Arch and FreeBSD qualify |
| gtksourceview-5, vte-2.91-gtk4, dbus-1, freetype2 (`.pc` and headers) | `jenova` | hand-written bindings through `pkgconfig.pkgConfig` |
| harfbuzz (`.pc` and headers) | **both** | `jenova_core.nim` imports `mathfont` for `math-selftest`, so `jenova-core` links `libharfbuzz` too |
| zlib headers (`-lz`) | both | `zlib.nim`, for PDF streams |
| node, npm | `public/` | `nimble web`; `npm install` reaches the registry |
| cmake, C/C++ toolchain, git, Vulkan headers and loader, `glslc` (shaderc), SPIR-V headers | `llama-server` | `nimble llama`: `-DGGML_VULKAN=ON`, built inside `external/llama.cpp/build`, copied to `external/ext_bin/bin`. At `a6ea155d3` the llama.cpp build downloads its web UI from Hugging Face unless told not to. There is no CUDA build path |

SQLite and PCRE2 are not needed at build time; both are loaded at run time.

### Run time — libraries

| Library | Loaded by | Notes |
|---|---|---|
| libsqlite3 (`.so`, `.so.0`, `.so.3`) | both, `dlopen` | must be thread-safe (`db.initDb` refuses otherwise); FTS5 is probed, and retrieval degrades to vectors-only without it |
| libpcre2-8 (`libpcre2-8.so.0`) | both, `dlopen` at start-up | pulled in by `std/re` in `hardware.nim` under Nim 2.2.12; without it neither binary starts. An older Nim loads `libpcre.so.1`/`.3` instead, as the FreeBSD build does |
| libz, libharfbuzz | both, linked | |
| GTK4, libadwaita, GtkSourceView 5, VTE (gtk4), libdbus-1, FreeType, cairo, pango | `jenova`, linked | |
| the llama.cpp libraries, libvulkan and a Vulkan driver | `llama-server` | Vulkan device order is OS-dependent: on the i5-1135G7 laptop FreeBSD lists the GTX 1650 Ti as `Vulkan0`, Linux lists the Iris Xe first |

### Run time — programs

| Program | Used by | Required |
|---|---|---|
| `/bin/sh` | `config.nim` evaluates the conf files | yes |
| `git` | `fssync.nim`: each workspace is a git repository; creating one fails without git | yes |
| `llama-server` | `lifecycle.nim` children; `hardware.detect` (`--list-devices`) | for inference |
| `sysctl`, `swapinfo`, `zpool`, `nvmecontrol` | `hardware.detect` | FreeBSD. On Linux it reads `/proc/cpuinfo`, `/proc/meminfo`, `/proc/swaps`, `/proc/self/mounts` and `/sys/class/nvme` instead; GPUs come from `llama-server --list-devices` on both |
| `fetch(1)` or `curl` | `websearch.nim` | optional; Linux needs `curl` |
| `nvim` | the editor page (`vte.nim`); the `Editor:` intent (`nvimctl.nim`) | optional |
| `xdg-open` | "Open Web UI" | optional |
| a StatusNotifierWatcher on the session bus | `tray.nim` | optional (`--no-tray`) |
| an OpenType MATH font | `mathfont.chooseFont` | optional; a formula falls back to literal LaTeX |

### Package names per OS

- **FreeBSD** (built and tested on 15.1 until 2026-09-10): `lang/nim`, `devel/nimble`,
  `devel/pkgconf`, `devel/git`, `devel/cmake`, `databases/sqlite3`, `devel/pcre2`,
  `x11-toolkits/gtk40`, `x11-toolkits/libadwaita`, `x11-toolkits/gtksourceview5`,
  `x11-toolkits/vte3`, `devel/dbus`, `print/harfbuzz`, `print/freetype2`, `www/node`,
  `www/npm`, `devel/xdg-utils`, `editors/neovim`, `graphics/vulkan-loader`,
  `graphics/shaderc`, `devel/spirv-headers`. zlib, `fetch` and `sysctl` are in base.
- **Arch** (the current host): `gtksourceview5`, `vte4`, `openbsd-netcat`, `nodejs`, `npm`
  verified by install; best knowledge for the rest — `nim`, `nimble`, `pkgconf`, `git`,
  `cmake`, `sqlite`, `pcre2`, `zlib`, `gtk4`, `libadwaita`, `dbus`, `harfbuzz`, `freetype2`,
  `curl`, `xdg-utils`, `neovim`, `vulkan-icd-loader`, `vulkan-headers`, `shaderc`,
  `spirv-headers`.
- **Debian 13** (best knowledge): `libgtk-4-dev`, `libadwaita-1-dev`,
  `libgtksourceview-5-dev`, `libvte-2.91-gtk4-dev`, `libdbus-1-dev`, `libharfbuzz-dev`,
  `libfreetype-dev`, `zlib1g-dev`, `libsqlite3-0`, `libpcre2-8-0`, `libvulkan-dev`, `glslc`,
  `spirv-headers`, `git`, `curl`, `neovim`, `nodejs`, `npm`. Packaged Nim may be below 2.2.10.
- **Fedora** (best knowledge): `gtk4-devel`, `libadwaita-devel`, `gtksourceview5-devel`,
  `vte291-gtk4-devel`, `dbus-devel`, `harfbuzz-devel`, `freetype-devel`,
  `zlib-ng-compat-devel`, `sqlite-libs`, `pcre2`, `vulkan-loader-devel`, `glslc`,
  `spirv-headers-devel`, `git`, `curl`, `neovim`, `nodejs`, `npm`.

## Runtime layout

`paths.resolve` derives the two roots and, from them, the state, workspaces, log, cache and pid
paths and the `llama-server` binary and library directory; the other paths below are built from
those fields by the modules that use them (`fssync`, `models`, `config`, `hardware`, `gui`,
`jenova_core`). A path with an environment variable named beside it can be relocated by it.

- **`JENOVA_ROOT` — the program tree:** `$JENOVA_ROOT`, else the executable's `../..`. The
  program reads from it:
  - `etc/` — the fallback configuration directory;
  - `hardware-profiles/`;
  - `public/` — the static root;
  - `png/jenova.jpg` — the window's logo;
  - `jvim/` — the embedded editor's configuration, reached through `XDG_CONFIG_HOME=<root>`
    and `NVIM_APPNAME=jvim`.
- **Source layout (`lySource`)** — every run today. `llama-server` and its libraries are in
  `<root>/external/ext_bin/bin/`.
- **Installed layout (`lyInstalled`)** — chosen when `<root>/bin/llama-server` exists and
  `<root>/external/llama.cpp` does not. The binary and its libraries are in `<root>/bin/`.
  Nothing builds this layout yet.
- `LLAMA_SERVER` in the environment overrides the binary path. When the library directory
  exists, it is prepended to the child's inherited `LD_LIBRARY_PATH`.
- **`JCA_HOME` — the data tree:** `$JCA_HOME`, else `~/Jenova`. `~/JCA` is refused unless
  `JENOVA_ALLOW_DEPLOYED=1`.
  - `.system/` (`JENOVA_STATE`): `jenova.db`, backend pid and lock files, `lan_mode`,
    `nvim.sock`, `settings.json`, `styles/`. The self-tests' scratch databases land here too.
  - `Workspaces/` (`JENOVA_WORKSPACES`): the disk mirror, one git repository per workspace.
    Deleted notes, files, projects and folders go to their workspace's own `.trash/`;
    storage-route deletions go to `Workspaces/.trash/`.
  - `.trash/`: deleted workspaces.
  - `var/log/` (`LOG_DIR`): backend logs, rotated at 8 MiB.
  - `var/cache/attachments/` (`CACHE_DIR`): decoded attachments, swept to 256 MiB when the
    window starts.
  - `models/{agent,draft,embed,instruct,thinking}/`: GGUF files; `agent/` holds the active
    link.
  - `etc/`: `jenova.conf` is copied here from the chosen profile by `jenova-core hardware apply`
    and by the window's Hardware screen; nothing writes a `jenova.local.conf` here.
- **Configuration directory switch.** `config.load` reads `$JCA_HOME/etc/` when it holds a
  `jenova.conf`, otherwise `<root>/etc/`. It switches the whole directory, so the
  repository's `etc/jenova.local.conf` stops applying once a profile has been applied.
- **The tracked `etc/jenova.conf`** is a machine-specific fallback that has drifted from its
  source profile.
- **Precedence:** `jenova.conf` is sourced, then `jenova.local.conf`, by `/bin/sh` with the
  inherited environment.
  - The environment wins only where a conf line reads it — mostly through a `JENOVA_`-prefixed
    name (`HOST="${JENOVA_HOST:-127.0.0.1}"`). An unconditional assignment such as
    `MAX_ACTIONS=20` in `etc/jenova.conf` ignores the environment.
  - Only keys in `config.Keys` come back, so a key read elsewhere but not listed there
    (`CANVAS`, `BACKEND_BIND_HOST`, `DRAFT_NGL`) can never be set.
  - Some listed keys are never read from the loaded configuration, only printed by `config`:
    `API_URL`, `LLAMA_URL`, `LLAMA_EMBED_URL`, `MAX_TURNS`, `MAX_ACTIONS`, `TIMEOUT`,
    `JENOVA_HEALTH_TIMEOUT`, and the path keys (`JCA_HOME`, `JENOVA_STATE`, `LOG_DIR`,
    `CACHE_DIR`, `PID_FILE`, `LLAMA_SERVER`), which `paths.resolve` takes from the environment.
  - `MODEL_PATH`, `MODEL_DRAFT` and `MODEL_EMBED` left empty are filled by `models.discover`.

## Data flow

### A chat turn

1. The window assembles the transcript and calls `pipeline.chatBody`, which:
   - appends the workspace context (`workspace.contextFor`, capped at 64 KiB) and the
     thinking directive to the system message;
   - merges the sampling settings.
2. It posts to **its own local server** over a raw socket, with `X-Jenova-Scope` naming the
   conversation's folder, project and workspace. The Web UI posts the same way without the
   header, which retrieval reads as the no-workspace scope.
3. An acceptor peeks at the request line; `routes.classify` hands the socket to the
   completion pool.
4. `server.handle` parses the scope header and calls `pipeline.prepare`, which in order:
   - detects and strips the intent;
   - strips tools for `Visual Rewrite:` and `Web Search:`;
   - queries retrieval within the scope;
   - runs web search for `Web Search:`;
   - reads the live editor buffer for `Editor:`;
   - injects the persona and those blocks into the system message;
   - trims the oldest turns to the history budget;
   - hashes the cache key **last**, over the rewritten body.
5. `server.handle` builds the diagnostic headers and consults the response cache.
   - A hit is replayed with this request's diagnostics and `X-Cache: HIT`.
   - A miss goes to `upstream.forward`.
6. The relay streams bytes back verbatim.
   - It splices the diagnostics in after the status line.
   - It tees a bounded copy of the upstream's own bytes, stored only for a complete,
     replayable stream.
7. The window's stream thread reads tokens and the diagnostic head, and posts both to the GTK
   thread over a channel carrying only plain values.

### Other flows

- **Storage.** `/api/db/*`, or the window's in-process `api.putEntity`, reaches `api.upsert`,
  which:
  - writes the row (omitted columns merged in);
  - mirrors it to disk (`fssync`, staging with `git add`);
  - re-indexes changed note and file text in `rag`, embedding through `127.0.0.1:8082`.
  `/api/fs/*` serves only the trash (list, restore, empty) and the tree. `/api/storage/*`
  reads, writes and trashes raw files under `Workspaces/` through `fssync`, with no row, no
  staging and no re-index.
- **Embeddings relay.** `/embed`, `/embeddings` and `/v1/embeddings` go to the embed pool and
  on to `:8082`. `rag.embed` calls `:8082` directly, not through the server.
- **Static files.** Any other `GET` or `HEAD` is served from `<root>/public/`.
- **Backends.** `serve` and the window call `lifecycle.startAll`: fork/exec, pid files, logs.
  - The agent runs on the profile's devices; the embed server is CPU-only.
  - `serve` adds a 30 s watchdog that restarts a failing backend and, once the embedder
    answers, backfills the retrieval index from existing chats, notes and files.
  - Quitting the window stops only the embed backend. The agent backend is left running on
    purpose: reloading the model into VRAM on every start costs more than an idle process
    (the quit path in `gui.run`).
- **Profiles.**
  - `hardware detect` scores every `profile.conf` under `<root>/hardware-profiles/` against
    the probed machine.
  - `apply` copies the chosen `jenova.conf` to `$JCA_HOME/etc/`, never touching
    `jenova.local.conf`.
  - `config.load` reads it when the window or `jenova-core serve` starts. A backend restarted
    inside a running process keeps the configuration that process started with
    (`Lifecycle.init` stores it once), so a new profile takes effect when the window or `serve`
    itself restarts.
- **LAN mode.** The window's toggle persists `$JENOVA_STATE/lan_mode`; the bind address is
  decided from it only when the window next starts. The running window re-reads it every 3 s to
  update what it displays. `jenova-core serve` binds from `HOST` or `--lan` and does not read
  the flag.
- **Editor.** The window's editor page runs `nvim` in VTE with the in-tree `jvim/`
  configuration, listening on `$JENOVA_STATE/nvim.sock`. `nvimctl` reads that socket for an
  `Editor:` turn.

## Concurrency model

- **Threads, not an event loop.** Multiplexing every client onto one thread means a single
  blocking call freezes routing and token streaming for everyone.
- **Route classes have isolated pools**, so a saturated class cannot starve another.
- **In the HTTP server only a socket handle crosses a thread boundary.** The acceptor peeks the
  path to classify it and passes the handle; the owning worker parses on its own thread.
  Elsewhere objects holding strings cross threads by copy: `serve`'s watchdog thread receives a
  `Lifecycle`, and the window's channels carry `StreamJob`, `ControlJob` and `UiMsg` values.
- **One database connection per thread**, in a threadvar, opened lazily.
- **The window's GTK thread is the only writer of window state.** Two persistent workers —
  stream and control — plus a separate hardware worker report back over channels.
- **`jenova-core serve` adds one watchdog thread**; the window has none.
- **`--mm:arc` on the GUI only**, deliberately leaking owlkettle's state/event cycles
  rather than letting ORC collect a widget state GTK still holds.

## Invariants that hold, and must keep holding

- The cache key hashes the body **after** rewriting. Hashing the client's original body
  orphans every entry already stored.
- The response cache stores the **upstream's** head, never the spliced one, or one
  request's diagnostics are replayed to another.
- `trimHistory` never drops the system message or the final turn, and never shortens
  content.
- Anything appended to the system message must be bounded at its source, because the
  trimmer will not shorten it.
- A relay that delivered less than a status line is not a reply, and is refused rather
  than counted as complete.
- Static path resolution compares **resolved** against **resolved**, so a symlink cannot
  walk out of the served root.
- The render path never does work proportional to a payload. The memos exist for that and
  are capped by entry count; `ParseMemo` has no byte bound.
- Partial entity updates preserve existing stored fields across both in-process and HTTP
  `/api/db/*` writes (merged in `api.upsert`).
- Retrieval scoping enforces strict down-tree container isolation via `X-Jenova-Scope`:
  - a folder scope confines to that folder;
  - a project scope searches its folders;
  - a workspace scope searches its projects and folders;
  - the no-workspace scope sees only unfiled content;
  - an absent header means the no-workspace scope. The Web UI never sends the header: its
    chats get their workspace's notes and files pasted into the prompt by the Web UI itself
    (`WorkspaceService.getWorkspaceContext`), but the server's search then covers only content
    outside every workspace (open question in `PLANS.md`).
- Request parsing decodes chunked and `Content-Length` bodies up to `MaxBodyBytes` and
  accepts only the `chunked` transfer coding.
- Display maths fences (`$$...$$`, `\[...\]`) parse into `bkMath` blocks, which are handled
  as follows:
  - laid out by `mathtex` with `mathfont`'s HarfBuzz metrics;
  - drawn with Cairo, size variants by glyph index through FreeType;
  - fall back to the literal source when layout is refused.

## Known architectural debts

Each has a plan in `PLANS.md`.

- **Render memos.** The four (`mdMemo`, `attachMemo`, `thumbCache`, `mathLayoutCache`) are
  conversation-scaled, not viewport-scaled, now that the transcript virtualises.
- **Platform.** Detection and device choice work on both OSes since 2026-09-30T03:07Z. Left: an
  i5-1135G7 with only its Iris Xe scores the dual-GPU profile highest (`PLANS.md` 5.6), and
  `MATCH_GPU_0` is matched against the whole device list, not against device 0.
- **No deploy step.** The pre-rewrite installer (`install-jenova.sh`, `scripts/install.sh`,
  deleted in `7b859f59`) deployed a standalone application home and left the repository
  deletable. The Nim code still expects that tree — `paths.nim`'s installed layout — but nothing
  produces it (`nimble llama` copies into `external/ext_bin/bin`), so every run uses the checkout
  as its program tree. `$JCA_HOME/etc/jenova.conf` is produced, by `hardware apply` or the
  window's Hardware screen, and `config.nim` prefers it once it exists.
- **The backend copy is not runnable.** `nimble llama`'s copy replaces the library links with
  full copies and drops `llama-server`'s execute bit (NimScript's `cpFile`), and its `RUNPATH`
  points into the build tree.
- **Supervision differs between the two binaries.**
  - Only `serve` has a watchdog.
  - The window starts the backends on every normal start, skipping them only under `--check`,
    and never reads `JENOVA_NO_BACKENDS`, which only `serve` honours.
  - Leaving the agent backend running after the window quits is deliberate (see Data flow).
- **Blocking and unguarded work in the window.**
  - Saving a note embeds on the GTK thread (up to 30 s per embedding batch).
  - The control worker's retrieval calls are unguarded, and an exception there ends the
    process.
- **Correctness.**
  - Two retrieval races:
    - an index write racing a delete: `indexContent` runs without a transaction, so rows can
      be written for a message deleted while it was being embedded;
    - descendant discovery against fork creation: forks are collected before the delete
      transaction and flagged inside it, so a fork created in between is flagged but never
      unfiled.
    `rag.query` drops hits whose row is flagged deleted (`pathIsLive`), so both leave index rows
    that are never cleaned up rather than surfacing deleted content.
  - A body shorter than its `Content-Length` is accepted as complete.
  - Timestamps are in mixed units. The window writes seconds for conversation `lastModified`,
    message `timestamp` and file-asset `uploadDate`, and milliseconds for note `updatedAt` and
    imported conversations; the Web UI and forks write milliseconds.
- **Test isolation.** The self-tests and a bare `jenova --check` write into the real
  `JCA_HOME` (`TESTS.md`).
