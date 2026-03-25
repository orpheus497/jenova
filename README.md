# Jenova Cognitive Architecture (FreeBSD / Dual Vulkan GPU + Optane NVMe)

Jenova is a high-performance, low-latency cognitive engine that turns a FreeBSD workstation into a persistent, systems-level AI environment. It implements a "Fluid Memory" architecture that treats high-speed NVMe (Optane) as an extended L4 cache for Large Language Models (LLMs), enabling large-context reasoning on modest hardware.

## Goals

- Persistent intelligence with a daemonized cognitive backend
- Low-latency, hardware-aware inference using dual Vulkan GPU offload (NVIDIA + Intel Iris Xe) and LuaJIT
- Optane-backed paging and cache strategies to enable large-context models on 16GB systems
- Minimal memory footprint and high throughput for 7B / 14B model workflows

## Key Features

- Fluid Memory: Uses FreeBSD paging + Optane NVMe to extend effective model memory and support large context windows (up to 32k in practical configurations).
- Persistent Embedding Daemon: CPU-only nomic-embed-text server eliminates subprocess and reinitialization bottlenecks for fast retrieval-augmented generation (RAG).
- NVIDIA GPU Offload: Dual-GPU layer distribution across GTX 1650 Ti (4GB discrete) and Intel Iris Xe (~7 GiB UMA) via Vulkan. The `-fitt` auto-fitter distributes transformer layers across both devices with a configurable safety margin. Remaining layers stay on CPU, paged through Optane swap.
- Hybrid Search: BM25 keyword search combined with semantic vector search.
- FreeBSD-first: Tuned for FreeBSD 15, ZFS ARC management, and kernel-friendly operation.

## Architecture

Jenova runs three persistent daemon processes:

1. **llama-server** (port 8081): Main inference engine with dual Vulkan GPU auto-fit offload.
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
| GPU 0 | GTX 1650 Ti 4GB (Vulkan0) — discrete VRAM |
| GPU 1 | Intel Iris Xe TGL GT2 (Vulkan1) — UMA, ~7 GiB from system RAM |
| Storage | Intel Optane NVMe (27GB+ swap partition) |
| Memory | 16GB RAM (recommend capping ZFS ARC to 2GB) |

**Dual-GPU strategy:** Both GPUs are used via Vulkan. Combined addressable GPU memory is ~11 GiB. The llama.cpp `-fitt` (fit target) flag auto-distributes transformer layers across both devices, reserving a configurable safety margin (default 768 MiB) so the KV cache fits without OOM. No explicit `-ngl` is needed — the fitter handles layer placement automatically.

### GPU Layer Distribution (auto-tuned by `-fitt`)

| Model | Total Layers | Typical GPU Layers | GPU Memory | CPU Layers |
|---|---|---|---|---|
| 7B | 28 | ~28 (all) | ~4.4 GiB across both | 0 |
| 14B | 48 | ~33-38 | ~8-10 GiB across both | 10-15 via mmap/Optane |

## Installation

Prerequisites:

```sh
pkg install luajit-openresty vulkan-loader
```

Build llama.cpp locally with Vulkan support. The built binary lives at `llama.cpp/build/bin/llama-server`.

## Configuration

Edit `etc/jenova.conf` to tune hardware settings. Key entries:

```sh
DEVICES="Vulkan0,Vulkan1"     # Dual-GPU: NVIDIA + Intel Iris Xe
TENSOR_SPLIT="2.0,1.0"        # Split ratio (NVIDIA gets 2 parts, Intel 1)
FIT_TARGET=768                 # Safety margin in MiB for -fitt auto-tuning
CTX_SIZE="8192"                # Context window (14B default; 7B uses 16384)
JENOVA_DRAFT=1                 # Enable speculative decoding (requires drafter model)
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
- The embedding server runs on CPU (`GGML_VULKAN_DISABLE=1`, ngl 0) to preserve all GPU memory for main model inference.
- The codebase avoids subprocess reinitialization penalties by using persistent daemon processes.

## License & Credits

Project creator: @orpheus497

License: AGPL-3.0

---

(See `etc/jenova.conf` and files under `lib/` for implementation details.)
