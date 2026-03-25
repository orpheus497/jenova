# Jenova Cognitive Architecture (FreeBSD / Vulkan Optimized)

Jenova is a high-performance, low-latency cognitive engine that turns a FreeBSD workstation into a persistent, systems-level AI environment. It implements a "Fluid Memory" architecture that treats high-speed NVMe (Optane) as an extended L4 cache for Large Language Models (LLMs), enabling large-context reasoning on modest hardware.

## Goals

- Persistent intelligence with a daemonized cognitive backend
- Low-latency, hardware-aware inference using Vulkan and LuaJIT
- Optane-backed paging and cache strategies to enable large-context models on 16GB systems
- Minimal memory footprint and high throughput for 7B / 14B model workflows

## Key Features

- Fluid Memory: Uses FreeBSD paging + Optane NVMe to extend effective model memory and support large context windows (up to 32k in practical configurations).
- Persistent Embedding Daemon: Eliminates subprocess and reinitialization bottlenecks for fast retrieval-augmented generation (RAG).
- Vulkan Tensor Splitting: Distributes compute across available GPUs (NVIDIA + Intel) to maximize usable VRAM for key-value cache residency.
- Hybrid Search: BM25 keyword search combined with semantic vector search.
- FreeBSD-first: Tuned for FreeBSD 15, ZFS ARC management, and kernel-friendly operation.

## Architecture

Jenova is partitioned into four parallel execution streams:

- The Architect (infrastructure): daemonized process management and runtime supervision (.jenova/jenova-ca.pid).
- The Signal (networking): non-blocking I/O loop with Lua coroutines for asynchronous proxying.
- The Mind (intelligence): hybrid BM25 + semantic vector retrieval with line-aware parsers.
- The Voice (UX): hardware-aware CLI reporting real-time GPU and indexing stats.

## Hardware & Performance (Target)

| Component | Target specification |
|---|---|
| OS | FreeBSD 15 (STABLE/CURRENT) |
| CPU | Intel i5-1135G7 (4P / 8T) |
| GPU(s) | GTX 1650 Ti (4GB) + Intel Iris Xe (~7GB) |
| Storage | Intel Optane-backed NVMe (recommended 27GB+ swap) |
| Memory | 16GB RAM (recommend capping ZFS ARC to 2GB) |

Jenova supports tensor-splitting across GPUs. Example: TENSOR_SPLIT="2.0,1.0" to allocate work across NVIDIA and Intel devices.

## Installation

Prerequisites (example):

```sh
pkg install luajit-openresty curl llama-server-ggml vulkan-loader
```

Adjust packages to match your platform and repositories.

## Configuration

Copy and edit `etc/jenova.conf` to tune hardware splits and memory targets. Example entries:

```ini
# etc/jenova.conf
MODEL_PATH="models/qwen-7b.gguf"
TENSOR_SPLIT="2.0,1.0"     # Balanced NVIDIA/Intel split
EMBED_DEVICES="Vulkan1"     # Offload embeddings to Intel Xe to save NVIDIA VRAM
CTX_SIZE="16384"            # Context window size for the agent
JENOVA_DRAFT=1                # Enable speculative decoding (requires small drafter model)
```

Notes:
- Ensure `/etc/sysctl.conf` and ZFS ARC settings are tuned if running on ZFS-heavy workloads: e.g. `vfs.zfs.arc_max=2147483648`.
- If relying on Optane swap, configure a dedicated swap partition/file and test paging behavior safely.

## Launching

Start the cognitive backend (daemon) and then the interactive agent:

```bash
# Start the Jenova Cognitive Architecture backend in daemon mode
bin/jenova-ca --daemon

# Launch the interactive agent
bin/jenova
```

## Models & Roles

- Fast Agent (7B): recommended for tool-calling and low-latency tasks (e.g., Qwen2.5-Coder-7B-Instruct).
- Deep Reasoner (14B): used by the `jenova-ca` server for heavy reasoning workloads.
- Drafter (0.5B): optional small model for speculative decoding to accelerate generation.

When enabling speculative decoding, provide the drafter model path and set `JENOVA_DRAFT=1`.

## Directory Layout

- `bin/` — Launch scripts (`jenova`, `jenova-ca`).
- `lib/` — Core LuaJIT logic for the agent, embedding, HTTP, and memory.
- `etc/` — Configuration files (`jenova.conf`).
- `models/` — Model storage (GGUF or similar formats).
- `var/` — Runtime state, logs, and cache.
- `.jenova/` — Internal agent state, PID files, and automated backups.

## Security & Privacy

- All session data, logs, and backups are stored locally in `.jenova/` and `var/` by default.
- Large binaries and personal configuration are ignored by Git; verify `.gitignore` entries before committing.

## Neovim Integration

`jenova-ca` supports multi-slot usage for both the interactive agent and Neovim FIM (Fill-In-Middle) completions. Configure your Neovim plugin to point at the local `jenova-ca` service.

## Troubleshooting & Notes

- If running into OOMs with ZFS, lower ARC (`vfs.zfs.arc_max`) and confirm swap/Optane configuration.
- Network behavior uses libcurl via FFI for robust HTTP/1.1 chunked encoding support.
- The codebase is tuned to avoid subprocess reinitialization penalties by using a persistent embedding daemon.

## License & Credits

Project creator: @orpheus497

License: AGPL-3.0


---

(See `etc/jenova.conf` and files under `lib/` for implementation details.)
