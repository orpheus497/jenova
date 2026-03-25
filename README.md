# Jenova Cognitive Architecture (FreeBSD / NVIDIA Vulkan + Optane NVMe)

Jenova is a high-performance, low-latency cognitive engine that turns a FreeBSD workstation into a persistent, systems-level AI environment. It implements a "Fluid Memory" architecture that treats high-speed NVMe (Optane) as an extended L4 cache for Large Language Models (LLMs), enabling large-context reasoning on modest hardware.

## Goals

- Persistent intelligence with a daemonized cognitive backend
- Low-latency, hardware-aware inference using NVIDIA Vulkan GPU offload and LuaJIT
- Optane-backed paging and cache strategies to enable large-context models on 16GB systems
- Minimal memory footprint and high throughput for 7B / 14B model workflows

## Key Features

- Fluid Memory: Uses FreeBSD paging + Optane NVMe to extend effective model memory and support large context windows (up to 32k in practical configurations).
- Persistent Embedding Daemon: CPU-only nomic-embed-text server eliminates subprocess and reinitialization bottlenecks for fast retrieval-augmented generation (RAG).
- NVIDIA GPU Offload: Partial layer offload to GTX 1650 Ti (4GB) via Vulkan. Remaining layers stay on CPU, paged through Optane swap.
- Hybrid Search: BM25 keyword search combined with semantic vector search.
- FreeBSD-first: Tuned for FreeBSD 15, ZFS ARC management, and kernel-friendly operation.

## Architecture

Jenova runs three persistent daemon processes:

1. **llama-server** (port 8081): Main inference engine with partial NVIDIA GPU offload.
2. **proxy.lua** (port 8080): Intelligence Proxy — non-blocking I/O with Lua coroutines, RAG injection, intent routing.
3. **llama-server --embedding** (port 8082): CPU-only embedding server (nomic-embed-text-v1.5) for semantic search.

These are managed as a unit by `jenova-ca` with 3-PID tracking.

The system is partitioned into four conceptual streams:

- The Architect (infrastructure): daemonized process management and runtime supervision (.jenova/jenova-ca.pid).
- The Signal (networking): non-blocking I/O loop with Lua coroutines for asynchronous proxying.
- The Mind (intelligence): hybrid BM25 + semantic vector retrieval with line-aware parsers.
- The Voice (UX): hardware-aware CLI reporting real-time GPU and indexing stats.

## Hardware & Performance (Target)

| Component | Specification |
|---|---|
| OS | FreeBSD 15 (STABLE/CURRENT) |
| CPU | Intel i5-1135G7 (4P / 8T) |
| GPU | GTX 1650 Ti 4GB (Vulkan0) — partial layer offload |
| Storage | Intel Optane NVMe (27GB+ swap partition) |
| Memory | 16GB RAM (recommend capping ZFS ARC to 2GB) |

**Note:** Intel Iris Xe (Vulkan1) is present but **not used**. Its UMA memory allocation steals system RAM that is better used by CPU mmap for model weights paged through Optane.

### GPU Layer Offload

| Model | Total Layers | GPU Layers (NGL) | GPU VRAM | CPU Layers |
|---|---|---|---|---|
| 7B (default) | 28 | 22 | ~3.5 GiB | 6 via mmap |
| 14B | 48 | 15 | ~3.5 GiB | 33 via mmap |

## Installation

Prerequisites:

```sh
pkg install luajit-openresty vulkan-loader
```

Build llama.cpp locally with Vulkan support. The built binary lives at `llama.cpp/build/bin/llama-server`.

## Configuration

Edit `etc/jenova.conf` to tune hardware settings. Key entries:

```sh
DEVICES="Vulkan0"           # NVIDIA GPU only (no Iris Xe)
NGL_7B=22                   # GPU layers for 7B model
NGL_14B=15                  # GPU layers for 14B model
CTX_SIZE="16384"            # Context window size
JENOVA_DRAFT=1              # Enable speculative decoding (requires drafter model)
```

Notes:
- Ensure `/etc/sysctl.conf` and ZFS ARC settings are tuned if running on ZFS-heavy workloads: e.g. `vfs.zfs.arc_max=2147483648`.
- Configure a dedicated Optane swap partition and test paging behavior safely.

## Launching

Start the cognitive backend (daemon) and then the interactive agent:

```bash
# Start the Jenova Cognitive Architecture backend in daemon mode
bin/jenova-ca --daemon

# Launch the interactive agent (auto-starts backend if needed)
bin/jenova
```

## Models & Roles

- Fast Agent (7B): recommended for tool-calling and low-latency tasks (e.g., Qwen2.5-Coder-7B).
- Deep Reasoner (14B): used for heavy reasoning workloads.
- Drafter (0.5B): optional small model for speculative decoding to accelerate generation.
- Embedding (nomic-embed-text-v1.5): CPU-only, persistent daemon for RAG and semantic search.

## Directory Layout

- `bin/` — Launch scripts (`jenova`, `jenova-ca`, `llama-server-nvim`).
- `lib/` — Core LuaJIT logic for the agent, embedding, HTTP, search, memory, and UI.
- `etc/` — Configuration files (`jenova.conf`).
- `models/` — Model storage (GGUF format).
- `var/` — Runtime logs and cache.
- `.jenova/` — Internal agent state, PID files, vectors, and automated backups.

## Networking

All HTTP communication uses raw BSD sockets via LuaJIT FFI — no libcurl dependency. The proxy handles HTTP/1.1 chunked transfer-encoding, non-blocking I/O via `select()`, and coroutine-based connection multiplexing.

## Security & Privacy

- All session data, logs, and backups are stored locally in `.jenova/` and `var/` by default.
- Large binaries and personal configuration are ignored by Git; verify `.gitignore` entries before committing.

## Neovim Integration

`jenova-ca` supports multi-slot usage for both the interactive agent and Neovim FIM (Fill-In-Middle) completions. Configure your Neovim plugin to point at the local `jenova-ca` service.

## Troubleshooting & Notes

- If running into OOMs with ZFS, lower ARC (`vfs.zfs.arc_max`) and confirm swap/Optane configuration.
- The embedding server runs on CPU (ngl 0) to preserve all 4GB VRAM for main model inference.
- The codebase avoids subprocess reinitialization penalties by using persistent daemon processes.

## License & Credits

Project creator: @orpheus497

License: AGPL-3.0

---

(See `etc/jenova.conf` and files under `lib/` for implementation details.)
