# Jenova Cognitive Architecture (FreeBSD / Dual Vulkan GPU + Optane NVMe)

Jenova is a high-performance, low-latency cognitive engine that turns a FreeBSD workstation into a persistent, systems-level AI environment. It implements a "Fluid Memory" architecture that treats high-speed NVMe (Optane) as an extended L4 cache for Large Language Models (LLMs), enabling large-context reasoning on modest hardware.

## Goals

- Persistent intelligence with a daemonized cognitive backend
- Low-latency, hardware-aware inference using dual Vulkan GPU offload (NVIDIA + Intel Iris Xe) and LuaJIT
- Optane-backed paging and cache strategies to enable large-context models on 16GB systems
- Minimal memory footprint and high throughput for 7B model workflows with optional speculative decoding

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

| Model | Total Layers | GPU Layers | GPU Memory | CPU Layers |
|---|---|---|---|---|
| Qwen2.5-Coder-7B | 28 | 28 (all) | ~4.4 GiB across both | 0 |
| Qwen2.5-Coder-0.5B (drafter) | 28 | 28 (all) | ~0.5 GiB | 0 |

## Installation

### Required Dependencies

| Dependency | FreeBSD Install | Purpose |
|---|---|---|
| `luajit` (OpenResty) | `pkg install luajit-openresty` | LuaJIT runtime for proxy, agent, embeddings, and all Lua modules |
| `git` | `pkg install git` | Repository management and lazy.nvim plugin bootstrap |
| `neovim` (0.9+) | `pkg install neovim` | Editor frontend (jvim) |
| `cmake` | `pkg install cmake` | Building llama.cpp from source |
| `vulkan-loader` | `pkg install vulkan-loader` | GPU inference via Vulkan (dual-GPU offload) |

### Optional Dependencies

| Dependency | FreeBSD Install | Purpose |
|---|---|---|
| `gmake` | `pkg install gmake` | Building telescope-fzf-native (Neovim plugin) |
| `curl` | `pkg install curl` | Fallback health probe in jenova-ca watchdog |
| `fetch` | *(FreeBSD base system)* | Web search feature in jvim (`<leader>as`) — see Known Limitations |
| `clangd` | `pkg install llvm` | C/C++ LSP server (optional) |
| `rust-analyzer` | `pkg install rust-analyzer` | Rust LSP server (optional) |
| `lua-language-server` | `pkg install lua-language-server` | Lua LSP server (optional) |
| `pyright` | `pkg install py311-pyright` | Python LSP server (optional) |
| `zls` | `pkg install zig` | Zig LSP server (optional) |
| `bash-language-server` | `npm install -g bash-language-server` | Bash/Shell LSP server (optional) |
| `stylua` | `cargo install stylua` | Lua code formatter (optional) |
| `goimports` | `go install golang.org/x/tools/cmd/goimports@latest` | Go import formatter (optional) |

### Required Model Files

Download GGUF model files and place them in `models/`:

| Model | Filename | Purpose | Required |
|---|---|---|---|
| Qwen2.5-Coder-7B | `Qwen2.5-Coder-7B-Q5_K_M.gguf` | Main inference (chat, code, rewrite) | **Yes** |
| nomic-embed-text-v1.5 | `nomic-embed-text-v1.5.Q8_0.gguf` | Embedding for RAG semantic search | Recommended |
| Qwen2.5-Coder-0.5B | `Qwen2.5-Coder-0.5B-Q8_0.gguf` | Speculative decoding drafter | Optional |

### Quick Install

```sh
# Install system dependencies
pkg install luajit-openresty git neovim cmake vulkan-loader

# Build llama.cpp with Vulkan support
cd llama.cpp
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
cd ..

# Run the installer (creates dirs, deploys nvim config, symlinks launchers)
./install.sh
```

The built binary lives at `llama.cpp/build/bin/llama-server`.

## Configuration

Edit `etc/jenova.conf` to tune hardware settings. Key entries:

```sh
DEVICES="Vulkan0,Vulkan1"     # Dual-GPU: NVIDIA + Intel Iris Xe
TENSOR_SPLIT="1.0,1.8"        # Split ratio: Intel Xe carries more layers (~7 GiB UMA vs NVIDIA 4 GiB)
FIT_TARGET=768                 # Safety margin in MiB for -fitt auto-tuning
CTX_SIZE="16384"               # Context window (7B: 16k)
JENOVA_DRAFT=1                 # Speculative decoding on by default; set to 0 to disable
```

Notes:
- Ensure `/etc/sysctl.conf` and ZFS ARC settings are tuned if running on ZFS-heavy workloads: e.g. `vfs.zfs.arc_max=2147483648`.
- Configure a dedicated Optane swap partition and test paging behavior safely.

## Launching

Start the cognitive backend (daemon) and then the interactive agent or Neovim:

```bash
# Start the Jenova Cognitive Architecture backend in daemon mode
bin/jenova-ca --daemon

# Launch the interactive agent (auto-starts backend if needed)
bin/jenova

# OR launch Neovim with Jenova integration (auto-starts backend if needed)
bin/jvim [files...]
```

## Models & Roles

- Agent (7B): Qwen2.5-Coder-7B-Q5_K_M — all 28 transformer layers fit across both Vulkan devices; 16k context, 2 slots, q8_0 KV cache.
- Drafter (0.5B): Qwen2.5-Coder-0.5B-Q8_0 — speculative decoding target; enabled by default (`JENOVA_DRAFT=1`), disable with `JENOVA_DRAFT=0`.
- Embedding (nomic-embed-text-v1.5): CPU-only persistent daemon on port 8082 for RAG and semantic search.

## Directory Layout

- `bin/jenova` — Interactive agent launcher (auto-starts backend if needed, runs `agent.lua`).
- `bin/jvim` — Neovim launcher with Jenova backend integration (auto-starts backend, exports environment variables).
- `bin/jenova-ca` — Backend manager: starts/stops/restarts llama-server, proxy, and embed server as a unit.
- `lib/` — Core LuaJIT logic for the agent, embedding, HTTP, search, memory, and UI.
- `etc/` — Configuration files (`jenova.conf`).
- `models/` — Model storage (GGUF format).
- `var/` — Runtime logs and cache.
- `.jenova/` — Internal agent state, PID files, vectors, and automated backups.
- `nvim/` — Neovim configuration (plugins, LSP, UI) for the integrated IDE.

## Networking

All HTTP communication uses raw BSD sockets via LuaJIT FFI — no libcurl dependency. The proxy handles HTTP/1.1 chunked transfer-encoding, non-blocking I/O via `select()`, and coroutine-based connection multiplexing.

## Security & Privacy

- All session data, logs, and backups are stored locally in `.jenova/` and `var/` by default.
- Large binaries and personal configuration are ignored by Git; verify `.gitignore` entries before committing.

## Neovim Integration

All clients — CLI agent, Neovim, and any other HTTP consumer — share the **single** backend started by `jenova-ca`. No separate model instance is loaded for Neovim.

### Using jvim (Recommended)

**IMPORTANT:** Always launch Neovim using the `jvim` wrapper to ensure proper backend integration:

```bash
bin/jvim [files...]     # Launch Neovim with Jenova backend
```

The `jvim` wrapper:
- Auto-starts the Jenova CA backend if not already running
- Exports environment variables (`JENOVA_CONNECT_HOST`, `JENOVA_PORT`, `JENOVA_LLAMA_PORT`) so plugins can connect
- Stops the backend on exit (only if `jvim` started it)

**Do NOT launch `nvim` directly** — the plugins (gp.nvim, llama.vim) require environment variables set by `jvim` to connect to the local backend. Launching `nvim` directly will cause connection failures and may attempt to use external APIs.

### Endpoints

Once launched via `jvim`, plugins use these endpoints automatically:

| Use case | Endpoint | Notes |
|---|---|---|
| FIM / infill completions | `http://127.0.0.1:8081` | Direct to llama-server; `--spm-infill` is always enabled |
| Chat completions + RAG | `http://127.0.0.1:8080` | Routes through intelligence proxy; RAG context injected |

Both ports are defined in `etc/jenova.conf` as `LLAMA_PORT` and `PORT`.

## Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `JENOVA_ROOT` | `$PWD` (auto-detected) | Project root directory path |
| `JENOVA_HOST` | `127.0.0.1` | Bind address for backend services (`0.0.0.0` to listen on all interfaces) |
| `JENOVA_CONNECT_HOST` | `127.0.0.1` | Client connection address (used by Neovim/CLI when `JENOVA_HOST` is a wildcard bind) |
| `JENOVA_PORT` | `8080` | Port for Jenova intelligence proxy |
| `JENOVA_LLAMA_PORT` | `8081` | Port for llama-server inference |
| `JENOVA_API_URL` | `http://127.0.0.1:8080` | Proxy endpoint for the agent |
| `JENOVA_LLAMA_URL` | `http://127.0.0.1:8081` | Direct llama-server endpoint (proxy internal) |
| `JENOVA_CONN_TIMEOUT` | `600` | Max seconds a proxy connection coroutine may live |
| `JENOVA_TIMEOUT` | `600` | Agent HTTP timeout (seconds) |
| `JENOVA_MAX_TURNS` | `25` | Max agentic tool-call turns per user message |
| `JENOVA_CTX` | `16384` | Context window token limit |
| `JENOVA_DRAFT` | `1` | Enable speculative decoding with 0.5B drafter model (`0` to disable) |
| `JENOVA_DEBUG` | `""` | Set to `1` for verbose debug output |

## Troubleshooting & Notes

### Common Issues

#### "llama-server not found"

If you see this error, llama.cpp hasn't been built yet:

```bash
cd llama.cpp
cmake -B build -DGGML_VULKAN=ON
cmake --build build -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
```

On FreeBSD, install dependencies first:
```bash
pkg install cmake gmake vulkan-loader
```

#### "Model not found"

Download a GGUF model file and place it in `models/`. Recommended:
- **Qwen2.5-Coder-7B-Q5_K_M.gguf** (main agent model)
- **nomic-embed-text-v1.5.Q8_0.gguf** (embedding for RAG)
- **Qwen2.5-Coder-0.5B-Q8_0.gguf** (optional drafter for speculative decoding)

Or set `JENOVA_MODEL` environment variable to point to your model file.

#### Neovim Plugins Not Working

**Always use `bin/jvim` to launch Neovim**, not `nvim` directly. The `jvim` wrapper:
- Starts the backend if needed
- Exports required environment variables (`JENOVA_CONNECT_HOST`, `JENOVA_PORT`, etc.)
- Ensures plugins can connect to the local backend

If you launch `nvim` directly, you'll see warning messages from gp.nvim and llama.vim about missing environment variables.

#### "Permission denied" or "Cannot create lock" errors

**Do not run scripts with sudo**. All Jenova commands should run as your regular user:

```bash
./install.sh           # NOT: sudo ./install.sh
bin/jenova-ca --daemon # NOT: sudo bin/jenova-ca --daemon
bin/jvim myfile.lua    # NOT: sudo bin/jvim myfile.lua
```

If you already ran with sudo and have permission issues, fix the ownership first:
```bash
# Fix ownership (if directory is owned by root)
sudo chown -R $USER:$USER .jenova/ var/

# Then fix permissions
chmod -R u+w .jenova/ var/
```

**Do NOT use `sudo chmod`** - this doesn't fix the ownership issue and can make it worse. Always use `chmod` without sudo after fixing ownership with `chown`.

#### Checking Backend Status

```bash
bin/jenova-ca status          # Check if backend is running
bin/jenova-ca stop            # Stop backend
bin/jenova-ca restart         # Restart backend
```

Check logs if something goes wrong:
```bash
tail -f var/log/jenova-ca.log
```

### Path Resolution

All scripts (`bin/jenova`, `bin/jvim`, `bin/jenova-ca`) automatically detect `JENOVA_ROOT` by resolving their own location. This works whether you:
- Run them from the project root: `./bin/jvim`
- Run them via symlinks in PATH: `jvim` (after `./install.sh`)
- Run them from any directory: `/full/path/to/bin/jvim`

The `JENOVA_ROOT` environment variable is automatically set and exported before loading `etc/jenova.conf`.

### Performance Notes

- If running into OOMs with ZFS, lower ARC (`vfs.zfs.arc_max`) and confirm swap/Optane configuration.
- The embedding server runs on CPU (`GGML_VULKAN_DISABLE=1`, ngl 0) to preserve all GPU memory for main model inference.
- The codebase avoids subprocess reinitialization penalties by using persistent daemon processes.
- Backup files in `.jenova/backups/` are rotated automatically: only the 5 most recent backups per filename are kept.
- Shell command output is capped at ~10KB in memory (head + tail) before being sent to the model, preventing OOM on runaway commands.

## Known Limitations

### Web Search (`<leader>as`) — FreeBSD Only

The web search feature in jvim uses FreeBSD's native `fetch` command to query DuckDuckGo.
This command is part of the FreeBSD base system and is **not available on Linux**.

**On FreeBSD:** Works as designed — `fetch` performs HTTPS requests to DuckDuckGo, results
are parsed and injected into the model context for synthesis.

**On Linux:** The search silently fails (no error shown) and the model responds without
web context. This is a known limitation that will be addressed in a future release by
adding a `curl` fallback.

**Affected keybind:** `<leader>as` (normal mode)
**Affected files:** `lib/proxy.lua` (`exec_web_search`), `nvim/lua/plugins/gp.lua` (`WebSearch` hook)

All other AI features (chat, visual rewrite, FIM completions, RAG, ChatWithContext) work
on both FreeBSD and Linux.

## License & Credits

Project creator: @orpheus497

License: AGPL-3.0

---

(See `etc/jenova.conf` and files under `lib/` for implementation details.)
