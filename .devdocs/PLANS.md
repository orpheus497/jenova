# PLANS

Forward-looking implementation plans. Every item here has a matching `TODOS.md` Active entry; on
execution it moves to `PROGRESS.md`.

**Plan of record, revised 2026-09-29T23:30Z**, after the USER's answers (`DECISIONS_LOG.md`
2026-09-29T23:30Z). It replaces the 23:04Z version. Amended 2026-09-30T02:07Z with the defects and
wrong comments found while checking every devdoc and product doc against the code (4.4, 4.5, 5.3,
5.4, the Stage 7 comment list, two Stage 8 items), and Stage 6's status. Every item below was established by the lead
running it on this machine **[run]** or reading the code **[code]**, with the code location given; no
item rests on a code comment, a devdoc, or a subagent's report.

**Stages 1 and 2 were approved and are done** (2026-09-30T03:07Z; `PROGRESS.md`, `DECISIONS_LOG.md`).
Every other stage needs the USER's approval first (`AGENTS.md` rule 1).

## Rulings in force

- FreeBSD and Linux (Arch, Debian, Fedora) are supported.
- The GUI and the Web UI are the two points of access; both stay, and they behave the same.
- The installed program is separate from the repository: built in the repository, installed into
  `$JCA_HOME` (`AGENTS.md` rule 4). The installer is part of the Nim build — no shell scripts, no
  model downloader, no `sudo` or tuning scripts.
- The OS is detected when building and when running; no OS-specific build folders.
- Git is out of scope. `~/JCA` is left alone. The llama.cpp update is intended.
- Implementation first; tests and CI last.
- References in code comments are fixed where code is touched, never mass-repaired.

---

## Stages 1 and 2 — done 2026-09-30T03:07Z

Built and checked on Arch Linux; the record is in `PROGRESS.md`, the choices made while building in
`DECISIONS_LOG.md` 2026-09-30T03:07Z and 04:36Z. `nimble llama` has since been run: this host's
static `llama-server` is in `external/ext_bin/bin/`.

## Stage 3 — The installed program, separate from the repository

**What the installed program must contain**, from every place the running code reads its own root
[code]:

| Read by | Path under the root |
|---|---|
| `paths.resolve` (installed layout) | `bin/llama-server`, and its libraries in `bin/` (`paths.nim:85-88`) |
| `server.start` from the window and from `serve` | `public/` — the Web UI (`gui.nim:7396`, `jenova_core.nim:7732`) |
| `hardware.listProfiles` | `hardware-profiles/` (`gui.nim:1009`, `jenova_core.nim:243`) |
| the window's logo | `png/jenova.jpg` (`gui.nim:7457`) |
| `nvimctl.editorEnv` | `jvim/` — the embedded editor's configuration (`nvimctl.nim:60-62`) |
| `config.configDir` | `etc/`, only when `$JCA_HOME/etc/jenova.conf` is absent (`config.nim:94-96`) |

`paths.nim` already treats a root that holds `bin/llama-server` and no `external/llama.cpp` as an
installed layout, and takes the root from the running binary's own location (`paths.nim:33-49`)
[code]. So binaries installed in `$JCA_HOME/bin` make `$JCA_HOME` the root, and `hardware apply`
already writes `$JCA_HOME/etc/jenova.conf` (`hardware.nim:376-388`) [code].

- **3.1 An install step in the Nim build.** It builds, then copies the table's contents plus
  `jenova` and `jenova-core` into `$JCA_HOME`. The copying is done by compiled Nim code (a
  `jenova-core` subcommand the nimble task calls), because NimScript's `cpFile` drops execute bits and
  follows symlinks [run]. It refuses to install a binary built for a different OS — this checkout's
  `external/ext_bin` is a FreeBSD build [run]. Files: `jenova_core.nimble`, `jenova_core.nim`, a new
  module for the copy.
- **3.2 Profile at install.** When `$JCA_HOME/etc/jenova.conf` does not exist, the install applies
  the best-matching profile (as `hardware apply --best` does). `jenova.local.conf` is never
  overwritten.
- **3.3 Launch from the installed copy:** `jenova` and `jenova-core` on the user's `PATH`, and the
  desktop entry pointing at the installed binary with its icon.
- **3.4 Uninstall** removes the installed program and leaves models, workspaces, the database and
  configuration in `$JCA_HOME` alone. **Update** is building and installing again.

After Stage 3, Jenova runs without the repository.

## Stage 4 — The GUI and the Web UI behave the same

- **4.1 The Web UI does not tell the server which workspace a chat is in.** The GUI sends
  `X-Jenova-Scope` built from the conversation's folder, project and workspace (`gui.nim:2197-2201,
  306-311`); the server scopes retrieval from that header alone (`server.nim:294-295`), and a request
  without it searches only content outside every workspace (`rag.nim` `inScope`). The Web UI has the
  same three ids in hand (`chat.service.ts:106-114`) but sends only JSON headers
  (`chat.service.ts:341-346`) [code]. Fix: the Web UI sends the header, in the format `rag.formatScope`
  writes (`rag.nim:35-38`). Files: `jca_web/src/lib/services/chat.service.ts`.
- **4.2 The notes-and-files block is bounded in the GUI and not in the Web UI.** Both apply the same
  scoping and format (`workspace.contextFor`; `WorkspaceService.getWorkspaceContext`), but only the
  GUI caps it at 64 KiB and names what it left out (`workspace.nim:32, 232-304`) [code]. Fix: the same
  bound and notice in the Web UI. Files: `jca_web/src/lib/services/workspace.service.ts`.
- **4.3 Timestamps are in different units.** The GUI writes `lastModified` and message timestamps in
  seconds (`gui.nim:701, 754, 757`); the Web UI writes milliseconds (`database.service.ts:43, 77`)
  [code]. Ordering by `lastModified` therefore puts every chat the Web UI touched above every chat only
  the GUI touched. Fix: the GUI writes milliseconds, and existing second values are converted once.
  Files: `gui.nim`, `db.nim` (migration).
- **4.4 The GUI cannot move an item; the Web UI can.** The Web UI moves chats, notes and files between
  workspaces, projects and folders by drag and drop (`FilesView.svelte` `handleDrop` →
  `workspaceStore.moveConversation`/`moveNote`/`moveFileAsset`); the GUI writes container ids only at
  creation (`gui.nim` `newChat`, `createNote`, attachment filing) [code]. Report 02 had filed this as
  a beyond-parity proposal (P-E2). Fix: a move in the GUI, through `api.putEntity`. Files: `gui.nim`.
- **4.5 The Web UI's Pull leaves the Push and Pull buttons disabled.** `handlePull` resets
  `isSyncing` only on error, expecting the page to reload (`ChatSidebarActions.svelte:48-60`);
  `SyncService.pull` no longer reloads — it dispatches `jenova-sync-updated`
  (`sync.service.ts:325-327`) — so after a successful Pull both buttons stay disabled until the page
  is reloaded [code]. Fix: reset it in a `finally`. Files: `ChatSidebarActions.svelte`.

Found by the Linux deployment test (2026-09-30T04:32Z) — reproduced against a running instance by
the verifiers, and each read in the code by the lead:
- **4.6 (high) Every Web UI page load creates new empty "FOCUS / RULES" notes.** The Web UI sends
  `isFocusNote` as a JSON boolean; `api.f` stores it as the text `true` (`api.nim:181-186`) and
  `rowToJson` reads that back as 0 (`api.nim:137-144`), so `ensureFocusNotes`
  (`workspace.svelte.ts:~300-330`) never finds one and creates another pair per container on each
  load; the duplicates are indexed and fill retrieval. Fix: store booleans as 1/0, and read `true`
  back as 1 for the rows already written. Files: `api.nim`.
- **4.7 The Web UI deletes a note's mirror file on every save when a path contains a space.**
  `SyncService.syncEntity` compares the percent-encoded path it builds with the decoded path the
  storage listing returns (`sync.service.ts:18-24, 460-474`), so they never match: it DELETEs the
  file into the trash and re-POSTs it, and for an empty note the POST is refused (`api.nim:1181`),
  leaving no mirror. Files: `sync.service.ts`.
- **4.8 A note restored from the Web UI's Trash view is not re-indexed**: `fssync.restoreTrash` only
  clears `is_deleted` (`fssync.nim:806-813`), unlike `api.restoreItem`. And Restore on a storage-trash
  entry does nothing: `TrashView` derives the original path with `/\.trash\/[0-9]+_/`
  (`TrashView.svelte:43`), which storage trash (`.trash/<epoch>/<path>`) never matches.
- **4.9 Deleting a note in the Web UI lands on a dead page**: `goto('/notes')` without the hash
  (`notes/[id]/+page.svelte:34-35`) makes a full load of `/notes`, which the server answers 404.
- **4.10 The service worker never installs**: its precache lists SvelteKit's `_app` build files
  (`service-worker.js:6-12`), which `scripts/post-build.sh` deletes. The manifest declares
  `favicon.jpg` as 192×192 and 512×512; it is 906×905.
- **4.11 The Web UI's Continue restarts the answer** — its request lacks the
  `continue_final_message`/`add_generation_prompt` the GUI sends (`chat.service.ts:248-265`) — and it
  retries every failed request three times, 4xx included (`chat.service.ts:338-352`).

## Stage 5 — Defects

- **5.1 A request body shorter than its `Content-Length` is accepted.** The receive loop stops when the
  connection closes and returns what it has (`http.nim:243-248`) [code]. Fix: refuse it. Files:
  `http.nim`.
- **5.2 Deleting a conversation can leave index rows behind.** Its forks are collected before the
  transaction and flagged inside it (`api.nim:413-431`), so a fork created in between is flagged but
  never unfiled (`api.nim:435`); and an index write that is embedding while its message is deleted
  inserts rows for the deleted message (`rag.nim:286-327, 389-399`) [code]. Queries hide these rows
  (`rag.nim:874-878`, `pathIsLive`), so the effect is rows that are never cleaned up, not leaked
  content. Fix: collect the affected ids inside the transaction; re-check liveness before writing the
  index rows. Files: `api.nim`, `rag.nim`.
- **5.3 A moved embedding port is ignored where most embedding happens.** `rag.embed` reads its
  address from threadvars (`rag.nim:206-207`), defaulting to `127.0.0.1:8082` (`rag.nim:220-221`).
  `configureEmbed` is called on the GUI's main thread and control worker (`gui.nim:7356, 894`) and on
  `serve`'s main thread and watchdog (`jenova_core.nim:7621, 7712`) — never on the server's worker
  threads (`server.nim` has no call), which run every retrieval query (`pipeline.prepare` →
  `rag.query`) and the indexing of everything the Web UI saves over `/api/db` [code]. With
  `LLAMA_EMBED_PORT` set to anything but 8082, those embeddings fail and retrieval falls back to
  keywords, silently. Fix: configure the address once per worker thread in `server.classWorker`, or
  make it process-wide. Files: `server.nim` or `rag.nim`.
- **5.4 `POST /api/db/cache` reports success when nothing was stored.** It calls
  `pipeline.cacheStore`, which returns nothing and swallows every failure and skips an entry over
  1 MiB, then answers `{"status":"ok"}` (`api.nim:1235-1236`) [code]. Fix: return whether it stored,
  and answer accordingly. Files: `pipeline.nim`, `api.nim`.

Found while building Stages 1 and 2 (2026-09-30T03:07Z):
- **5.5 "Open Web UI" can stall the window's control worker.** `runOutput` waits for `xdg-open`,
  kills it after 5 s, then reads its output to end of file (`gui.nim:518-530`); a browser that
  `xdg-open` starts in the foreground inherits the pipe, so the read lasts until the browser exits.
  The job runs on the control worker that also serves the 3-second poll, start, stop and restart
  (`gui.nim:900-902`) [code]. Fix: do not read the output of `xdg-open`, or read it without
  waiting for end of file. Files: `gui.nim`.
- **5.6 An i5-1135G7 with only its Iris Xe gets the dual-GPU profile.** A `MATCH_GPU_0` miss scores
  +0 (`hardware.nim:445`) while the `MATCH_GPU_1` hit scores +5, so `dgpu-igpu-i5-1135g7` scores 35
  against `dgpu-i5-1135g7`'s 30 — a 9B and its drafter on the iGPU alone [code]. Fix: a missing
  primary GPU disqualifies or is penalised. Files: `hardware.nim`, its self-test.
- **5.7 Settings that nothing reads.** `JENOVA_HEALTH_TIMEOUT` is in `config.Keys` (`config.nim:51`)
  and set by several profiles; `JENOVA_WATCH_INTERVAL` was documented in four confs while the
  watchdog's 30 s is fixed (`lifecycle.nim` `defaultWatch`); `PID_FILE` (`jenova-ca.pid`) is resolved
  and printed (`paths.nim:83, 174`) and never written [code]. Decide for each: use it, or remove it.
- **5.8 The dual-GPU profile puts most of a model on the Iris Xe.** With `TENSOR_SPLIT` empty,
  llama.cpp splits layers by each device's free memory, and the Iris Xe reports ~11.8 GiB of shared
  RAM against the GTX 1650 Ti's 4 GiB; `-fitt` does not rebalance a split that already fits
  (`llama-model.cpp` default split, `common/fit.cpp`) [code, and measured on the Nemotron 4B:
  ~1.5 GiB on the GTX, ~4 GiB on the iGPU, ~3 tok/s].

Also found by the Linux deployment test, each read in the code:
- **5.9 The GUI drops a reasoning-only assistant turn from the next request**
  (`gui.nim:2134`, `m.text.len == 0: continue`), so the model sees two user turns in a row.
- **5.10 The history budget assumes 2 bytes per token** (`pipeline.nim:278-281`); dense text such as
  logs runs ~1.1, so a conversation under the byte budget can still overflow the slot and every
  later turn is refused.
- **5.11 A malformed JSON body gets 500, not 400**: `pipeline.prepare` passes it through
  (`pipeline.nim:370-376`) and llama-server calls its own parse error a server error.
- **5.12 `--spm-infill` is passed for every model** (`lifecycle.nim:173`); a model without FIM tokens
  (the Nemotron 4B) answers `/infill` with 501, and `llama.vim` drops that silently, so the editor's
  completion does nothing.
- **5.13 An empty note is indexed as its title alone** (`rag.nim:451-457`), and with
  `SemanticFloor` 0.3 (`rag.nim:75`) such hits — and one unrelated unfiled note — are injected into
  unrelated turns.
- **5.14 Paths starting `/chat`, `/props`, `/slots`, `/completion` or `/infill` all go to
  llama-server** by bare prefix (`routes.nim:66-72`).
- **5.15 libadwaita warns "AdwWindow does not have a minimum size"** in bursts while the window
  runs; a window with `AdwBreakpoint`s must set a size request.
- **5.16 jvim: the vendored nvim-treesitter is the `main` rewrite**, whose `setup()` reads only
  `install_dir`, so `plugins/editor.lua`'s `ensure_installed`, highlight and indent options are
  ignored; and `lan.lua` validates a discovered host on `:8081/health`, which binds loopback only.

Report 03 lists further suspected defects; each is read in the code before it is scheduled here.

## Stage 6 — Documentation matches the code

**Done 2026-09-30 for what the code does today:** `README.md`, the five `docs/*.md` files and
`hardware-profiles/README.md` were corrected against the code, each correction read in the code
first, and rewritten for both OSes — including the Linux package list in `docs/install.md` (Arch
names checked on this machine; Debian and Fedora given as the pkg-config modules to provide).

`jca_web/README.md` (report 01 B48–B50) and `jvim/README.md` (B51–B56; B58 was the `.gitignore`
fix) were corrected on 2026-09-30T04:36Z.

Still to do:
- Rewriting the install and update steps once Stage 3 exists, and the self-test wording if Stage 8
  moves them.

## Stage 7 — GUI feature backlog

The open items in reports 02 and 05 — render caches, keyboard bindings and the command palette, the
error surface, attachment and model panels, PDF rendering, audio capture, maths M-4, deprecated
toolkit calls. Each is read in the code before it is scheduled.

**Comments found wrong in this pass, to correct when that code is next touched** (ruling 7; none is a
behaviour defect) [code]:
- `gui.nim:246` says every timeout checks `quitting`; the 100 ms tray pump (`gui.nim:7503-7506`)
  does not.
- `gui.nim:2372-2377` says `loadPixbuf` answers nil without raising; owlkettle's raises.
- `gui.nim:4977-4981` names `deleteMessage`, `saveEdit` and `forkFrom` as taking the list index;
  the three that do are `startEdit`, `regenerate` and `deleteMessage`.
- `gui.nim:7197-7203` quotes an old comment as history.
- `lifecycle.nim:17-19` says `std/posix` binds none of the flag constants; Nim 2.2.12 exports them —
  what it lacks is `pipe2`.
- `mathfont.nim:301` says "the six style pairs"; the block asserts eight.
- `ChatSidebarActions.svelte:54` says Pull reloads the page (see 4.5).

## Stage 8 — Last: tests

- The self-tests write into the real `~/Jenova/.system` [run]. Isolate them.
- `pipeline-selftest` sends a real `Web Search:` query to DuckDuckGo (`jenova_core.nim:5412`) [code].
  Take the network out of it.
- The Web UI's `ui` test project names `./.storybook/vitest.setup.ts` (`jca_web/vite.config.ts:79`),
  and there is no `.storybook/` directory [code].
- CI or checks on other distributions, only if the USER wants them.

## Afterwards, only on the USER's confirmation — cleanup

Candidates, nothing removed without confirmation: repository-root `.system/` and `var/` (not read by
any code — see the root-reading table above), `jca_web/build/`, `jvim/nvim.log`, `.clangd.example`,
the test databases in `~/Jenova/.system`, and — once `nimble llama` has put a static `llama-server`
there — the FreeBSD shared libraries left in `external/ext_bin/bin/`, which nothing then loads.

## Delegation

- One agent per stage, in its own worktree. The lead reads every diff and the code it touches, and
  builds and runs the existing self-tests and suites before accepting it.
- `gui.nim` has one owner at a time.
- An agent's finding enters this plan only after the lead has read the code behind it.
- Order: Stages 1 and 2 in parallel; Stage 3 after Stage 1; Stage 4 alongside Stage 3; Stage 5 at any
  point; Stages 6 and 7 after; Stage 8 last.
