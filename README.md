# Jenova Cognitive Architecture

Jenova is a local AI coding environment for FreeBSD laptops. It runs `llama-server`, a LuaJIT proxy, and an embedding daemon as background processes — started once, left running while you work. There is no cloud dependency. Conversation history is stored as plain text files managed by `jvim`. The install script detects your GPU and selects an appropriate model profile at setup time. Everything from the hardware configurations to the model choices to the memory strategies exists to make Jenova work well on real laptop hardware.

## The Jenova trinity

Jenova is partitioned across three repositories that together form the complete system:

| Repo | Role | Stack |
|------|------|-------|
| [`orpheus497/jenova`](https://github.com/orpheus497/jenova) *(this repo)* | **Cognitive backend** — `llama-server`, LuaJIT `proxy.lua`, embedding daemon, `jenova-ca` supervisor | C/C++ + LuaJIT |
| [`orpheus497/jvim`](https://github.com/orpheus497/jvim) | **Editor / IDE** — `jvim`, a Neovim hard-fork purpose-built for Jenova | C + Lua |
| [`orpheus497/cloda-codey-lua`](https://github.com/orpheus497/cloda-codey-lua) | **Terminal agent** — `jenova-cli` for headless and scripted workflows | Lua 5.4 + Rust |

The backend in this repository is the shared brain. `jvim` is the editor that the user lives inside; `jenova-cli` is the terminal agent for scripted, headless, and async workflows. Both frontends communicate with the backend services, primarily via `proxy.lua` on port 8080, with `jvim` additionally talking to `llama-server` on port 8081 for FIM completions and the embedding server on port 8082.

## Goals

- Run local LLM inference on a laptop — no cloud, no internet dependency, processes stay running in the background
- Install-time profile selection: auto-detects your GPU(s) at setup and configures the right model (3B → 14B) and offload strategy
- Low-latency proxy and RAG pipeline using LuaJIT coroutines — no subprocess overhead, no blocking I/O
- Minimal memory footprint with optional speculative decoding for faster generation
- FreeBSD-first: tuned for ZFS, FreeBSD paging, and Vulkan (NVIDIA, AMD, Intel)

## Key Features

- **Multi-profile model support:** 3B Q8_0, 7B Q5_K_M, and 14B Q4_K_M profiles — hardware auto-detected at install time.
- **Persistent Embedding Daemon:** CPU-only nomic-embed-text server eliminates subprocess and reinitialization bottlenecks for fast retrieval-augmented generation (RAG).
- **Vulkan GPU Offload:** Single or dual-GPU layer distribution via the llama.cpp `-fitt` auto-fitter. Works with NVIDIA (NVIDIA), AMD (RADV), and Intel (ANV) Vulkan drivers.
- **Speculative Decoding:** 0.5B Qwen2.5-Coder drafter accelerates all main model sizes.
- **Hybrid Search:** BM25 keyword search combined with semantic vector search.
- **FreeBSD-first:** Tuned for FreeBSD 15, ZFS ARC management, and kernel-friendly operation. Linux and macOS are supported.
- **Fluid Memory:** An optional technique used on the Optane profiles (`Optane/dgpu_igpu/i5-1135g7-7b`, `Optane/dgpu/i5-1135g7-3b`, `Optane/dgpu/i5-1135g7-7b`). By layering Intel Optane NVMe swap (UFS, ~7 μs latency) with ZFS and 16 GiB RAM, the system creates a double-paging effect — hot pages stay in RAM, warm pages flow to Optane swap, cold pages go to ZFS. This extends the effective working set of the LLM runtime well beyond physical RAM without the stall penalty of standard NVMe swap (~100 μs). It is one strategy Jenova can use, not a requirement.

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

## Hardware & Performance

Jenova is designed for laptops. Every profile targets a real laptop form factor: thin-and-light APU, GPU laptop, or a compact workstation. The profiles auto-detect at install time — no manual hardware configuration required.

| Profile | Hardware | Model | Context |
|---|---|---|---|
| `Vulkan/dgpu/full-offload-14b` | Any GPU 8GB+ VRAM | Qwen2.5-Coder-14B Q4_K_M | 32K |
| `Intel/dgpu_igpu/i5-1135g7-3b` | i5-1135G7 + GTX 1650 Ti + Iris Xe | Qwen2.5-Coder-3B Q8_0 | 32K |
| `Optane/dgpu_igpu/i5-1135g7-7b` | i5-1135G7 + GTX 1650 Ti + Iris Xe + Optane | Qwen2.5-Coder-7B Q5_K_M | 32K |
| `Optane/dgpu/i5-1135g7-3b` | i5-1135G7 + GTX 1650 Ti (dGPU only) + Optane | Qwen2.5-Coder-3B Q8_0 | 16K |
| `Optane/dgpu/i5-1135g7-7b` | i5-1135G7 + GTX 1650 Ti (dGPU only) + Optane | Qwen2.5-Coder-7B Q5_K_M | 8K |
| `AMD/apu/ryzen7-5700u-3b` | Ryzen 7 5700U + Vega 8 UMA | Qwen2.5-Coder-3B Q8_0 | 16K |

### i5-1135G7 Dual-GPU (3B, default)

| Component | Specification |
|---|---|
| OS | FreeBSD 15 (STABLE/CURRENT) |
| CPU | Intel i5-1135G7 (4P / 8T) — laptop CPU |
| GPU 0 | GTX 1650 Ti 4GB (Vulkan0) — discrete VRAM |
| GPU 1 | Intel Iris Xe TGL GT2 (Vulkan1) — UMA, ~7 GiB from system RAM |
| Memory | 16GB RAM |

**Strategy:** 3B Q8_0 (~3.1 GiB) fully offloaded across both GPUs (~11 GiB combined). ~8 GiB headroom available for 32K context + KV cache + 0.5B drafter. The `-fitt` flag auto-distributes transformer layers across both Vulkan devices.

### Ryzen 7 5700U AMD

| Component | Specification |
|---|---|
| OS | FreeBSD 15 |
| CPU | AMD Ryzen 7 5700U (8C / 16T, Zen 2) — thin-and-light laptop CPU |
| GPU | AMD Radeon Vega 8 (Lucienne) — UMA, ~2-4 GiB from system RAM |
| Storage | Standard NVMe (16 GiB ZFS swap) |
| Memory | 15.28 GiB RAM |

**Strategy:** 3B Q8_0 with partial Vega 8 offload — 24 of 36 layers on GPU, remainder on the 8C/16T Zen 2 CPU. 16K context default; reduce to 8192 if swap pressure is observed.

### GPU Layer Distribution

| Profile | Model | Layers | GPU Memory | CPU Layers |
|---|---|---|---|---|
| i5 dual-GPU (3B) | Qwen2.5-Coder-3B Q8_0 (36 layers) | all | ~3.1 GiB | 0 |
| i5 dual-GPU (7B+Optane) | Qwen2.5-Coder-7B Q5_K_M (28 layers) | all | ~4.8 GiB | 0 |
| Ryzen AMD (3B) | Qwen2.5-Coder-3B Q8_0 (36 layers) | 24 (partial) | ~2-3 GiB UMA | 12 |
| All profiles | Qwen2.5-Coder-0.5B drafter | all | ~0.5 GiB | 0 |

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

Download GGUF model files and place them in `models/agent/` (or `models/` for legacy flat layout):

| Model | Filename | Profiles | Required |
|---|---|---|---|
| Qwen2.5-Coder-14B | `Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf` | `Vulkan/dgpu/full-offload-14b` | Profile-dependent |
| Qwen2.5-Coder-7B | `Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf` | `Optane/dgpu_igpu/i5-1135g7-7b`, `Optane/dgpu/i5-1135g7-7b` | Profile-dependent |
| Qwen2.5-Coder-3B | `Qwen2.5-Coder-3B-Instruct-Q8_0.gguf` | `Intel/dgpu_igpu/i5-1135g7-3b`, `Optane/dgpu/i5-1135g7-3b`, `AMD/apu/ryzen7-5700u-3b` | Profile-dependent |
| nomic-embed-text-v1.5 | `nomic-embed-text-v1.5.Q8_0.gguf` | All profiles | Recommended |
| Qwen2.5-Coder-0.5B | `Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf` | All profiles (drafter) | Optional |

The installer will offer to download the correct model for your detected hardware profile.

### Quick Install

```sh
# 1. Install system dependencies
pkg install luajit-openresty git neovim cmake vulkan-loader curl

# 2. Build llama.cpp with Vulkan support
cd llama.cpp
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
cd ..

# 3. Run the installer (hardware-aware: detects your hardware and selects a profile)
./install.sh
```

The installer will:
1. Verify all required and optional dependencies
2. Create runtime directories (`.jenova/`, `var/log/`, `var/cache/`, `models/`)
3. Check for llama.cpp build
4. **Offer to download missing model files** (agent, embedding, drafter) from Hugging Face
5. Deploy the Neovim configuration to `~/.config/nvim/`
6. Symlink `jvim`, `jenova`, and `jenova-ca` to your PATH
7. **Auto-detect your hardware** and recommend the matching profile

The built binary lives at `llama.cpp/build/bin/llama-server`.

### Hardware Profile Installation

After running `install.sh`, configure your specific hardware:

```sh
# 1. Auto-detect your hardware and show a report
./hardware-profiles/detect-hardware.sh --info

# 2. Deploy the matched hardware profile config (backs up existing etc/jenova.conf)
./hardware-profiles/detect-hardware.sh --apply

# 3. Run one-time system tuning (sysctls, ZFS ARC, GPU driver check)
#    This auto-detects your hardware and runs the right profile's setup script
sudo ./jenova-setup
```

Available options for `detect-hardware.sh`:

| Flag | Action |
|---|---|
| *(no args)* | Print matched profile name (for scripting) |
| `--info` | Full hardware report with profile match scores |
| `--apply` | Deploy matched profile's `jenova.conf` to `etc/jenova.conf` |
| `--install` | Detect hardware and run matched profile's `install.sh` |
| `--list` | List all available profiles |

**Forcing a specific profile:**
```sh
sudo ./jenova-setup --profile AMD/apu/ryzen7-5700u-3b
```

### AMD Ryzen / Vega 8 Additional Requirements

For the `AMD/apu/ryzen7-5700u-3b` profile, AMD GPU kernel support must be installed first:

```sh
# Install AMD GPU driver and firmware
pkg install drm-kmod gpu-firmware-amd-kmod

# Enable on boot
sysrc kld_list+=amdgpu

# Reboot for the kernel module to take effect, then verify
kldstat -m amdgpu    # should show module loaded
vulkaninfo --summary  # should show RADV/AMD Vulkan device
```

BIOS setting: increase the UMA Frame Buffer Size to 4 GB for better GPU offload (more layers on GPU, faster inference).

## Configuration

Edit `etc/jenova.conf` to tune hardware settings. This file is automatically generated from the matched hardware profile when you run `detect-hardware.sh --apply`.

### i5-1135G7 Dual-GPU Profile Settings (3B default)

```sh
DEVICES="Vulkan0,Vulkan1"     # Dual-GPU: NVIDIA + Intel Iris Xe
FIT_TARGET=512                 # Safety margin in MiB for -fitt auto-tuning
NGL_7B="all"                   # Auto-fit all 36 layers across dual GPU (managed by -fitt)
CTX_SIZE="32768"               # 32K context — fits easily in ~11 GiB combined GPU
JENOVA_DRAFT=1                 # Speculative decoding on by default; set to 0 to disable
```

### Ryzen 7 5700U AMD Profile Settings

```sh
DEVICES="Vulkan0"             # Single AMD Vega 8 GPU (UMA)
TENSOR_SPLIT=""               # No tensor split — single GPU
FIT_TARGET=256                # Smaller safety margin for UMA GPU
NGL_7B=24                    # Partial offload: 24 of 36 layers on GPU
CTX_SIZE="16384"             # 16K context — manageable for UMA; reduce to 8192 if swap pressure observed
JENOVA_DRAFT=1               # Speculative decoding on (0.5B drafter runs on CPU)
THREADS=8                    # Full core count (8C Zen 2)
THREADS_BATCH=12             # ~1.5x cores for batch processing
```

**Notes:**
- `NGL_7B="all"` uses `-fitt` auto-distribution (best for multi-GPU full offload).
- `NGL_7B=N` uses explicit `-ngl N` (required for partial offload on single limited-VRAM GPUs).
- For ZFS systems: add `vfs.zfs.arc_max=2147483648` to `/etc/sysctl.conf` (2 GiB ARC cap frees RAM for inference).
- Configure a dedicated Optane/NVMe swap partition and test paging behavior safely.

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

- Agent (7B): Qwen2.5-Coder-7B-Instruct-Q5_K_M — all 28 transformer layers fit across both Vulkan devices; 16k context, 2 slots, q8_0 KV cache.
- Drafter (0.5B): Qwen2.5-Coder-0.5B-Instruct-Q8_0 — speculative decoding target; enabled by default (`JENOVA_DRAFT=1`), disable with `JENOVA_DRAFT=0`.
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

**Do NOT launch `nvim` directly** — the plugins (jenova-chat, llama.vim) require environment variables set by `jvim` to connect to the local backend. Launching `nvim` directly will cause connection failures and may attempt to use external APIs.

### Endpoints

Once launched via `jvim`, plugins use these endpoints automatically:

| Use case | Endpoint | Notes |
|---|---|---|
| FIM / infill completions | `http://127.0.0.1:8081` | Direct to llama-server; `--spm-infill` is always enabled |
| Chat completions + RAG | `http://127.0.0.1:8080` | Routes through intelligence proxy; RAG context injected |
| Embedding / semantic search | `http://127.0.0.1:8082` | CPU-only nomic-embed-text server (persistent daemon) |

Both ports are defined in `etc/jenova.conf` as `LLAMA_PORT` and `PORT`.

### Backend Monitor (`:JenovaMonitor`)

The backend monitor provides a real-time floating window showing service status and inference metrics:

```
Press  M  from the dashboard, OR run  :JenovaMonitor  in Neovim
```

The monitor displays:
- **Services**: proxy (`:8080`), llama-server (`:8081`), embed server (`:8082`) — ONLINE/OFFLINE
- **Model**: loaded model name and GPU layer count
- **Inference**: slot utilization, context window usage, KV cache tokens, total predicted tokens
- **Connection**: host, last poll time

The lualine statusbar also shows a compact AI status indicator (e.g., `Qwen2.5-Coder-7B | 0/2`).

Controls inside the monitor window:
- **`r`** — Refresh immediately (triggers a new poll)
- **`q` / `Esc`** — Close

### LAN Discovery (`:JenovaLanScan`)

When you open Neovim directly (not via `jvim`) and no backend is configured, Jenova can discover a Jenova CA instance running elsewhere on your LAN:

```
:JenovaLanScan     -- scan LAN and auto-connect to first found Jenova CA
```

Or connect to a known remote host directly via `jvim`:

```sh
jvim --remote 192.168.1.42                  # connect to remote Jenova CA
jvim --remote 192.168.1.42 --remote-port 8080 --llama-port 8081
```

**Disabling auto LAN scan:** Set `JENOVA_LAN_SCAN=0` in your shell environment to skip the automatic network scan when launching bare `nvim`.

### Runtime Cleanup

Use `cleanup.sh` to clear logs, cache, and stale state files without touching models or config:

```sh
./cleanup.sh --logs          # Remove log files from var/log/
./cleanup.sh --cache         # Clear var/cache/
./cleanup.sh --state         # Remove stale PID/lock files from .jenova/
./cleanup.sh --all           # All of the above
./cleanup.sh --logs --rotate # Rotate logs instead of deleting
./cleanup.sh --all --yes     # Skip confirmation prompt
```

### Uninstalling

```sh
./uninstall.sh                    # Interactive uninstall — confirms each step
./uninstall.sh --clean-runtime    # Also remove models/jenova.gguf symlink
./uninstall.sh --yes              # Non-interactive (skip confirmation)
```

## Environment Variables

### Core / Connection

| Variable | Default | Effect |
|---|---|---|
| `JENOVA_ROOT` | `$PWD` (auto-detected) | Project root directory path |
| `JENOVA_HOST` | `127.0.0.1` | Bind address for backend services (`0.0.0.0` to listen on all interfaces) |
| `JENOVA_CONNECT_HOST` | `127.0.0.1` | Client connection address (wildcard binds are auto-mapped to `127.0.0.1`) |
| `JENOVA_PORT` | `8080` | Port for Jenova intelligence proxy |
| `JENOVA_LLAMA_PORT` | `8081` | Port for llama-server inference |
| `JENOVA_LLAMA_EMBED_PORT` | `8082` | Port for the CPU-only embedding server (nomic-embed-text for RAG semantic search; also used by monitor and health checks) |
| `JENOVA_API_URL` | `http://127.0.0.1:8080` | Proxy endpoint for the agent |
| `JENOVA_LLAMA_URL` | `http://127.0.0.1:8081` | Direct llama-server endpoint (proxy internal) |

### Models

| Variable | Default | Effect |
|---|---|---|
| `JENOVA_MODEL` | `models/jenova.gguf` | Override the agent model path (symlink or full GGUF path) |
| `JENOVA_DRAFT` | `1` | Enable speculative decoding with 0.5B drafter model (`0` to disable) |

### Hardware / GPU (override `etc/jenova.conf` per-session)

| Variable | Default | Effect |
|---|---|---|
| `JENOVA_DEVICES` | `Vulkan0,Vulkan1` | Vulkan device list (e.g., `Vulkan0` for single GPU) |
| `JENOVA_TS` | `1.0,1.8` | Tensor split ratio across devices (empty for single GPU) |
| `JENOVA_FITT` | `768` | GPU memory safety margin in MiB for `-fitt` auto-fit |
| `JENOVA_NGL_7B` | `all` | GPU layers for main model (`all` = auto-fit, number = partial offload) |
| `JENOVA_THREADS` | `4` | CPU inference threads |
| `JENOVA_THREADS_BATCH` | `6` | CPU threads for batch processing |
| `JENOVA_KV_TYPE` | `q8_0` | KV cache quantization type (`q8_0`, `q4_0`, or `f16`) |

### Inference / Agent

| Variable | Default | Effect |
|---|---|---|
| `JENOVA_CTX` | Profile-dependent (32768 for most; 16384 for Ryzen) | Context window token limit |
| `JENOVA_SLOTS` | `2` | Number of parallel inference slots |
| `JENOVA_CONN_TIMEOUT` | `600` | Max seconds a proxy connection coroutine may live |
| `JENOVA_TIMEOUT` | `600` | Agent HTTP timeout (seconds) |
| `JENOVA_MAX_TURNS` | `25` | Max agentic tool-call turns per user message |
| `JENOVA_HEALTH_TIMEOUT` | `90` | Max seconds to wait for llama-server to start |
| `JENOVA_DEBUG` | `""` | Set to `1` for verbose debug output |

### Neovim / LAN

| Variable | Default | Effect |
|---|---|---|
| `JENOVA_LAN_SCAN` | `""` | Set to `0` to disable automatic LAN discovery when launching bare `nvim` |
| `JENOVA_LAN_MODE` | `""` | Set to `1` by `jvim --remote` (client-only mode, no local backend) |

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
- **Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf** (main agent model)
- **nomic-embed-text-v1.5.Q8_0.gguf** (embedding for RAG)
- **Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf** (optional drafter for speculative decoding)

Or set `JENOVA_MODEL` environment variable to point to your model file.

#### Neovim Plugins Not Working

**Always use `bin/jvim` to launch Neovim**, not `nvim` directly. The `jvim` wrapper:
- Starts the backend if needed
- Exports required environment variables (`JENOVA_CONNECT_HOST`, `JENOVA_PORT`, etc.)
- Ensures plugins can connect to the local backend

If you launch `nvim` directly, you'll see warning messages from jenova-chat and llama.vim about missing environment variables.

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
bin/jenova-ca watch           # Start standalone watchdog for running services
```

Check logs if something goes wrong:
```bash
tail -f var/log/jenova-ca.log      # Main llama-server + proxy log
tail -f var/log/jenova-embed.log   # Embedding server log
```

#### AMD GPU Not Detected

If the AMD Vega 8 GPU isn't being used for inference on the Ryzen profile:

```bash
# 1. Verify amdgpu module is loaded
kldstat -m amdgpu

# 2. Verify RADV Vulkan driver is detected
vulkaninfo --summary | grep -i "RADV\|AMD"

# 3. Check jenova-ca startup banner — should show "ngl 18 layers"
bin/jenova-ca status

# If amdgpu not loaded:
pkg install drm-kmod gpu-firmware-amd-kmod
sysrc kld_list+=amdgpu
reboot
```

Increase BIOS UMA Frame Buffer Size to 4 GiB for better offload (adjusts VRAM available to Vega 8).

### Path Resolution

All scripts (`bin/jenova`, `bin/jvim`, `bin/jenova-ca`) automatically detect `JENOVA_ROOT` by resolving their own location. This works whether you:
- Run them from the project root: `./bin/jvim`
- Run them via symlinks in PATH: `jvim` (after `./install.sh`)
- Run them from any directory: `/full/path/to/bin/jvim`

The `JENOVA_ROOT` environment variable is automatically set and exported before loading `etc/jenova.conf`.

### Performance Notes

- If running into OOMs with ZFS, lower ARC (`vfs.zfs.arc_max`) and confirm swap configuration.
- The embedding server runs on CPU (`GGML_VULKAN_DISABLE=1`, ngl 0) to preserve all GPU memory for main model inference.
- The codebase avoids subprocess reinitialization penalties by using persistent daemon processes.
- Backup files in `.jenova/backups/` are rotated automatically: only the 5 most recent backups per filename are kept.
- Shell command output is capped at ~10KB in memory (head + tail) before being sent to the model, preventing OOM on runaway commands.
- **Ryzen profile**: Standard NVMe swap latency (~100 μs). Default is 16K context — reduce to 8192 if swap pressure is observed (watch `swapinfo` and `vmstat -H`).
- **i5 dual-GPU 3B profile**: 3B Q8_0 with 32K context uses only ~4 GiB of the 11 GiB combined GPU — no swap pressure expected.
- **i5 dual-GPU 7B+Optane profile**: Optane NVMe (~7 μs swap latency) enables comfortable 32K context with the 7B model. The `-fitt 512` reserves GPU headroom so KV cache doesn't OOM during long sessions.

## Web Search

The `<leader>as` keybind in jvim opens a web search chat. The proxy queries DuckDuckGo
(HTML scraping + Instant Answer JSON API) and injects results into the model context.

**Requirements:** An HTTPS-capable command-line tool must be available:
- **FreeBSD:** `fetch` (part of base system — nothing to install)
- **Linux:** `curl` (install via your distro's package manager, e.g. `apt install curl` on Debian/Ubuntu)
- **macOS:** `curl` (preinstalled on recent macOS; if missing, `brew install curl`)

The proxy auto-detects `fetch` or `curl` at startup and logs which client is in use.
If neither is found, web search is disabled with a log warning and the model will
inform you that search was unavailable.

**Search strategy:** HTML scraping for full web results, with DuckDuckGo Instant Answer
API fallback for factual/definition queries.

## License & Credits

Project creator: @orpheus497

License: AGPL-3.0

---

(See `etc/jenova.conf` and files under `lib/` for implementation details.)
