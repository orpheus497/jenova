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
| `hardware-profiles/` | Profile data plus `detect-hardware.sh`, the setup-time selection tool. Data outlives the rewrite |
| `jca_web/` | The SvelteKit Web UI. Still holds the workspace side — workspaces, projects, folders, notes, fileAssets — which the native GUI does not have |
| `public/`, `png/`, `docs/`, `var/`, `external/` | Web bundle, icons, user docs, runtime dirs, submodules |

**Archived to `.devdocs/ARCHIVE/` (D-AM):** `Makefile`, `tests/Makefile`, `scripts/` (8 files),
`lib/` (2 files), `proxy.log`, four orphaned test scripts, `bin/jenova-swap-mount`.

**Module roles are in the source headers.** They are not duplicated here: an inventory in prose rots
on the next commit, which is what caused the doc-churn loop.

## 2. `src/` — the program

Two entry points and one module directory. **Each module's purpose is in its own header comment;
that is the single source of truth and it is not copied here**, because a duplicated inventory rots
on the next commit and re-deriving the drift is what consumed whole sessions (see D-AN).

| | |
|---|---|
| `jenova_core.nim` | Headless server. Subcommands: run `jenova-core` with no arguments |
| `jenova_gui.nim` | Desktop application. `bin/jenova` |
| `jenova/` | The modules — server, routing, database, filesystem mirror, RAG, completion pipeline, backend lifecycle, model discovery, GUI, tray, D-Bus, **theme, canvas** |

**Added 2026-08-31 (G-1 … G-5, ruling D-AP):** `theme.nim`, `canvas.nim`, `markdown.nim`.

**Added 2026-08-31 (G-7, G-18, G-19):** `sourceview.nim`, `nvimctl.nim`, `vte.nim`.

- **`nvimctl.nim`** reads the document open in Neovim — path, buffer, cursor, dirty flag, filetype —
  through `nvim --server <sock> --remote-expr`. **It is deliberately not an RPC client:** Neovim
  ships the expression evaluator, so msgpack framing would re-implement what exists (Directive 3),
  and the program already drives `wl-copy`, `git`, `fetch` and `xdg-open` the same way. The buffer,
  not the file on disk, is the point — unsaved work is what the USER is looking at.
- **`vte.nim`** is the terminal hosting `nvim`, a hand-written `vte-2.91-gtk4` binding. **It spawns
  at the same socket `nvimctl` reads**, which is what ties the tab to the `Editor:` intent. The
  `renderable` lives in `gui.nim` for the reason `sourceview.nim`'s does — owlkettle's macro emits
  an unexported type. **GUI binary only**; `jenova-core` links neither.

**`sourceview.nim` and `vte.nim` are the program's only FFI.** Both follow one shape: flags from
`staticExec("pkg-config …")`, a small Nim surface, the widget declared in `gui.nim`.

- **`markdown.nim`** splits an assistant reply into text and fenced-code blocks and converts inline
  markdown to Pango markup. An unterminated fence renders as code so a block appears while it is
  still streaming rather than popping in when the closing fence lands.

`api.nim` gained `putEntity`/`deleteEntity` — the GUI sidebar writes through the same
`upsert`/`softDelete` the HTTP routes use, so cascades and the filesystem mirror apply whichever
surface the user is on. The GUI writes no entity SQL of its own.

- **`theme.nim`** holds the palette **as Nim constants** and generates the GTK4 stylesheet from
  them. The palette is not duplicated in CSS text, because `canvas.nim` paints behind the widgets
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

## 3. `hardware-profiles/` — 6 profiles, uniform depth 2

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

**Archived 2026-08-31:** `test_gpu.sh`, `test_gpu_single.sh`, `test_validate_arg.sh` (which rewrote
`etc/jenova.conf` as a side effect) and `download-draft-model.sh` — all orphaned, none wired into
any target.

## 6. `jca_web/` — SvelteKit Web UI

Directory-level only; a full read remains outstanding.

`src/lib/{actions,assets,components,constants,contexts,enums,hooks,markdown,services,stores,types,utils}`,
`src/routes/`, `src/app.css` (the Google Fonts leak, B-01), `src/service-worker.js`, `static/`,
`docs/flows/` (two Mermaid diagrams depicting an impossible path, B-04), `tests/`, plus the
Vite / Svelte / Playwright / ESLint / TS configs. Zero OS coupling (C-5).

## 7. Supporting trees

| Path | Role |
|---|---|
| `public/` | Prebuilt static client bundle (`bundle.js`, `bundle.css`, `index.html`, icons) |
| `png/` | Source icons. Ships `jca.jpg`, `jca_grey.jpg`, `jenova.jpg/png`, `jvim.jpg`, splash art |
| `external/` | Submodules — `llama.cpp` and `ext_bin`. **Untouched by policy** |
| `var/` | Runtime logs/cache within the source tree |
| `docs/` | User-facing documentation. **Five files** — `architecture.md`, `context-and-retrieval.md`, `install.md`, `privacy.md`, `usage.md`. Empty `architecture/`, `installation/`, `usage/` directories remain (B-38). *This entry said "8 files" until 2026-08-31; it was never eight.* There is no `docs/README.md` — the archived `BLUEPRINT_pre-007.md` §7 cites one |
| `.devdocs/` | This workspace, incl. `ARCHIVE/` — everything retired from the product tree. Trackers + `ARCHIVE/` (pre-consolidation reference). **Fully tracked in git — corrected 2026-08-31.** This entry previously claimed `.gitignore:54` ignores `/.devdocs/` and that the trackers were therefore local-only. **That was false in both halves:** `.gitignore` contains no `devdocs` entry at all, and `git ls-files .devdocs/` lists the entire tree. **The process record is committed and public in repository history.** `PROGRESS.md`'s 2026-08-28 16:29 entry carries the same false claim and is corrected there |
