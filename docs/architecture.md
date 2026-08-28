# Architecture

Jenova is a local personal AI environment: an inference backend, a browser-based workspace, and a
management layer, running entirely on your own hardware.

## Principles

- **Human-first** — the system amplifies your thinking rather than replacing it.
- **Local-first** — inference, retrieval and storage all happen on your machine. The one outbound
  call is web search, and only when a model invokes it.
- **Hardware-aware** — installation detects your GPU, CPU and RAM and deploys a matching
  `etc/jenova.conf` overlay from `hardware-profiles/`.
- **FreeBSD-native** — the only supported platform. ZFS, Vulkan, `mdmfs` swap-backed model
  storage, `sysctl`-based detection. The source contains no other platform.

## Components

| Component | Role | Stack |
|---|---|---|
| Intelligence proxy | Fronts everything: Web UI, workspace database, retrieval, tool execution, web search, inference forwarding | LuaJIT |
| `llama-server` | GGUF inference | C++ (llama.cpp, Vulkan) |
| Embedding server | A second `llama-server` in embedding mode | C++ |
| Web UI | Browser workspace and chat | SvelteKit / Svelte 5 / Tailwind 4 |
| `jenova-ui` | Tray icon and ncurses TUI | C, GTK3, ncurses, Lua |
| `jenova-ca` | Supervisor for the three daemons | POSIX `/bin/sh` |

Everything except `external/llama.cpp` lives in this repository. All components read the same
configuration hierarchy — `etc/jenova.conf` (the deployed hardware profile), then
`etc/jenova.local.conf` (your overrides, gitignored and preserved across updates) — so a changed
model path or port propagates to the daemon, the tray and the Web UI alike.

## Ports — one front door

`:8080` is the port. `:8081` and `:8082` are internal backends and bind loopback
unconditionally, including under `--lan`.

| Port | Reached by | How |
|---|---|---|
| **8080** | clients, Web UI, LAN peers | the proxy's own listener |
| 8081 | the proxy only | forwarded HTTP, with the `Host` header rewritten |
| 8082 | the proxy only | an **in-process** call — `lib/embed.lua` is loaded inside the proxy and posts to `127.0.0.1:8082` itself. Embeddings never traverse the proxy's public HTTP surface |

`bin/jenova-ca` launches both backends with `--host "$BACKEND_BIND_HOST"`, which is loopback
regardless of `--lan`. Exposing 8081 or 8082 would publish unauthenticated inference endpoints.

## Request flow

1. **Input** arrives at the proxy on `:8080`, from the Web UI or an API client.
2. **The proxy** (`lib/proxy.lua`) augments the request — workspace context from SQLite,
   retrieval hits, prior tool results — and forwards it to `:8081`.
3. **Inference** runs in `llama-server` with Vulkan or CUDA offload.
4. **Tool calls** emitted by the model are executed locally by the proxy — storage read/write,
   filesystem discovery, web search — and fed back as the next turn.
5. **Embeddings** for retrieval are requested in-process from `:8082`.
6. **Output** streams back through the proxy with chunked transfer-encoding, token by token.

For the detail of step 2 — which of the two context systems supplies what, and in what order —
see [context-and-retrieval.md](context-and-retrieval.md).

---

## The intelligence proxy

A LuaJIT process built on a `select`-based event loop with coroutine yielding for all I/O
(`lib/http.lua`):

- **Non-blocking sockets** — every accepted connection is set `O_NONBLOCK` and `FD_CLOEXEC`, so
  requests interleave and forked children never inherit live client sockets or the listener.
- **Async subprocesses** — `find` for file discovery, `fetch`/`curl` for web search, run through a
  non-blocking `fork`/`pipe` that yields to the scheduler while waiting.
- **Async health checks** — backend liveness is probed over non-blocking TCP.
- **Background indexing** — inbound storage writes queue re-indexing rather than blocking the
  response.

Its HTTP surface is documented in [usage.md](usage.md#http-api). Every response carries
`Connection: close`; there is no keep-alive, no compression, and no caching headers.

> These asynchrony properties are recent. Until the `d2afac0` fix, an FFI ABI bug made
> `set_nonblocking()` a silent no-op, so the event loop was decorative and the proxy served
> exactly one request at a time. `tests/proxy-concurrency/` guards against the regression.

## Inference server (`:8081`)

- **Offload** — `DEVICES` selects Vulkan or CUDA devices (`Vulkan0`, `Vulkan0,Vulkan1`, `CUDA0`,
  `CPU`). `NGL_AGENT=all` offloads every layer; an integer offloads that many.
- **Multi-GPU** — when `NGL_AGENT=all`, `-fitt $FIT_TARGET` auto-fits layers across the available
  devices. An explicit layer count skips `-fitt`, which conflicts with it.
- **Speculative decoding** — an optional small drafter model, enabled per profile with
  `JENOVA_DRAFT=1` and pinned to `JENOVA_DRAFT_DEVICE`. Typically 1.5×–2× faster generation when
  there is VRAM headroom. It is **off** in the dual-GPU and CPU profiles and on in the rest.
- **KV cache** — `q8_0` by default, via `KV_CACHE_TYPE` / `JENOVA_KV_TYPE`. `q4_0` uses less
  memory at some quality cost; `f16` is the highest quality and the largest.

## Embedding server (`:8082`)

A second `llama-server` launched with `--embedding` and `GGML_VULKAN_DISABLE=1`, so it runs on
CPU and leaves VRAM to the main model. Its consumers are the proxy's retrieval pipeline and the
codebase indexer (`lib/indexer_runner.lua`). If no embedding model is found, `jenova-ca` warns and
starts without it.

## Web UI

A SvelteKit static SPA — no server-side rendering. `@sveltejs/adapter-static` compiles it to
plain HTML/JS/CSS in `public/`, which the proxy serves at the same origin as the API, so there is
no CORS to configure.

```
Browser ──HTTP──▶ Intelligence proxy (:8080) ──▶ llama-server (:8081)
                  │                          └──▶ embedding server (:8082)
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

**Workspace state is server-side, in SQLite.** The proxy owns `~/JCA/var/jenova.db` through
`lib/db.lua`, which loads `libsqlite3` over the FFI; the Web UI reaches it over `/api/db/*`. Your
data is not trapped in browser storage — clearing site data does not lose a conversation.

| Path | Contents |
|---|---|
| `var/jenova.db` | Workspaces, projects, folders, conversations, messages, notes, file assets. **Back up this file** |
| `var/log/` | Daemon logs, rotated by `jenova-ca` |
| `var/cache/` | Embedding index and retrieval snapshots |
| `Workspaces/` | Markdown mirror of notes and chats, plus uploaded file assets |
| `.system/` | PID and lock files |
| `etc/jenova.conf` | The deployed hardware profile |
| `models/` | GGUF storage: `agent/`, `draft/`, `embed/`, and optionally `instruct/`, `thinking/` |

All paths are relative to `$JCA_HOME`, which defaults to `~/JCA`.

`lib/fs_sync.lua` mirrors notes and chats to `$JCA_HOME/Workspaces` as `.md` files on every
significant change, so the same content is editable with any text editor and backed up by
ordinary tools. The database remains authoritative.

---

## Performance and tuning

Jenova is tuned for laptop hardware, where VRAM is the binding constraint.

**GPU offload.** Full offload when the model fits in VRAM; partial otherwise, with the remaining
layers on CPU. On a dual-GPU laptop, `-fitt` distributes layers across both Vulkan devices — the
point is not raw speed but pooled VRAM, which buys either a larger model or a much wider context
than the discrete GPU alone allows. Coordination between devices costs a little throughput.

**Memory.** On ZFS, cap `vfs.zfs.arc_max` so the ARC does not compete with the model; each
profile's `jenova-setup` does this. Integrated-GPU systems share system RAM with the GPU and
benefit from fast NVMe swap. Where an Optane device is present, `jenova-swap-mount` can back the
model store with it, letting context overflow page at roughly 7 µs.

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
| `external/ext_bin/` | Build output — `llama-server` and its shared libraries | `make llama` |

`ext_bin/` exists so the runtime is isolated from the raw build tree; `make install` deploys from
it rather than from `external/llama.cpp/build`.
