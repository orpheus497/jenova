# Architecture

Jenova is a local personal AI environment: an inference backend, a browser-based workspace, and a
management layer, running entirely on your own hardware.

## Principles

- **Human-first** — the system amplifies your thinking rather than replacing it.
- **Local-first** — inference, retrieval and storage all happen on your machine. The runtime's one
  outbound call of its own is web search, and only when your last message begins `Web Search:` —
  the pipeline detects that prefix and runs the search itself; no model can trigger it. Everything
  else that can reach a network is listed in [privacy.md](privacy.md).
- **Hardware-aware** — `jenova-core hardware apply --best`, or the desktop application's Hardware
  screen, detects the machine, scores the profiles under `hardware-profiles/` on OS, CPU, GPU and
  swap (RAM is detected but not scored), and copies the winner's `jenova.conf` whole over
  `$JCA_HOME/etc/jenova.conf`. Nothing runs this for you; `jenova.local.conf` is never touched.
- **FreeBSD and Linux** — both are supported targets: FreeBSD, and Linux on Arch, Debian and Fedora.
  One source builds on both. Hardware detection is the one part that differs by OS, chosen when
  building: `sysctl`, `swapinfo`, `zpool` and `nvmecontrol` on FreeBSD, `/proc` and `/sys` on
  Linux; the GPU probe, `llama-server --list-devices`, is the same on both. `nimble llama` builds a
  static `llama-server` with the Vulkan and CPU backends, and on Linux with CUDA as well when `nvcc`
  is found. ZFS is detected and reported, not tuned, and nothing creates swap-backed or `mdmfs`
  model storage.

## Components

The product is **two Nim binaries**, declared in `jenova_core.nimble` and built with `nimble`.
Both link the shared core modules under `src/jenova/` — server, API, database, retrieval, pipeline,
backend lifecycle, configuration. Only `bin/jenova` links the desktop modules (`gui`, `theme`,
`canvas`, `sourceview`, `vte`, `shortcuts`, `tray`, `dbus`) and owlkettle, so `bin/jenova-core`
builds on a headless or LAN-server host without a graphical toolkit.

| Component | Role | Stack |
|---|---|---|
| `bin/jenova` | The desktop application: chat window, workspace tree, canvas, tray, backend control. **Starts the HTTP server and both backends in its own process.** Its control worker polls the chat backend's health, reports a backend that exited, and starts, stops and restarts on request; it runs no automatic watchdog. On quit it stops the embedding server and deliberately leaves `llama-server` running, so the next start does not reload the model | Nim, owlkettle, GTK4/libadwaita (`src/jenova_gui.nim`) |
| `bin/jenova-core` | The same program without GTK: HTTP server, database, filesystem mirror, retrieval. `serve` adds a watchdog thread that restarts a failed backend | Nim (`src/jenova_core.nim`) |
| `llama-server` | GGUF inference | C++ (llama.cpp, built with Vulkan and CPU, and CUDA on Linux) |
| Embedding server | A second `llama-server` in embedding mode | C++ |
| Web UI | Browser workspace and chat, served by the HTTP server | SvelteKit / Svelte 5 / Tailwind 4 |

The Jenova source lives in this repository. Three things are fetched: `external/llama.cpp` is a git
submodule of ggml-org/llama.cpp, owlkettle is fetched by nimble (pinned to commit `ac61ecf`), and
the Web UI's dependencies by `npm install`.

Both binaries read their configuration through `config.load` in `src/jenova/config.nim`. It sources
`jenova.conf` and then `jenova.local.conf` from `$JCA_HOME/etc/` when `$JCA_HOME/etc/jenova.conf`
exists — which is what `hardware apply` creates — and otherwise from the repository's `etc/`. The
two directories are never combined: once a profile is applied, the repository's `etc/`, including its
`jenova.local.conf`, stops applying. The environment wins only through the `JENOVA_*` variables the
conf files read as `${JENOVA_X:-default}`; a variable named after a key itself, such as `PORT`, is
overwritten when the files are sourced. Only the keys in `config.Keys` are read, and empty model
paths are then filled by directory discovery. The conf files keep their `/bin/sh` format and are
evaluated by `/bin/sh`, because they *are* shell. The running product also starts other processes —
the backends, `git` for the workspace mirror, `curl` or `fetch` for web search, `nvim` for the
editor, and hardware detection's probes — but none of them is a project shell script.

## Ports — one front door

`:8080` is the port. `:8081` and `:8082` are internal backends and bind loopback
unconditionally, including under `--lan`.

| Port | Reached by | How |
|---|---|---|
| **8080** | clients, Web UI, LAN peers | the server's own listener (`src/jenova/server.nim`) |
| 8081 | the server, for every client request | the request is rebuilt and forwarded, with the `Host` header rewritten (`src/jenova/upstream.nim`). The backend health probe also connects to it directly, and the bundled editor configuration (`jvim/`) polls its `/health`, `/slots` and `/props` over loopback |
| 8082 | the server | retrieval asks for embeddings **in process** — `src/jenova/rag.nim` posts to `127.0.0.1` itself. Client requests to `/embed*`, `/embeddings` and `/v1/embeddings` on `:8080` are also relayed there, so embeddings are reachable through the public surface, unauthenticated and LAN-reachable under `--lan`. `jvim` probes the port too |

`src/jenova/lifecycle.nim` launches both backends with `--host` bound to loopback regardless of
`--lan`. Exposing 8081 or 8082 directly would publish unauthenticated inference endpoints.

The embedding port is set per thread (`rag.configureEmbed`), and only the main thread, the
window's control worker and `serve`'s watchdog set it. The server's worker threads — which run
retrieval queries and index whatever the Web UI saves over `/api/db` — never do, so they always
use port 8082: on a host that moves `LLAMA_EMBED_PORT`, those embeddings fail and retrieval there
falls back to keywords.

## Request flow

1. **Input** arrives on `:8080`. An acceptor thread reads the request line without consuming it and
   routes it to the pool that owns that class of work (`src/jenova/routes.nim`).
2. **The completion pipeline** (`src/jenova/pipeline.nim`) rewrites the request — intent detection,
   retrieval hits, web search, editor context, persona injection, tool stripping — and the response
   cache is keyed on the SHA-256 of the *rewritten* body.
3. **Forwarding** to `:8081` (`src/jenova/upstream.nim`) rebuilds the request — hop-by-hop
   headers dropped, `Host`, `Connection: close` and `Content-Length` set — and relays the response
   chunk by chunk without buffering, so streamed tokens reach the client as the model produces
   them. The only change to the response is the request's `X-Jenova-*` diagnostic headers, spliced
   in after the status line.
4. **Inference** runs in `llama-server`. `nimble llama` builds it with Vulkan and CPU, and on Linux
   with CUDA too when `nvcc` is on the `PATH` of `sh`, `bash` or `csh`; `JENOVA_BACKEND` builds one
   backend instead. The opt-in CUDA profile names its device `CUDA0`.
5. **Embeddings** for retrieval are requested from `:8082` by `rag.nim`.
6. **Workspace state** is served by `src/jenova/api.nim`: `/api/db/*` from SQLite, mirrored to
   disk by `src/jenova/fssync.nim`; `/api/fs/*` (the trash and the tree) and `/api/storage/*` (raw
   files) directly on the workspaces directory, through `fssync`.

For the detail of step 2 — which context systems supply what, and in what order — see
[context-and-retrieval.md](context-and-retrieval.md).

---

## The HTTP server

`src/jenova/server.nim` is threads and blocking I/O, deliberately. Two stages:

- **Acceptor threads** wait in `poll` (200 ms) on a non-blocking listener and then `accept`, peek
  at the request line with `MSG_PEEK` in a few short rounds without consuming it, classify the
  route, and push the descriptor onto that class's queue. They never run a handler, so no handler
  can stall the accept path.
- **A dedicated pool per route class** — static, health, api, completion, embed, debug — each with
  its own queue and its own threads. A saturated class cannot starve another: completion streams are
  held open for the length of a generation, so a single shared pool would stop answering health
  checks and serving assets while generations were in flight.

Only integers cross thread boundaries — a `SocketHandle` — and the owning worker parses the request
on its own thread. Every response the server builds itself carries `Connection: close`, with no
keep-alive and no compression; the debug event stream also sends `Cache-Control: no-cache`.
Forwarded and cache-replayed responses carry `llama-server`'s own head, relayed as it came apart
from the spliced `X-Jenova-*` and `X-Cache` lines. The surface is documented in
[usage.md](usage.md#http-api).

`jenova-core serve-selftest` measures both properties: that an established stream holds its cadence
under blocking database load, and that saturating one class leaves health and static responsive.

### The response cache

A completion whose rewritten body hashes to a stored key is answered from `llm_cache` in the
workspace database rather than from the model. What was stored is the upstream response as it went
down the wire, head included, and it is replayed rather than re-framed: **the body — every SSE
`data:` record — goes back byte for byte**, so chunked and event-stream framing survive and no
reader has to know the difference. The response as a whole is not identical to a live one: the
*current* request's `X-Jenova-*` diagnostic headers and then an `X-Cache: HIT` line are inserted
straight after the stored status line, which is how a hit is recognisable at all. The stored head is
the upstream's own, so it carries no diagnostics from the request that filled the entry.

Bounded at 256 entries and 1 MiB per entry, evicted oldest-first. A reply over the cap is simply
not stored, and only a complete relay that actually contains `data:` lines is stored at all: a
fragment filed to serve later as a whole answer, or a body the streaming reader cannot replay,
would each be worse than a cache miss.

### Diagnostics

`/debug/slow-query`, `/debug/stream` and `/debug/hold`, and `/api/_selftest/slow-query` in the API
class, exist to demonstrate that saturating one route class does not starve another. They are **off
unless explicitly enabled** and answer `404` otherwise; `serve-selftest` is what turns them on.

## Inference server (`:8081`)

- **Offload** — `DEVICES` selects the devices and is passed as `-dev`; `-sm layer` is always
  passed. An entry is a device number (`Vulkan0`, `CUDA0`), `none`, or a name pattern (`NVIDIA`,
  `Intel`), which `lifecycle.llamaArgs` turns into the number of the matching device from
  `llama-server --list-devices` when it builds the command line; `DRAFT_DEVICE` is resolved the
  same way. With `NGL_AGENT=all` (or empty) no `-ngl` is
  passed at all, only `-fitt $FIT_TARGET`, and llama-server's automatic fit decides how many layers
  go to the device — every layer when the model fits, fewer otherwise. An integer passes `-ngl N`
  and offloads that many.
- **Multi-GPU** — under that automatic fit, llama-server splits layers across the devices
  `DEVICES` names; `-ts` is added only when `TENSOR_SPLIT` is set, which no shipped profile does.
  An explicit layer count skips `-fitt`, which conflicts with it.
- **Thinking** — `JENOVA_REASONING` is passed as `--reasoning`. Left empty, a model that
  `models/agent/active.gguf` resolves into `models/instruct/` gets `--reasoning off`
  (`models.roleOf`), and any other keeps llama-server's automatic setting.
- **Load mode** — `JENOVA_MLOCK` and `JENOVA_MMAP` become one `-lm` value (`mmap+mlock`, `mlock`
  or `none`); the default, mmap without mlock, passes none.
- **Speculative decoding** — runs when a draft model is found (`MODEL_DRAFT`, else
  `models/draft/`) and `JENOVA_DRAFT` is not false; the code's own default is on. The draft goes to
  the `DRAFT_DEVICE` key (`-devd`), which the profiles default and let `JENOVA_DRAFT_DEVICE`
  override. Every shipped profile sets `JENOVA_DRAFT`: **off** in the CPU profile and in
  `Vulkan/dgpu-i5-1135g7`, which has no VRAM to spare, and on in the rest. Typically 1.5×–2× faster
  generation when there is VRAM headroom — a llama.cpp property, not one this code settles.
- **KV cache** — every shipped profile sets `KV_CACHE_TYPE` to `q8_0`, overridable with
  `JENOVA_KV_TYPE`. The code has no default of its own: with `KV_CACHE_TYPE` empty it passes no
  `-ctk`/`-ctv`, and llama-server uses its default. `q4_0` uses less memory at some quality cost;
  `f16` is the highest quality and the largest.

## Embedding server (`:8082`)

A second `llama-server` launched with `--embedding`, `-dev none -ngl 0` and
`GGML_VULKAN_DISABLE=1`, so it runs on CPU and leaves VRAM to the main model. Within Jenova's own
code, `src/jenova/rag.nim` is the only caller that asks it for embeddings; the server also relays
clients' `/embed*`, `/embeddings` and `/v1/embeddings` requests to it, and `jvim` probes its port.
If no embedding model is found, the supervisor says so and starts without it; retrieval degrades to
keyword-only, which is a supported state.

## Web UI

A SvelteKit static SPA — no server-side rendering. `@sveltejs/adapter-static` compiles it to
plain HTML/JS/CSS in `public/`, which the server serves at the same origin as the API, so there is
no CORS to configure. It serves a browser on this machine or on the LAN; the desktop window is the
other point of access, and the two are meant to behave the same.

```
Browser ──HTTP──▶ jenova / jenova-core (:8080) ──▶ llama-server (:8081)
                  │                            └──▶ embedding server (:8082)
                  └── static assets from public/
```

| Layer | Technology |
|---|---|
| Framework | SvelteKit 2 + Svelte 5 runes |
| Components | shadcn-svelte + bits-ui |
| Styling | TailwindCSS 4 |
| Rendering | remark → rehype; GFM, KaTeX math, highlight.js |
| PDF | pdfjs-dist |
| Protocol | `@modelcontextprotocol/sdk` |
| Testing | Playwright, Vitest, Storybook |
| Build | Vite + adapter-static → `../public/` |

Features: persistent multi-workspace organisation, branching conversation history, streaming with
generation and prompt-processing statistics (tokens per second; there is no time-to-first-token
figure), `<think>` reasoning blocks, workspace notes and files injected into context by the Web UI
itself, a badge on replies the server's response cache answered (`X-Cache: HIT` — the cache is
server-side), a WakeLock-backed PWA layout, and light/dark themes.

Development commands are in [../jca_web/README.md](../jca_web/README.md).

## Persistence

**Workspace state is server-side, in SQLite.** The server owns the database through
`src/jenova/db.nim`, which loads `libsqlite3` at run time (`libsqlite3.so`, `.so.0` or `.so.3`) and
gives **every thread its own connection** in WAL mode, so readers run during a write. Clients reach it over `/api/db/*`. Your data is not trapped in
browser storage — clearing site data does not lose a conversation.

| Path | Contents |
|---|---|
| `.system/jenova.db` | Workspaces, projects, folders, conversations, messages, notes, file assets, the response cache and the retrieval index. **Back up this file** |
| `var/log/` | Backend logs |
| `var/cache/` | Cache directory |
| `Workspaces/` | Notes as Markdown and uploaded file assets, mirrored on every save, one git repository per workspace. The Web UI also writes each of its chats here as Markdown, through `/api/storage`, on every message, rename and move and on Push; the desktop window's chats are not written here, though one can be exported to a file on demand |
| `.system/` | The database, PID files and the Neovim socket |
| `.trash/` | Deleted workspaces, beside their `.metadata.json` sidecars |
| `etc/jenova.conf` | The deployed hardware profile, when one has been applied here |
| `models/` | GGUF storage: `agent/`, `draft/`, `embed/`, and optionally `instruct/`, `thinking/` |

All paths are relative to `$JCA_HOME`, which defaults to `~/Jenova`. `src/jenova/paths.nim`
resolves `$JCA_HOME`, `.system`, `Workspaces`, `var/log`, `var/cache`, the PID file and where
`llama-server` is; the rest are built from those by the modules that use them — `models/` in
`models.nim`, `.trash` in `fssync.nim`, `etc/` in `config.nim` and `hardware.nim`, the database in
`gui.nim` and `jenova_core.nim`, the backend PID files in `lifecycle.nim` and the Neovim socket in
`nvimctl.nim`.

`src/jenova/fssync.nim` mirrors notes and file assets to `$JCA_HOME/Workspaces` on every
significant change, so the same content is editable with any text editor and backed up by
ordinary tools. Deletion moves an item into a trash tree beside a `.metadata.json` sidecar rather
than unlinking it, which is what makes restore possible. The database remains authoritative.

---

## Performance and tuning

Jenova is tuned for laptop hardware, where VRAM is the binding constraint.

**GPU offload.** Full offload when the model fits in VRAM; partial otherwise, with the remaining
layers on CPU. The dual-GPU profile names its devices `NVIDIA,Intel.*(Iris|Xe)` and passes them as `-dev`
with `-sm layer -fitt` (no `-ts`, since its `TENSOR_SPLIT` is empty), and llama-server splits the
layers across both devices. The point is pooled VRAM rather than raw speed — a larger model or a
wider context than the discrete GPU alone allows — and coordination costs a little throughput;
both are llama.cpp behaviour, not something this code settles. The devices are named because the
driver's numbering differs between systems: the i5-1135G7 laptop's GTX 1650 Ti is `Vulkan0` on
FreeBSD and `Vulkan1` on Linux, so the same profile passes `-dev Vulkan0,Vulkan1` on one and
`-dev Vulkan1,Vulkan0` on the other. On Linux with CUDA built, `llama-server` lists the GTX first as
`CUDA0`, so the name `NVIDIA` resolves to it and the profile passes `-dev CUDA0,Vulkan0`: the GTX
through CUDA and the Iris Xe through Vulkan. See
[../hardware-profiles/README.md](../hardware-profiles/README.md).

**Memory.** On FreeBSD with ZFS, capping `vfs.zfs.arc_max` stops the ARC competing with the model
— worth doing, and **yours to do: Jenova sets no kernel tunable and never writes
`/etc/sysctl.conf`.** Integrated-GPU systems share system RAM with the GPU, so fast swap helps when
a model does not fit.

**Speculative decoding.** A small drafter proposes several tokens and the main model verifies
them in one pass — usually 1.5×–2× faster, at roughly 0.5–0.8 GB extra VRAM. On unless
`JENOVA_DRAFT` turns it off; every shipped profile sets `JENOVA_DRAFT` one way or the other.

**KV cache quantisation.** `q8_0` in every shipped profile. Halving to `q4_0` roughly halves KV
memory, which matters most at 32K context; `f16` doubles it. Those ratios are llama.cpp's.

Per-profile values, the detection scoring, and how to add a profile are in
[../hardware-profiles/README.md](../hardware-profiles/README.md).

---

## External code

| Directory | Type | Update |
|---|---|---|
| `external/llama.cpp` | Git submodule of [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | `git submodule update --init` |
| `external/ext_bin/` | Build output — a static `llama-server` | `nimble llama` |
| owlkettle | Nim GUI library, fetched by nimble, pinned to commit `ac61ecf` in `jenova_core.nimble` | nimble |
| `jca_web/node_modules/` | The Web UI's npm dependencies | `npm install`, run by `nimble web` |

`ext_bin/` exists so the runtime is isolated from the raw build tree: `src/jenova/paths.nim` looks
for `llama-server` there in a source checkout, and under `bin/` in a deployed one.
