# TODOS

Granular task list. Completed items move to the `BLUEPRINT.md` implementation registry.

**Last updated:** 2026-08-31 10:38

---

## Rulings in force — 2026-08-31, closed permanently

| Ruling | Effect |
|---|---|
| **D-X** | **Licence is AGPL-3.0; copyleft dependencies permitted. Q-4 closed permanently.** `AGENTS.md` Directive 2's copyleft clause is dead letter; its operative clause is "zero proprietary dependencies". **Not to be raised again by any session** |
| **D-Y** | **No deployment/build/install testing until the rewrite is complete.** `make install`, `make verify`, `jenova-ca --daemon` **prohibited**. B-1 superseded; V-1 … V-6 move to a post-refactor phase, taking B-08, B-23, B-24 off the near path |
| **D-Z** | **`jca_web/` frozen — not touched, edited or damaged.** The `jca_web/src/` full read is **cancelled**. B-01, B-03, B-04 deferred to N-S9 |
| **D-AB** | **Linuxulator: a detection is not evidence until its mechanism is shown not to route through the emulation layer.** State the mechanism with the claim |
| **N-8** | **CLOSED — substantially wrong, my error.** `AGENTS.md` has four directives; no Directive 7, `.dbc` or `test_roms/`. Separately, **`Directive 6` is cited 14× across these docs and does not exist** — the Codebase Integrity Standard is retained as practice, not governance |

---

## Rulings in force

| Ruling | Effect |
|---|---|
| **D-A** | No bash — POSIX `sh` only |
| **D-B** | CUDA opt-in, never auto-detected |
| **D-C** | `node`/`npm` required while the WebUI exists |
| **D-D** | Nim rewrite is the long-term target → **subtract, do not rewrite** |
| **D-E** | :8080 is the port; :8081/:8082 internal |
| **D-F** | Uniform `<backend>/<config>` profile layout, depth 2 |
| **D-G** | Delete `JENOVA_DISTRO`/`JENOVA_WSL`, keep `JENOVA_PKG_MGR` |
| **D-H** | **No `rc.d`** — defer service integration to the Nim cut-over |
| **D-I** | Execution approved |
| **D-K** | Explicit COMMAND LAWS outrank implicit tooling preferences |
| **D-L** | **Nim rewrite is the active workstream. Target: a native FreeBSD GUI desktop application, not a web wrapper. `jca_web/` retained but deprecated** |
| **D-M** | **Project is AGPL-3.0 — GPL/LGPL dependencies permitted. Directive 2's copyleft ban is superseded; Q-4 CLOSED** |
| **D-N** | **Single binary — the GUI links the Nim core in-process.** ~~Implies direct `llama.cpp` linkage~~ — **that clause was mine, not the USER's, and is superseded by D-AF**: `llama-server` is the inference engine |
| **D-AF** | **`llama-server` is the inference engine; the Nim core is the harness.** `upstream.nim` is the primary path; in-process inference retained as `JENOVA_INPROC=1` |
| **D-AE** | **`~/JCA` is permanently off limits — no migration, overwrite or change, ever.** Not to be raised again |
| **D-O** | **Backlog triage adopted** — fix only what survives the rewrite |
| **C-11** | **I run no git actions.** Commits are the USER's alone |

---

## Backlog — the Nim rewrite (D-L), 2026-08-28

**Nothing here is scoped or approved.** Q-20, Q-21 and Q-22 gate all of it.

| ID | Item |
|---|---|
| ~~N-S0~~ | **Complete 2026-08-28** — `make core` builds `bin/jenova-core`, runs, guard verified. See `PROGRESS.md` |
| ~~N-S1~~ | **Complete 2026-08-28** — paths + config, one precedence rule, B-12 fixed in the core and demonstrated live. See `PROGRESS.md` |
| ~~N-S2~~ | **Complete 2026-08-28** — concurrent SQLite layer, per-thread connections, proven by measurement. See `PROGRESS.md` |
| ~~N-S3a~~ | **Complete 2026-08-28** — threaded HTTP server, static serving, SSE. D-R satisfied and measured. See `PROGRESS.md` |
| ~~N-S3b~~ | **Complete 2026-08-28** — `/api/db/*` reproduced with a 22-assertion contract test; completion/embed proxying in place. See `PROGRESS.md` |
| ~~N-S4a~~ | **Complete 2026-08-28** — direct `libllama` linkage verified generating on Vulkan0. See `PROGRESS.md` |
| ~~N-S4b~~ | **Complete 2026-08-28** — in-process generation, streaming, model's own chat template; other classes verified responsive during generation. See `PROGRESS.md` |
| ~~N-28~~ | **Closed 2026-08-31 by D-AD + Q-27.** The runtime home moved to `$HOME/Jenova` at all 20 code sites (15 changed, 5 already correct), and `paths.resolve` now refuses `$HOME/JCA` outright unless `JENOVA_ALLOW_DEPLOYED=1`. See `PROGRESS.md` |
| **N-30** | **THE LARGEST GAP IN THE REWRITE. The Nim core's completion path is a raw llama-server equivalent, not Jenova.** `lib/proxy.lua:1225-1400` does **seven** things to every `/v1/chat/completions` request that `server.nim:181-185` does not do at all — it reads only `stream`, `max_tokens`/`n_predict` and `messages`/`prompt`. Unported: **(1) intent detection** from user-message prefixes (`Visual Rewrite:`, `Open File Chat:`, `Chatbot:`, `Web Search:`), which are stripped from the message; **(2) RAG retrieval** via `search.query`, with a per-intent limit (visual 1, websearch 0, default 3, 5 for a long message carrying `Path:`) and a special query built from basename + trailing prose for large file-chat payloads; **(3) RAG injection** as a `--- REPOSITORY CONTEXT ---` block of `[n] path` + 1000-char snippets; **(4) web search** for the websearch intent (DuckDuckGo HTML, falling back to the Instant Answer API, via `fetch` or `curl`) injected as `--- WEB SEARCH RESULTS ---`, with distinct fallback prose for "no results" vs "no HTTPS client"; **(5) persona/system-prompt injection** in three distinct modes — agent (`has_tools`: never override a client system prompt, inject `CORE MANDATE: You are Jenova, an autonomous agent.` only when absent, append contexts to `messages[1]`), conversational (persona-first, `prompts[intent] or freechat`, prepended to any existing system message), and no-intent (persona prepended, RAG appended); **(6) tool stripping** — `visual` and `websearch` set `tools = nil` and `tool_choice = "none"`; **(7) an LLM cache intercept** keyed on the SHA-256 of the *rewritten* body, returning the stored response with an `X-Cache: HIT` header. **This is the product's distinguishing behaviour and none of it exists in the core.** It also reframes N-S5b: RAG is one input to this pipeline, not the stage itself | `lib/proxy.lua:1225-1400`, `lib/prompts.lua`; vs `src/jenova/server.nim:181-195` |
| ~~N-S5a~~ | **Complete 2026-08-31** — `fssync.nim`, the ten `/api/db/*` mirroring call sites, the four `/api/fs/*` routes, the four `/api/storage/*` routes and `fs_sync.trash_path`. **N-27, N-20 and N-29 all closed; `lib/proxy.lua` is superseded.** `tests/test_api_fs.sh` 46 assertions, `test_routes.sh` 11, `test_api_db.sh` 23 — all PASS. `/api/workspaces` deliberately dropped (dead; no caller, never worked). See `PROGRESS.md` |
| ~~N-29~~ | **Closed 2026-08-31.** All five routes resolved: `/api/storage/*` ported with containment, `/infill` and `/v1/health` classified at N-S4c, `/api/workspaces` subtracted under D-D |
| ~~N-S5b~~ | **Complete 2026-08-31** — `rag.nim`: FTS5 keyword index, BLOB vectors, chunk text persisted. **FTS5 confirmed present by probe** (`jenova-core db-capabilities`), so Q-24 option A shipped. `db.nim` gained `execBlob`/`queryBlob`. `rag-selftest` 7 assertions PASS, including the vector path verified without an embedding server. See `PROGRESS.md` |
| **N-31** | **The embedding server HTTP call is unverified.** `rag.embed` posts to `:8082/v1/embeddings` and parses `data[].embedding`. The storage and similarity maths are asserted directly by `rag-selftest`, but **the request/response shape has never been exercised against a running embedding server** — `chunks with vectors: 0` in the self-test is that server being absent. Keyword-only retrieval is a supported degraded mode, so this does not block N-S5c; it does mean the semantic half is written and not proven | `src/jenova/rag.nim` `embed()` |
| ~~N-25~~ | **Closed 2026-08-31 by D-AF, not fixed — `llama-server` parses sampling parameters per request.** The defect was real only for the in-process path, which is now optional. It reapplies if `JENOVA_INPROC=1` is ever made load-bearing again |
| ~~N-26~~ | **Closed 2026-08-31 by D-AF** — `llama-server` handles client disconnect. Same caveat as N-25: real only for the in-process path |
| ~~N-S4c~~ | **Complete 2026-08-31** — inference default inverted to the proxy path; `/infill` classified (the USER's Neovim FIM need, satisfied by classification alone under D-AF); `/v1/health` fixed from 400; `tests/test_routes.sh` added, 9 assertions PASS. See `PROGRESS.md` |
| ~~N-22~~ | **RETRACTED 2026-08-28 — the claim was false and the fault was mine.** `CTX_SIZE=32768` serves fine on this hardware, as the USER stated. My binding ignored `DEVICES` (so the whole model went to Vulkan0 alone instead of splitting across Vulkan0+Vulkan1) and ignored `KV_CACHE_TYPE` (so the KV cache was f16, twice the size of the configured `q8_0`). Verified after the fix: ctx=32768, slots=2, kv=q8_0, Vulkan0 152 MiB + Vulkan1 381 MiB, generation succeeds |
| **N-24** | **`etc/jenova.local.conf` names a device that does not exist** — `DEVICES="Vulkan0,Vulkan1,Vulkan2"`, but this machine has only `Vulkan0`, `Vulkan1` and `CPU`. Harmless until now **only because B-12 meant the shell discarded the local conf entirely**; the Nim core honours it and so is the first thing to read the bad value. `scripts/build-llama.sh` generated it. **Fixing B-12 exposed a latent bad configuration that had been invisible for as long as it has existed** |
| **N-23** | The llama rpath is absolute to `external/ext_bin/bin`, correct for a source tree. An installed binary needs the deployed lib directory instead — resolve before N-S6 |
| **N-21** | **Restoring a conversation revives every message, including ones deleted individually beforehand.** Faithful to `db.restore_item` and therefore correct for now — but it is a latent defect in the contract, and the GUI (N-S7) need not inherit it |
| **N-16** | **No HTTP keep-alive** — every response is `Connection: close`, so a page with many assets opens a connection per asset. Acceptable now; revisit before the Web UI is served in anger, since connections beyond the worker count queue in the accept backlog |
| ~~N-17~~ | **Withdrawn by D-T.** It framed bounded concurrency as a capacity limit needing documentation. For a two-device personal product the bound is the specification, not a limitation |
| **N-18** | Class thread counts are compile-time constants in `routes.nim`. Fine for D-T's two devices; make them configurable only if the "can be expanded" case is ever taken up |
| **N-19** | `/api/db/*` returns an honest 501 today. `lib/proxy.lua` still serves the Web UI, so both exist until N-S3b lands |
| **N-14** | **The `SQLITE_OPEN_NOMUTEX` invariant is enforced by discipline, not the type system.** If a `Conn` is ever passed between threads it becomes a data race. Consider making `Conn` non-shareable at the type level before N-S3 wires the worker pool |
| **N-15** | `db.columnNames` has no caller yet. Recorded by the N-S2 integrity pass rather than left silent |
| **N-12** | `config.getInt` has no caller until N-S3. Recorded by the N-S1 integrity pass rather than left silent |
| **N-13** | **Eventual:** replace the shell conf format so the Nim core stops shelling out to `/bin/sh` to read it. Touches all six shipped hardware profiles and every remaining shell consumer — a separate decision, not scoped |
| **N-1** | Rewrite the Nim specification. `jenova_refactor_analysis.md` on `develop/nim` assumes the WebUI is the client and has no GUI component; D-L removes that assumption and adds a seventh component. The server, RAG, DB and `llama.cpp`-linkage analysis survives; the client assumption does not |
| ~~N-2~~ | **Closed by D-P** — GTK4 + libadwaita via owlkettle; `gintro` as escape hatch |
| ~~N-9~~ | **Resolved at N-S0.** The Makefile probes `PATH` then `/usr/local/nim/bin`, so no user PATH change is needed. `libadwaita`/`gtksourceview5` are not required until N-S7 (D-Q) |
| **N-11** | **Dependency change awaiting approval:** add `nim` (and later `libadwaita`, `gtksourceview5`) to `scripts/install-dependencies.sh` DEPS, then make `core` depend on `deps`. Until approved, `make core` requires a pre-installed compiler |
| **N-10** | **Tray rebuild on StatusNotifierItem.** GTK4 drops `libappindicator`; the tray is an existing feature and is retained (Directive 3) |
| ~~N-3~~ | **Closed by D-N** — single binary, GUI links the core in-process; `llama.cpp` linked directly |
| **N-4** | `jca_web/` deprecation policy: no new features, what "retained" means in practice, and what replaces `/api/db/*` when it goes |
| ~~N-5~~ | **Closed by D-O** — triage adopted. Survivors were B-05, B-09, B-10, B-20, B-21, B-22, B-01. **Updated 2026-08-31:** B-09 closed by deletion (Q-11); B-01 deferred to N-S9 (D-Z). Remaining: B-05, B-10, B-20, B-21, B-22 |
| ~~N-6~~ | **Withdrawn by C-11** — commit boundaries are the USER's. Noted only: the working tree still has none |
| **N-7** | **D-N follow-through:** a single binary must still serve LAN mode without the GUI running (Directive 3), and must isolate inference so a GUI fault cannot kill a generation |
| ~~N-8~~ | **CLOSED 2026-08-31 — substantially wrong, and the error was mine.** `AGENTS.md` contains **four** directives and **no Directive 7, no `.dbc`, no cartridge, no `test_roms/`** — they were removed before this session. I reported this item out of this file without checking it against the governance file I had read in full minutes earlier. Directive 2's copyleft clause is ruled dead letter by **D-X**, not amended. **The real defect the check found:** the devdocs cite a superseded numbering — **`Directive 6` appears 14× and does not exist**, and it is what `D-J`, `C-10` and the mandated per-session integrity pass were built on; `Directive 7` appears 6×. The Codebase Integrity Standard is retained on its merits as workspace practice and is no longer claimed to be mandated by a directive |

**Migration questions Q-1 … Q-8: closed, and they stay closed.**

**Four new questions are open** — Q-9 … Q-12 in `DECISIONS_LOG.md`, raised by the 2026-08-28
full-tree audit. They do not affect the migration or the outstanding verification work; they gate
the fixes for B-08 … B-12 and B-21.

---

## Backlog — full-tree audit, 2026-08-28

Two audits, both recorded here per Directive 6. **B-01 … B-06** came from the documentation
consolidation (claims checked against source; the source was at fault). **B-07 … B-31** came from
the subsequent comprehensive read of every file in `.devdocs/`, `.jules/`, `bin/`, `lib/`,
`scripts/`, `hardware-profiles/`, `etc/`, `jenova-ui/`, `tests/` and `Makefile`.

**Nothing below is scoped or approved.** Severity ordering is in the index; work items move to
Active only with a `PLANS.md` entry.

### Severity index

| Severity | Items | Meaning |
|---|---|---|
| **S1 destructive** | — | **Empty. B-07 fixed 2026-08-28** — see `PROGRESS.md` |
| **S2 documented step fails** | B-10, B-11 | A command the docs tell users to run cannot succeed. **B-08 and B-09 closed by deletion 2026-08-31 (Q-10, Q-11) — see `PROGRESS.md`** |
| **S3 architectural** | B-12, B-13 | The system does not behave as its own design states |
| **S4 remediation-plan carry-over** | B-14 … B-19 | Phase 2–4 work, plus two items worse than the plan records |
| **S5 data contradiction** | B-05, B-20, B-21 | Shipped data files disagree with each other |
| **S6 test suite** | B-22 … B-26 | Tests that cannot fail, cannot run, or damage the tree |
| **S7 documented-but-absent** | B-27 … B-31 | Flags, variables and steps that do not exist |
| **S8 privacy / hygiene** | B-01 … B-04, B-06 | From the documentation audit |

---

### S1 — destructive

**Empty.** B-07 was fixed on 2026-08-28 (Session 004) and is recorded in `PROGRESS.md`.

### S2 — a documented step cannot succeed

| ID | Defect | Evidence |
|---|---|---|
| **B-10** | **`CPU/generic/jenova-setup` is entirely Linux.** `cpupower frequency-set`, `/sys/devices/system/cpu/*/cpufreq/scaling_governor`, `/sys/kernel/mm/transparent_hugepage/enabled`, `numactl`, `isolcpus=`. It never sources `common-setup.sh`, defines no `apply_sysctl`, and applies zero FreeBSD tunables. This is the **only CPU-only profile**, so it is exactly what a FreeBSD host with no working Vulkan gets. **`PROGRESS.md` asserts these six scripts were audited clean — that claim is false** (see the correction entry in `PROGRESS.md`) | `hardware-profiles/CPU/generic/jenova-setup` (whole file) |
| **B-11** | **`bin/jenova-term` is never deployed.** `install.sh` deploys and symlinks six binaries; `jenova-term` is not among them. But `lib/ui.lua:104` invokes `$root/bin/jenova-term` for the tray's **"System Control"** menu item. In an installed deployment that path does not exist and the menu item silently does nothing. `update.sh:220` omits both `jenova-term` and `jenova-model-switch` from its redeploy loop | `scripts/install.sh:240,294`; `lib/ui.lua:104`; `scripts/update.sh:220` |

### S3 — architectural

| ID | Defect | Evidence |
|---|---|---|
| **B-12** | **PARTIALLY FIXED 2026-08-28 — corrected in the Nim core (N-S1), still live in the shell path until `bin/jenova-ca` is deleted at N-S6.** **The configuration hierarchy is inverted; `etc/jenova.local.conf` is ineffective.** `bin/jenova-ca` sources `lib/jenova-conf.sh` (which sources `jenova.local.conf`) at `:45`, then `etc/jenova.conf` at `:48`. The profile conf runs **last** and unconditionally reassigns every tuning variable via `VAR="${JENOVA_VAR:-default}"`, discarding whatever the local conf set. Setting `DEVICES`, `THREADS`, `CTX_SIZE`, `NGL_AGENT`, `FIT_TARGET` or `KV_CACHE_TYPE` in `jenova.local.conf` has **no effect**; only `JENOVA_*`-prefixed assignments survive. **`build-llama.sh` generates a local conf using the unprefixed names, so the build script's own auto-tuning is discarded.** The live `etc/jenova.local.conf` sets `DEVICES="Vulkan0,Vulkan1,Vulkan2"` and `THREADS=8`; neither reaches `llama-server`. Documented in `BLUEPRINT.md §2.2`. Needs a USER ruling — see `DECISIONS_LOG.md` Q-9 | `bin/jenova-ca:44-48`; `lib/jenova-conf.sh:53-74`; `etc/jenova.conf:56,70`; `scripts/build-llama.sh:264-275` |
| **B-13** | **`--daemon` starts no `:8080`** (remediation-plan WP-9, confirmed unfixed). `PROXY_PID` is declared at `jenova-ca:13` and never assigned; the daemon block launches only `llama-server` and the embed server. The proxy is `io.popen`'d as a child of the tray (`ui.lua:69`). Consequences: a headless start has no client-facing port, `status` and `stop` cannot see it, and `_probe_health` targets `$LLAMA_PORT`, so a wedged proxy reads green. Out of scope by ruling **D-H**, but it is why `tests/test-health.sh` cannot pass on a headless start | `bin/jenova-ca:13,706-725,258-294`; `lib/ui.lua:69` |

### S4 — remediation-plan carry-over (verified in source, not from the tracker)

| ID | Defect | Evidence |
|---|---|---|
| **B-14** | **WP-11 is worse than recorded.** `embed.init()` returns `true` after spawning the server **without setting `initialized`**. So `/health` reports `embed: true` while every `embed.encode()` returns `"not initialized"`. If the embed server was not already listening when the proxy started, embeddings are permanently dead *and* reported healthy. Two-line fix | `lib/embed.lua:66-69,97`; `lib/proxy.lua:591` |
| **B-15** | **WP-12 — RAG inert, three independent breaks.** `search.index_dir` and `search.reindex_file` have **zero callers repo-wide**, so `total_docs == 0` and `search.query` returns `{}` before doing anything. `search.init_embeddings` is never called from the proxy. `_G._last_project_root` is a dead store. `background_tasks` is declared, iterated twice, and never populated | `lib/proxy.lua:74,1534,1539,1583,1683,1234`; `lib/search.lua:495,442,743` |
| **B-16** | **WP-5 — `async_popen_read` still blocks the event loop** in its own private `select()`. `fs_sync`'s three blocking `io.popen` sites unchanged | `lib/proxy.lua:233`; `lib/fs_sync.lua:299,384,435` |
| **B-17** | **WP-6 — fork storms unchanged.** `get_fs_tree` still forks `test -d` per entry. `ui.poll_status` still forks `jenova-ca status` (which sources four config files) every 3 s in the tray and **every 1 s** in the TUI. `detect_probe_tool()`'s cached result is now dead code — `_cached_probe_tool` is written and never read | `lib/fs_sync.lua:445`; `lib/ui.lua:41-58,164`; `jenova-ui/src/main.c:375,495` |
| **B-18** | **WP-7 — hot-path items unchanged.** SHA-256 `llm_cache` intercept still present against a 20-entry cache; `async_send`'s O(n²) `data:sub(sent + 1)`; unbounded `SELECT *` in `get_all_messages`; no prepared-statement cache — `execute_query` prepares and finalizes on every call | `lib/proxy.lua:1386-1401,159`; `lib/db.lua:431,212,276,868` |
| **B-19** | **Unreachable header timeout** (deferred in WP-3, still open). The `os.time() - start_time > 10` check sits after a successful `recv`, so a client that connects and sends nothing never reaches it; it yields on `"read"` until `COROUTINE_TIMEOUT` (600 s) | `lib/proxy.lua:535` |

### S5 — shipped data files contradict each other

| ID | Defect | Evidence |
|---|---|---|
| **B-20** | **`profile.conf` `PROFILE_*` values contradict the `jenova.conf` beside them**, despite the comment *"should match jenova.conf in this directory"*. For `Vulkan/dgpu-i5-1135g7` **every value differs**: CTX 8192 vs 16384, slots 1 vs 2, NGL 16 vs `all`, DRAFT 0 vs 1, FIT 256 vs 128. `dgpu-igpu` disagrees on DRAFT (1 vs 0). This is the drift `BLUEPRINT.md §6.5` flagged; S-7 corrected the README and left the data | `hardware-profiles/Vulkan/dgpu-i5-1135g7/profile.conf:29-39` vs its `jenova.conf` |
| **B-21** | **`CUDA/dgpu-generic` ships a third-party "Uncensored / Aggressive" model as its recommended default.** `model_dl.sh` sources `RECOMMENDED_AGENT_URL` from `profile.conf`, so applying this profile and running the downloader fetches it. Also: `RECOMMENDED_AGENT_URL` values across profiles point at `huggingface.co/Qwen/...` while `model_dl.sh`'s own defaults point at `unsloth/...` — at least one set is wrong | `hardware-profiles/CUDA/dgpu-generic/profile.conf:46-47`; `scripts/model_dl.sh:48-58,61-81` |

### S6 — test suite

| ID | Defect | Evidence |
|---|---|---|
| **B-22** | **`tests/test_validate_arg.sh` rewrites the repository's `etc/jenova.conf`.** `assert_pass "Vulkan/dgpu-i5-1135g7"` genuinely invokes `--apply-profile`, and `apply_profile` mirrors the profile into `$JENOVA_ROOT/etc/jenova.conf` when that directory is writable. The test's `JCA_HOME` mktemp isolation does not cover the repo mirror. **This is the origin of commit `eee557e` "Revert hand-edit of etc/jenova.conf" — it was not a hand-edit** | `tests/test_validate_arg.sh:62`; `hardware-profiles/detect-hardware.sh:339-342` |
| **B-23** | **The fd-leak assertion is vacuous on FreeBSD.** `run.sh` counts descriptors with `find /proc/$PX/fd`. `/proc` is not mounted on stock FreeBSD, so both counts are 0 and `[ 0 -le 2 ]` passes regardless of a leak. The check only ever worked under the Linuxulator, where it was written. **V-4, the S-1 acceptance gate, is partly vacuous on the target platform.** FreeBSD needs `procstat -f` | `tests/proxy-concurrency/run.sh:58,96` |
| **B-24** | **`python3` is an undeclared dependency.** Required by `tests/test-health.sh` and the entire `proxy-concurrency` harness (`stub_backend.py`, `probe_streams.py`, inline heredocs). Absent from the `DEPS` list, so `make deps` does not install it and V-4 cannot run on a clean machine | `scripts/install-dependencies.sh` DEPS; `tests/test-health.sh:14`; `tests/proxy-concurrency/run.sh:27,46` |
| **B-25** | **`tests/Makefile` runs 4 of the 9 test scripts** *(count corrected 2026-08-31; was "3 of 8" before `test_api_db.sh` was added at N-S3b — the defect stands, only the number was stale)*. `test_bin_jenova.sh`, `test_validate_arg.sh`, `test_gpu.sh`, `test_gpu_single.sh` are orphaned. Both GPU tests additionally require `external/ext_bin/bin/llama-cli`, which `build-llama.sh` never copies (it copies `llama-server` and `*.so*` only), so they fail unconditionally | `tests/Makefile:7-10`; `scripts/build-llama.sh:205-210` |
| **B-26** | **`download-draft-model.sh` writes to the wrong directory and fetches the wrong model.** It targets the repository's `models/`, not `$JCA_HOME/models/draft/`, so discovery never finds the result; and it downloads Qwen2.5-Coder-0.5B while `model_dl.sh` downloads Qwen3.5-0.8B. Its closing message claims speculative decoding will be enabled automatically — `JENOVA_DRAFT` is 0 in the deployed profile | `tests/download-draft-model.sh:8,10-11,44` |

### S7 — documented but absent

| ID | Defect | Evidence |
|---|---|---|
| **B-27** | **`uninstall.sh --purge` is documented but not parsed** → `Unknown option: --purge`, exit 1. The whole header describes removing a Neovim config (`~/.config/jenova/`, `~/.local/share/nvim/lazy/`, Mason, shada). It never removes `jenova-model-switch`, which `install.sh` symlinks, leaving a dangling link. `:105-107` prints the same path three times with three different descriptions | `scripts/uninstall.sh:11,44-58,105-107,128,142` |
| **B-28** | **`update.sh` gates a block on `$SKIP_JVIM`, a variable never set or parsed**, guarding a rebuild of a Neovim tree at `$JENOVA_ROOT/jenova`. Dead code. Separately, `:199` and `:210` invoke `make` without `-C "$JENOVA_ROOT"`, so under `--no-pull` (which skips the `cd`) they run in the caller's working directory. Header still says it "resyncs the Neovim plugin set" | `scripts/update.sh:4-7,159-189,199,210` |
| **B-29** | **`install.sh`'s header documents a model-download step that does not exist** ("5. Downloads required model files"). `--client-only` claims to skip it. The header's step numbering skips 4, 6 and 7 | `scripts/install.sh:19-26` |
| **B-30** | **`MAX_TURNS`, `MAX_ACTIONS` and `TIMEOUT` in `etc/jenova.conf` are read by nothing.** No shell script or Lua module references them. The real agentic turn limit is 100, defined in the Web UI | `etc/jenova.conf:80-82` |
| **B-31** | **`main.c` hardcodes `.jpg` tray icons** (`png/jca.jpg`, `png/jca_grey.jpg`) while `install.sh`'s icon loop prefers `.png` and converts `.jpg`→`.png` when a converter exists. If `png/` ships `.png`, the tray icon path never resolves. **Unverified — enumerating `png/` needs a shell command, which was not permitted this session.** Also uses `$HOME/.jenova/ui.lock`, a fourth spelling of the state directory | `jenova-ui/src/main.c:290-294,324,359`; `scripts/install.sh:331-360` |

### S8 — from the documentation audit

| ID | Defect | Evidence |
|---|---|---|
| **B-01** | **DEFERRED to N-S9 by D-Z, 2026-08-31 — it leaves the D-O survivor list.** The Web UI fetches webfonts from Google on every page load: a browser with network access contacts `fonts.googleapis.com` and `fonts.gstatic.com` every time the UI opens, exposing the user's IP and the fact they run Jenova. Contradicts the local-first claim. **The fix — self-hosting Inter and JetBrains Mono — requires editing `jca_web/`, which D-Z freezes.** Re-verified still present in source 2026-08-31. **The leak is live until `jca_web/` is retired at N-S9**; this is flagged, not quietly reclassified | `jca_web/src/app.css:3` |
| **B-02** | **Four spellings of the runtime state directory.** Real state is `$JCA_HOME/.system`. `.jenova/` appears as a dead fallback in `update.sh` and `uninstall.sh`, as the live (broken) value in `cleanup.sh` (see B-07), and as the tray lock directory in `main.c`. Only the `cleanup.sh` instance is load-bearing | `scripts/update.sh:105`; `scripts/uninstall.sh:99,226`; `scripts/cleanup.sh:23`; `jenova-ui/src/main.c:324` |
| **B-03** | **Stale Dexie/IndexedDB comments in the Web UI.** `DatabaseService` is documented in-source as an "IndexedDB persistence layer via Dexie ORM". Dexie is not a dependency; the service is a `fetch` wrapper over `/api/db/*` backed by SQLite. This comment is the origin of the same false claim in three documents | `jca_web/src/lib/services/index.ts:63,71` |
| **B-04** | **Two Mermaid diagrams depict a path that cannot work.** `data-flow-simplified-router-mode.md` and `models-flow.md` show llama.cpp ROUTER-mode `/models/load` and `/models/unload`. `jenova-ca` launches `llama-server` in single-model mode; switching goes through `bin/jenova-model-switch` and a restart | `jca_web/docs/flows/` |
| **B-05** | **Profile header comments disagree on the model each profile targets.** `apu-ryzen7-5700u` and `dgpu-igpu-i5-1135g7` say Qwen2.5-Coder-3B in their `STRATEGY_DESC` while `PROFILE_DESC` says Qwen3.5-4B; `dgpu-igpu`'s own title says "3B Profile" while its conf comments say 9B; `dgpu-generic-12gb`'s header says "14B model". Nothing reads these, but they are the source of the fictional model columns removed from `hardware-profiles/README.md` | `hardware-profiles/*/*/{profile,jenova}.conf` headers |
| **B-06** | **V-1…V-3 below say `gmake`.** The `make`→`gmake` change was reverted; the Makefile builds with base `make(1)`. The verification steps still name a binary that is not a dependency | this file, Active table |

### S9 — found by the Session 004 integrity pass, 2026-08-28

Recorded per Directive 6. The pass was scoped to `scripts/` (the area touched by the B-07 fix);
B-36 surfaced incidentally while building `ARCHITECTURE_MAPPING.md`.

| ID | Defect | Evidence |
|---|---|---|
| **B-35** | **The B-07 fix widens `cleanup.sh`'s trust boundary — disclosed, not hidden.** `jenova-conf.sh` sets `LOG_DIR`/`CACHE_DIR` at `:42-43` and *then* sources `etc/jenova.local.conf` at `:53-74`, so a local conf can reassign either one — and `cleanup.sh --cache` runs `rm -rf "$CACHE_DIR"`. This is strictly safer than the unset-`JCA_HOME` defect it replaces (which pointed at `/var/cache` with no user action at all), and it is the same trust model `jenova-ca` already operates under. But `cleanup.sh` is the one consumer that deletes. **Candidate fix: refuse to operate on any path that does not resolve inside `$JCA_HOME`.** Not done — adding a path guard is beyond the approved scope of the B-07 fix | `lib/jenova-conf.sh:42-43,53-74`; `scripts/cleanup.sh:159` |
| **B-36** | **Five `lib/` modules carry no purpose header**, against CODE DOCUMENTATION STANDARDS: `db.lua` (934 lines), `fs_sync.lua` (454), `ui.lua` (257), `git.lua` (58), `sha256.lua` (87). `proxy.lua`'s opening comment documents a path-resolution detail, not the module. **Do not mass-edit** — the standard forbids retroactive comment additions without an explicit request. Recorded so the gap is visible, not to schedule a sweep | `lib/*.lua` opening lines |
| **B-37** | **The proxy writes `proxy.log` into the source root**, not `$LOG_DIR`. Untracked and gitignored via `*.log`, so nothing is committed — but `cleanup.sh --logs` cleans `$JCA_HOME/var/log` and will never find it, so it accumulates unbounded in the repository | `proxy.log`; `.gitignore:111` |
| **B-38** | **Three empty directories survive the Session 002 consolidation** — `docs/architecture/`, `docs/installation/`, `docs/usage/`. Git does not track empty directories, so they are local clutter only, but they are the last step of that session's stated plan | `docs/` |

### Corrections to the backlog itself — Session 004

| ID | Correction |
|---|---|
| **B-31** | **Half retracted — the icon claim is a false positive.** Verified this session: `png/` ships `jca.jpg` and `jca_grey.jpg`; `install.sh:279` sets `JENOVA_ROOT="$JCA_HOME"` and `:329` copies `png/*` there wholesale, so `main.c`'s `%s/png/jca.jpg` resolves in an installed deployment. The audit flagged this "unverified" because shell was withheld that session. **The second half stands** — `main.c:322-325` builds `$HOME/.jenova/ui.lock` (falling back to `/tmp/.jenova/`), a fourth spelling of the state directory |
| **B-06** | **Still open, and it is this file's own defect.** The Active table's V-1…V-3 continue to say `gmake`; the `make`→`gmake` change was reverted and the Makefile builds with base `make(1)`. Corrected in `TESTS.md` §5; not yet corrected in the Active table below |

### Residual Linux references in project code

Contradicting migration scorecard #1 ("3 explanatory comments only"): B-10 (whole file),
plus `HW_STORAGE="ext4/xfs/btrfs"` in `hardware-profiles/CPU/generic/profile.conf:18` and
`HW_SWAP`/`HW_STORAGE` in `hardware-profiles/Vulkan/apu-ryzen7-5700u/profile.conf:19-20`,
plus B-23's `/proc` dependency.

### Documentation defects introduced 2026-08-28 by this workspace

Recorded per Directive 6; these are errors in the consolidated docs, not in the source.

| ID | Defect | Site |
|---|---|---|
| **B-32** | `docs/architecture.md` claims "inbound storage writes queue re-indexing" and lists the embedding server's consumers as "the proxy's retrieval pipeline". Both false — this is exactly the WP-14 claim, reproduced. The proxy never indexes and never queries `:8082` | `docs/architecture.md` |
| **B-33** | `docs/context-and-retrieval.md` links to `remediation-plan.md` relatively; broken since the file moved to `.devdocs/REMEDIATION_PLAN.md` | `docs/context-and-retrieval.md:300` |
| **B-34** | `docs/usage.md` tells users to put overrides in `etc/jenova.local.conf` without the B-12 caveat that only `JENOVA_*` names take effect there | `docs/usage.md` |

---

## Deferred to post-refactor — verification gates V-1 … V-6 *(moved out of Active by D-Y, 2026-08-31)*

> **D-Y: deployment, build and install testing happens AFTER all refactoring is complete.** The
> USER runs a working deployment from this tree; `make install` would overwrite it. `make install`,
> `make verify` and `jenova-ca --daemon` are **prohibited** until then.
>
> **B-1 is not a blocker** — it was gating the wrong phase. **B-08, B-23 and B-24 leave the
> near-term path with these gates**; they are prerequisites for work that is not yet due.
>
> The rule from C-12/D-AB still applies when these are finally run: a detection is not evidence
> until its mechanism is shown not to route through the Linuxulator.

| ID | Task | Notes |
|---|---|---|
| V-1 | `gmake deps` | Exercises the single mandatory dependency list. Confirms all 20 packages resolve, including which appindicator FreeBSD provides |
| V-2 | `gmake` — full build | `jenova-ui` is the one to watch: the `#error` guard and the indicator-library probe |
| V-3 | `gmake install` → `gmake verify` | Validates the FreeBSD-ELF-only binary check |
| V-4 | `sh tests/proxy-concurrency/all.sh` | **The S-1 acceptance gate** for the ABI collapse |
| V-5 | `jenova-ca --daemon --lan`, then `sockstat -4l` | Confirm :8080 on `0.0.0.0`, :8081/:8082 on `127.0.0.1` |
| V-6 | Streaming completion end-to-end in the WebUI; `lsof` flat across a session | From remediation-plan Phase 1 rollout |

Until V-1 … V-6 pass on native FreeBSD, `.devdocs/ARCHIVE/` stays as the reference source.

---

## Completed — S-0 … S-7

### S-0 · Port exposure ✅
T-01 llama-server binds loopback · T-02 embed binds loopback · T-03 firewall text :8080 only ·
banner distinguishes client-facing from internal.

### S-1 · Runtime ABI ✅
T-05 Linux struct arm deleted · T-06 `AF_INET6=28` · T-07 FreeBSD constants only · T-08
`IS_LINUX` export removed · T-09 `proxy.lua` ×3 collapsed · T-10 `http.lua` ×2 collapsed ·
T-11 load-time FreeBSD guard. **304 → 236 lines.**

### S-2 · bash eliminated ✅
T-13 `jenova-model-switch` → POSIX sh · T-14 `lib/ui.lua:121` interpreter removed · T-15 zero
non-`/bin/sh` shebangs · T-16 6/6 functional cases pass.

### S-3 · Environment detection ✅
T-17 rewritten on `kern.ostype` · T-18 WSL probe deleted · T-19 distro/pkg matrix deleted ·
T-20/21 `/proc` and macOS arms deleted · T-22 Vulkan detection FreeBSD-only · T-23/24
`linux-tune.sh` + test deleted · T-25 dead caller branch removed.

### S-4 · Shell excision ✅
T-26 one `pkg` block (498 → 210 lines) · T-27 `realpath:coreutils` removed · T-28 apt/cargo
paths removed · T-29 node/npm required · T-30/31 OS gating and hint matrices removed · T-32
FreeBSD-ELF-only checks · T-33 `*.dylib*` globs removed · T-34 desktop entries un-gated ·
T-35 `make`→`gmake` · T-36/37 preflight arms and `fetch`-first network check · T-38
build-desktop rewritten · T-39 Metal machinery removed · T-40 glslc hints · T-41 CUDA
auto-detect removed · T-42/43 Darwin arms removed · T-44 Linux GPU/swap detection removed ·
T-45 BSD `stat -f` · T-46 `.dylib` probe removed · T-47 `flock` removed for the mkdir lock ·
T-48 `$OLD_PROXY_PID` fixed · T-49 probe order bundled→base→package · T-50 header comment ·
T-51 GNU-stat probe fork removed · T-52 opener simplified · T-53 `route`/`ifconfig` replaces
Linux `ip route get` · T-54 comment reworded.

### S-5 · jenova-ui ✅
T-56 `KERN_PROC_PATHNAME` only · T-57 `mach-o/dyld.h` and `_GNU_SOURCE` removed · T-58
`#error` guard · T-59 Makefile probes both indicator libraries and names FreeBSD packages.

### S-6 · Profiles ✅ — 10 → 6
T-60 macOS deleted · T-61 byte-identical AMD duplicate deleted · T-62 gtx-1650ti deleted ·
T-63 survivors relocated to uniform depth 2 · **T-64 WP-13 drift fixed** · T-65 CUDA excluded
via new `PROFILE_OPT_IN` · T-66 fixed-depth glob replaced with `find` · T-67 ladder verified.

### S-7 · Documentation ✅
T-68 linux/macos guides deleted · T-69 `dependencies.md` rewritten (+`sqlite3`, +node/npm,
+base-system "do not install" list) · T-70 `freebsd.md` promoted to primary · **T-71 port
topology corrected in `overview.md` and `backend.md`** · T-72 README platform section ·
T-74 `docs/README.md` drift list · T-75 `hardware-profiles/README.md` rewritten · T-76 WP-13,
WP-8 and WP-15 marked in the remediation plan · T-77 `.clangd.example` · T-79 test fixtures
repointed.

**T-70 was listed as done and was not.** "Update `tests/test_bin_jenova.sh` for the removed
Darwin arm" — the tests contain no platform references, so there was nothing to update. The
task was never needed and should never have been marked complete.

### Beyond plan — defects found during execution ✅
| ID | Fix |
|---|---|
| X-1 | **Vulkan GPU fallback could never be selected** — scored 0, and selection requires > 0. `MATCH_OS="FreeBSD"` → 25. Ladder documented so the trap is not re-armed |
| X-2 | `scripts/jenova-setup` never sourced `detect-env.sh`, so its OS guard could not fire |

---

## Cancelled

| ID | Task | Reason |
|---|---|---|
| T-81 | WP-9 — supervise the proxy from `jenova-ca` | **D-H** — only needed for a correct `rc.d`; deferred to Nim |
| T-82 | Write `rc.d/jenova` | **D-H** |
| T-83 | Install rc script, document `sysrc` | **D-H** |

---

## Deferred

| Item | Ruling |
|---|---|
| Q-4 GTK3/appindicator LGPL exposure | **D-D** — likely disappears in the Nim rewrite; only the FreeBSD package name was addressed |
| `docs/installation/{STREAMLINED,checklist,CHANGELOG-install}.md` residual sweep | Marked ⚠️ in `docs/README.md`; stale beyond platform concerns |
| `/api/fs` missing from the vite dev proxy (D-13) | Dev-server config, not platform |
| Adding fallbacks in `jenova-ca` for profile variable names | Remediation-plan WP-13 tail; the drift itself is fixed |
