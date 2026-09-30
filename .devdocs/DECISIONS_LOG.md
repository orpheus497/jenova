# DECISIONS LOG

Architectural and structural decisions, and ambiguities resolved. Newest first.

---

## 2026-09-30T04:36Z — the Linux build and deployment, jvim, thinking, and git

1. **Git is back in scope for this branch.** The USER asked for `idk` to have a clean history, the
   `.gitignore` to be up to date and the documentation congruent. This lifts ruling 1 of
   2026-09-29T23:30Z for that purpose.
2. **`jvim/` is Jenova's own Neovim configuration, under Jenova's licence** (USER). Neovim loads it
   from the repository as `NVIM_APPNAME=jvim`, inside the GUI or standalone. "Clean up jvim" means
   removing what is left over from its having been a separate repository — its `LICENSE` (BSD-2),
   `.gitattributes`, `.gitignore` (rules folded into the root file) and `nvim.log` — and never
   removing configuration on the grounds that it duplicates Neovim's runtime. The lead first deleted
   29 stock colour schemes and `pack/dist` on that ground; the USER stopped it and all was restored.
3. **Thinking is a setting, and follows the model's folder.** `JENOVA_REASONING` (`on`, `off`,
   `auto`) is passed as `--reasoning`; left empty, a model in `models/instruct/` gets `off` and any
   other llama-server's automatic setting. Measured: the Nemotron 4B build answers inside an unclosed
   `<think>` under Jenova's persona prompt (its reply arrived as reasoning with an empty answer),
   while the Qwen3.5 9B thinking model reasons and answers correctly 5 of 5.
4. **llama.cpp's `-lm` replaces `--mlock`/`--no-mmap`**, which the updated llama.cpp refuses;
   `JENOVA_MLOCK`/`JENOVA_MMAP` map onto it.
5. **This deployment's GPU split lives in `~/Jenova/etc/jenova.local.conf`, not in the profile**:
   `5,1` for the instruct model only, since the 9B does not fit the GTX at that ratio. The USER asked
   that GPU split tuning not be pursued further.
6. **Models live in `models/instruct/` and `models/thinking/`** (USER): the Nemotron 4B in instruct,
   the Qwen3.5 9B in thinking, and `models/agent/active.gguf` links to the active one.

---

## 2026-09-30T03:07Z — how Stages 1 and 2 were built

Made while executing `PLANS.md` Stages 1 and 2, which the USER approved. Each was read in the code
or run on this Arch host.

1. **`nimble llama` builds a static `llama-server`** (`-DBUILD_SHARED_LIBS=OFF`, `--target
   llama-server`) and copies it with `cmake -E copy`, not the plan's `$ORIGIN` library path with
   `cmake --install`. `cmake --install` installs every tool target llama.cpp defines, and a static
   binary is one file with no libraries of its own and no library path into the build tree
   (`readelf` shows no `RUNPATH`) [run]. llama.cpp's web UI is not downloaded
   (`LLAMA_BUILD_UI=OFF`, `LLAMA_USE_PREBUILT_UI=OFF`); tests and examples are off; jobs are
   `getconf _NPROCESSORS_ONLN`, else 4.
2. **`JENOVA_BACKEND=vulkan|cuda|cpu`** chooses the backend `nimble llama` builds, every GPU backend
   named ON or OFF so a value CMake cached from an earlier run cannot persist. The CUDA profile
   documented this route and nothing provided it. The CUDA build has not been run.
3. **GPUs are named in `DEVICES` and `DRAFT_DEVICE`.** The driver numbers them differently on
   FreeBSD and Linux [run]. `lifecycle.llamaArgs` resolves a name against
   `llama-server --list-devices` before the start lock is taken. A `Vulkan|CUDA|ROCm|SYCL` id in
   any case passes through; `none` means no GPU only on its own; each device is taken once; a name
   is matched against the device name, not its memory figures. A name that matches nothing is noted
   at the head of the backend log. When nothing resolves, or the probe does not answer, no `-dev`
   is passed and llama-server uses every GPU — a profile's GPUs being absent says nothing about which
   to use instead. `TENSOR_SPLIT` is withheld when `DEVICES` lost an entry, since it is positional.
4. **`CPU/generic` sets `DEVICES=none`.** llama-server refuses `-dev CPU` as an invalid device
   [run].
5. **The libadwaita warning is the desktop's, not Jenova's.** KDE writes
   `gtk-application-prefer-dark-theme=true` to `~/.config/gtk-4.0/settings.ini`; Jenova sets neither
   the property nor `darkTheme` [run, code]. The window clears the in-process value between
   `gtk_init` and `adw_init`; libadwaita's colour scheme decides light and dark either way.
6. **The LAN address comes from the kernel:** `std/net.getPrimaryIPAddr` (a UDP connect, which sends
   nothing, to the documentation address 192.0.2.1), else the first non-loopback IPv4 from
   `getifaddrs`. No subprocess.
7. **The OS name is the one the binary was built for.** Linux reads `/proc/cpuinfo`,
   `/proc/meminfo`, `/proc/swaps`, the filesystem `$JCA_HOME` is on (`/proc/self/mounts`) and
   `/sys/class/nvme/*/model`; the FreeBSD probes are unchanged.
8. **Every profile matches `FreeBSD|Linux`.** `dgpu-generic-12gb`'s allowlist reads `Arc.*A770`,
   because the driver reports `Arc(tm) A770`.
9. **A missing library's hint is chosen when compiling**: the FreeBSD port, else by which package
   manager exists — `pacman -F`, `dnf provides`, `apt-file search`.

---

## 2026-09-29T23:30Z — the USER's answers to the 23:04Z plan

1. **Git is out of scope.** No git history work, no branch, commit or permission operations, no git
   cleanup of any kind. This withdraws Stage 0.1–0.4 and Q1–Q4 of the 23:04Z plan.
2. **Cleanup only after the requested work, and only on the USER's confirmation.** Nothing is
   proposed that could delete or destroy something the project needs.
3. **The llama.cpp update to `a6ea155d3` was intentional.**
4. **The Web UI and the GUI are the two points of access. Both stay, and they behave the same.**
   Where the Web UI lacks behaviour the GUI has, the Web UI is changed; the earlier "`jca_web` is
   frozen" ruling does not stand in the way of parity.
5. **The installer is part of the Nim build.** No shell scripts, no model downloader, no `sudo` or
   system-tuning scripts. The pre-rewrite scripts are not brought back.
6. **Separation of concerns means the installed program is separate from the repository.**
7. **Cross-reference labels and bracketed references never belong in code comments.** They are fixed
   where code is touched, never by a mass repair. Earlier sessions reported this as resolved; it was
   not.
8. **`~/JCA` is left alone.**
9. **`AGENTS.md` rules 2 and 4 amended** as proposed: copyleft licences allowed; product code under
   `src/` and `jca_web/`, build output git-ignored, the installed application outside the repository
   in `$JCA_HOME`.
10. **Evidence.** The lead reads the code. A subagent's finding is not accepted until the lead has
    read the code behind it, and code comments and devdocs are never evidence on their own.

---

## 2026-09-29T23:06Z — implementation before tests; the existing deployment design is the intent; plan of 22:35Z withdrawn

Two rulings by the USER, given in review of the 22:35Z plan:

1. **Implementation comes first.** Test infrastructure, CI and VMs are planned after everything
   else, not placed in front of the work or used as gates between stages — otherwise the work
   becomes making tests pass instead of building the product. Checking a change by building it and
   running the existing self-tests and suites stays.
2. **The existing deployment design is the intent, and ruling 4 means restoring it.** Until
   `7b859f59` (#115) the repository had an installer — `install-jenova.sh`,
   `scripts/install-dependencies.sh`, `scripts/install.sh`, `update.sh`, `uninstall.sh`,
   `verify-install.sh`, with `lib/detect-env.sh` detecting the OS and package manager — that
   deployed a standalone application home, symlinked launchers into `~/.local/bin`, and left the
   repository deletable. The Nim rewrite deleted it without a replacement, while `paths.nim`'s
   installed layout and `config.nim`'s preference for `$JCA_HOME/etc` still expect the tree it
   produced.

Corrections made with them:

- **The 22:35Z plan is withdrawn and replaced.** It invented a deployment layout (`assets/`,
  `packaging/`, a stamped `build/root/`, `~/.local/lib/jenova`) without investigating the existing
  design, put tests, CI and VMs first, asked overlapping and unclear questions, and listed only some
  of them.
- **Evidence rule for the devdocs.** Several claims in that plan came from audit-agent reports the
  lead had not checked against the code, and some rested on code comments. From here, a finding in
  `PLANS.md` is tagged by how it was established — run on this machine, read in the code by the
  lead, or reported by an agent — and an agent-reported finding is re-read in the code before any
  work on it.
- **Quitting the window leaves the agent backend running on purpose.** The quit path in `gui.run`
  stops only the embedding backend and says why: reloading the model into VRAM on every start costs
  more than an idle process. It was wrongly presented as a defect.
- **GPU order.** The i5-1135G7 profiles encode a device order in executable values —
  `DEVICES=Vulkan0` in the dGPU profile, `DEVICES=Vulkan0,Vulkan1` and `DRAFT_DEVICE=Vulkan1` in the
  dual profile — and in their `HW_GPU_*` data values (read into `hwSummary`, which nothing uses). That this order is FreeBSD's is stated only
  in comments and was never measured. The measured fact is Linux on this machine: `Vulkan0` = Iris
  Xe, `Vulkan1` = GTX 1650 Ti. The order depends on the installed drivers.
- **`png/`'s images.** The pre-rewrite installer (`scripts/install.sh`) copied `png/` into the
  deployment and installed `jenova`, `jca` and `jca_grey` as desktop icons. In the current code only
  `gui.nim` reads from `png/` (`jenova.jpg`, the window's logo).

---

## 2026-09-29T22:29Z — platform, licensing, build and structure rulings; host and tracker corrections

Five rulings by the USER (given 2026-09-29, about 21:53Z):

1. **Supported operating systems are FreeBSD and Linux — Arch, Debian and Fedora — both
   first-class.** This supersedes "FreeBSD is the supported and tuned target" wherever it appears
   (README, the `jenova_core.nim` header, the nimble description, `pkgconfig.nim`'s error text).
   Consequences: runtime OS detection must be real, hardware profiles must match both OSes, the
   platform-shaped commands need a path per OS, and the install docs need per-OS dependency tables.
2. **The project is AGPL-3.0-or-later; GPL-licensed code and tools are allowed.** This supersedes
   `docs/install.md`'s "no GPL tools" policy and opens GPL/LGPL libraries (for example poppler-glib
   for the PDF rasteriser, GStreamer for audio capture) as candidates. `AGENTS.md` rule 2 then read
   "permissive, non-copyleft"; it was amended at the USER's approval (entry 2026-09-29T23:30Z).
3. **No OS-specific build folders.** The build detects the host OS and builds for it. This rejects
   the per-OS `bin/`/`nimcache/`/`ext_bin/` proposal made earlier in the same session.
4. **The deployed build is separated from the repository project folder.** The checkout stops being
   the place the application runs from.
5. **The repository gets a clear structural separation of concerns.**

Ambiguities resolved and corrections made in the same pass:

- **The host.** This workspace is bare-metal Arch Linux (HP ENVY, i5-1135G7, Iris Xe + GTX 1650 Ti),
  not a container and not the Linuxulator. The 2026-09-09T22:23Z entry's "Linux container hosted on
  a FreeBSD machine" was false when written; the 2026-09-09T04:24Z entry's "target host reached
  through the Linuxulator" described the FreeBSD 15.1 host that was the working host until
  2026-09-10. Both are superseded by this entry.
- **D-15 has the wrong remedy.** `hardware apply` writes `$JCA_HOME/etc/jenova.conf`, never the
  repository's `etc/jenova.conf`, and `config.nim` then reads the whole `$JCA_HOME/etc/` directory
  instead of `<root>/etc/`. Re-applying a profile therefore cannot repair the tracked file. D-15 is
  reframed under ruling 4: the repository should not ship a machine-tuned active configuration.
- **The comment-standard retrofit is finished history, not pending work.** Report 04's batches 1–8
  and a residue sweep were executed on 2026-09-03 and squashed into main as `989c2b5d` (#117).
  "Batches 3–8 pending" is withdrawn everywhere. `AGENTS.md`'s touched-code rule governs from here.
  V-17 stands for new and touched code. 89 full-line comment lines in seven files still carry
  cross-references — 71 labels or report references and 18 file:line citations; `gui.nim` holds 67 —
  plus two trailing comments citing file:line (`canvas.nim`, `pipeline.nim`): 91 lines in nine files,
  measured on comment text only, with standards citations (PDF 32000-1, RFC 3986) and
  `serverselftest`'s own phase names discounted. The USER ruled at 23:30Z that they are fixed where
  code is touched, never by a mass repair.
- **Listener suites.** `serve-selftest` binds kernel-assigned loopback ports, not 18642. No record
  shows the "do not bind listeners" instruction being lifted, but it was scoped to one session and was
  acted against on 2026-09-10 (FreeBSD) and 2026-09-29T21:59Z (Linux, under the USER's instruction to
  validate). The listeners are loopback-only except `test_lifecycle.sh`'s `serve --lan` run, which
  listens on `0.0.0.0` for up to 3 s. It is recorded as lapsed; the USER may reinstate it.
- **D5 as built.** An absent `X-Jenova-Scope` header means the no-workspace scope, not "today's global
  behaviour" as the held recommendation proposed. The Web UI never sends the header, so server-side
  retrieval never returns workspace content for Web UI turns; the Web UI pastes its workspace's notes
  and files into the prompt itself. The USER ruled at 23:30Z that the Web UI behaves as the GUI does.
- **Unrecorded decisions made in the 2026-09-10 sessions**, recorded now: with no usable maths font a
  display formula is shown as its source with a note; the maths font is resolved once at startup;
  `view` writes no application-state field or notice while it builds (it does fill the render
  caches); only the `chunked` transfer coding is accepted, and every refused body is drained under a
  byte cap and a deadline before the answer, with a quiet-peer stop for chunked and bad-coding
  refusals; FreeType is bound directly by the GUI to draw size-variant maths glyphs by index.
- **Standing rulings recorded elsewhere and back-filled here**: `jca_web` is frozen and no Web-side
  change is proposed (report 02, session 2; since superseded for parity with the GUI, entry 23:30Z);
  Push/Pull is out of scope; MCP and TTS are deferred
  (report 05); maths rendering is in scope (report 05, open decision 1); linking libz was approved by
  the USER on 2026-09-02 (recorded in `jenova_core.nim` beside the PDF assertions).
- **Commit citations.** `5606d418` and the other pre-squash hashes the devdocs cite (`8033bdd`,
  `63a7440`, `c8fb564`, `e495c8f` and the `nimby` branch's commits) are reachable only through this
  clone's reflog and can be pruned. The devdocs now cite `989c2b5d` (#117) and `4acedfa0` (#118).
  Preserving the originals under an archive ref is proposed in `PLANS.md` and is time-sensitive.
- **Counts.** `AGENTS.md`'s workspace table lists ten trackers, not eleven.

---

## 2026-09-09T23:55Z — rulings on M-3 (display math rendering: delimiter parsing, font metrics, and fallback strategy)

Three open design questions resolved by USER ruling for M-3 display math rendering:

1. **Task selection:** Progress M-3 display math rendering into the product, connecting `markdown.parse` to `mathtex` and Cairo rendering in `gui.nim`.
2. **Fallback strategy:** If a formula fails to parse or lay out (or if no usable OpenType MATH font is available), the GUI falls back gracefully to displaying the raw LaTeX source in a clean, readable text container, ensuring the transcript never crashes or displays blank blocks.
3. **Font metrics & layout:** `mathfont` and Pango/Cairo font metrics provide character widths and stretchy delimiter variant bounds to `mathtex.MathFont`, with `FontCandidates` recognizing installed math fonts (`DejaVuMathTeXGyre.ttf`, `FreeSerif.ttf`, `latinmodern-math.otf`, etc.). [2026-09-29T22:29Z: as built, HarfBuzz supplies glyph advances, MATH constants and size-variant glyph indices through `mathfont`; glyph ascent and descent are fixed ratios of the size. Cairo draws size variants by glyph index through FreeType when that face opens, and every other glyph with `cairo_show_text` in a face chosen by family name.]


## 2026-09-09T22:35Z — rulings on D5 (retrieval scoping hierarchy), D6 (partial-node merge), and V-17 (citation policy)

Three open design decisions resolved by USER ruling:

1. **D5, retrieval scoping hierarchy:**
   Retrieval-Augmented Generation (RAG) scoping is strictly hierarchical down the container tree:
   - **No workspace (root/global chat):** RAG searches only non-workspace chats and saved files/notes outside of any workspace. It does not retrieve anything from any workspace.
   - **Workspace Folder:** RAG scopes to this workspace and all its subfolders and projects.
   - **Workspace Project Folder:** RAG scopes to only this project and its subfolders.
   - **Project Sub-folder:** RAG scopes to only this folder and its contents.
   The wire contract uses `X-Jenova-Scope` carrying the container context (folderId, projectId, workspaceId) matching `workspace.contextFor` scoping.
   [2026-09-29T22:29Z: as built, an absent header means the no-workspace scope, and the frozen Web UI never sends it — see the top entry.]

2. **D6, partial-node merge in `upsert`:**
   Ruled as recommended: Move the merge-with-existing-row logic directly into `api.upsert`. When any caller (in-process GUI or `POST /api/db/*`) updates a row by `id`, omitted fields are merged from the stored row rather than overwritten with blank strings (`""`), protecting existing note contents and metadata from silent data loss.

3. **V-17, documentation citation policy:**
   Ruled as recommended: Absolute prohibition on citation labels, document references, line numbers, or cross-references inside source code comments. Code comments strictly adhere to AGENTS.md standards (`Script function and purpose:`, `Function purpose:`, `Action purpose:`). Reference citations and tracking belong exclusively in `.devdocs/` as reference material and nowhere else.

## 2026-09-09T22:23Z — devdocs audit corrections: relay socket independence, container context, and tracker sync

Three tracker ambiguities and inaccuracies resolved:

1. **`relay-selftest` socket requirements corrected:** the `relay-selftest` case in
   `src/jenova_core.nim` demonstrates that `relay-selftest` tests `upstream.spliceHeaders` on fixed
   string literals in memory without opening network sockets. Previous tracker statements claiming
   both `serve` and `relay` bind listeners were inaccurate. Only `serve-selftest` binds listeners.
   21 of 22 self-tests bind no listener (`lifecycle` and `rag` still open loopback client
   connections). [2026-09-29T22:29Z: the port given here, 18642, was wrong
   when written — `serve-selftest` asks the kernel for free loopback ports.]
2. **Execution environment clarified:** The workspace is a Linux container environment hosted on
   a FreeBSD machine. Operating system assertions, `sysctl` probes, and hardware detection must
   account for Linux container semantics and isolated `/proc` / kernel visibility.
   [2026-09-29T22:29Z: false when written — the working host was then FreeBSD 15.1 and is now
   bare-metal Arch Linux. Superseded by the top entry.]
3. **Repository and tracker synchronization:** `AGENTS.md` is confirmed tracked and committed in
   git commit `5606d418` [2026-09-29T22:29Z: a reflog-only commit on the since-deleted `nimby`
   branch; `AGENTS.md` reached main in `4acedfa0` (#118)]. Executed plans D1, D2/D3, D4, D7, and D8 are cleared from `PLANS.md`
   per the workspace architecture rule that `PLANS.md` carries only forward-looking implementation plans.

## 2026-09-09T04:24Z — the FreeBSD "blocked" framing is retired

Report 05 Phase 1 and report 01 A-2 both record their remaining work as blocked on a
FreeBSD host with the GUI built. That was true of the container the audits ran in; it is
not true of this workspace, which is the target host reached through the Linuxulator.
Both binaries build natively here and the twenty-one self-tests pass.

The `sysctl` probe, the `fork`/`setsid`/`execv` path, the D-Bus tray, the Neovim page,
GTK 4.20.4 and the GUI screenshots are therefore outstanding work rather than blocked
work, and are recorded in `TODOS.md` as such.

[2026-09-29T22:29Z: superseded. The working host is now bare-metal Arch Linux, so the FreeBSD items
need a FreeBSD host again, and Linux is a first-class target in its own right (top entry, ruling 1).
The self-test count above overstated that session: its handoff entry records nineteen passing, with
`relay` and `serve` not run.]

## 2026-09-09T04:24Z — the `.devdocs/` trackers are created rather than assumed absent

`AGENTS.md` mandates ten trackers under `.devdocs/` [count corrected 2026-09-29T22:29Z; this
entry said eleven]; none existed, and `AGENTS.md` itself is absent from the tree (deleted in
`c5111ce3`; restored, and on main since `4acedfa0`). Report 03 records that the
earlier tracker corpus was deleted deliberately, because the labelling apparatus it
produced had spread into 689 dangling references across `src/`.

Resolved: the trackers are recreated because the governance file requires them, and are
written without cross-reference labels — the defect was the labels and their reach into
source comments, not the existence of a task ledger. `AGENTS.md` is read from git history
until it is restored to the tree.

## 2026-09-09T04:24Z — nine audit defects: six repaired in five changes, two held, one backlogged

[Heading corrected 2026-09-29T22:29Z; it read "six audit defects split into five executed and two
held", which did not match the body.]

Nine defects were found by reading `src/` against the audit reports. Five are unambiguous
repairs of code that does not do what its own module says it does, and are executed:
D1, D2/D3, D4, D7, D8. The ninth, chunked request bodies, was backlogged and later executed as D9.

Two are held for a ruling because they change a contract rather than repair a defect:

- **D5, retrieval scoping.** `pipeline.prepare` accepts a `projectRoot` and no caller
  passes one, so every retrieval searches every workspace. Closing it requires the server
  to learn which conversation a completion belongs to, and the body carries no
  conversation id — so it needs a new header or body field, which the frozen Web UI also
  sees. Recommended: an `X-Jenova-Scope` request header, absent meaning today's global
  behaviour. [2026-09-29T22:29Z: ruled and built differently — an absent header means the
  no-workspace scope; see the top entry.]
- **D6, the partial-node merge.** `api.putEntity` merges a partial node onto the stored
  row; the `POST /api/db/*` route calls `upsert` directly and blanks every column the
  caller omitted. `api.nim`'s own header states the blanking is intended — the client
  "posts partial objects and means them" — while `gui.nim` documents the same behaviour
  as the defect that wrote a zero-byte file over a real one. The two cannot both stand.
  Recommended: move the merge into `upsert`, since a blanked `content` column destroys
  stored bytes.

## 2026-09-09T04:24Z — the workspace context is bounded at its source, not at the trimmer

`workspace.contextFor` has no token budget and its output enters the system message,
which `pipeline.trimHistory` deliberately never drops. Teaching the trimmer to drop or
truncate system content was rejected: that message carries the persona and every injected
block, so shortening it changes who is answering and what was retrieved. The budget goes
on the block being built instead, where the omission can be counted and reported.
