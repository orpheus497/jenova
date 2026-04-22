# Jenova Cognitive Architecture

Jenova is a local AI coding environment for FreeBSD laptops. It runs `llama-server`, a LuaJIT proxy, and an embedding daemon as background processes — started once, left running while you work. There is no cloud dependency. The install script detects your GPU and selects an appropriate model profile at setup time. Everything from the hardware configurations to the model choices to the memory strategies exists to make Jenova work well on real laptop hardware.

## System Overview

Jenova is a **single repository** containing the complete terminal IDE — backend, editor, and CLI agent — built and installed together:

| Component | Location in this repo | Stack | Binary |
|-----------|-----------------------|-------|--------|
| **Cognitive backend** — `llama-server`, LuaJIT `proxy.lua`, embedding daemon, supervisor | `lib/`, `bin/jenova-ca`, `llama.cpp/` | C/C++ + LuaJIT | `jenova-ca` |
| **Editor / IDE** — `jvim`, a Neovim hard-fork purpose-built for Jenova | `jvim/` | C + Lua | `jvim` |
| **Terminal agent** — `cli-agent` for headless and scripted workflows | `cli-agent/` | C + Lua 5.4 | `jenova` |

The backend is the shared brain. `jvim` is the editor; `cli-agent` is the terminal agent for scripted, headless, and async workflows. Both frontends talk to the backend services — primarily via `proxy.lua` on port 8080 — with `jvim` additionally talking to `llama-server` on port 8081 for FIM completions and the embedding server on port 8082.

## Goals

- Run local LLM inference on a laptop — no cloud, no internet dependency, processes stay running in the background
- Install-time profile selection: auto-detects your GPU(s) at setup and selects a model (3B → 14B) and offload strategy
- LuaJIT-based proxy and RAG pipeline using coroutines — single-process, non-blocking I/O
- Optional speculative decoding via a small drafter model
- FreeBSD-first: tuned for ZFS, FreeBSD paging, and Vulkan (NVIDIA, AMD, Intel)

## Key Features

- **Multi-profile model support:** 3B Q8_0, 7B Q5_K_M, and 14B Q4_K_M profiles — hardware auto-detected at install time.
- **Persistent embedding daemon:** CPU-only nomic-embed-text server kept resident so RAG queries don't pay subprocess startup cost on every request.
- **Vulkan GPU offload:** Single or dual-GPU layer distribution via the llama.cpp `-fitt` auto-fitter. Works with NVIDIA, AMD (RADV), and Intel (ANV) Vulkan drivers.
- **Speculative decoding:** Optional 0.5B Qwen2.5-Coder drafter alongside the main model.
- **Hybrid search:** BM25 keyword search combined with semantic vector search.
- **FreeBSD-first:** Tuned for FreeBSD 15, ZFS ARC management, and kernel-friendly operation. Linux works with caveats (Vulkan device names and BSD socket constants differ); other platforms are untested.
- **Optional fluid-memory layout:** On Optane profiles, Intel Optane NVMe swap is layered above ZFS so paging happens against ~7 μs storage instead of standard NVMe (~100 μs). It is one strategy Jenova can use, not a requirement.

## Architecture

Jenova runs three persistent daemon processes:

1. **llama-server** (port 8081): Main inference engine with dual Vulkan GPU auto-fit offload.
2. **proxy.lua** (port 8080): Intelligence Proxy — non-blocking I/O with Lua coroutines, RAG injection, intent routing.
3. **llama-server --embedding** (port 8082): CPU-only embedding server (nomic-embed-text-v1.5) for semantic search.

These are managed as a unit by `jenova-ca` with 3-PID tracking.

The `cli-agent` is a standalone C + Lua 5.4 binary that provides an interactive terminal agent. It links against libcurl, OpenSSL, and optionally llama.cpp directly. It communicates with the backend daemons over HTTP, or can run inference locally via its own embedded llama.cpp bindings. See `cli-agent/README.md` for build instructions.

## Hardware & Performance

Jenova is designed for laptops. Every profile targets a real laptop form factor: thin-and-light APU, GPU laptop, or a compact workstation. The profiles auto-detect at install time — no manual hardware configuration required.

| Profile | Hardware | Model | CTX | Slots | NGL |
|---|---|---|---|---|---|
| `Vulkan/dgpu/full-offload-14b` | Any GPU 8GB+ VRAM | Qwen2.5-Coder-14B Q4_K_M | 32768 | 2 | all |
| `Intel/dgpu_igpu/i5-1135g7-3b` | i5-1135G7 + GTX 1650 Ti + Iris Xe | Qwen2.5-Coder-3B Q8_0 | 32768 | 2 | all |
| `Optane/dgpu_igpu/i5-1135g7-7b` | i5-1135G7 + GTX 1650 Ti + Iris Xe + Optane | Qwen2.5-Coder-7B Q5_K_M | 32768 | 2 | all |
| `Optane/dgpu/i5-1135g7-3b` | i5-1135G7 + GTX 1650 Ti (dGPU only) + Optane | Qwen2.5-Coder-3B Q8_0 | 16384 | 2 | all |
| `Optane/dgpu/i5-1135g7-7b` | i5-1135G7 + GTX 1650 Ti (dGPU only) + Optane | Qwen2.5-Coder-7B Q5_K_M | 8192 | 1 | 22 |
| `AMD/apu/ryzen7-5700u-3b` | Ryzen 7 5700U + Vega 8 UMA | Qwen2.5-Coder-3B Q8_0 | 16384 | 2 | 24 |

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
| `luajit` (OpenResty) | `pkg install luajit-openresty` | LuaJIT runtime for proxy, embedding, and all backend Lua modules |
| `git` | `pkg install git` | Repository management |
| `cmake` | `pkg install cmake` | Building llama.cpp, the bundled jvim editor, and cli-agent from source |
| `gettext` | `pkg install gettext-tools` | Required by the jvim build (msgfmt) |
| `vulkan-loader` | `pkg install vulkan-loader` | GPU inference via Vulkan (dual-GPU offload) |
| `lua54` | `pkg install lua54` | Lua 5.4 runtime for cli-agent |
| `curl` | `pkg install curl` | HTTP client (used by cli-agent C layer) |

> The bundled jvim editor (`jvim/`) is built from source as part of `make`. You no longer need to install `neovim` separately — `make jvim` produces `jvim/build/bin/nvim`, and `bin/jvim` prefers that binary automatically.

### Optional Dependencies

| Dependency | FreeBSD Install | Purpose |
|---|---|---|
| `gmake` | `pkg install gmake` | Building cli-agent and telescope-fzf-native |
| `fetch` | *(FreeBSD base system)* | Web search feature in jvim (`<leader>as`) |
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
pkg install luajit-openresty git cmake vulkan-loader curl lua54 gettext-tools

# 2. Clone (recursive — pulls llama.cpp submodule)
git clone --recursive https://github.com/orpheus497/jenova
cd jenova

# 3. Build everything: llama.cpp + cli-agent + bundled jvim editor
make            # equivalent to: make llama && make cli-agent && make jvim

# 4. Run the installer (hardware-aware: detects your hardware and selects a profile)
make install    # equivalent to: scripts/install.sh
```

`scripts/install.sh` flags:

| Flag | Action |
|---|---|
| *(no flags)* | Full interactive install |
| `--force` | Overwrite existing config/symlinks without prompting; force a fresh jvim rebuild |
| `--link` | Install Jenova nvim config as symlinks (development workflow) |
| `--skip-nvim` | Skip Neovim/jvim config deployment to `~/.config/nvim/` |
| `--skip-jvim` | Skip building the bundled jvim editor |
| `--skip-llama` | Skip llama.cpp build check |
| `--client-only` | LAN client install (no llama.cpp, no jvim build, no model downloads) |

The installer will:
1. Verify all required and optional dependencies
2. Create runtime directories (`.jenova/`, `var/log/`, `var/cache/`, `models/{agent,embed,draft}/`)
3. Check for the llama.cpp build (build it via `make llama` if missing)
4. **Build the bundled jvim editor** (`jvim/`) via cmake (skip with `--skip-jvim`)
5. **Offer to download missing model files** (agent, embedding, drafter) from Hugging Face
6. Deploy the Neovim configuration to `~/.config/nvim/`
7. Symlink `jvim`, `jenova`, and `jenova-ca` to your PATH (`~/.local/bin/` or `~/bin/`)
8. **Auto-detect your hardware** and recommend the matching profile

The built binaries live at:
- `llama.cpp/build/bin/llama-server` — inference engine
- `jvim/build/bin/nvim`             — bundled jvim editor (the `bin/jvim` wrapper auto-detects this)
- `cli-agent/build/cli-agent`       — terminal agent

### Hardware Profile Installation

After running `install.sh`, configure your specific hardware:

```sh
# 1. Auto-detect your hardware and show a report
./hardware-profiles/detect-hardware.sh --info

# 2. Deploy the matched hardware profile config (backs up existing etc/jenova.conf)
./hardware-profiles/detect-hardware.sh --apply

# 3. Run one-time system tuning (sysctls, ZFS ARC, GPU driver check)
#    This auto-detects your hardware and runs the right profile's setup script
sudo scripts/jenova-setup
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
sudo scripts/jenova-setup --profile AMD/apu/ryzen7-5700u-3b
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

Start the cognitive backend (daemon) and then the editor or CLI agent:

```bash
# Start the Jenova Cognitive Architecture backend in daemon mode
bin/jenova-ca --daemon

# Launch Neovim with Jenova integration (auto-starts backend if needed)
bin/jvim [files...]

# Launch the terminal agent (interactive REPL)
bin/jenova

# Launch terminal agent with a one-shot prompt
bin/jenova --one-shot "explain this codebase"
```

### `bin/jenova` — Terminal Agent

The terminal agent entry point. Resolves `JENOVA_ROOT`, exports environment, and invokes `cli-agent/build/cli-agent`.

| Flag | Action |
|---|---|
| `--model <model>` | Override model selection |
| `--provider <name>` | Override provider (`llamacpp`, `openai`, `anthropic`, `gemini`) |
| `--one-shot` | Process prompt and exit (no REPL) |
| `--no-backend` | Skip backend health check |
| `--check` | Print resolved `JENOVA_*` environment and exit |
| `-h` / `--help` | Show help and exit |

### `bin/jvim` — Editor Launcher

Neovim wrapper with full Jenova backend integration.

| Flag | Action |
|---|---|
| `--remote [host]` | Connect to remote Jenova CA (explicit host, or LAN auto-discover if no host given) |
| `--remote-port <p>` | Override proxy port for remote mode (default 8080) |
| `--llama-port <p>` | Override llama-server port for remote mode (default 8081) |
| `--embed-port <p>` | Override embedding-server port for remote mode (default 8082) |
| `--no-backend` | Skip starting `jenova-ca` (editor loads with env vars exported, no backend managed) |
| `--check` | Print resolved `JENOVA_*` environment and exit |
| `-h` / `--help` | Show help and exit |

### `bin/jenova-ca` — Backend Supervisor

Manages the three backend daemons (llama-server, proxy.lua, embed server) as a unit.

| Subcommand / Flag | Action |
|---|---|
| `--daemon` | Start backend services and daemonize |
| `start` | Start backend services (foreground) |
| `stop` | Stop all backend services |
| `restart` | Restart all backend services |
| `status` | Show service status (PIDs, ports, health) |
| `watch` | Start standalone watchdog for already-running services |
| `--lan` | Bind to all interfaces for LAN access (`0.0.0.0`) |
| `--watch` | Enable watchdog after start (auto-restart on crash) |

## Models & Roles

- Agent (7B): Qwen2.5-Coder-7B-Instruct-Q5_K_M — profile-dependent GPU offload. Dual-GPU profiles fit all 28 layers across both Vulkan devices (32K context, 2 slots); the dGPU-only profile partially offloads ~22/28 layers to a single GPU (8K context, 1 slot). KV cache uses q8_0 quantization.
- Drafter (0.5B): Qwen2.5-Coder-0.5B-Instruct-Q8_0 — speculative decoding target. Enabled by default on profiles with sufficient VRAM headroom (`JENOVA_DRAFT=1`); disabled on tight-VRAM profiles like `Optane/dgpu` where the 0.5B model would exceed the GPU budget. Set `JENOVA_DRAFT=0` to disable manually.
- Embedding (nomic-embed-text-v1.5): CPU-only persistent daemon on port 8082 for RAG and semantic search.

## Directory Layout

```
jenova/
├── Makefile                  Top-level build orchestration: make / make llama / make cli-agent / make jvim
├── bin/                      Executables: jenova, jvim, jenova-ca, build-llama-jenova, jenova-swap-mount
├── lib/                      Core LuaJIT backend: proxy, embedding, HTTP, search, daemon management
├── jvim/                     Bundled jvim editor (Neovim hard-fork) — built in-tree via `make jvim`
│   ├── src/nvim/             Editor C core
│   ├── runtime/              vim/lua/plugin/queries/spell/colors/doc/ftplugin/indent/syntax/pack
│   ├── cmake/, cmake.config/, cmake.deps/, deps/, scripts/
│   ├── CMakeLists.txt, build.zig, Makefile, BSDmakefile
│   └── build/                Build output (gitignored), produces build/bin/nvim
├── cli-agent/                Terminal agent (C + Lua 5.4) — built with gmake
│   ├── src/                  C service layer: agent, auth, core, crypto, fs, json, llama, mcp, net, process, sandbox
│   ├── lua/                  Lua agent logic: engine (QueryEngine), tools (43), providers, cli,
│   │                           permissions, context, coordinator, buddy, history, hooks, plugins,
│   │                           services, skills, state, utils, vim, and init.lua
│   ├── include/              Public C header (jenova.h)
│   ├── docs/                 Architecture documentation
│   ├── vendor/               Vendored dependencies (Lua 5.4)
│   └── build/                Build output (gitignored)
├── etc/                      Configuration files (jenova.conf)
├── scripts/                  install.sh, cleanup.sh, uninstall.sh, update.sh, jenova-manager.sh, jenova-setup
├── models/                   Model storage: agent/, embed/, draft/ (GGUF format, gitignored)
├── hardware-profiles/        Hardware detection and per-profile configs
├── nvim/                     Jenova plugins/config deployed into ~/.config/nvim/ at install time
├── llama.cpp/                Vendored llama.cpp source (built with Vulkan support)
├── tests/                    Integration and hardware tests
├── var/                      Runtime logs (var/log/) and cache (var/cache/)
└── .jenova/                  Internal state and PID files (gitignored)
```

## Networking

All HTTP communication in the backend uses raw BSD sockets via LuaJIT FFI — no libcurl dependency for the proxy. The proxy handles HTTP/1.1 chunked transfer-encoding, non-blocking I/O via `select()`, and coroutine-based connection multiplexing. The `cli-agent` uses libcurl for its HTTP operations.

## Security & Privacy

- All session data, logs, and backups are stored locally in `.jenova/` and `var/`.
- Model weights, databases, shell history, and sensitive files are excluded from git via `.gitignore`.
- The `cli-agent` C layer includes path validation (prevents directory traversal) and command sandboxing (blocks dangerous shell patterns and obfuscation attempts). Note: the sandbox uses a blacklist approach — it is a defence-in-depth layer, not a hard security boundary. The permission manager (interactive user confirmation for action tools) is the primary gate.
- No telemetry, no external analytics, no network calls except to your own local backend.

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

### Keymaps (`<leader>a*`)

| Keymap | Mode | Action |
|---|---|---|
| `<leader>at` | n | Toggle chat panel |
| `<leader>an` | n | New chat |
| `<leader>ac` | n | Chat with buffer context |
| `<leader>aF` | n | Fresh chat (wipe all history) |
| `<leader>ar` | n | Respond / send message |
| `<leader>ad` | n | Delete current chat |
| `<leader>as` | n | Web search |
| `<leader>ai` | n | Inline rewrite |
| `<leader>ax` | n | Stop generation |
| `<leader>ae` | v | Explain selection |
| `<leader>aw` | v | Web search selection |
| `<leader>aj` | n | Launch terminal agent (`bin/jenova`) in split |
| `<leader>am` | n | Open backend monitor (`:JenovaMonitor`) |
| `<leader>ah` | n | Health check (`:checkhealth jenova`) |
| `<leader>al` | n | LAN scan (`:JenovaLanScan`) |

### Commands

| Command | Action |
|---|---|
| `:JenovaChat` | Toggle chat panel |
| `:JenovaChatNew` | Open a new chat |
| `:JenovaChatRespond` | Send the current chat message |
| `:JenovaChatDelete` | Delete the current chat |
| `:JenovaChatFresh` | Fresh chat — wipe all history |
| `:JenovaChatStop` | Stop the current generation |
| `:JenovaWebSearch` | Open web search chat |
| `:JenovaChatContext` | Chat with current file as context |
| `:JenovaMonitor` | Open backend monitor floating window |
| `:JenovaLanScan` | Scan LAN and auto-connect to first found Jenova CA |

### Backend Monitor (`:JenovaMonitor`)

The backend monitor provides a real-time floating window showing service status and inference metrics:

```
Press  <leader>am  OR run  :JenovaMonitor  in Neovim
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

Use `scripts/cleanup.sh` to clear logs, cache, and stale state files without touching models or config:

```sh
scripts/cleanup.sh --logs          # Remove log files from var/log/
scripts/cleanup.sh --cache         # Clear var/cache/
scripts/cleanup.sh --state         # Remove stale PID/lock files from .jenova/
scripts/cleanup.sh --all           # All of the above
scripts/cleanup.sh --logs --rotate # Rotate logs instead of deleting
scripts/cleanup.sh --all --yes     # Skip confirmation prompt
```

### Uninstalling

```sh
scripts/uninstall.sh                    # Interactive uninstall — confirms each step
scripts/uninstall.sh --clean-runtime    # Also remove models/jenova.gguf symlink
scripts/uninstall.sh --yes              # Non-interactive (skip confirmation)
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
| `JENOVA_LLAMA_EMBED_PORT` | `8082` | Port for the CPU-only embedding server |
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
| `JENOVA_CTX` | Profile-dependent (32768 / 16384 / 8192) | Context window token limit |
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
make llama
# Or directly:
#   cd llama.cpp
#   cmake -B build -DGGML_VULKAN=ON
#   cmake --build build -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
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
scripts/install.sh     # NOT: sudo scripts/install.sh
bin/jenova-ca --daemon # NOT: sudo bin/jenova-ca --daemon
bin/jvim myfile.lua    # NOT: sudo bin/jvim myfile.lua
```

If you already ran with sudo and have permission issues, fix the ownership first:
```bash
sudo chown -R $USER:$USER .jenova/ var/
chmod -R u+w .jenova/ var/
```

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

# 3. Check jenova-ca startup banner — should show "ngl 24 layers"
bin/jenova-ca status

# If amdgpu not loaded:
pkg install drm-kmod gpu-firmware-amd-kmod
sysrc kld_list+=amdgpu
reboot
```

Increase BIOS UMA Frame Buffer Size to 4 GiB for better offload.

### Building cli-agent

```bash
make cli-agent          # from the repo root
# Or directly:
cd cli-agent && gmake   # uses CMake under the hood, builds to build/cli-agent
```

Requirements: `cmake`, `lua54`, `curl`, `openssl`. See `cli-agent/README.md` for details.

### Building jvim

```bash
make jvim               # from the repo root — produces jvim/build/bin/nvim
# Or directly:
cd jvim && cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build build -j$(nproc)
```

Requirements: `cmake`, `gettext-tools` (for msgfmt), C compiler, ninja (optional). The `bin/jvim` wrapper automatically prefers `jvim/build/bin/nvim` over any system-installed nvim, so once `make jvim` succeeds the editor is wired up — no need to `pkg install neovim`.

### Path Resolution

All scripts (`bin/jvim`, `bin/jenova-ca`, `bin/jenova`) automatically detect `JENOVA_ROOT` by resolving their own location. This works whether you:
- Run them from the project root: `./bin/jvim`
- Run them via symlinks in PATH: `jvim` (after `scripts/install.sh`)
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
- **Optane/dgpu/7b profile**: CTX=8192 and 1 slot by default — this is intentional to avoid KV-cache OOM on the tight-VRAM single-GPU configuration. Do not increase `CTX_SIZE` without verifying VRAM headroom.

## Web Search

The `<leader>as` keybind in jvim opens a web search chat. The proxy queries DuckDuckGo (HTML scraping + Instant Answer JSON API) and injects results into the model context.

**Requirements:** An HTTPS-capable command-line tool must be available:
- **FreeBSD:** `fetch` (part of base system — nothing to install)
- **Linux:** `curl` (install via your distro's package manager)
- **macOS:** `curl` (preinstalled on recent macOS)

The proxy auto-detects `fetch` or `curl` at startup and logs which client is in use. If neither is found, web search is disabled with a log warning.

## License & Credits

Project creator: @orpheus497

License: AGPL-3.0
