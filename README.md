# Jenova Cognitive Architecture (FreeBSD/Vulkan Optimized)

Jenova Cognitive Architecture (CA)
Persistent intelligence. Systems-level engineering. FreeBSD Native.

Jenova is a high-performance, low-latency cognitive engine designed to turn a FreeBSD workstation into a self-aware AI environment. Moving beyond the stateless request-response model, Jenova implements a "Fluid Memory" architecture that treats high-speed NVMe (Optane) as an extended L4 cache for Large Language Models (LLMs).
1. The Systems Engineering Edge

Unlike Python-based alternatives, Jenova is built on LuaJIT with a C FFI core. This allows for near-native performance while maintaining a minimal memory footprint—crucial for running 14B models on consumer hardware.
1.1 Fluid Memory & Optane Integration

    Virtual Memory Mastery: By disabling mlock, Jenova leverages FreeBSD’s kernel to page inactive LLM weights to Optane NVMe.

    Context Expansion: Handles context windows up to 32k on 16GB RAM systems by utilizing 10μs latency Optane swap as a secondary weight-store.

    ARC Management: Operates in harmony with ZFS by strictly capping vfs.zfs.arc_max to 2GB, preventing kernel OOM kills during heavy KV cache growth.

1.2 Persistent Intelligence (The Daemon Architecture)

    No Subprocess Bottlenecks: Replaces legacy os.execute calls with a persistent Embedding Daemon.

    Instant RAG: Eliminated the 800ms Vulkan device re-initialization penalty. Codebase indexing is now near-instantaneous via a background server-client model.

    Protocol Resilience: Networking is handled by libcurl via FFI, ensuring robust HTTP/1.1 chunked-encoding support and BSD socket integrity (correct sin_len alignment).

2. Technical Architecture

Jenova is partitioned into four independent, parallel execution streams:

    The Architect (Infrastructure): High-efficiency process management using daemon(8) and PID tracking in .jenova/jenova-ca.pid.

    The Signal (Networking): A non-blocking, select()-based I/O loop using Lua coroutines for asynchronous intelligence proxying.

    The Mind (Intelligence): Hybrid BM25 and Semantic vector search with line-aware parsers that respect function and class boundaries.

    The Voice (UX): A responsive, hardware-aware CLI providing real-time stats on GPU utilization and background indexing progress.

3. Hardware Requirements & Performance

Optimized for high-efficiency mobile/mini-PC workstations:
Component	Target Specification
OS	FreeBSD 15 (STABLE/CURRENT)
CPU	i5-1135G7 (4P / 8L Cores)
GPU (Hybrid)	GTX 1650 Ti (4GB) + Intel Iris Xe (~7GB)
Storage	Intel Optane-backed NVMe (27GB+ Swap)
Memory	16GB Physical RAM (ZFS ARC capped at 2GB)
GPU Acceleration

Jenova utilizes Vulkan-based Tensor Splitting. By setting TENSOR_SPLIT="2.0, 1.0", compute is distributed across the NVIDIA and Intel Iris Xe chips, maximizing the available 11GB of total VRAM for KV cache residency.
4. Installation & Setup
Prerequisites
Bash

pkg install luajit-openresty curl llama-server-ggml vulkan-loader

Configuration

Edit etc/jenova.conf to tune hardware splits and memory targets:
Bash

# etc/jenova.conf
TENSOR_SPLIT="2.0,1.0" # Balanced NVIDIA/Intel split
EMBED_DEVICES="Vulkan1" # Offload embeddings to Intel Xe to save NVIDIA VRAM
CTX_SIZE="16384"        # Optimized context for speed/memory balance

Launching the CA
Bash

# Start the background CA server
bin/jenova-ca --daemon

# Launch the interactive agent
bin/jenova

5. Deployment Methodology

This architecture was developed using a Quad-Agent implementation plan, ensuring strict separation between intelligence, networking, and hardware optimization. Every component is hardened against the unique requirements of the FreeBSD kernel, making it the definitive cognitive suite for the BSD power user.

Project Creator: @orpheus497

License: AGPL-3.0

Jenova is optimized for a dual-tier model hierarchy with advanced memory paging:

- **Fast Agent (7B)**: The `jenova` launcher uses **Qwen2.5-Coder-7B-Instruct** for rapid tool calling (15-20+ tokens/s).
- **Deep Reasoner (14B)**: The `jenova-ca` (Cognitive Architecture) server uses **Qwen2.5-Coder-14B-Instruct**.
- **Optane Paging**: Optimized for FreeBSD 15 to leverage 27GB of Optane NVMe swap as secondary RAM, allowing 14B models to handle massive context (up to 32k) without OOM.
- **Speculative Decoding**: Uses the **0.5B model** as a drafter to accelerate generation by up to 3x.

## 🛠 Features

- **Robust Tooling**: `read_file`, `edit_file`, `write_file`, and a high-speed `grep_search`.
- **Hybrid Search**: BM25 keyword matching + Semantic vector search (Nomic Embed v1.5).
- **FreeBSD First**: Tailored for `cc`, `sysctl`, and Vulkan offloading (NVIDIA + Intel).
- **Session Isolation**: Automatic backups and session-local memory in `.jenova/`.

## 📁 Directory Structure

- `bin/`: Launch scripts (`jenova`, `jenova-ca`).
- `lib/`: Core logic (LuaJIT) for the agent, tool execution, and memory.
- `etc/`: Central configuration (`jenova.conf`).
- `models/`: Model storage (GGUF format).
- `var/`: Runtime state, logs, and cache.
- `.jenova/`: Internal agent state, PID files, and automated file backups.

## ⚙️ Configuration

Edit `etc/jenova.conf` to adjust:

- `MODEL_PATH`: Primary server model (Default: 7B).
- `MODEL_7B`: Agent model (Default: 7B).
- `TENSOR_SPLIT`: Hardware allocation (Optimized for 1650 Ti + Iris Xe + Optane).
- `JENOVA_DRAFT=1`: Enable speculative decoding (Requires 0.5B model).

## 🔒 Security

- All session data, logs, and backups are stored locally in `.jenova/` and `var/`.
- Large binary files and personal configuration files are ignored by Git.

## 🖥 Usage

```bash
# Start the Jenova Cognitive Architecture backend
bin/jenova-ca --daemon

# Run the Jenova agent
bin/jenova
```

## 📋 Neovim Integration

The `jenova-ca` server supports multi-slot usage for both the agent and Neovim FIM (Fill-In-Middle) completions simultaneously.
