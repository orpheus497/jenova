# BLUEPRINT

Authoritative system architecture: what the program is, what it depends on, and how data moves
through it. Mandated by `AGENTS.md` § WORKSPACE ARCHITECTURE.

**Last updated:** 2026-09-01 12:55 (Session 016)

> **Rewritten 2026-08-31 (Session 007). The previous 626-line revision is in
> `.devdocs/ARCHIVE/devdocs/BLUEPRINT_pre-007.md`** — archived, not deleted, per D-AM.
>
> **Why it had to go.** It described `lib/proxy.lua`, `bin/jenova-ca`, `scripts/install.sh`,
> `jenova-ui/src/main.c`, `lib/ffi_defs.lua`, `lib/detect-env.sh`, a `Makefile` and a ten-profile
> tree. **None of those exist.** Its §1 placed `lib/`, `scripts/`, `jenova-ui/` and `Makefile` "in
> scope"; its §2 routed all traffic through `proxy.lua`; its §3 required LuaJIT, Lua 5.4 and
> ncurses; its §7 cited `docs/README.md`, a file that is not in the tree. It was a **pre-rewrite
> audit record sitting in the slot reserved for the current architecture**, and a session reading it
> as authoritative would re-derive a system that was deleted. That is D-AN's loop with a different
> input. Its findings are history and are preserved as such; they are not requirements.
>
> **This file states only what is in the tree now.** Per BRIEFING rule 8, it does not enumerate
> counts, file lists or subcommand lists — those rot on the next commit. It points at the code.

---

## 1. What the program is

A **native FreeBSD desktop application in Nim.** `llama-server` performs inference; Jenova is the
harness around it — configuration, supervision, an HTTP surface, persistence, retrieval, a prompt
pipeline, and a window (D-AF: `llama-server` is the engine, always; never a standalone).

| | |
|---|---|
| **Language** | Nim only. No Lua, no C, no shell script executed by the running product. Shell-format **config files** are exempt by the USER's own parenthetical at D-AI |
| **Platform** | FreeBSD only. Both entry points carry a `when not defined(freebsd): {.error.}` guard |
| **Build** | `nimble`. Tasks are in `jenova_core.nimble`. **There is no Makefile** (D-AM) |
| **Licence** | AGPL-3.0-or-later. Copyleft dependencies permitted (**D-X — settled, never to be reopened**) |
| **Runtime home** | `$HOME/Jenova`. **`~/JCA` is permanently off limits** (D-AE) |

## 2. The two binaries

| Binary | Built from | Is |
|---|---|---|
| `bin/jenova` | `src/jenova_gui.nim` | The desktop application: window, tray, chat, backend control, model switching, LAN toggle |
| `bin/jenova-core` | `src/jenova_core.nim` | The headless server and the operational subcommand surface |

**Both link the same modules in `src/jenova/`.** The split is a *build* split, not a program split:
N-7 requires LAN mode to serve whether or not a GUI is running, and folding owlkettle into the core
would make a graphical toolkit a build-time requirement for a server host. This is what D-N's
"single binary" ruling was about — one program, not a daemon plus a detached client over a socket.

**`bin/jenova` starts everything itself.** One command. The two-command split (server started
separately) was `bin/jenova-ca`'s shape reproduced without asking why it existed; in the shell the
*tray* owned the client-facing proxy, which is the whole of defect B-13. **Settled at N-S6 and
again at Session 006 — do not rebuild it.**

## 3. Runtime topology — one front door

**:8080 is the port.** :8081 and :8082 are backends, reached only by the harness.

```
client / Web UI / LAN
        │
        ▼
   :8080  server.nim  ──── /v1/*, /completion, /infill ───▶ :8081  llama-server (agent, GPU)
        │  the only listener      via upstream.forward
        │  a client uses
        └── rag.nim, in-process ────────────────────────▶ :8082  llama-server (embed, CPU)
```

**`--lan` moves only the client-facing port to `0.0.0.0`.** Both backends bind loopback
unconditionally, including under `--lan`. This is a security property, not a default: publishing
them would put two unauthenticated inference endpoints on the network (S-0, D-E). `tests/test_lifecycle.sh`
asserts it **in both directions** — that :8080 moves *and* that the backends do not — because a
one-directional assertion passes on a build that publishes everything.

**Device assignment (SETTLED FACT):** agent on GPU, embedding on CPU, drafter on GPU. **`Vulkan0`
and `Vulkan1`. There is no `Vulkan2`** — an unknown device makes `llama-server` reject the entire
`-dev` argument and exit before loading anything, so the backend leaves a pidfile and no process.

## 4. Module map

Every module's purpose is in **its own header comment. That is the single source of truth and it is
deliberately not duplicated here** — a prose inventory rots on the next commit, and re-deriving the
drift is what consumed whole sessions (D-AN). The file-level map is `ARCHITECTURE_MAPPING.md`.

The layers, named so the data flow below is readable:

`paths` → `config` → `db` / `rag` / `fssync` → `http` / `server` / `routes` → `api` / `pipeline` /
`upstream` / `websearch` → `lifecycle` / `models` → `gui` / `tray` / `dbus`.

## 5. Data flow

**A chat turn.** Client POSTs `/v1/chat/completions` to :8080 → `server` accepts on a worker thread
and `routes` classifies → `pipeline` detects intent, strips the prefix, retrieves RAG context,
injects the persona and computes the cache key as the SHA-256 **of the rewritten body** → `upstream`
forwards to :8081 and relays the SSE stream back. **A 502 means the pipeline completed and
`llama-server` is absent; a 500 means the pipeline threw.** That distinction is the assertion in
`tests/test_routes.sh` and it exists because `serve` once failed to call `rag.initSchema()`.

**A GUI turn.** `gui.send` builds the same OpenAI-shaped body and posts it to the local :8080, so
intents, RAG and personas apply identically to the window and to the Web UI. The stream worker
relays tokens over one channel to the GTK loop.

**The body is built by `pipeline.chatBody`, not by the window**, and that is where the user's
sampling and penalty settings are merged (**D-BK**). `settings.nim` owns the fields, the store
under `p.state`, the validator and the merge; `gui.nim` draws them. **An unset parameter is
omitted from the request rather than sent as a zero**, so `llama-server`'s own preset stays
authoritative for anything the user has not chosen — which is also what the settings panel shows
as each field's placeholder, read from `/props` on the call that already fetches the context size.

**Persistence.** `db` owns SQLite in WAL mode with a **per-thread connection** and a per-connection
prepared-statement cache. `api` serves `/api/db/*`; `fssync` mirrors the database rows onto disk
(workspace directories, the `<epoch>_<name>` trash naming, the `.metadata.json` sidecar) and
enforces containment on `/api/storage/*` — traversal is refused with **403, not 404**, because a 404
discloses whether a path outside the root exists.

**A note or asset's path is built from its ancestors' names**, so renaming a workspace,
project or folder **moves that container's directory** and everything under it travels
with it. A move that cannot be performed rolls the database write back, and a rename
onto an already-occupied path is refused rather than merged (**D-BE**) — the invariant
being kept is that the database never claims a name the disk does not carry.

**Retrieval is fed by the chat itself.** A message is a document at
`chat/<convId>/<role>/<id>`, so `rag.query`'s existing path filter scopes a search to one
conversation or across all of them. **The unit is a completed exchange, not a message**
(**D-BI**): the reply and the turn it answers are indexed together when the reply lands,
because `pipeline.prepare` queries this index on the way to the model and a question
indexed at save time would be retrieved by its own request. The window feeds it from its
control worker and the HTTP surface from the message routes — one rule, two surfaces.
Existing history is backfilled once the embedding server answers, incrementally and
self-healingly; a deleted turn is forgotten after the commit that deleted it.

**Configuration precedence:** environment → `etc/jenova.local.conf` → `etc/jenova.conf` (the applied
hardware profile). `config.nim` implements this order. **The inverted shell order (Q-9/B-12) died
with `bin/jenova-ca`** and is not a live defect.

**`etc/jenova.local.conf` is the USER's machine file. No session edits, rewrites or "fixes" it.**

## 6. Dependencies

FOSS only, zero proprietary. **Under an AGPL-3.0 project, GPL and LGPL dependencies are permitted
(D-X).** AGENTS.md Directive 2's "permissive, non-copyleft" clause is dead letter here; its
operative clause is "zero proprietary dependencies", which this project satisfies. The previous
revision's licence table marked GTK and libappindicator as violations and **three separate sessions
re-derived a conflict that does not exist from those rows** — the rows were the defect.

| Dependency | Licence | Role |
|---|---|---|
| Nim ≥ 2.2.10 | MIT | The language |
| owlkettle ≥ 3.0.0 | MIT | GTK4 + libadwaita bindings (D-P, D-AK) |
| gtk4, libadwaita, gtksourceview5 | LGPL-2.1 | The window (D-AK) |
| vte-2.91-gtk4 | LGPL-3.0 | The terminal hosting Neovim (G-19, D-AT). GUI binary only |
| dbus | AFL-2.1 / GPL-2 dual | StatusNotifierItem + `com.canonical.dbusmenu` for the tray (D-AJ) |
| sqlite3 | Public domain | Persistence and the FTS5 retrieval index. **FTS5 confirmed present by probe**, not assumed (D-AB) |
| llama.cpp / ggml | MIT | Submodule under `external/`. **Consumed, never modified** |
| vulkan-loader | Apache-2.0 | GPU offload |
| cmake | BSD-3 | Builds the submodule via `nimble llama` |

**Base-system tools the product invokes**, which are not project scripts and do not block the
total-conversion gate: `/bin/sh` (to evaluate the shell-format config files), `git`, `fetch(1)`,
`xdg-open`, `route`, `ifconfig`, `wl-copy`, and **`nvim`** — spawned into the terminal tab, and
invoked as `nvim --server <sock> --remote-expr` to read the open buffer. **That is deliberately not
an RPC client:** Neovim ships the expression evaluator, so msgpack framing would re-implement what
exists.

## 7. Data that outlives the code

`hardware-profiles/` is **data, not product code** — six profiles at uniform depth 2 (`<backend>/<config>`,
ruling D-F), plus `detect-hardware.sh` and `common-setup.sh`, which are **setup-time** tools the
running product never invokes. `etc/jenova.conf` is the applied profile mirrored into place, and
`config.nim` prefers the deployed copy under `$JCA_HOME/etc` over the source tree's (D-AT2).

**The profile *data* is current and correct** — all six profiles were re-checked key by
key on 2026-09-01 against their own `profile.conf`, and the only mismatch left is two
inert values on `Vulkan/dgpu-i5-1135g7`.

**The two shell scripts here are the last shell in the tree, and they are broken by
subtraction:** `detect-hardware.sh:19` sources `lib/detect-env.sh` and
`Vulkan/dgpu-i5-1135g7/jenova-setup:100` resolves `bin/jenova-swap-mount`, both archived
with the old build. **Neither is invoked by the running product**, so there is currently
no way to detect hardware or change profile at all.

**Ruled at D-BC: detection, scoring and apply are ported into Nim and driven from the
GUI**, with the same available as a `jenova-core` subcommand for headless hosts. The
kernel-tuning values in the `jenova-setup` scripts become data in `profile.conf`, applied
by Nim. **Both scripts are archived when that lands.** `TODOS.md` S-1, `PLANS.md` Step 6.

**CUDA is not meaningfully available on FreeBSD**, so `CUDA/dgpu-generic` is unreachable on the
target platform and is opt-in only (D-B). **Apply that constraint before raising anything about
that profile** — Q-12 should never have been put.

## 8. What is deliberately not here

| | |
|---|---|
| **In-process `libllama`** | Deleted 2026-08-31, not deferred. Duplicating the engine is the opposite of being a harness for it (D-AF) |
| **The shell tree** | Installer, `jenova-ca`, `proxy.lua`, `ffi_defs.lua`, the C tray, the ncurses TUI. Archived under `.devdocs/ARCHIVE/`. **Not outstanding work — it is gone** (D-AH, D-AM). **A surviving reference to one of these files is fixed by deleting the reference or porting the behaviour to Nim. Repairing the archived thing is never an outcome** (D-AZ) — the last two such references are in `hardware-profiles/` and are ported at Step 6 (D-BC) |
| **`rc.d` / service integration** | Cancelled at D-H. It gets written once, against the Nim program, as part of the deployment decision |
| **A CLI** | Waits for the total-conversion gate, then the `jca_web` decision (D-AI) |

## 9. Open architectural questions

**None.** `DECISIONS_LOG.md`'s QUESTION STATUS index is the authority. The last two were
answered on 2026-09-01:

- **The retrieval index indexes chats** (D-BD), and **the feed was built on 2026-09-01**
  (D-BI). See §5.
- **Hardware profile selection becomes Nim, driven from the GUI** (D-BC) — see §7.

**Two architectural principles now bind the design:** the product is Nim plus
`llama-server` and nothing else (D-AM, D-AZ), and **every operation must be reachable
from the window** (D-BC) — a feature requiring a terminal or a hand-edited file is not
finished.

**Longer-standing product decisions, parked deliberately:** filesystem as the source of
truth (T-11, D-AQ), deployment (T-7), and a CLI (T-8, gated by D-AI). **T-6 is closed**
— D-AP settled `jca_web`'s fate: it becomes the ephemeral single-device LAN client and
is frozen (D-Z).

## 10. What is NOT built, and is the actual outstanding work

The architecture above is complete and serving. **The gap is in the desktop
application**, which reproduces the Web UI's shape without all of its function: no
attachments, no trash view, no stop control, and no typed error reporting.

**Built 2026-09-01:** message actions (copy, edit, delete, regenerate, continue),
**conversation branching**, **generation statistics**, **a reasoning view**,
**recall of past chats** — the retrieval index is fed now (§5, D-BI) — and **a
settings surface with every sampling and penalty parameter, plus import/export**
(§5, **D-BK**). Parity with the Web UI's settings means parity in what the user can
do: **a field whose feature does not exist here is not drawn**, and
`settings.OmittedFields` names each one with the step that brings it back, so the
difference is a schedule rather than an oversight.

**The chat turn now asks for two things it did not before.** `gui.send` puts
`timings_per_token` and `reasoning_format` in the request body; `pipeline.prepare`
re-serialises the whole object, so both reach `llama-server` untouched, and the reply
stream carries a top-level `timings` object and a `delta.reasoning_content` field
alongside the content. The window reads the per-conversation context window from
`llama-server`'s `/props` — **not** from `CTX_SIZE`, which is the total shared across
parallel slots and would overstate what is left.

**A conversation is a tree, not a list.** `messages.parent` links a turn to the one it
follows, and two turns sharing a parent are alternative versions of the same turn;
`conversations.currNode` records which branch is being read. The walk over that tree is
three pure functions in `api.nim` and is asserted by `jenova-core tree-selftest`
(**D-BG**). Messages written before branching carry a **NULL** `parent`, so
`db.initDb` chains each conversation's messages in the order they were written, once
and idempotently. **That migration is required, not optional** — see the correction in
D-BG.

**One subsystem is still built and unreachable rather than missing:** hardware profile
selection has no working entry point at all (Step 6). Retrieval was the other, and it was
the sharper case — **fully asserted by its own self-test and never once executed by the
program**, because nothing called `indexContent`. Fixed 2026-09-01 (Step 4, D-BI). The
lesson generalises past retrieval: a green suite says the parts work, never that anything
calls them.

**This is GUI work over the surface described above, which already carries it** — the
message-update route, the recursive fork cascade, `/api/db/import`, the trash routes and
model switching are all implemented and asserted. Nothing in §1-§8 needs to change to
build any of it.

Enumerated against `jca_web/src/lib/components/app/*/index.ts`; the itemised list is
`TODOS.md` G-17, G-20, G-21 and G-28 … G-36, and the order is `PLANS.md`.
