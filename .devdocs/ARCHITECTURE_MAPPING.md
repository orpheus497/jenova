# ARCHITECTURE MAPPING

File-by-file map of the codebase: what lives where, and why. Mandated by `AGENTS.md`
§ WORKSPACE ARCHITECTURE. Update whenever a file is added, removed or relocated.

**Created:** 2026-08-28 (Session 004). **Last updated:** 2026-09-02 08:13 (Session 020).

This file was mandated from the outset and did not exist for Sessions 001–003 —
including Session 001, which moved or deleted 31 files. See `DECISIONS_LOG.md` C-10.

> **Provenance.** Every entry below is first-hand: each file was enumerated on disk this session
> and its role taken from its own header comment, its opening lines, or `file(1)`. Where a role
> could not be established first-hand it is marked **`(unread)`** rather than guessed —
> per Directive 6, an invented description is a fabrication.
>
> `jca_web/src/` is mapped **to directory level only**. A full read of that tree has been
> outstanding since Session 003 and is not claimed here.

---

## 1. Root

**A Nim program: no Makefile, no shell scripts** (D-AM). Build with `nimble` — tasks are in
`jenova_core.nimble`.

| Path | Role |
|---|---|
| `jenova_core.nimble` | Package metadata **and the build system**: `core`, `gui`, `suites`, `llama`, `web`, `clean` |
| `AGENTS.md` | Governance |
| `src/` | The whole program. `jenova_core.nim` and `jenova_gui.nim` are the two entry points; `src/jenova/` holds the modules |
| `bin/` | `jenova` (desktop app) and `jenova-core` (headless server), both build artifacts, plus `jenova.desktop` |
| `tests/` | Shell suites driven by `nimble suites`, plus `nvimctl_check.nim` — the one suite that needs a compiled caller |
| `etc/` | `jenova.conf` (applied profile) and `jenova.local.conf` (**the USER's file — never edited by a session**) |
| `hardware-profiles/` | **Profile data only** — `profile.conf` + `jenova.conf` per profile. Detection and selection are `src/jenova/hardware.nim`; the six shell scripts were archived 2026-09-01 (S-1) |
| `jca_web/` | The SvelteKit Web UI. Still holds the workspace side — workspaces, projects, folders, notes, fileAssets — which the native GUI does not have |
| `public/`, `png/`, `docs/`, `var/`, `external/` | Web bundle, icons, user docs, runtime dirs, submodules |

**Archived to `.devdocs/ARCHIVE/` (D-AM):** `Makefile`, `tests/Makefile`, `scripts/` (8 files),
`lib/` (2 files), `proxy.log`, four orphaned test scripts, `bin/jenova-swap-mount`, and — 2026-09-01 — `hardware-profiles/`'s six shell scripts (`detect-hardware.sh`, `common-setup.sh`, four `jenova-setup`). **The product tree now contains no shell script outside `tests/`.**

**Module roles are in the source headers.** They are not duplicated here: an inventory in prose rots
on the next commit, which is what caused the doc-churn loop.

> **This is deliberate, and it has now been rediscovered twice — do not "fix" it a third
> time.** `AGENTS.md` Directive 4 calls this file a *full file-by-file map*, and §2 below
> does **not** list the fourteen original modules (`db`, `fssync`, `rag`, `models`, `tray`,
> `dbus`, `http`, `upstream`, `paths`, `prompts`, `sha256`, `websearch`, and the two
> selftest modules), deferring instead to each module's own header comment. That tension
> was recorded and left as it stands by Session 019 (2026-09-01 18:07), on rule 9's
> reasoning and D-AN's: a duplicated prose inventory rots on the next commit and
> re-deriving the drift is what consumed whole sessions. **Session 020 filed it as a
> backlog defect anyway and then retracted it on re-reading that note.** The guard is
> written here, at the point of discovery, rather than only in a handoff entry nobody
> re-reads.

## 2. `src/` — the program

Two entry points and one module directory. **Each module's purpose is in its own header comment;
that is the single source of truth and it is not copied here**, because a duplicated inventory rots
on the next commit and re-deriving the drift is what consumed whole sessions (see D-AN).

| | |
|---|---|
| `jenova_core.nim` | Headless server. Subcommands: run `jenova-core` with no arguments |
| `jenova_gui.nim` | Desktop application. `bin/jenova`. Flags: `--no-tray`, and **`--check`** — the start-up smoke test (`TESTS.md` §0h): builds the whole window under a real GTK and exits, showing no window and starting no backend |
| `jenova/` | The modules — server, routing, database, filesystem mirror, RAG, completion pipeline, backend lifecycle, model discovery, GUI, tray, D-Bus, **theme, canvas** |

**Added 2026-08-31 (G-1 … G-5, ruling D-AP):** `theme.nim`, `canvas.nim`, `markdown.nim`.

**Added 2026-08-31 (G-7, G-18, G-19):** `sourceview.nim`, `nvimctl.nim`, `vte.nim`.

**Added 2026-09-01 (G-31, rulings D-BK and D-BL):** `settings.nim` — the desktop application's
settings: the field declarations, the file store under `p.state`, the validator, and
`applyTo`, which merges the sampling and penalty parameters into the outbound request
body. **It sits beside `config.nim` in the layering, not beside `gui.nim`**: it depends
only on `paths` and `std/json`, and `pipeline.chatBody` calls the merge. That placement
is deliberate and is the reason the whole settings feature is assertable from
`pipeline-selftest` with no window — see D-BH for what the alternative cost.

**Added 2026-09-01 (S-1, ruling D-BC):** `hardware.nim` — hardware detection, the
`profile.conf` reader, the profile scorer and apply, replacing the archived
`detect-hardware.sh`. **Same layering argument as `settings.nim`**: it depends only on
`std` and knows nothing of owlkettle, so `hardware-selftest` asserts the whole scoring
ladder with no window and no machine. `gui.nim` draws the Hardware screen and
`jenova_core.nim` exposes `hardware detect|list|apply`; neither contains any scoring.
**It never sets a `sysctl`** (D-BN) — it reads them to describe the machine and nothing
more.

**Added 2026-09-01 (G-43, ruling D-BU):** `workspace.nim` — the workspace artifact
context: the four-level scoping ladder (folder → project → workspace → global), the
FOCUS-note escape, and the literal output format the Web UI teaches the model. **Same
layering argument as `settings.nim` and `hardware.nim`**: it imports `db` and `std` and
nothing else, so `workspace-selftest` asserts the whole ladder with no window, no backend
and no conversation. `pipeline.chatBody` injects what it returns and `gui.nim` only
supplies the scope ids it already holds.

**Removed 2026-09-01 (G-46, ruling D-BW):** the document side panel. `vte.nim` lost
`configureDoc` and `newDocTerminal`, `nvimctl.nim` lost `docSocketPath` and
`DocSocketName`, `theme.nim` lost `.doc-panel` and `.doc-panel-closed`, and `gui.nim`
lost the `DocTerminal` renderable with the panel's state and procs. **There is one
embedded Neovim now, the editor page's**, which is what makes `pipeline.configureEditor`
a single call in `gui.run` and moots Q-30.

**`nvimctl.nim` also gained `editorEnv` (G-45, D-BS)** — the environment the embedded
editor is spawned with, so the in-tree `jvim/` configuration loads. It lives there rather
than in `vte.nim` because `vte.nim` is GUI-only FFI and `nvimctl.nim` links into
`jenova-core`, which is what makes the environment assertable at all.

**No new module for Step 7 (2026-09-01), and that is the point.** Its four features went
into the modules that already owned the behaviour, so each could be asserted:
`markdown.nim` gained tables, task lists and strikethrough and is **now linked into
`jenova-core`** purely so `markdown-selftest` can reach it; `pipeline.nim` gained
`classifyError` (G-35) and `contentFor` (G-30), for the reason `chatBody` is there — the
request body and the failure report are the two things that were got wrong while they
lived in `gui.nim`; and `api.nim` gained `cascadeCount`, which derives its numbers by
rewriting the `Cascades` statements rather than restating them. **`gui.nim` holds the
widgets and the socket cancellation**, which is the one part that cannot move: it is a
file descriptor and two threads (D-BO).

**Finishing 7b (16:19) moved more of it down, and one move was forced.**
`pipeline.nim` now also holds the attachment *classifier* — `Attachment`,
`readAttachment`, `looksTextual`, `mimeForImage`, `uriToPath` — and `gui.nim`'s
`PendingAttachment` is an alias of `pipeline.Attachment`. The forcing reason is worth
recording: the drag-and-drop drain runs inside the `viewable`'s own timer, where a proc
taking `AppState` **cannot exist yet**, because that type is produced by the macro the
timer is written inside. Splitting the decision out was the only way to share one
implementation between the picker and the drop — and it made all of it assertable.

**`gui.nim` gained one renderable and seven protos.** `DropZone` is a renderable for the
reason `AutoScroll` is: owlkettle offers no route from a `gui:` block to a `GtkWidget`,
and a `GtkDropTarget` has to attach to one. The protos are the four for the drop target
and three for the clipboard; **everything else was already in owlkettle's bindings and
is imported**, including `g_signal_connect_data`, `GValue`, `G_TYPE_STRING`,
`GdkClipboard`, `GAsyncResult` and both display/clipboard getters. Thumbnails needed
**no** new proto at all — `loadPixbuf` already wraps
`gdk_pixbuf_new_from_file_at_scale`, so a pasted or attached image is written to the
cache dir under its own digest and loaded from there.

- **`nvimctl.nim`** reads the document open in Neovim — path, buffer, cursor, dirty flag, filetype —
  through `nvim --server <sock> --remote-expr`. **It is deliberately not an RPC client:** Neovim
  ships the expression evaluator, so msgpack framing would re-implement what exists (Directive 3),
  and the program already drives `wl-copy`, `git`, `fetch` and `xdg-open` the same way. The buffer,
  not the file on disk, is the point — unsaved work is what the USER is looking at.
- **`vte.nim`** is the terminal hosting `nvim`, a hand-written `vte-2.91-gtk4` binding. **It spawns
  at the same socket `nvimctl` reads**, which is what ties the tab to the `Editor:` intent. The
  `renderable` lives in `gui.nim` for the reason `sourceview.nim`'s does — owlkettle's macro emits
  an unexported type. **GUI binary only**; `jenova-core` links neither.

**`sourceview.nim` and `vte.nim` are the program's only FFI *modules*.** Both follow one shape:
flags from `staticExec("pkg-config …")`, a small Nim surface, the widget declared in `gui.nim`.

**Two files now also declare a handful of individual protos** (2026-09-01, G-31), and the rule
they follow is worth stating because it is what keeps this from spreading: **check owlkettle's
own bindings first and declare only what is genuinely missing.** `owlkettle/bindings/gtk` and
`.../adw` are importable directly — `sourceview.nim` already did — and carry most of what was
needed. `theme.nim` declares **two** (`gtk_style_context_remove_provider_for_display`,
`adw_style_manager_get_dark`) for the runtime palette swap; `gui.nim` declares **three**
adjustment getters for `AutoScroll`. Everything else is imported.

- **`markdown.nim`** splits an assistant reply into text and fenced-code blocks and converts inline
  markdown to Pango markup. An unterminated fence renders as code so a block appears while it is
  still streaming rather than popping in when the closing fence lands.

`api.nim` gained `putEntity`/`deleteEntity` — the GUI sidebar writes through the same
`upsert`/`softDelete` the HTTP routes use, so cascades and the filesystem mirror apply whichever
surface the user is on. The GUI writes no entity SQL of its own.

- **`theme.nim`** holds the palette **as Nim constants** and generates the GTK4 stylesheet from
  them. **Two palettes since 2026-09-01** (G-31's Theme setting): a `Palette` record, `DarkPalette`
  assembled from the constants above it, and `LightPalette` converted from the Web UI's `oklch`
  `:root` block. `active()` is what `canvas.nim`, `vte.nim` and `sourceview.nim` read, because each
  paints outside the stylesheet and cannot pick a colour up from a `@define-color`. `applyPalette`
  swaps it on a running window, which owlkettle itself cannot do. The palette is not duplicated in CSS text, because `canvas.nim` paints behind the widgets
  and needs the same values — the Web UI's own canvas hard-codes colours that match no token in
  `app.css`, which is the drift this arrangement prevents.
- **`canvas.nim`** is the `NeuralCanvas` port: a cairo particle field on a `DrawingArea`.

Both headers record what did **not** survive the port from `jca_web/src/app.css` —
`backdrop-filter` and `mix-blend-mode` have no GTK4 equivalent. That belongs in the source, not
here.

**Confirmed 2026-08-31 (Session 007)** by reading every module header: each file below the two entry
points has one, and the headers are the authority this file defers to. `BLUEPRINT.md` §4 names the
layering; neither file lists the modules, deliberately.

**Deleted 2026-08-31, not deferred:** `llama.nim` and `inference.nim`. They duplicated
`llama-server`, which is the engine (D-AF); duplicating it is the opposite of being a harness for
it. The `JENOVA_INPROC` path went with them.

**Both binaries link the same modules.** The split exists so a LAN or server host builds without
GTK — N-7 requires LAN mode to serve whether or not the GUI runs.

## 3. `hardware-profiles/` — 6 profiles, uniform depth 2, **data only**

Layout `<backend>/<config>` per ruling D-F. Each directory holds exactly two files now:
`jenova.conf` (**consumed by `config.nim`**, unprefixed names) and `profile.conf`
(metadata plus the `MATCH_*` patterns the scorer reads).

**As of 2026-09-01 15:13 there are no scripts here at all.** `detect-hardware.sh`,
`common-setup.sh` and the four per-profile `jenova-setup` scripts are archived to
`.devdocs/ARCHIVE/hardware-profiles/`, and **detection, scoring and apply are
`src/jenova/hardware.nim`** — reached from the window's Hardware screen and from
`jenova-core hardware`. `PROGRESS.md` 2026-09-01 15:13, `PLANS.md` Step 6, D-BC.

**Kernel tuning is not part of the product and nothing replaced those scripts (D-BN).**
Jenova applies no `sysctl` and never writes `/etc/sysctl.conf`; it reads `sysctl` only
to detect the machine.

**Re-verified 2026-09-01, key by key across all six profiles.** Every `PROFILE_*` value
matches the `jenova.conf` beside it except two on `Vulkan/dgpu-i5-1135g7` — `FIT_TARGET`
256 vs 128 and `HEALTH_TIMEOUT` 120 vs 90 — **and both are inert**, since `-fitt` is
only passed when the layer count is `all` (`lifecycle.nim:99`) and the watchdog
hardcodes its own constants (`lifecycle.nim:357`). The long-running "three profiles
contradict themselves" item was stale and is closed.

| Profile | Role in detection |
|---|---|
| `Vulkan/dgpu-igpu-i5-1135g7` | The USER's machine. Wins at **40** — the only profile declaring `MATCH_GPU_1` |
| `Vulkan/dgpu-i5-1135g7` | Same CPU and dGPU, no `MATCH_GPU_1`. Scores 35 on this machine, and wins if the Iris Xe is absent — that split is the whole purpose of the `-8` penalty |
| `Vulkan/apu-ryzen7-5700u` | Ryzen 7 5700U + Vega 8 |
| `Vulkan/dgpu-generic-12gb` | The **GPU fallback**, allowlisted by device name |
| `CPU/generic` | The **last-resort fallback** — no GPU pattern at all |
| `CUDA/dgpu-generic` | **`PROFILE_OPT_IN=1` — excluded from scoring entirely** (D-B). Unreachable on FreeBSD in any case |

**`HW_STORAGE` was `ext4/xfs/btrfs` on `apu-ryzen7-5700u` and `CPU/generic`** — Linux
filesystems on a FreeBSD-only project. Corrected to `ZFS` on 2026-09-01 (S-2, closed).

Supporting: `README.md`, which documents the scoring ladder and the profile format.

## 4. `etc/`

| File | Role |
|---|---|
| `jenova.conf` | The deployed hardware profile, mirrored here by `--apply-profile`. Read by `config.nim`, which applies environment → `jenova.local.conf` → `jenova.conf`. *This row described `jenova-ca` sourcing order and `test_validate_arg.sh` until 2026-08-31; both were deleted — see D-AM, Q-9* |
| `jenova.local.conf` | The USER's machine file. **Never edited by a session** (SETTLED FACT) |

## 5. `tests/`

Shell suites run by **`nimble suites`** (which builds both binaries first), plus
`nvimctl_check.nim` — the compiled driver `test_nvimctl.sh` needs, because `nvimctl` has no
`jenova-core` subcommand to curl. Each runs in a scratch `JCA_HOME` and none spawns a
`llama-server` backend; `test_nvimctl.sh` spawns a headless `nvim` and skips when none is installed.
Specs are in `TESTS.md`.

**Six suites, plus the self-test subcommands inside `jenova-core`.** *Read the list out of
`src/jenova_core.nim` — do not carry a number here. This line has said four, five, six,
nine and ten, and was wrong in three files three different ways on 2026-09-01 (rule 9).*

**Every one of them exercises `jenova-core`. Nothing tests `gui.nim` at all** — no
suite, no self-test, no driver. Every GUI defect in this project's history was found by
the USER looking at the screen. That is recorded here because the outstanding work is
mostly GUI *logic* (branch trees, message mutation, parameter plumbing), and `PLANS.md`
names for each step what would prove it worked.

**Archived 2026-08-31:** `test_gpu.sh`, `test_gpu_single.sh`, `test_validate_arg.sh` (which rewrote
`etc/jenova.conf` as a side effect) and `download-draft-model.sh` — all orphaned, none wired into
any target.

## 6. `jca_web/` — SvelteKit Web UI

Directory-level, plus **the component surface, enumerated 2026-09-01**.

**How it was enumerated, so it is not re-derived by guesswork:** every component group
ships a barrel file listing its exports with a doc comment each —
`src/lib/components/app/index.ts` names the groups (`actions`, `badges`, `chat`,
`content`, `dialogs`, `forms`, `mcp`, `misc`, `models`, `navigation`, `server`), and
each group's own `index.ts` names and describes its components. **That is the
authoritative inventory of what the Web UI does**, and it is what the GUI parity scope
must be checked against — the previous six-item scope was written from a summary and
missed most of it (see `TODOS.md` G-28 … G-36).

The groups that matter for parity: **`chat`** is by far the largest (attachments, the
input form, message rendering with branching and actions, the screen, settings, the
sidebar), then **`models`** (selector, model information), **`dialogs`** (errors,
confirmations, previews, import/export), **`content`** (markdown with tables and
LaTeX, syntax highlighting, collapsible blocks, `FilesView`) and **`server`** (status,
error splash with retry, loading splash). **`mcp`** is deferred by the USER.

`src/lib/{actions,assets,components,constants,contexts,enums,hooks,markdown,services,stores,types,utils}`,
`src/routes/`, `src/app.css` (the Google Fonts leak, B-01), `src/service-worker.js`, `static/`,
`docs/flows/` (two Mermaid diagrams depicting an impossible path, B-04), `tests/`, plus the
Vite / Svelte / Playwright / ESLint / TS configs. Zero OS coupling (C-5).

## 6b. `jvim/` — the embedded Neovim's configuration. **Added by the USER 2026-09-01**

**4,201 files, untracked as of this session.** A self-contained Neovim distribution that
the USER has designated the default configuration for the Neovim that Jenova embeds.

**It is not product Lua and the no-Lua rule does not reach it (D-BS).** D-AM/D-AZ and
`BRIEFING.md` rule 2 archive Lua that *implements Jenova*; Lua is the configuration
language of a program Jenova embeds, and porting a Neovim config to Nim is not a coherent
idea. **Recorded here because a session applying the rule mechanically would archive a
deliberate addition.**

| Path | Role |
|---|---|
| `init.lua` | Entry point — options, spec runner, keymaps, health checks |
| `lua/jvim/` | First-party native UI stack — tree, finder, statusline, tabline, terminal, dashboard, notify, keyhelp, indent guides, layout, diagnostics list, icons, ui |
| `lua/jenova/` | **The integration layer.** `endpoints.lua` (the URL/env contract), `chat.lua`, `health.lua`, `lan.lua`, `monitor.lua`, `spec_runner.lua` |
| `lua/jenova/agent/` | Tool registry, memory, learning, context compaction, provider, engine |
| `lua/jenova/agent/tools/` | `buffer_read/write/edit/multiedit/grep/glob/ls/list`, `lsp`, `shell`, `vim_cmd`, `ask_user`, `remember` |
| `pack/` | Vendored plugins — zero package manager, zero network on first boot. **Carries 24 third-party shell scripts; none is Jenova product code** |
| `colors/`, `doc/`, `plugin/` | Themes, `:help jvim` tags, UI/dashboard plugin files |

**The contract with the Nim side, read out of `lua/jenova/endpoints.lua`:** host from
`JENOVA_CONNECT_HOST`/`JENOVA_HOST`, ports from `JENOVA_PORT` (8080),
`JENOVA_LLAMA_PORT` (8081) and `JENOVA_LLAMA_EMBED_PORT` (8082); it calls
`/v1/chat/completions`, `/infill` and `/api/storage/<path>`, and reads `JENOVA_ROOT` and
`JENOVA_LAN_MODE`. **Every one of those routes is already served** — `routes.nim` routes
`/infill`, `server.nim` handles `/api/storage`.

**What is not wired (G-45):** `vte.nim` spawns with `envv = nil`, so `NVIM_APPNAME` is
never set and none of the `JENOVA_*` variables are passed. Both embedded editors run
stock Neovim.

**Two things noted, neither acted on:** `jvim/README.md` documents an `install.sh` that
is **not in the tree**, and `jvim/nvim.log` is a stray log (its own `.gitignore` ignores
`*.log`).

---

## 7. Supporting trees

| Path | Role |
|---|---|
| `public/` | Prebuilt static client bundle (`bundle.js`, `bundle.css`, `index.html`, icons) |
| `png/` | Source icons. Ships `jca.jpg`, `jca_grey.jpg`, `jenova.jpg/png`, `jvim.jpg`, splash art |
| `external/` | Submodules — `llama.cpp` and `ext_bin`. **Untouched by policy** |
| `var/` | Runtime logs/cache within the source tree |
| `docs/` | User-facing documentation. **Five files** — `architecture.md`, `context-and-retrieval.md`, `install.md`, `privacy.md`, `usage.md`. Empty `architecture/`, `installation/`, `usage/` directories remain (B-38). *This entry said "8 files" until 2026-08-31; it was never eight.* There is no `docs/README.md` — the archived `BLUEPRINT_pre-007.md` §7 cites one |
| `.devdocs/` | This workspace, incl. `ARCHIVE/` — everything retired from the product tree. Trackers + `ARCHIVE/` (pre-consolidation reference). **Fully tracked in git — corrected 2026-08-31.** This entry previously claimed `.gitignore:54` ignores `/.devdocs/` and that the trackers were therefore local-only. **That was false in both halves:** `.gitignore` contains no `devdocs` entry at all, and `git ls-files .devdocs/` lists the entire tree. **The process record is committed and public in repository history.** `PROGRESS.md`'s 2026-08-28 16:29 entry carries the same false claim and is corrected there |
