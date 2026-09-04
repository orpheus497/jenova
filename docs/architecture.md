# Architecture

Jenova is a local personal AI environment: an inference backend, a browser-based workspace, and a
management layer, running entirely on your own hardware.

## Principles

- **Human-first** — the system amplifies your thinking rather than replacing it.
- **Local-first** — inference, retrieval and storage all happen on your machine. The one outbound
  call is web search, and only when a model invokes it.
- **Hardware-aware** — installation detects your GPU, CPU and RAM and deploys a matching
  `etc/jenova.conf` overlay from `hardware-profiles/`.
- **FreeBSD-native** — the only supported platform, and the one everything is tuned against:
  ZFS, Vulkan, `mdmfs` swap-backed model storage, `sysctl`-based detection. The *tuning* is
  FreeBSD-specific; the *source* is not, and builds anywhere Nim and GTK4 do.

## Components

The product is **two Nim binaries**, declared in `jenova_core.nimble` and built with `nimble`.
Both link the same modules under `src/jenova/`; the split exists so a headless or LAN-server host
builds without a graphical toolkit.

| Component | Role | Stack |
|---|---|---|
| `bin/jenova` | The desktop application: chat window, workspace tree, canvas, tray, backend control. **Starts and supervises the HTTP server and both backends itself** | Nim, owlkettle, GTK4/libadwaita (`src/jenova_gui.nim`) |
| `bin/jenova-core` | The same program without GTK: HTTP server, database, filesystem mirror, retrieval, backend supervision | Nim (`src/jenova_core.nim`) |
| `llama-server` | GGUF inference | C++ (llama.cpp, Vulkan) |
| Embedding server | A second `llama-server` in embedding mode | C++ |
| Web UI | Browser workspace and chat, served by the HTTP server | SvelteKit / Svelte 5 / Tailwind 4 |

Everything except `external/llama.cpp` lives in this repository. Both binaries read the same
configuration hierarchy through `src/jenova/config.nim` — `etc/jenova.conf` (the deployed hardware
profile), then `etc/jenova.local.conf` (your overrides, preserved across updates), then the
environment — so a changed model path or port propagates to every surface alike. The conf files
keep their `/bin/sh` format and are evaluated by `/bin/sh`, because they *are* shell; nothing in
the running product depends on a project shell script.

## Ports — one front door

`:8080` is the port. `:8081` and `:8082` are internal backends and bind loopback
unconditionally, including under `--lan`.

| Port | Reached by | How |
|---|---|---|
| **8080** | clients, Web UI, LAN peers | the server's own listener (`src/jenova/server.nim`) |
| 8081 | the server only | forwarded HTTP, with the `Host` header rewritten (`src/jenova/upstream.nim`) |
| 8082 | the server only | an **in-process** call — `src/jenova/rag.nim` posts to `127.0.0.1:8082` itself. Embeddings never traverse the public HTTP surface |

`src/jenova/lifecycle.nim` launches both backends with `--host` bound to loopback regardless of
`--lan`. Exposing 8081 or 8082 would publish unauthenticated inference endpoints.

## Request flow

1. **Input** arrives on `:8080`. An acceptor thread reads the request line without consuming it and
   routes it to the pool that owns that class of work (`src/jenova/routes.nim`).
2. **The completion pipeline** (`src/jenova/pipeline.nim`) rewrites the request — intent detection,
   retrieval hits, web search, editor context, persona injection, tool stripping — and the response
   cache is keyed on the SHA-256 of the *rewritten* body.
3. **Forwarding** to `:8081` is a verbatim byte relay (`src/jenova/upstream.nim`), so streamed
   tokens reach the client as the model produces them.
4. **Inference** runs in `llama-server` with Vulkan or CUDA offload.
5. **Embeddings** for retrieval are requested from `:8082` by `rag.nim`.
6. **Workspace state** — `/api/db/*`, `/api/fs/*` and `/api/storage/*` — is served by
   `src/jenova/api.nim` over SQLite, mirrored to disk by `src/jenova/fssync.nim`.

For the detail of step 2 — which context systems supply what, and in what order — see
[context-and-retrieval.md](context-and-retrieval.md).

---

## The HTTP server

`src/jenova/server.nim` is threads and blocking I/O, deliberately. Two stages:

- **Acceptor threads** block in `accept(2)`, peek at the request line with `MSG_PEEK` without
  consuming it, classify the route, and push the descriptor onto that class's queue. They never run
  a handler, so no handler can stall the accept path.
- **A dedicated pool per route class** — static, health, api, completion, embed, debug — each with
  its own queue and its own threads. A saturated class cannot starve another: completion streams are
  held open for the length of a generation, so a single shared pool would stop answering health
  checks and serving assets while generations were in flight.

Only integers cross thread boundaries — a `SocketHandle` — and the owning worker parses the request
on its own thread. Every response carries `Connection: close`; there is no keep-alive, no
compression, and no caching headers. The surface is documented in [usage.md](usage.md#http-api).

`jenova-core serve-selftest` measures both properties: that an established stream holds its cadence
under blocking database load, and that saturating one class leaves health and static responsive.

### The response cache

A completion whose rewritten body hashes to a stored key is answered from `llm_cache` in the
workspace database rather than from the model. What was stored is the upstream response as it went
down the wire, head included, and it is replayed rather than re-framed: **the body — every SSE
`data:` record — goes back byte for byte**, so chunked and event-stream framing survive and no
reader has to know the difference. The response as a whole is not identical to a live one: a single
`X-Cache: HIT` line is inserted straight after the status line, which is how a hit is recognisable
at all.

Bounded at 256 entries and 1 MiB per entry, evicted oldest-first. A reply over the cap is simply
not stored, and only a complete relay that actually contains `data:` lines is stored at all: a
fragment filed to serve later as a whole answer, or a body the streaming reader cannot replay,
would each be worse than a cache miss.

### Diagnostics

`/debug/slow-query`, `/debug/stream` and `/debug/hold` exist to demonstrate that saturating one
route class does not starve another. They are **off unless explicitly enabled** and answer `404`
otherwise; `serve-selftest` is what turns them on.

## Inference server (`:8081`)

- **Offload** — `DEVICES` selects Vulkan or CUDA devices (`Vulkan0`, `Vulkan0,Vulkan1`, `CUDA0`,
  `CPU`). `NGL_AGENT=all` offloads every layer; an integer offloads that many.
- **Multi-GPU** — when `NGL_AGENT=all`, `-fitt $FIT_TARGET` auto-fits layers across the available
  devices. An explicit layer count skips `-fitt`, which conflicts with it.
- **Speculative decoding** — an optional small drafter model, enabled per profile with
  `JENOVA_DRAFT=1` and pinned to `JENOVA_DRAFT_DEVICE`. Typically 1.5×–2× faster generation when
  there is VRAM headroom. It is **off** in the CPU profile and in `Vulkan/dgpu-i5-1135g7`, which
  has none to spare, and on in the rest.
- **KV cache** — `q8_0` by default, via `KV_CACHE_TYPE` / `JENOVA_KV_TYPE`. `q4_0` uses less
  memory at some quality cost; `f16` is the highest quality and the largest.

## Embedding server (`:8082`)

A second `llama-server` launched with `--embedding`, `-dev none -ngl 0` and
`GGML_VULKAN_DISABLE=1`, so it runs on CPU and leaves VRAM to the main model. Its only consumer is
`src/jenova/rag.nim`. If no embedding model is found, the supervisor says so and starts without it;
retrieval degrades to keyword-only, which is a supported state.

## Web UI

A SvelteKit static SPA — no server-side rendering. `@sveltejs/adapter-static` compiles it to
plain HTML/JS/CSS in `public/`, which the server serves at the same origin as the API, so there is
no CORS to configure. It is the LAN client; the desktop window is the primary surface.

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
TPS and TTFT metrics, `<think>` reasoning blocks, workspace artifacts injected into context,
client-side response caching, a WakeLock-backed PWA layout, and light/dark themes.

Development commands are in [../jca_web/README.md](../jca_web/README.md).

## Persistence

**Workspace state is server-side, in SQLite.** The server owns the database through
`src/jenova/db.nim`, which links `libsqlite3` and gives **every thread its own connection** in WAL
mode, so readers run during a write. Clients reach it over `/api/db/*`. Your data is not trapped in
browser storage — clearing site data does not lose a conversation.

| Path | Contents |
|---|---|
| `.system/jenova.db` | Workspaces, projects, folders, conversations, messages, notes, file assets, the response cache and the retrieval index. **Back up this file** |
| `var/log/` | Backend logs |
| `var/cache/` | Cache directory |
| `Workspaces/` | Markdown mirror of notes and chats, plus uploaded file assets, one git repository per workspace |
| `.system/` | The database, PID files and the Neovim socket |
| `.trash/` | Deleted workspaces, beside their `.metadata.json` sidecars |
| `etc/jenova.conf` | The deployed hardware profile, when one has been applied here |
| `models/` | GGUF storage: `agent/`, `draft/`, `embed/`, and optionally `instruct/`, `thinking/` |

All paths are relative to `$JCA_HOME`, which defaults to `~/Jenova`. `src/jenova/paths.nim`
resolves every one of them in one place.

`src/jenova/fssync.nim` mirrors notes and file assets to `$JCA_HOME/Workspaces` on every
significant change, so the same content is editable with any text editor and backed up by
ordinary tools. Deletion moves an item into a trash tree beside a `.metadata.json` sidecar rather
than unlinking it, which is what makes restore possible. The database remains authoritative.

---

## Performance and tuning

Jenova is tuned for laptop hardware, where VRAM is the binding constraint.

**GPU offload.** Full offload when the model fits in VRAM; partial otherwise, with the remaining
layers on CPU. On a dual-GPU laptop, `-fitt` distributes layers across both Vulkan devices — the
point is not raw speed but pooled VRAM, which buys either a larger model or a much wider context
than the discrete GPU alone allows. Coordination between devices costs a little throughput.

**Memory.** On ZFS, capping `vfs.zfs.arc_max` stops the ARC competing with the model — worth
doing, and **yours to do: Jenova sets no kernel tunable and never writes `/etc/sysctl.conf`.**
Integrated-GPU systems share system RAM with the GPU and benefit from fast NVMe swap; where an
Optane device is present, backing the model store with it lets context overflow page at roughly
7 µs.

**Speculative decoding.** A small drafter proposes several tokens and the main model verifies
them in one pass — usually 1.5×–2× faster, at roughly 0.5–0.8 GB extra VRAM. Enabled per profile,
not globally.

**KV cache quantisation.** `q8_0` by default. Halving to `q4_0` roughly halves KV memory, which
matters most at 32K context; `f16` doubles it.

Per-profile values, the detection scoring, and how to add a profile are in
[../hardware-profiles/README.md](../hardware-profiles/README.md).

---

## External code

| Directory | Type | Update |
|---|---|---|
| `external/llama.cpp` | Git submodule of [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | `git submodule update --init` |
| `external/ext_bin/` | Build output — `llama-server` and its shared libraries | `nimble llama` |

`ext_bin/` exists so the runtime is isolated from the raw build tree: `src/jenova/paths.nim` looks
for `llama-server` there in a source checkout, and under `bin/` in a deployed one.
