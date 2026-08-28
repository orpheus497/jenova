# DECISIONS LOG

Ledger of architectural decisions, clarified ambiguity, and USER/DEVELOPER TODOs scoped for
resolution. Most recent entries at the top.

---

## 2026-08-28 22:40 — Q-23 answered; a false claim of mine retracted

### D-W — Inference is serial for now: one context, one generation at a time. *(BINDING — answers Q-23)*

> "A for now"

One `llama_context`, one inference thread. A second request waits for the first to finish.
Option **B** (two contexts sharing the model weights, honouring `NUM_SLOTS=2`) is revisited when
the GUI lands and the real memory budget is known — it is a contained change.

### C-14 — N-22 retracted. **The claim was false and the fault was mine.**

I recorded that `CTX_SIZE=32768` "cannot be served on this 4 GB GPU" and called it a live
configuration problem. **The USER contradicted it — llama-server has always run that config
fine — and the USER was right.** The failure was entirely in my binding:

| What the config says | What my first binding did |
|---|---|
| `DEVICES="Vulkan0,Vulkan1"` — split across two GPUs | Left `model_params.devices` NULL, so llama.cpp chose for itself and the whole model landed on Vulkan0 alone, exhausting 4 GB |
| `KV_CACHE_TYPE="q8_0"` | Left `type_k`/`type_v` at the f16 default — **twice the KV memory for the same context** |
| `NUM_SLOTS=2`, `BATCH_SIZE`, `UBATCH_SIZE` | Not passed at all |

`llama-server` passes all of these, which is exactly why it worked where my binding did not.
**Verified after the fix:** ctx=32768, slots=2, kv=q8_0, Vulkan0 152.85 MiB + Vulkan1 381.11 MiB,
generation succeeds.

**The rule this cost:** *when a binding fails and the existing implementation succeeds on the same
input, the binding is wrong until proven otherwise.* I inverted that and blamed the hardware. The
config was the specification, and I had not implemented it.

**Consequence for the design:** `LoadSpec` now carries every backend value `etc/jenova.conf`
exposes, and there is no silent default that can override the profile. An unknown KV cache type
raises rather than falling back, because a quiet fallback to f16 is precisely what produced the
false conclusion.

### The finding that fell out of it — see `TODOS.md` N-24

`etc/jenova.local.conf` sets `DEVICES="Vulkan0,Vulkan1,Vulkan2"`. **There is no Vulkan2** — this
machine has `Vulkan0`, `Vulkan1` and `CPU`. The value is wrong and has always been wrong.

It has never caused a failure **because B-12 meant the shell discarded the local conf entirely**,
so `llama-server` ran on the profile's `Vulkan0,Vulkan1`. The Nim core honours the documented
precedence, so it is the first component ever to read that value — and it stopped with a clear
error naming the available devices.

**Fixing a precedence bug surfaced a latent bad configuration that the bug had been hiding.**
Worth expecting more of these as the shell path is retired.

---

## 2026-08-28 22:11 — llama.cpp binding, and a decision the USER should take

### D-V — Bind llama.cpp through its C header, never by mirroring the ABI. *(BINDING)*

`llama_model_params` and `llama_context_params` are large, versioned structs passed **by value**.
Declaring them by hand in Nim would rebuild precisely the hazard this migration removed:
`lib/ffi_defs.lua` hand-mirrored C structs, its two platform arms disagreed on field order and
integer width, and reading the wrong one silently swapped a `struct sockaddr *` for a `char *`.
The remediation plan traced three of four Phase 1 defects to that surface, and S-1 deleted the
Linux arm for it.

Nim compiles to C, so these types are imported from `llama.h` with `{.importc, header.}` and only
the fields actually assigned are named. **The C compiler resolves every layout.** A field that
moves, changes width or disappears between llama.cpp releases becomes a *compile error* instead of
a wrong pointer at runtime. This is the concrete payoff `jenova_refactor_analysis.md` predicted
from leaving LuaJIT FFI behind, and it is why the rewrite is worth doing at all.

**Linking took three corrections, recorded because the symptom is opaque:**

1. `llama.h` includes `ggml.h` from a sibling tree — `external/llama.cpp/ggml/include` must be on
   the include path.
2. The binary got `DT_RUNPATH`, which is consulted **only** for an executable's own direct
   dependencies. `-Wl,--disable-new-dtags` gives `DT_RPATH`, which is inherited.
3. That still failed, because **`libllama.so` carries its own `DT_RUNPATH`** pointing at a build
   directory that no longer exists — and an object with `DT_RUNPATH` does not fall back to the
   parent's `DT_RPATH`. `ggml`, `ggml-base`, `ggml-cpu` and `ggml-vulkan` are therefore linked
   **explicitly**, making them direct dependencies this binary's own rpath resolves.

Symptom of getting any of these wrong: `Shared object "libggml.so.0" not found, required by
"libllama.so.0"` — while the file sits in the directory the rpath names.

### Q-23 — One llama context serializes generations. Slots, or is serial acceptable?

**Status: OPEN. Shapes N-S4b.**

A `llama_context` is not safe to drive from two threads, so a single context means **one
generation at a time**. Under D-T there are two devices, and both could plausibly ask at once —
the host and the LAN client. The deployed profile already sets `NUM_SLOTS=2`, which is how
`llama-server` handled exactly this.

| | Option | Cost |
|---|---|---|
| **A** | **Serial** — one inference thread, one context; a second request waits | Simplest. The wait is a whole generation, so the second device appears frozen |
| **B** | **Two contexts from one model** — the model weights are shared, each context has its own KV cache | Honours `NUM_SLOTS=2`. Costs a second KV cache in VRAM, and KV cache is what already failed to allocate at `CTX_SIZE=32768` on this 4 GB GPU |
| **C** | **Sequence slots in one context** (`n_seq_max`) — llama.cpp's own mechanism | Matches what `llama-server` does. Most work, and the batching logic is genuinely intricate |

**Recommendation: A now, B when the GUI lands.** Serial is honest for a two-device product where
simultaneous generation is uncommon, and it avoids spending VRAM that this GPU has already proven
short of. B is a contained change once the real memory budget is known. **This is a USER call
because it trades responsiveness against VRAM on specific hardware.**

**AWAITING USER DECISION.**

---

## 2026-08-28 21:48 — Scale, and per-surface isolation

### D-T — Jenova is a personal, single-user product: **two devices**. *(BINDING)*

> "we aren't giving this 16 access ports … the idea is that one other device connects via lan
> meaning a maximum of two devices … this is a one user type system that can be expanded but
> larger local servers already exist … this is a personal use product"

**The host, plus at most one LAN client** — a phone, or a second laptop. Not a multi-user server;
that niche is already served by existing local servers. Expansion is possible later but is not
the design target.

**This is a sizing input, and it corrects work I had already done.** Every capacity number must
derive from two devices, not from server intuition. `routes.nim` was provisioned at 34 handler
threads — 16 for completions alone — which is roughly double what two devices can use, and
`BRIEFING.md` recorded the resulting bound as a "capacity limit" needing documentation. Both were
wrong-headed. Corrected to **14 handler threads**:

| Class | Threads | Derived from |
|---|---|---|
| `static` | 4 | Browsers open several parallel connections per page, and there is no keep-alive yet (N-16), so one page load is several short connections. The largest pool despite being the cheapest work |
| `health` | 2 | Must answer while everything else is saturated |
| `api` | 3 | Database calls, milliseconds each |
| `completion` | 3 | **Two devices, two possible live generations, plus one margin** — a reloaded browser tab leaves a half-open stream holding a thread until the 30 s socket timeout, and without the margin that stale connection would block the real one |
| `embed` | 1 | Background work, one at a time |
| `debug` | 1 | Diagnostics only |

**N-17 is withdrawn.** It recorded bounded concurrency as a limitation to document wherever LAN
mode is described. Under D-T the bound is not a limitation, it is the specification.

**D-S is strengthened, not weakened.** My stated worry about not serving "tens of thousands of
connections" was irrelevant to what this product is. The threaded model is straightforwardly
correct at this scale.

### D-U — Every service surface owns its own routine and threads. *(BINDING)*

> "we need to ensure every endpoint proxy and server and port has its own routine and thread"

**This corrected a real defect in the server I had just built, not a preference.** With one shared
pool, connections of every kind compete for the same threads — and completion streams are
long-lived *by design*, so enough concurrent generations occupy every worker and the server stops
answering health checks and serving assets. That is not an edge case; it is normal operation.

Implemented as two stages:

1. **Acceptor threads** accept, then peek the request line with `MSG_PEEK` — **without consuming
   it** — classify the route, and hand the descriptor to that class's queue. They never run a
   handler, so no handler can stall the accept path. Only a `SocketHandle` crosses the thread
   boundary; nothing reference-counted is shared.
2. **A pool per class**, each with its own queue and threads.

The health endpoint having dedicated threads is the point in miniature: a liveness endpoint that
stops answering under load is worse than not having one.

**Verified** (`serve-selftest` phase 3): with the debug class over-subscribed 3:1 by 800 ms holds,
`/health` answered in **0.2 ms** and static in **0.2 ms**. Under a shared pool both would have
queued behind the holds.

---

## 2026-08-28 21:33 — N-S3 architecture

### D-S — Thread-per-connection worker pool, **not** `asyncdispatch`. *(Deviates from the spec — flagged for review)*

`jenova_refactor_analysis.md` proposes Nim `asyncdispatch` with a framework such as Prologue or
Jester, plus isolated thread pools. **The server implemented at N-S3 does not use async at all.**
A fixed pool of worker threads each block in `accept(2)` on one shared listening socket, and each
connection is served start to finish on its own thread with blocking I/O.

**Why, given D-R.** `asyncdispatch` is one cooperative loop per thread — the same shape of
machine as `proxy.lua`'s `ffi.C.select` loop. Async does not by itself remove the defect; it
relocates it. Correct async requires that every blocking call be dispatched to a worker and
awaited, and **a single missed dispatch anywhere reintroduces the global stall** with no
compile-time signal. The failure mode is silent, and it is precisely the failure this project
already shipped once.

The threaded model makes the property structural instead of conditional. There is no shared loop,
so there is nothing for a blocking call to stall. Blocking database access — which `db.nim`
already provides safely, one connection per thread — becomes correct by default rather than a
hazard requiring discipline at every call site.

**What this trades away, stated plainly:** concurrency is bounded by the worker count (default
16, `JENOVA_WORKERS`), not by memory. Connections beyond that wait in the accept backlog. This
serves tens of concurrent connections well and would not serve tens of thousands. The spec's
"thousands of concurrent connections" is an aspiration inherited from server framing; **Jenova
under D-L is a desktop application with a LAN mode**, where the realistic peak is one GUI, a few
browser tabs and a handful of LAN clients. If that assumption is ever wrong, the honest fix is a
hybrid — async accept and header parsing, worker threads for handlers — not a return to a single
loop.

**Verified rather than argued** (`serve-selftest`): an SSE stream held a 40 ms cadence with a
40.1 ms maximum gap idle, and 40.1–47.6 ms across runs while four clients pushed 31–37 real
400,000-row recursive CTEs through SQLite. Average inter-event gap was unchanged at 40.0–40.2 ms.
A serializing server would show gaps in multiples of the interval.

**This is my architectural call, not the USER's, and it departs from the document C-7 designates
as the specification to honour.** If the async design is wanted for reasons beyond concurrency —
connection scale, or alignment with a Nim web framework's ecosystem — this is the decision to
revisit, and the cost of revisiting it grows once handlers are written against blocking I/O.

---

## 2026-08-28 21:25 — Concurrency is a requirement, not an optimisation

### D-R — The rewrite must not reproduce a single-threaded execution model. *(BINDING)*

> "remember we need to make sure we aren't building a single threaded system as that will just
> inherit the same issues the lua build had"

**The failure being designed out.** `lib/proxy.lua` ran on a single-threaded custom
`ffi.C.select` event loop. Every database query, filesystem operation and shell-out ran *on* that
loop, so any one of them halted HTTP serving, routing and token streaming for every connected
client — the "desync and lagging" `jenova_refactor_analysis.md` diagnoses.

**The diagnosis is sharper than the analysis document states.** SQLite was never the bottleneck:
`lib/db.lua:65-68` already set `journal_mode=WAL`, `synchronous=NORMAL` and `busy_timeout=5000`.
The store supported concurrency the whole time. **The caller could not use it.**

**The trap this ruling exists to avoid, stated concretely:** Nim's `asyncdispatch` is *also* a
single-threaded cooperative event loop. A blocking call inside an `async` proc stalls it exactly
as the Lua loop was stalled. Adopting async without threads would reproduce the defect in a new
language and call it a rewrite.

### C-13 — Standing architectural rule for the remainder of Plan B

**Blocking work never runs on the event loop.** Database access, filesystem I/O, indexing,
embedding and inference execute on worker threads; the async layer only awaits their results.

Enforcement points, by stage:

| Stage | The rule applied |
|---|---|
| **N-S2** ✅ | One SQLite connection per thread; no shared handle, no global lock. Verified by measurement, not assertion |
| **N-S3** | **The decisive stage.** The HTTP server may await database and filesystem results but must never call them inline. If this is got wrong, N-S2's work is thrown away and the Lua defect returns |
| **N-S4** | Inference isolated on its own thread (already required by N-7 under D-N's single-binary model) |
| **N-S5** | RAG indexing and embedding on worker threads, never on the loop |

**N-S2 makes concurrency possible; it does not by itself make the system concurrent.** That is
decided at N-S3.

---

## 2026-08-28 20:37 — USER rulings: licensing corrected, rewrite shape settled

### D-Q — Plan B approved: backend first, GUI last; source in a new `src/`. *(BINDING)*

Stage order **N-S0 … N-S9** as recorded in `PLANS.md`. Nim source lives in a **new `src/` at the
root**, alongside the retained `lib/` and `bin/`, which shrink as stages land — Directive 4 read
literally, and it keeps the two eras visibly separate during the transition.

**Two consequences banked immediately:**

- `libadwaita` and `gtksourceview5` are not needed until **N-S7**. N-S0 installed nothing.
- **The risk this ordering accepts:** owlkettle is unproven on this host and its stage is last, so
  toolkit surprises arrive after the backend is committed. Mitigation if that becomes
  uncomfortable is a throwaway spike at any point before N-S7; it does not disturb the order.

### C-12 — This environment executes FreeBSD binaries. The "nothing here is evidence" rule was too strong.

Recorded as a constraint correction, not a decision.

`TESTS.md` §1 and `TODOS.md` carried a standing rule that the editing environment is a Linux
container and *"nothing run there is evidence"*. **Verified false this session:**
`sysctl -n kern.ostype` returns `FreeBSD` while `uname -s` returns `Linux` (C-8); `pkg` reaches
the real FreeBSD package database; and `/usr/local/nim/bin/nim`, a FreeBSD amd64 ELF, **executes
and reports its version**. `bin/jenova-core` was then compiled here as a FreeBSD ELF and run.

Session 001 already reached this conclusion once and retracted C-3 for it. The stricter rule
reappeared in Session 003's trackers regardless. **The accurate rule is narrower:** anything
depending on `uname -s`, on `/proc`, or on Linux-emulated syscalls is not evidence — B-23's
`/proc` fd count is exactly that case. Native FreeBSD builds and binaries run here and *are*
evidence.

This does not clear **B-1**: a full `make` build, `make install` and a live daemon start remain
unexercised. It does mean they are runnable from here rather than blocked on the USER.

### D-P — GUI toolkit: GTK4 + libadwaita, via owlkettle. *(BINDING — answers Q-20, closes N-2)*

Nim binding **owlkettle** (MIT) over **GTK4** and **libadwaita**. Declarative and reactive, which
suits a UI driven by streaming tokens; **GtkSourceView 5** supplies syntax-highlighted code
blocks. Available only because **D-M** corrected the licence position. `gintro` remains the
escape hatch for any widget owlkettle does not expose — the two are not exclusive.

**Verified on the host, not assumed** (via the Linuxulator, which reaches the real FreeBSD `pkg`
database):

| Component | State |
|---|---|
| `nim-2.2.10`, `nimble-0.20.0` | Installed. **But `nim` is absent from `PATH` while `nimble` resolves** — must be fixed before N-S0 |
| `gtk4-4.20.4` | Installed |
| `libadwaita-1.8.5.1` | In ports, **not installed** |
| `gtksourceview5-5.18.0` | In ports, **not installed** — only `gtksourceview4` is present |

**Consequence for an existing feature:** GTK4 drops `libappindicator`. The tray must be rebuilt on
**StatusNotifierItem**, and the GTK3 dependency retires with `jenova-ui/src/main.c` at N-S3. The
tray is an existing feature and is retained (Directive 3), not dropped in passing.

### D-M — The project is AGPL-3.0. Copyleft dependencies are permitted. *(BINDING)*

> "this project is agpl3 licensed so it permits these gpl and lgpl licenses"

**Verified, not taken on assertion:** `LICENSE` is the GNU Affero General Public License v3.0 in
full, and `NOTICE:14` states *"Jenova original material … Licensed under the GNU Affero General
Public License v3.0"*. `external/llama.cpp` is MIT and SPIRV-Headers is Khronos Free Software
Licence — both permissive, both compatible.

**Ruling:** AGPL-3.0 is a copyleft licence compatible with GPL-3.0 and with LGPL. GTK, Qt, FLTK
and GtkSourceView are all available to this project. **`AGENTS.md` Directive 2 — *"GPL, LGPL, or
any other copyleft license is strictly prohibited"* — is wrong about this codebase and is
superseded on the copyleft point.** Its *"zero proprietary dependencies"* clause is untouched and
still binding.

**Consequences:**

- **Q-4 is CLOSED, not deferred.** The GTK3 + libappindicator tray was never a licence violation.
  Three sessions treated it as one, and `PLANS.md` Plan A §5 carries "no GPL dependency to build,
  install or run" as a migration objective on that false basis. The bash removal (D-A) stands on
  its own grounds and is unaffected.
- **Q-20 reopens with the full field available** — the four-option shape I put to the USER was
  built on the false constraint, and its recommendation was wrong. Re-asked.
- **`AGENTS.md` Directive 2 needs amending by the USER.** I do not edit governance. Flagged
  alongside a second discrepancy: **Directive 7 governs `.dbc` cartridges, binary struct layouts
  and `test_roms/` conversion — none of which exist in this repository.** That directive appears
  to have been written for a different project, and it is worth a read-through before it is
  relied on.

### D-N — Single binary: the GUI links the Nim core in-process. *(BINDING — answers Q-22)*

No IPC, no serialisation between GUI and core; fastest path for streaming tokens. The HTTP
server becomes a subsystem the binary hosts, serving `jca_web/` for as long as it is retained.

**Recorded honestly: this was not my recommendation.** I argued for a core daemon plus a thin
client, on the grounds that it preserves LAN mode as a peer, survives WebUI deprecation
unchanged, and keeps a GUI crash from killing a running generation. The USER chose the single
binary. **Two things must therefore be designed in deliberately rather than assumed:**

1. **LAN mode is an existing feature** (Directive 3 — Total Feature Retention). A single binary
   must still bind and serve it; the GUI cannot be a precondition for the server running.
2. **A GUI fault kills inference in the same process.** Generation state needs to survive a UI
   error — isolate the inference thread and do not let GUI code run on it.

This also settles the spec's own open question (`jenova_refactor_analysis.md:94`) toward
**direct linkage of `llama.cpp`** rather than local HTTP.

### D-O — Adopt the proposed backlog triage. *(BINDING — answers Q-21)*

Fix only what survives the rewrite: hardware-profile data (B-05, B-09, B-10, B-20, B-21), the
destructive test **B-22**, and the WebUI privacy leak **B-01**. Everything living in Lua modules
and shell scripts the rewrite deletes stays recorded but unworked, so the Nim implementation does
not reproduce it.

**Follow-on: this likely re-answers Q-10 as option B** — retire `verify-install.sh` and the
`verify` target rather than rewrite them, since they verify a shell install the rewrite replaces.
Not taken as decided; Q-10 remains the USER's.

### C-11 — I do not run git. *(BINDING)*

> "you are not permitted to run git actions, commits happen from me not you"

No commits, staging, branching, checkout, `git mv` or `git rm` by me, ever. Commit boundaries are
the USER's alone, and **N-6 is withdrawn as a task I could perform** — it stands only as a note
that the working tree has no commit boundary.

**Clarified by the USER, same session: read-only inspection is permitted.** `git status`, `git
diff`, `git log` and `git show` may be used for verification and to reach other branches. The
prohibition covers every write: staging, commits, branching, checkout, `git mv`, `git rm`.
**Branch creation for Plan B is therefore the USER's action, not mine.**

---

## 2026-08-28 20:29 — USER ruling: the target is a native FreeBSD desktop application

### D-L — Nim rewrite becomes the active focus; Jenova becomes a native GUI app. *(BINDING)*

> "i think we should just focus on the nim rewrite and go with that — we want to make this a
> freebsd native gui application not a web wrapper or webui — for now we will keep the webui but
> we are going to deprecate it, the focus should instead be on the nim conversion and turning this
> into a native freebsd graphical desktop application"

**Ruling, in four parts:**

1. **The Nim rewrite is promoted from long-term trajectory (D-D) to the active workstream.**
2. **The delivery target is a native FreeBSD graphical desktop application** — compiled, drawing
   its own interface. **Explicitly not** a web wrapper, an embedded browser, or a WebUI in a
   window.
3. **`jca_web/` is retained for now and deprecated.** It keeps working during the transition; it
   is not the destination. No new feature work goes into it.
4. **Directive 3 (Total Feature Retention) is satisfied** — this is the explicit instruction that
   directive requires before anything may be deprecated.

**This supersedes the shape of the existing spec.** `jenova_refactor_analysis.md` on
`develop/nim` — the document `BLUEPRINT.md §10` and C-7 treat as the specification to honour —
describes a Nim **server and CLI** that *keeps the WebUI as its client*: it lists WebUI static
file serving as a core responsibility, cites "WebUI clients never experience lag" as an
acceptance criterion, and its six-component roadmap contains **no GUI component at all**. Under
D-L that roadmap gains a seventh component and loses its client. The spec's server, RAG, DB and
`llama.cpp`-linkage analysis stands; its client assumption does not.

**The consequence that needs stating plainly:** the current desktop surface is GTK3 +
libappindicator, which is **LGPL — already prohibited by Directive 2** and recorded as the
deferred **Q-4**. D-D deferred it on the reasoning that the dependency "likely disappears in the
Nim rewrite." Under D-L the GUI *is* the product, so Q-4 stops being deferrable: **the toolkit
choice is now the first architectural decision of the rewrite, and Directive 2 rules out GTK,
Qt, FLTK and every toolkit that wraps them.** Raised as **Q-20**.

**Second consequence: the backlog must be re-triaged, not worked through.** Roughly two-thirds of
the 37 open defects sit in Lua modules and shell scripts the rewrite deletes. Under D-D's
governing principle — *subtract, do not rewrite* — fixing them is work thrown away. Re-triage
raised as **Q-21**; no defect is to be worked until it is triaged against this ruling.

### Q-20 — Which GUI toolkit? Directive 2 eliminates every mainstream one.

**Status: OPEN. Blocks all GUI work — this is the first decision of the rewrite.**

Directive 2 permits MIT, BSD, zlib and public domain, and prohibits GPL **and LGPL** outright.
That removes GTK (LGPL), Qt (GPL/LGPL/commercial), wxWidgets (LGPL-derived), FLTK (LGPL + static
exception — still LGPL), and every wrapper over them: `libui`/`libui-ng`, `nigui`, `owlkettle`.
**The current tray is GTK3 + libappindicator and is therefore already in violation** — Q-4,
deferred under D-D on the reasoning that it disappears in the rewrite. It does not disappear; it
becomes the product.

Surviving options, all with real FreeBSD ports and Nim bindings:

| | Stack | Licence | Fit |
|---|---|---|---|
| **A** | **Dear ImGui + SDL2 + OpenGL** | MIT + zlib | Draws every widget itself. Mature text input, tables, docking, scrolling. Nim: `nimgl`. The realistic choice for a text-dense chat/agent UI |
| **B** | **raylib + raygui** or **Clay** layout | zlib | Simplest to stand up; Nim `naylib` is good. raygui is thin for rich text — a markdown chat view, code blocks and a file tree would be largely hand-built |
| **C** | **XCB/Xlib + FreeType directly** | MIT + FTL | Total control, no toolkit dependency, genuinely native. Very large effort — text shaping, input methods and scrolling all become ours |
| **D** | **Relax Directive 2** for a dynamically-linked LGPL toolkit (GTK4, Qt) | — | The only path to platform-native look-and-feel and accessibility. **Requires the USER to amend a non-negotiable rule** — I cannot take this decision |

**Recommendation: A.** It is the only permissive stack whose text handling is already adequate
for a chat client, and immediate-mode suits a UI driven by streaming tokens. But note honestly
what A costs: an ImGui app looks like a tool, not like a FreeBSD desktop application. **If
"native desktop application" means it should look and behave like other desktop apps —
system theme, font settings, accessibility, drag-and-drop — then A is the wrong answer and the
real question is D.** That distinction is the USER's to settle.

**AWAITING USER DECISION.**

### Q-21 — Re-triage the backlog against D-L before working any of it.

**Status: OPEN. Blocks defect work.**

Of 37 open defects, most sit in files the rewrite deletes — `lib/*.lua`, `bin/jenova-ca`,
`scripts/*`, `jenova-ui/src/main.c`. Under D-D's *subtract, do not rewrite*, fixing them is work
thrown away. Proposed triage:

| Class | Items | Action |
|---|---|---|
| **Dies with the rewrite** | B-08, B-11, B-12, B-13, B-14 … B-19, B-27 … B-31, B-35, B-37 | **Do not fix.** Leave recorded so the Nim implementation does not reproduce them |
| **Survives — data, not code** | B-05, B-09, B-10, B-20, B-21 | Fix. `hardware-profiles/` survives the rewrite (`BLUEPRINT.md §10`) |
| **Fix now regardless** | B-22 | A test that rewrites `etc/jenova.conf`. Cheap, and it protects the tree during the rewrite |
| **WebUI, now deprecated** | B-01, B-03, B-04 | B-01 is a live privacy leak contradicting the local-first claim — fix even while deprecating. The other two are documentation of a component being retired |
| **Test surface** | B-23 … B-26 | The proxy-concurrency harness tests the Lua proxy. **Its value drops sharply**; the Nim core needs its own tests |

**Consequence for V-1 … V-6:** these gates verify a build and install that the rewrite replaces.
V-2 (build) and V-5 (port topology) stay meaningful. **V-3 is a fix to a verifier for a shell
install that is going away** — which likely answers Q-10 with option B rather than A.

**AWAITING USER DECISION.**

### Q-22 — One binary, or a core plus a GUI client?

**Status: OPEN. Shapes the whole rewrite.**

The WebUI is retained during deprecation, so the Nim core must serve HTTP either way. The
question is where the desktop app sits:

- **A — Single binary.** The GUI links the core in-process; no IPC, no serialisation, fastest
  path for streaming tokens. The HTTP server becomes a subsystem it hosts for the legacy WebUI.
- **B — Core daemon + thin GUI client** over the unified local port. Keeps LAN mode and the
  WebUI as peers, lets the GUI be restarted without dropping inference, and matches the existing
  `jenova-ca` supervision model.

**Recommendation: B**, with the GUI and core in one repository and one build. It preserves LAN
mode (an existing feature — Directive 3), survives WebUI deprecation unchanged, and means a GUI
crash does not kill a running generation. A is faster to write and faster at runtime; B is the
one that still makes sense after the WebUI is gone.

The spec's own open question — **static vs dynamic `llama.cpp` linkage**
(`jenova_refactor_analysis.md:94`) — is still unanswered and rides on this.

**AWAITING USER DECISION.**

---

## 2026-08-28 20:01 — USER ruling on rule precedence

### D-K — Explicit rules outrank implicit ones. *(BINDING)*

> "command laws explicit the behaviour rules are implicit"

**Ruling:** `AGENTS.md` COMMAND LAWS are explicit obligations. Tooling preferences — including
"use native IDE tooling" and any in-session instruction to avoid the shell — are behavioural and
implicit. **An implicit rule does not override an explicit one, and it is not licence to infer an
exemption from one.**

**Applied to the case that produced this ruling:** COMMAND LAWS name exactly one command
outright — `date '+%Y-%m-%d %H:%M'` — and require every `.devdocs/` timestamp to come from it.
Session 003 read a general "do not run commands" instruction as overriding that, did not run it,
and then wrote the conflict into `BRIEFING.md` and `SESSION_HANDOFF.md` as a justification. Both
were wrong: the omission, and the editorialising about it. The notes are removed; the Session 003
entry now simply records that its end time is unknown.

**Standing consequences:**

- `date` is run every session that writes a `.devdocs/` timestamp. It is not optional and it is
  not subject to tooling preference.
- Where COMMAND LAWS and a behavioural instruction genuinely conflict, follow the law and say so
  in one line — do not construct a rationale for the exception and file it as a finding.
- Session 004's practice is the correct shape: Read/Edit/Write for all content work, shell
  reserved for what has no native equivalent in this harness (`date`, search, `file`, `git`) and
  for verification commands.

Supersedes the reasoning in Session 003's removed timestamp note. Does not disturb **C-9** or
**C-10**.

---

## 2026-08-28 19:49 — Session 004: workspace compliance

### D-J — The Codebase Integrity Standard is defined in `PLANS.md`, authored this session

**Decision taken by me, under the standing approval to proceed. Recorded for review.**

`AGENTS.md` Directive 6 mandates that *"every session must run a `.devdocs/PLANS.md` 'Codebase
Integrity Standard' pass … proportional to the area touched"* and points at that file for the
definition. **No such section existed.** `grep` across `.devdocs/` found no occurrence of the
phrase anywhere. The directive has therefore been unrunnable since the workspace was created,
and no session — 001, 002 or 003 — could have complied with it.

I authored the section rather than leaving the directive inert. It codifies seven violation
classes (placeholder, simulated stand-in, dead code, unverified logic, false completion record,
artifact contradiction, platform foreignness) and five rules for running a pass, three of which
are lifted directly from failures this workspace has already recorded:

- *A tracker entry is not evidence for its own claim* — from the three retracted `PROGRESS.md` claims.
- *`sh -n` is not a pass* — from **C-9**, where a syntactically perfect Linux script survived it.
- *Retract rather than edit away* — from `PROGRESS.md`'s existing practice.

**This is my wording, not the USER's.** If the intended standard was something else, this section
is the thing to correct.

### C-10 — Two mandated trackers never existed; the doc-update matrix was unmet for 31 files

Recorded as a constraint, not a decision.

`ARCHITECTURE_MAPPING.md` and `TESTS.md` are both mandated by the `AGENTS.md` workspace table.
Neither existed until Session 004. The doc-update matrix requires `ARCHITECTURE_MAPPING.md` to
be updated on every file added, removed or moved — **Session 001 moved or deleted 31 files**
(13 deleted, 18 renamed, per its own handoff entry) and Session 002 relocated or deleted a
further set of documentation files whose split from S-7's own moves cannot be cleanly attributed
from the working tree. None of it was mapped.

The general failure: *a workspace can be internally consistent and still be out of compliance
with its own governance, because the trackers only audit the product, never themselves.* All
three prior sessions read `BRIEFING.md` and `SESSION_HANDOFF.md` at start-up, as instructed, and
neither file records an obligation that was never begun. Session start should compare the
`.devdocs/` directory against the `AGENTS.md` workspace table, not just read what is present.

---

## 2026-08-28 — Full-tree audit: four new questions opened

The migration's questions (Q-1 … Q-8) are all closed and stay closed. The audit surfaced four
decisions that are **not** mine to make. Recorded per Directive 1; none blocks the outstanding
verification work (V-1 … V-6), all block the fixes for `TODOS.md` B-07 … B-12.

---

### Q-9 — The configuration hierarchy is inverted. Which way should it be fixed?

**Status: OPEN. Blocks B-12.** Architecture recorded in `BLUEPRINT.md §2.2`.

`etc/jenova.local.conf` is sourced *before* `etc/jenova.conf`, and the profile conf assigns every
tuning variable unconditionally from `${JENOVA_*:-default}`. Bare assignments in the local conf are
therefore discarded. `scripts/build-llama.sh` generates a local conf using exactly those discarded
bare names, so the build script's own hardware tuning never takes effect.

| | Option | Cost | Note |
|---|---|---|---|
| **A** | **Swap the source order** — source `jenova.local.conf` *after* `etc/jenova.conf` | One line in `bin/jenova-ca`; `lib/jenova-conf.sh` splits into path-resolution and override halves | Makes the documented hierarchy true. Risk: `jenova-conf.sh` also resolves `LLAMA_SERVER`/`LLAMA_LIB_DIR`, which `jenova.conf` depends on, so the file must be split rather than moved |
| **B** | **Keep the order; fix the generator and document the rule** — `build-llama.sh` emits `JENOVA_*` names, and the `JENOVA_*`-only rule is stated in `docs/usage.md` and `hardware-profiles/README.md` | Smaller, no runtime change | Leaves a hierarchy whose two files use opposite naming conventions for the same settings — the trap that produced this defect |
| **C** | **Delete `jenova.local.conf` as an override mechanism**; document `JENOVA_*` environment variables as the only supported override | Smallest; aligns with D-D (subtract) | Loses persistent per-host overrides unless the user edits their shell profile |

**Recommendation: A.** It is the only option under which the shipped `build-llama.sh` output does
what it says. B is a documentation patch over a design inversion, and under D-D the Nim backend
will need one config precedence rule that is actually true.

**AWAITING USER DECISION.**

---

### Q-10 — `scripts/verify-install.sh` verifies a product that does not exist. Rewrite or remove?

**Status: OPEN. Blocks B-08 and verification step V-3.**

The script checks `$VIMRUNTIME` (never set), `~/.config/jenova/init.lua`, `share/jenova/mason`, and
a `jenova --version` string containing `JVIM`. It exits 1 on a correct install. `make verify` is
wired to it, and both `docs/install.md` and the V-3 step tell users to run it.

**Options:** (A) rewrite against what `install.sh` actually deploys — six launchers, `llama-server`
+ shared libs, `lib/`, `scripts/`, `hardware-profiles/`, `public/`, `etc/jenova.conf`, the
`~/JCA` directory tree, and the three model directories; (B) delete it and drop the `verify` target,
letting `make install`'s own summary stand; (C) leave it and remove the docs that recommend it.

**Recommendation: A.** V-3 is one of the six outstanding verification gates; without a working
verifier there is no defined "installed correctly" for this project. B is defensible under D-D only
if the Nim cut-over will ship its own verifier.

**AWAITING USER DECISION.**

---

### Q-11 — Two `jenova-setup` scripts are config-symlinkers, not tuning scripts. Delete?

**Status: OPEN. Blocks B-09.**

`Vulkan/dgpu-generic-12gb/jenova-setup` and `CUDA/dgpu-generic/jenova-setup` do not tune anything.
They symlink their `jenova.conf` over `etc/jenova.conf` — duplicating `detect-hardware.sh
--apply-profile`, but by symlink instead of copy, and with a root computed from five `dirname`
calls that lands on `$HOME`. `scripts/jenova-setup` dispatches to them as kernel tuning.

**Options:** (A) delete both; have `scripts/jenova-setup` report "no tuning defined for this
profile" when the file is absent; (B) replace both with real FreeBSD tuning (generic ARC cap + OOM
policy); (C) fix only the path bug and leave the symlink behaviour.

**Recommendation: A.** Profile deployment already has one correct owner. C would leave two
mechanisms that write the same file by different means — and the symlink form defeats
`detect-hardware.sh`'s backup step. Note this decision also covers `CPU/generic` (B-10), which is a
separate question of *writing* FreeBSD tuning rather than removing wrong tuning.

**AWAITING USER DECISION.**

---

### Q-12 — `CUDA/dgpu-generic` recommends a third-party "Uncensored / Aggressive" model. Intended?

**Status: OPEN. Blocks B-21.**

`RECOMMENDED_AGENT_URL` points at `HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive`.
`scripts/model_dl.sh` sources these values from `profile.conf`, so applying the CUDA profile and
running the downloader fetches it. Every other profile recommends a first-party Qwen build.

Separately, the `RECOMMENDED_*` URLs across profiles point at `huggingface.co/Qwen/…` while
`model_dl.sh`'s own defaults point at `unsloth/…`. At least one set is wrong, and none has been
verified to resolve.

**This is a product-identity decision, not a technical one.** Confirm the intent, or replace with a
first-party default.

**AWAITING USER DECISION.**

---

### C-9 — A stage that *moves* files must re-read them at the destination

Recorded as a constraint, not a decision. All three retracted completion claims in `PROGRESS.md`
concern files that S-6 **relocated rather than edited**. Verification for those stages was `sh -n`
plus diff review — and a moved file produces no diff to review. `sh -n` passes on
`CPU/generic/jenova-setup` because it is syntactically valid POSIX shell; it simply does nothing on
this kernel.

**Static syntax checking cannot detect a valid script that is semantically foreign to the target
platform.** Any future restructure must re-read relocated files at the destination and assert
positively on their content, not merely on their syntax.

---

## 2026-08-28 14:32 — USER Rulings (D-F … D-I) — BINDING. All questions closed.

### D-F — Profile tree: uniform `<backend>/<config>`, depth 2. *(closes Q-1)*

Drop the OS directory level — every profile is FreeBSD, so it carries no information. Fixed
depth 2 **structurally eliminates D-9**, the fixed-depth glob bug at `scripts/jenova-setup:107`,
instead of patching it. Target tree:

```
hardware-profiles/
├── Vulkan/{apu-ryzen7-5700u, dgpu-i5-1135g7, dgpu-igpu-i5-1135g7, dgpu-generic-12gb}/
├── CUDA/dgpu-generic/     ← opt-in only, never auto-matched (D-B)
├── CPU/generic/           ← + mandatory WP-13 fix
├── common-setup.sh, detect-hardware.sh, README.md
```

Deleted: `macOS/` (2 profiles), `Linux/AMD/apu/ryzen7-5700u-3b` (byte-identical duplicate),
`Linux/Vulkan/dgpu/gtx-1650ti` (same physical machine as `FreeBSD/dgpu/i5-1135g7-9b`).
**10 → 6.** The WP-13 fix on `CPU/generic` is mandatory, not optional. **Q-1 CLOSED.**

### D-G — Delete `JENOVA_DISTRO` and `JENOVA_WSL`; keep `JENOVA_PKG_MGR`. *(closes Q-3)*

The first two encode nothing once there is one OS; delete them and every read site. Keep
`JENOVA_PKG_MGR` as a seam for possible future `ports` support. **Q-3 CLOSED.**

### D-H — No `rc.d` script. Defer to the Nim cut-over. *(closes Q-5)*

This migration stays **purely subtractive**. The Nim backend will need service integration
anyway; `rc.d/jenova` gets written once, against the final binary.

**Consequences:** stage S-8 is removed from the plan. **WP-9 is out of scope** — it entered
only as a prerequisite for a correct `rc.d`. It remains a real defect (`jenova-ca:13` declares
`PROXY_PID` and never assigns it, so `--daemon` never starts :8080) and stays tracked in
`remediation-plan.md`; it is simply not this migration's problem. **Q-5 CLOSED.**

### D-I — Execution approved for S-0, S-1, S-2, S-5.

The four unblocked stages, approved to proceed now (~2¾ h). S-3, S-4, S-6 and S-7 are now
unblocked by D-F and D-G but are **not yet approved** — halt for permission after S-5.

**All questions are now closed.** Q-4 remains formally open but de-prioritised by D-D; only its
mechanical part (the FreeBSD pkg-config name) is done, inside S-5.

---

## 2026-08-28 14:20 — USER Rulings (D-A … D-E) — BINDING

Five rulings from the USER. These close Q-2, Q-6, Q-7 and Q-8, add a governing long-term
constraint, and correct an error in this workspace.

---

### D-A — No bash. POSIX `sh` everywhere. *(closes Q-7)*

> "there should be no bash in this at all - i dont know why that is there - is supposed to be
> posix sh"

**Ruling:** every script is `#!/bin/sh` POSIX. bash is neither a build nor a runtime
dependency.

**Two sites, not one** (the second was missed in the first pass):

| Site | Problem |
|---|---|
| `bin/jenova-model-switch:1` | `#!/usr/bin/env bash` — the only non-`/bin/sh` shebang in the repository |
| `lib/ui.lua:121` | explicitly invokes `sys_exec_sync("bash " .. …jenova-model-switch…)` — hard-codes the interpreter, so fixing the shebang alone is not enough |

Removing both also removes a GPL-3.0 dependency (AGENTS.md rule 2) and an unstated
`pkg install bash` requirement, since bash is not in FreeBSD base. **Q-7 CLOSED.**

---

### D-B — CUDA is opt-in. *(closes Q-6)*

> "cuda is opt in"

**Ruling:** CUDA is never auto-detected and never auto-selected. It remains available to a
user who explicitly asks for it.

**Implications:**
- `bin/build-llama-jenova:104-106` — delete the `nvcc`-presence auto-enable inside the `auto`
  branch. `JENOVA_BACKEND=cuda` (`:78-80`) stays as the explicit opt-in.
- `bin/build-llama-jenova:276-284` — the `nvidia-smi` device count runs only when CUDA was
  explicitly requested.
- The CUDA profile must not win auto-detection. Its `MATCH_OS="Linux|FreeBSD"` currently makes
  it eligible on FreeBSD and its broad `MATCH_GPU_0="NVIDIA|GeForce|Quadro|RTX|GTX"` scores +5
  on any NVIDIA host. It must become deployable only via `--apply-profile`.
- NVIDIA hardware continues to work through Vulkan, which is what the surviving dGPU profiles
  already use.

**Q-6 CLOSED.** The earlier CUDA-on-FreeBSD availability question is now moot — opt-in means
the user decides, and the code stops asserting anything.

---

### D-C — `node`/`npm` are required while the WebUI exists. *(closes Q-8)*

> "node/npm is required for as long as we have the webUI"

**Ruling:** required, not optional. `scripts/preflight-check.sh:176-177` is **correct**; the
documentation is stale.

**Implications:** fix the docs, not the code — `docs/installation/dependencies.md:29-30`
("optional and only required for the Web UI build") and `docs/installation/freebsd.md:21-22`
("If you want the optional Web UI"). Add `node` and `npm` to the required `pkg install` line.
**Q-8 CLOSED.** D-6 is resolved as a documentation defect.

---

### D-D — Long-term target is a Nim-native desktop app and backend. **Governing constraint.**

> "the long-term goal will be to convert the Lua and webUI into nim native desktop app and
> backend to solve the bottlenecking with thread and proxies etc"

Corroborated by `jenova_refactor_analysis.md` on the `develop/nim` branch, which specifies
replacing `proxy.lua`, `db.lua`, `search.lua`, `embed.lua` and the shell orchestrators with a
Nim binary using `asyncdispatch` (kqueue on FreeBSD), isolated thread pools, and direct
`libllama` linkage — and unifying the three ports behind one router.

**This governs how the FreeBSD migration is executed:**

| Principle | Consequence |
|---|---|
| **Subtract, do not rewrite.** | Every hour spent restructuring Lua or shell logic is thrown away at the Nim cut-over; every hour spent *deleting* is banked as less to port. |
| S-1 (ABI collapse) is **more** valuable, not less | It is pure deletion, and it removes precisely the LuaJIT FFI class the Nim analysis cites as motivation. FreeBSD-only kernel constants are also exactly what a Nim/kqueue backend needs. |
| S-3 (shell purge) must be **deletion of foreign arms**, not restructuring | Do not redesign `install.sh` or `install-dependencies.sh`; excise the non-FreeBSD branches and stop. |
| S-4 (`jenova-ui` C) drops to **minimum viable** | The Nim plan replaces the GTK3/C tray with a native desktop app. Do the `#ifdef` collapse and the FreeBSD pkg-config name; nothing more. **This also de-prioritises Q-4** — the LGPL exposure likely disappears in the rewrite. |
| Additive work must target the **interface**, not the implementation | An `rc.d` script that calls `jenova-ca` keeps working when `jenova-ca` becomes a Nim binary. Write it against the verbs. |
| WP-15 is effectively **decided** | `docs/architecture/remediation-plan.md:324-340` framed Lua-vs-Nim as open. The USER has decided it. Its "compile-time-checked C shim" middle path is now moot. |

---

### D-E — Port topology: **8080 is the port.** 8081 and 8082 are internal.

> "proxy 8080 is the port - 8081 and 8082 go through the proxy"

**The USER is correct, and `BLUEPRINT.md` was wrong.** It tabulated three ports as peer
services, implying three front doors. Corrected in `BLUEPRINT.md` §2.

**Verified against source — the intent is already implemented in the data path:**

| Fact | Evidence |
|---|---|
| The proxy binds :8080 and is the only listener a client uses | `lib/proxy.lua:53-54,1523,1529` |
| Everything unmatched is forwarded to :8081; the Host header is rewritten to the internal target | `lib/proxy.lua:1204,1428` |
| :8082 is consumed **in-process**: `embed.lua` is `require`d by the proxy and POSTs to `127.0.0.1:8082` itself | `lib/proxy.lua:15,63-72`; `lib/embed.lua:26,107` |
| The WebUI never addresses :8081 or :8082 — zero occurrences in `jca_web/src` | searched |
| The vite dev proxy targets only `localhost:8080` | `jca_web/vite.config.ts:91-99` |

**But two places contradict the intent and expose the internals:**

1. **The bind address.** `bin/jenova-ca` launches llama-server and the embed server with
   `--host "$HOST"` (`:239`, `:708`, `:804`, `:823`). Under `--lan`, `HOST="0.0.0.0"`
   (`:331`) — so **:8081 and :8082 are published to the LAN with no authentication.** The code
   already knows they are internal: `:332` sets `_INT_HOST="127.0.0.1"` and `:556-557` build
   the proxy's upstream URLs from it. The *bind* simply does not follow the *intent*.
2. **The firewall instructions.** `scripts/install.sh:562` tells LAN-client users to open
   "ports 8080, 8081, and 8082".

**Fix (scoped):** bind :8081 and :8082 to `127.0.0.1` unconditionally, including under `--lan`;
correct the firewall text to :8080 only.

**Note this is *smaller* than remediation-plan WP-8.** WP-8 proposed an upstream routing table
so `/v1/embeddings` could be routed to :8082. That is unnecessary — embeddings never traverse
the proxy's HTTP surface; they are an in-process call. Only WP-8's binding half applies.

---

## 2026-08-28 14:20 — Revised Open Questions

Q-2, Q-6, Q-7 and Q-8 are closed by the rulings above. Q-4 is de-prioritised by D-D. Three
questions remain, and Q-1 is reframed by the deduplication analysis.

---

### Q-1 (revised) — Profile tree: which layout, after deduplication?

**Status:** OPEN — blocks S-5. The USER instruction is clear on intent ("all the profiling
needs to be for freebsd, and we dont want duplications"); what remains is the layout.

**Deduplication analysis is complete and proven — see `BLUEPRINT.md` §6.** Two genuine
duplicates found:

| # | Duplicate | Proof |
|---|---|---|
| 1 | `Linux/AMD/apu/ryzen7-5700u-3b` ≡ `FreeBSD/AMD/apu/ryzen7-5700u-3b` | `jenova.conf` **byte-identical**; `jenova-setup` **byte-identical**; `profile.conf` differs only in a comment, `PROFILE_NAME`, `PROFILE_DESC` and `MATCH_OS`. Pure OS-duplicate — delete with zero loss. |
| 2 | `Linux/Vulkan/dgpu/gtx-1650ti` ≈ `FreeBSD/dgpu/i5-1135g7-9b` | Same physical machine: both `MATCH_CPU="i5-1135G7"` + single NVIDIA dGPU. Settings have drifted (8192/1 slot/no drafter vs 16384/2 slots/drafter). Hardware duplicate across OS — delete the Linux one; consider adopting its tighter `MATCH_GPU_0="GeForce GTX 1650 Ti"`. |

Three `Linux/` profiles are **not** duplicates and carry coverage nothing else provides:
`CPU/generic` (the only CPU-only profile anywhere), `Vulkan/dgpu/full-offload-9b` (the only
generic 12GB+ fallback, `MATCH_OS=""` so it already matches FreeBSD), and
`CUDA/dgpu/nvidia-generic` (now opt-in per D-B). Both `macOS/` profiles are deleted outright.

**Target: 6 profiles.** The open question is only how to arrange them.

The current tree is **taxonomically incoherent** — the middle level is sometimes a vendor
(`AMD`), sometimes a backend (`Vulkan`, `CUDA`, `CPU`), sometimes a GPU class (`dgpu`,
`dgpu_igpu`) — and depth varies between 3 and 4. That inconsistency is what breaks the
fixed-depth glob at `scripts/jenova-setup:107`, which silently omits every 4-deep profile.

| | Layout | Example | Notes |
|---|---|---|---|
| **A** | Keep `FreeBSD/` root, relocate survivors under it | `FreeBSD/CPU/generic` | Smallest churn. But the OS level now carries zero information — every profile is FreeBSD. Leaves depth incoherent. |
| **B** *(recommended)* | Drop the OS level; uniform `<backend>/<config>` at fixed depth 2 | `Vulkan/dgpu-i5-1135g7`, `Vulkan/apu-ryzen7-5700u`, `Vulkan/dgpu-igpu-i5-1135g7`, `Vulkan/dgpu-generic-12gb`, `CUDA/dgpu-generic`, `CPU/generic` | One OS, so the OS level is noise. Uniform depth **structurally fixes** the glob bug rather than patching it. Coherent single taxonomy (backend → hardware config). |
| **C** | Flat, single level | `dgpu-i5-1135g7` | Simplest, but loses the backend grouping that `DEVICES` actually keys on. |

**Recommendation: B.** It is the layout that expresses "FreeBSD only, no duplications" — and
because every path changes anyway (they are already wrong in the docs, `docs/README.md:127-132`),
this is the one moment where a rename is free.

⚠️ **Hazard carried into any option.** `Linux/CPU/generic/jenova.conf:57-63` sets
`JENOVA_CTX_SIZE` / `JENOVA_NUM_SLOTS` / `JENOVA_THREADS`, while `bin/jenova-ca:228-233` reads
`CTX_SIZE` / `NUM_SLOTS` / `THREADS`. All three FreeBSD profiles use the correct names.
**Relocating `CPU/generic` without fixing this makes a broken profile FreeBSD's only CPU
fallback**, launching `llama-server` with `-c "" -np "" -t ""`. Any approval must include the
fix (remediation-plan WP-13).

**AWAITING USER DECISION — layout A, B or C.**

---

### Q-3 — Do `JENOVA_DISTRO`, `JENOVA_PKG_MGR` and `JENOVA_WSL` stay as constants, or go?

**Status:** OPEN — blocks S-2. Unchanged.

Once only FreeBSD is supported these are constants: `freebsd`, `pkg`, `0`. Exported at
`lib/detect-env.sh:255-259`, read across the install scripts.

**Recommendation: delete `JENOVA_DISTRO` and `JENOVA_WSL`; keep `JENOVA_PKG_MGR`.** The first
two encode nothing; the third leaves a clean seam if `ports` is ever supported alongside `pkg`.
Under D-D ("subtract, do not rewrite") this is a deletion, which is the cheap direction.

**AWAITING USER DECISION.**

---

### Q-5 — Does "100% natively built for FreeBSD" include shipping an `rc.d` script?

**Status:** OPEN — defines "done". Reframed by D-D.

No `rc.d` script exists (`docs/README.md:187-188`, confirmed by search). FreeBSD-native means
`service(8)`, `rcvar`, `sysrc jenova_enable=YES`.

**D-D makes this *more* attractive, not less.** An `rc.d` script calls `jenova-ca`'s verbs
(`start`/`stop`/`status`); when `jenova-ca` becomes a Nim binary exposing the same verbs, the
rc script is unchanged. It is additive work that survives the rewrite — unlike anything spent
on the Lua internals.

⚠️ **But it inherits a real gap.** `bin/jenova-ca:13` declares `PROXY_PID` and never assigns
it. `--daemon` starts only llama-server (`:695`) and the embed server (`:699`), so **a headless
start has no :8080 at all** — and given D-E, :8080 is *the* port. `_probe_health` (`:254-279`)
watches :8081, so a wedged proxy reads green. An `rc.d` script is a headless start path, so it
would publish that gap as a supported interface (remediation-plan WP-9).

**Options:** (A) in scope, sequenced last, fixing WP-9 first so `service jenova start` actually
brings up :8080; (B) in scope, shipping what `--daemon` starts today with the limitation
documented; (C) out of scope, defer to the Nim cut-over.

**Recommendation: A.** Under D-E, a service that does not start :8080 does not start Jenova.
The WP-9 fix is small — assign `PROXY_PID`, add it to the pidfile, report it in `status`, stop
it in `stop`, repoint `_probe_health` at :8080 — and it is the same work the Nim backend will
need to get right anyway.

**AWAITING USER DECISION.**

---

### Q-4 — GTK3 / libappindicator LGPL vs AGENTS.md rule 2

**Status:** OPEN but **DE-PRIORITISED by D-D.**

`jenova-ui/Makefile:5-6` links `gtk+-3.0` and `appindicator3-0.1`, both LGPL-2.1 (ayatana is
LGPL-3.0), beyond the pango/cairo exception. Under D-D the C/GTK3 tray is scheduled for
replacement by a Nim native desktop app, so the exposure likely resolves itself.

**Recommendation: defer the licence question; do only the mechanical part now** — verify the
FreeBSD pkg-config name, since `appindicator3-0.1` is the Linux name and FreeBSD ships the
ayatana fork (affects `jenova-ui/Makefile:5-6` and `scripts/install-dependencies.sh:113,284`).
Revisit the licence at the Nim rewrite, when the dependency may no longer exist.

**AWAITING USER CONFIRMATION that deferral is acceptable.**

---

## Constraints Recorded (no decision required)

### C-1 — `external/` is a dependency, not project code
Explicit USER instruction: *"LEAVE THE FUCKING GIT SUBMODULES ALONE THEY ARE NOT PROJECT CODE
THEY ARE DEPENDENCIES."* `external/llama.cpp` is never edited, audited, or counted. FreeBSD
build concerns are expressed through `bin/build-llama-jenova`'s CMake invocation only.

### C-2 — Feature-retention lift is scoped
The directive to drop macOS/Windows/Linux is explicit instruction under AGENTS.md rule 3, but
authorises removal of *platform support only*. Anything that would also remove a capability
working on FreeBSD is tabled. This produced Q-1.

### C-3 — ~~Verification cannot happen in this workspace~~ **RETRACTED 2026-08-28**

**This was wrong.** The workspace *is* the FreeBSD host, reached through the Linuxulator
(Linux ABI compatibility layer). Verified:

| Probe | Result |
|---|---|
| `sysctl -n kern.ostype` | **FreeBSD** |
| `sysctl -n kern.osrelease` | **15.1-RELEASE** |
| `sysctl -n hw.model` | 11th Gen Intel Core i5-1135G7 — the CPU in two shipped profiles |
| LuaJIT `jit.os` | **BSD** |
| `/usr/local/libdata/pkgconfig` | present (FreeBSD convention) |
| `pkg` | present |
| **`uname -s`** | **`Linux`** ← the Linuxulator answers, not the kernel |

Consequences: acceptance testing **can** run here, and S-1 was verified live.

### C-8 — **`uname -s` is not a reliable OS probe on this project's own host**

Because the working environment is the Linuxulator, `uname -s` returns `Linux` on a FreeBSD
15.1 machine. Every current OS decision in the codebase is built on `uname -s`
(`lib/detect-env.sh:36-42`, `hardware-profiles/detect-hardware.sh:79`, `bin/jenova:15`,
`bin/jenova-term:6`).

**Measured effect on this machine, before any change:**

```
JENOVA_OS       linux        (ground truth: FreeBSD 15.1-RELEASE)
JENOVA_DISTRO   fedora
JENOVA_PKG_MGR  none         → install-dependencies.sh:74 aborts, "No supported package manager"
selected profile: Linux/Vulkan/dgpu/gtx-1650ti
```

Two things follow:

1. **The FreeBSD-first project has been running its Linux path on FreeBSD.** This is a live
   defect, not merely tidy-up — it is the strongest justification for the migration.
2. It explains the Q-1 profile drift: `Linux/Vulkan/dgpu/gtx-1650ti` is the profile actually
   being selected on this hardware, so it is the one that got tuned, while its FreeBSD twin
   `FreeBSD/dgpu/i5-1135g7-9b` drifted. The "duplicate" is the one in use.

**Binding design correction to S-3:** OS detection must key off **`sysctl -n kern.ostype`**,
never `uname -s`. The originally planned "hard-fail when `uname -s` is not FreeBSD" would have
refused to run on the USER's actual FreeBSD host. Recorded as **D-12**.

### C-4 — Windows was never supported
No `win32`, `mingw`, `msvc`, or `.exe` handling in project code. The only Windows-adjacent code
is the WSL probe at `lib/detect-env.sh:51-54`, which is Linux detection. No separate work item.

### C-5 — `jca_web/` has no OS coupling
Zero matches for `process.platform`, `os.platform`, or platform-name strings across
`jca_web/src`, `vite.config.ts`, `playwright.config.ts`, `svelte.config.js`, `package.json`,
`scripts/`. Browser-targeted; no migration work. (It is in scope for the Nim rewrite under D-D,
but not for this migration.)

### C-6 — `lib/linux-tune.sh` is already unreachable
Its only caller is `scripts/jenova-setup:125`, guarded by `[ "$JENOVA_OS" = "linux" ]` — in a
script that never sources `lib/detect-env.sh`, so `$JENOVA_OS` is empty and the branch cannot
fire. Deleting the file, the branch, and `tests/test_linux_tune_regex.sh` removes ~206 lines of
never-executed code. No behaviour change is possible.

### C-7 — `develop/nim` carries the target architecture, not an implementation
The branch holds `jenova_refactor_analysis.md` (the Nim design) but **no Nim source**, and it is
behind `main` — it lacks `tests/proxy-concurrency/` entirely, which `d2afac0` added. It is a
design document to honour under D-D, not a base to merge. This migration targets `bsd`.
