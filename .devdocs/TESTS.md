# TESTS

Test specs, validation criteria, expected outcomes, and the record of what ran where.

**Current as of 2026-09-29T22:36Z.** Rewritten against the code and the Arch Linux
validation of 2026-09-29 by the devdocs congruence audit.

---

## The standard this project holds itself to

**An assertion that has not been proven to fail is not a gate.** The record is explicit
about this — a check that states a property it does not test passes whatever the code
does, and one such assertion shipped and was caught only by reverting the fix underneath
it. So: after writing an assertion, revert the fix, run it, confirm it goes red, restore.
Record which assertions actually moved, not how many were added.

**Vary the data, not the code.** A test that constructs its own fixture through raw SQL
cannot see a defect in the write path the product uses. Where a property depends on the
shared write path, drive it through that path.

**Isolate from real data.** Self-tests resolve paths through `paths.resolve`, so their
scratch state lands in the real `~/Jenova/.system` unless `JCA_HOME` points at a scratch
directory. On a machine with data, run them with `JCA_HOME=$(mktemp -d)`.

## Layers, and what each can and cannot see

| Layer | Command | Sees | Cannot see |
|---|---|---|---|
| Type check | `sh tests/gui_check.sh` (`nim check` of the window) | Nim semantic errors, owlkettle API misuse | Anything the C compiler decides: header conflicts, incompatible pointer types |
| Build | `nimble core`, `nimble gui` | C compilation and linking of the shipped configuration into `bin/` | Anything at run time |
| Self-tests | `bin/jenova-core <name>-selftest` | Pure logic, database behaviour, the request path against scratch state | Widget behaviour, allocation, keystrokes |
| Shell suites | `sh tests/test_*.sh` | The HTTP contract of a scratch `jenova-core serve`, the CLI verbs, the Neovim reader | Anything in the window |
| Mapped window | `sh tests/gui_build.sh` | Build, link, `--check`, allocation, real keystrokes and clipboard | The tray (always `--no-tray`), real backends, a window GTK renders on Wayland |

**A type check is not a build, and a build is not a run.** Each of the three has caught a
defect the one below it could not. Most recently, `gui_check.sh` passes on Linux while
`nimble gui` fails there on a C type error.

## `nimble suites`

The tasks run in this order, and any non-zero exit fails the run:

1. `core`, then `gui`.
2. `web` — `npm install` (network) and `npm run build`.
3. Every self-test in `SelfTests`, cheapest first.
4. The six shell suites.
5. `gui_check.sh`.
6. `gui_build.sh`, or its build-only tier (`JENOVA_GUI_NO_RUN=1`, with the missing tools
   named) when any of these is absent: `import`, `convert`, `xwininfo`, `xdotool`, `xclip`,
   `nc`, or `Xvfb` when there is no `DISPLAY`.

It writes `bin/`, `nimcache/`, `public/` and `jca_web/node_modules/`. Through the self-tests it
also writes `$JENOVA_STATE`, scratch trees under `$TMPDIR`, and — through `rag-selftest`'s
workspace delete, which does not redirect `JENOVA_WORKSPACES` — the real `$JCA_HOME`. Through the
suites it writes `$TMPDIR` scratch homes and, through `test_nvimctl.sh`, Nim's default cache under
`~/.cache/nim`.

## Self-test inventory

Registered in three places that must agree: the `SelfTests` list in `jenova_core.nimble`,
the `of "…-selftest"` dispatch in `src/jenova_core.nim`, and `usage()`. A test missing from
one is a test nothing runs or nobody can find. All three list the same twenty-two today:

`db` · `sha256` · `markdown` · `error` · `tree` · `attach` · `workspace` · `nvim-env` ·
`models` · `fs` · `hardware` · `composer` · `convmd` · `asset` · `lifecycle` · `relay` ·
`inspect` · `math` · `pipeline` · `rag` · `routes` · `serve`

### Side effects

`$JENOVA_STATE` defaults to `~/Jenova/.system`.

| Self-test | Writes | Network and sockets | Needs |
|---|---|---|---|
| `sha256`, `markdown`, `error`, `convmd`, `composer`, `asset`, `routes`, `relay`, `inspect` | nothing | none | — |
| `math` | nothing; reads the system font directories | none | passes with or without a maths font |
| `nvim-env` | nothing; sets `JENOVA_PORT` and `JENOVA_ROOT` in its own process and then deletes them, so inherited values are not put back | none | — |
| `models` | `$TMPDIR/jenova-models-*` | none | — |
| `fs` | `$TMPDIR/jenova-fstest`, with `JENOVA_WORKSPACES` and `JCA_HOME` pointed there | none | — |
| `lifecycle` | `$TMPDIR/jenova-{exec,sweep,lock,rot}-<pid>` | forks and execs; connects to `127.0.0.1:28081` | — |
| `tree`, `attach` | `tree`: `$JENOVA_STATE/jenova-treetest.db` and `jenova-cascadetest.db`; `attach`: `$JENOVA_STATE/attachtest` and `attachcost`, plus `$TMPDIR/jenova-selftest-{empty,good}.pdf`; all removed | none | — |
| `hardware` | `$JENOVA_STATE/hwtest-home`, removed | none; one check detects this host (`sysctl` and FreeBSD's tools, or `/proc` and `/sys`) | `<root>/hardware-profiles` |
| `db` | `$JENOVA_STATE/jenova-selftest.db` (+wal, shm), **left behind** | none | — |
| `workspace` | `$JENOVA_STATE/jenova-wstest.db`, **left behind**; mirror under `$TMPDIR/jenova-wstest-workspaces` | connects to `:8082`; runs `git` | `git` |
| `pipeline` | `$JENOVA_STATE/jenova-pipetest.db`, **left behind** | **live HTTPS to DuckDuckGo** for its `Web Search:` turns whenever `curl` or `fetch` is on `PATH` (the results are not asserted); connects to `:8082` | — |
| `rag` | `$JENOVA_STATE/jenova-ragtest.db`, **left behind**; deletes and restores workspaces named `Doomed` and `Restorable` against the **real** `Workspaces/` and `.trash/` | connects to `:8082`, and uses a real embedding server if one answers | a `jenova.conf` in `$JCA_HOME/etc` or `<root>/etc` |
| `serve` | `$JENOVA_STATE/jenova-servertest.db`, **left behind** | binds a kernel-assigned loopback port, plus a fake upstream for the relay phase | `<root>/public/index.html`; exits 1 before binding without it |

Twenty-one bind no listener; `serve` does. "Socket-free" is not "offline": see `pipeline`,
`rag`, `workspace` and `lifecycle` above.

## Shell suites and GUI harnesses

All in `tests/`. Common behaviour:

- The shell suites that run a server (`test_api_db`, `test_api_fs`, `test_routes`,
  `test_lifecycle`) execute `<repo>/bin/jenova-core`, which must be a native build for the host.
  `gui_build.sh` compiles its own `jenova-core` and `jenova` into a `mktemp` directory and runs
  those.
- Their scratch `JCA_HOME` has no `etc/`, so configuration falls back to the repository's
  `etc/`. That includes the untracked, machine-specific `etc/jenova.local.conf`.
- An exported `JENOVA_STATE`, `JENOVA_WORKSPACES`, `LOG_DIR`, `CACHE_DIR` or `JENOVA_HOST`
  escapes the scratch home.

| Suite | Verifies | Ports | Writes | Needs |
|---|---|---|---|---|
| `test_api_db.sh` | `/api/db/*` contract: CRUD and integer columns, partial update, per-message delete, soft delete → trash → restore with cascades, fork reparenting and recursive fork delete, upward restore, cache, import, error bodies | serves `:18719` (argument 1) | `$TMPDIR/jenova-apidb.*`, removed | `nc`, `git` |
| `test_api_fs.sh` | The disk mirror: path layout, `<epoch>_<name>` trash names, `.metadata.json` sidecars, rename-then-trash, `/api/fs/*`, restore refusing a source outside the trash | `:18721` | `$TMPDIR/jenova-apifs.*`, removed | `nc`, `git` |
| `test_routes.sh` | Route inventory by status (200/403/404/502), a chat body surviving the pipeline to the (absent) upstream, `/infill` passthrough, traversal refusal | `:18743`; upstreams `:18744`/`:18745` deliberately unbound | `$TMPDIR/jenova-routes.*`, removed | `nc` |
| `test_lifecycle.sh` | `llama-server` argument vector (FIM, prompt cache, offline, `-cb`, `-fa`, `-sm layer`, mlock/mmap switches, `-fitt` vs `-ngl`), loopback-only backends, `--lan` moving only the client port, port flags, unknown-flag refusal, health vs liveness, start/stop/status refusals | short `serve` runs on `:18771`–`:18774`; health probes on `:18775`/`:18776` | `$TMPDIR/jenova-lifecycle.*`, removed | `timeout(1)` |
| `test_models.sh` | Discovery order, `JENOVA_MODEL`/`JENOVA_DRAFT_MODEL` overrides, flat layout, switch semantics (link, `.old` backups), refusals | none | `/tmp/jenova-test-models-*`, removed | — |
| `test_nvimctl.sh` with `nvimctl_check.nim` | `nvimctl.activeDocument` against a headless `nvim`: a clean buffer, then an edited unsaved one | UNIX socket `/tmp/jenova-test-nvim.<pid>.sock` | the driver in `mktemp`, with Nim's default cache under `~/.cache/nim` | `nim`; `nvim` (SKIP, exit 0, without it) |
| `gui_check.sh` | `nim check` of `src/jenova_gui.nim` with the `.nimble`'s `-d:`/`--mm:` switches, compared against the `.nimble` | none | a temporary probe directory | Nim 2 and owlkettle; `pkg-config` plus the `.pc` files the bindings query at compile time |
| `gui_build.sh` | See the steps below | seed and run ports derived from the PID, in 18000–21999; an Xvfb display in `:40`–`:99` when there is no `DISPLAY` | scratch `JENOVA_ROOT` (copies `<repo>/etc`, including `jenova.local.conf`, and `png/`) and scratch `JCA_HOME`, inside `mktemp`; screenshots and `run.log` copied to `$TMPDIR/gui_build-evidence.<pid>` only when a mapped-window probe fails (other failures keep nothing) | Nim 2, owlkettle, and the pkg-config modules `gtk4`, `libadwaita-1`, `gtksourceview-5`, `vte-2.91-gtk4`, `dbus-1`, `sqlite3`, `zlib`; `nc`; for the mapped tier `import`, `convert`, `xwininfo`, `xdotool`, `xclip`, and `Xvfb` only when there is no `DISPLAY` |

`gui_build.sh` steps:

1. Builds both binaries in `mktemp`, with its own nimcache.
2. Seeds a conversation over HTTP through a scratch `jenova-core serve`.
3. Runs `--check`.
4. Builds a variant with every overlay panel forced open and runs `--check` on it.
5. Maps the window, then clicks, types, copies and photographs it.

`gui_build.sh` exercises less than it appears to:

- The window ignores `JENOVA_NO_BACKENDS`; only `jenova-core serve` reads it.
- `CANVAS=0` is inert, because `CANVAS` is not in `config.Keys`.
- `GDK_BACKEND` is not forced to `x11`. On a Wayland session GTK can draw where the X-based
  probes cannot see.

## Web UI suites

`jca_web/` carries its own vitest (unit, client, ui) and Playwright suites, and Storybook scripts
and stories; there is no `.storybook/` configuration directory, so the `ui` project's setup file
`./.storybook/vitest.setup.ts` is missing. The
Playwright configuration builds `../public` and serves it on `:8181`. `nimble suites` runs
none of them.

## Validation criteria

Every assertion covering a change must have been proven to fail without the fix.

- **A change to the request path** must show `pipeline`, `routes`, `rag`, `relay` and
  `inspect`, and `serve` — the only self-test that runs `upstream.forward` against a live
  (fake) upstream; `test_routes.sh` reaches it only on the connect-failure path, which answers
  502 — plus `test_routes.sh` and `test_api_db.sh`.
- **A change to the database or the mirror** must show `db`, `tree`, `fs`, `workspace` and
  `asset`, plus `test_api_db.sh` and `test_api_fs.sh`.
- **A change to backend supervision or configuration** must show `lifecycle` and
  `test_lifecycle.sh`.
  - Model changes add `models` and `test_models.sh`; profile changes add `hardware`.
  - `lifecycle` drives `start` against a real file with no execute bit, the one shape of an
    `execve` failure reproducible without a backend.
- **A change to `gui.nim`** is not validated by a type check. It needs `nimble gui`, then
  `jenova --check`, then the window run (`gui_build.sh`). This is the standing rule and the
  one most often skipped.
- **A change to a self-test's own fixture** is suspect: an assertion adjusted until it
  passes is the defect it was written to catch, in a new place.

## Known-fragile assertions

- **`db-selftest` concurrency overlap** is a wall-clock measurement. It is scored against the
  shorter of the two spans, not the reader's own, but remains timing-sensitive on a loaded
  host.
- **`serve-selftest` needs `public/`.** It serves `/` from `public/index.html`, which only the
  `web` task builds; `suites` depends on `web` for this reason.
- **`gui_build.sh`'s screen probes.** The `<Ctrl>n` probe takes the largest per-frame mean
  change over eight frames and scores it against measured idle noise, because a blinking caret
  reaches the top of a per-pixel range. The typing probe takes the largest per-pixel change
  (`fx:maxima`) against a 0.05 floor.
- **`test_lifecycle.sh`'s "start refuses with no model"** fails if anything listens on
  `127.0.0.1:8081`. The port check precedes the model check, and the suite does not override
  that port.
- **`rag-selftest`'s semantic-hit check** is not an assertion: a miss prints a `note` and never
  counts as a failure. Its gate, `rag.chunkCount() > 0`, is met by the vector the self-test
  stores itself, so the check runs whether or not an embedding server answers on `:8082`.
- **`hardware-selftest`** (24 assertions since 2026-09-30T03:15Z) scores the i5-1135G7 laptop
  under FreeBSD's device order and Linux's, resolves device names against both orders, and parses
  the Linux `/proc` formats from fixtures, so those run on FreeBSD too. Its OS-mismatch check uses
  `NetBSD`, which no profile names. One check detects the host it runs on: the OS name it was built
  for and a CPU count above zero.

## Known weak gates

- **`math-selftest` passes with no maths font installed.** Its live block falls back to
  `buildDefaultMathFont` when `chooseFont` finds none, so the HarfBuzz font path can regress
  unseen on a font-less host.
- **No committed assertion covers the socket-level refusals:**
  - a `413` answered while the peer is still sending;
  - the refusal of an unsupported `transfer-encoding`.

  Both were checked live only (PROGRESS 2026-09-10T02:59Z). `routes-selftest` asserts the
  pure chunk parser, not the refusals.
- **`thumbCache`'s cap is untested.** It lives in `gui.nim`, which links into no test binary.
- **`pipeline-selftest`'s web-search checks** assert the intent and the stripped prefix, not
  the search, yet the search runs for real.

## Results by host

**FreeBSD 15.1 — 2026-09-10T02:59Z** (PROGRESS):
- Pass: the twenty-two self-tests, including `serve`; the six shell suites; `gui_check.sh`.
- `nimble gui` built there; the older clang only warned on `vte.nim`. `jenova --check`
  passed.
- Not run: the mapped-window tier, for want of `Xvfb`, `xdotool` and `xclip`.

**Arch Linux, bare metal — 2026-09-29** (lead's validation). Artifacts in
`~/Jenova/.system` are stamped 2026-09-29T04:28Z (core build and self-tests) and
2026-09-29T21:59Z (`serve-selftest`; the window's `styles/`).

| Check | Result |
|---|---|
| `nimble core` | builds (gcc 16.2) |
| Twenty-two self-tests | all PASS |
| Six shell suites | all PASS; `test_lifecycle.sh` prints GNU grep "stray \" warnings |
| `gui_check.sh` | PASS |
| `nimble gui` | **FAILS** under gcc 16.2 and clang 22.1: `vte.nim` passes its own `GdkRGBA` object to the header-declared `vte_terminal_set_colors` (incompatible pointer types) |
| GUI with that one error downgraded (diagnostic only) | builds; `--check` PASS; libadwaita warns that `gtk-application-prefer-dark-theme` is unsupported |
| llama.cpp `a6ea155d3`, Vulkan, `CMAKE_INSTALL_RPATH=$ORIGIN` | builds; relocatable when copied with its SONAME links |
| `llama-server --list-devices` | `Vulkan0` = Iris Xe, `Vulkan1` = GTX 1650 Ti on this machine under Linux. The i5-1135G7 profiles assume `Vulkan0` = NVIDIA — in `DEVICES` and `DRAFT_DEVICE`, which select by index, and in their comments and unused `HW_GPU_*` values; `MATCH_GPU_*` scoring does not depend on it. The order was never re-measured on FreeBSD |
| `jenova-core hardware detect` | "OS: FreeBSD unknown", empty CPU, 0 threads, 0 GiB RAM and swap, storage "UFS" on btrfs; matched `CPU/generic` |
| Not run | the mapped-window tier (tools absent, Wayland session); `nimble web`; `nimble suites` end to end |

**Arch Linux, bare metal — 2026-09-30T03:15Z** (Stages 1 and 2, lead's run). Both binaries built into
the scratchpad from a copy of the tree, run with `JENOVA_ROOT` at that copy and `JCA_HOME` in the
scratchpad, so nothing wrote to `~/Jenova` or to the repository's `bin/` and `external/ext_bin/`.

| Check | Result |
|---|---|
| `jenova-core`, gcc 16.2 | builds |
| `jenova`, gcc 16.2 and clang 22.1 | builds (the `GdkRGBA` error is gone) |
| `nim check --os:freebsd`, both entry points | no errors (the FreeBSD branches type-check; C not compiled) |
| Twenty-two self-tests | all PASS (`hardware` 24 assertions, `lifecycle` 35) |
| Six shell suites, `gui_check.sh`, `gui_build.sh` (build tier) | all PASS |
| `jenova --check` | PASS, and libadwaita no longer warns; a program calling `adw_init` alone still does, from KDE's `settings.ini` |
| `jenova-core hardware detect` | "Linux 7.2.6-zen2-1-zen", i5-1135G7, 8 threads, 15 GiB RAM, 27 GiB swap, storage of `$JCA_HOME`, both NVMe models; with the new `llama-server` both GPUs, and `Vulkan/dgpu-igpu-i5-1135g7` matched at 40 |
| `jenova-core backends args`, dual-GPU profile | `-dev Vulkan1,Vulkan0`, `-devd Vulkan0` — the GTX 1650 Ti first and the drafter on the Iris Xe; an unmatched name passes no `-dev` and prints its note |
| llama.cpp `a6ea155d3`, static, Vulkan, `--target llama-server` | one 62 MB file, no `RUNPATH`, only system libraries; nothing downloaded (the UI step warns and continues); `cmake -E copy` keeps mode 0755 |
| That `llama-server` with an embedding model on `-dev Vulkan1` | `/health` ok, `/embedding` answered, clean exit |
| `llama-server -dev CPU` | refused: "invalid device: CPU" |
| Not run | `nimble llama` itself (it would replace the FreeBSD `external/ext_bin/`); a CUDA build; FreeBSD |

**Arch Linux, bare metal — 2026-09-30T04:36Z** (Linux build and deployment, lead's run plus four
verifiers against a scratch-home copy of the deployment):

| Check | Result |
|---|---|
| `nimble llama`, `core`, `gui`, `web` | all build; `external/ext_bin/bin/llama-server` and `bin/` are Linux builds |
| `nimble suites` (scratch `JCA_HOME`) | PASS end to end — 22 self-tests, six suites, `gui_check`, `gui_build` build tier |
| Deployment to `~/Jenova` | profile applied (score 40), models in `instruct/`/`thinking/`, both backends healthy in ~12 s |
| Chat through `:8080` (headless and GUI-hosted) | works; streaming, reasoning split, cache, intents, two concurrent slots, scoped retrieval all pass |
| Nemotron 4B, persona prompt, thinking on | the reply often arrives only as reasoning — fixed by `--reasoning off` for `models/instruct/` (3/3 through the pipeline) |
| Qwen3.5 9B thinking, persona prompt, thinking on | reasoning and answer separate, 5/5 |
| Embeddings (nomic 1.5) | 768-wide vectors through `:8080`; CPU-only as designed |
| `/infill` with the Nemotron 4B | 501 — the model has no FIM tokens (`PLANS.md` 5.12) |
| Web UI in headless Brave | loads; the FOCUS-note runaway, mirror deletion, service worker and delete-navigation defects recorded (`PLANS.md` 4.6–4.11) |
| Generation speed, Nemotron 4B | 3.0 tok/s with the profile's default split; 7.8 with `-ts 5,1` (this machine's `jenova.local.conf`) |

Side effects of that run:
- The self-tests left `jenova-{selftest,wstest,pipetest,ragtest,servertest}.db` (+wal, shm)
  in the real `~/Jenova/.system`.
- The window's `--check` wrote `jenova.db` and `styles/` there.
- `pipeline-selftest` made live DuckDuckGo requests.

**Earlier:** the mapped-window tier passed end to end once, in report 07's audit
environment:
- Nim 2.2.10 and distribution packages: GTK 4.14.5, libadwaita 1.5.0, Xvfb.
- Commit `aabcc77`, now reachable only through the reflog.

It has not run on FreeBSD 15.1 or on this Arch host.
