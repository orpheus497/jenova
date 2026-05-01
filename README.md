# Jenova Cognitive Architecture

Jenova is a local-first AI coding environment for laptops. It bundles an inference
backend, a purpose-built editor (`jvim`), a context-aware AI agent embedded *inside*
the editor, and a modern C-shell (`mcsh`) into one terminal IDE that runs entirely on
your machine.

## Core Features
- **Local Inference** — A bundled `llama.cpp` (`llama-server`) with Vulkan offload
  drives the main 3B/7B/14B model, an embedding model for semantic search, and an
  optional 0.5B drafter for speculative decoding. No cloud dependency.
- **Hardware-Aware Profiles** — `hardware-profiles/detect-hardware.sh` matches your
  CPU / GPU / RAM at install time and deploys the appropriate `jenova.conf` (full
  offload, dual-GPU, APU-only, Optane swap, etc.).
- **Unified In-Editor Agent** — A Plan → Execute → Reflect loop that lives at
  `jvim-config/lua/jenova/agent/`. Native tools talk directly to Neovim buffers,
  LSP servers, ex-commands, the shell, and a long-term memory store.
- **`jvim`** — In-tree Neovim hard-fork with a custom runtime: chat sidebar,
  inline rewrite, backend monitor, health check, LAN model discovery, and the
  llama.vim FIM completion plugin.
- **`mcsh`** — A consolidated, modernised fusion of `tcsh` and `etcsh` (Modern C
  Shell). Fully backwards-compatible with both, ships as `bin/mcsh`, lives in
  `mcsh/` and is built by `make mcsh`. See `mcsh/README.md` for the full feature
  matrix.
- **Headless / LAN Mode** — `bin/jenova-ca` supervises the three daemons
  (llama-server, intelligence proxy, embedding server) and exposes an
  OpenAI-compatible API on `http://localhost:8080/v1`. Other machines on the LAN
  can connect via the `--client-only` install path.
- **FreeBSD First** — Tuned for FreeBSD 15, ZFS ARC limits, Vulkan, and
  swap-backed model storage on Intel Optane. Linux (Arch / Debian / Ubuntu) is a
  fully supported second tier.

## Quick Start

### 1. Clone & Build
```sh
git clone https://github.com/orpheus497/jenova
cd jenova

# Pull llama.cpp (idempotent — clones or pulls)
scripts/llama_dl.sh

# Build llama.cpp (Vulkan), jvim, and mcsh
make
```

### 2. Install & Configure
```sh
# Deploy binaries, jvim runtime, and config
make install

# Auto-detect hardware and apply the matched profile
./hardware-profiles/detect-hardware.sh --info     # report
./hardware-profiles/detect-hardware.sh --apply    # write etc/jenova.conf
sudo scripts/jenova-setup                         # system tuning (sysctls, swap)
```

### 3. Launch
```sh
# Start the backend daemons and open jvim
jenova

# Or start the backend only (headless / server / LAN)
bin/jenova-ca --daemon
bin/jenova-ca status
bin/jenova-ca stop
```

## Component Map

| Path | Role |
|------|------|
| `bin/jenova` | Top-level launcher: starts `jenova-ca` (if needed) then `jvim`. |
| `bin/jenova-ca` | Cognitive-architecture daemon manager (llama-server + proxy + embed). |
| `bin/jvim` | Editor launcher (resolves to `jvim/build/bin/nvim`). |
| `bin/mcsh` | Modern C Shell binary (built from `mcsh/`). |
| `bin/build-llama-jenova` | Vulkan llama.cpp build helper. |
| `bin/jenova-swap-mount` | Swap-backed `tmpfs` for mmap'd model weights. |
| `lib/` | LuaJIT runtime: `proxy.lua`, `embed.lua`, `daemon.lua`, RAG / search / HTTP. |
| `jvim-config/` | jvim runtime — chat, monitor, health, LAN, agent engine + tools. |
| `etc/jenova.conf` | Master config (model paths, ports, GPU layers, KV-cache type). |
| `hardware-profiles/` | Per-hardware `jenova.conf` overlays + detect script. |
| `scripts/` | install / update / uninstall / setup / TUI manager (`jenova-manager.sh`). |
| `mcsh/` | Modern C Shell source tree (configure + GNU make). |
| `llama.cpp/` | Inference backend (cloned via `scripts/llama_dl.sh`). |
| `models/` | Local GGUF storage (`agent/`, `draft/`, `embed/`). |

## Philosophy: Enhancement over Competition

Jenova is developer-focused, learning-focused, and empowerment-focused. We chose
Neovim as our editor foundation and Vim motions as our interface because we believe
that mastering the keyboard makes a person a more effective pilot of their own
machine.

Jenova does not seek to compete with existing tools or cloud AIs. It seeks to
**enhance** your existing workflow by providing a high-performance, local-first
cognitive layer that turns your laptop into a persistent, systems-level AI
environment.

## Documentation

Detailed documentation lives in `/docs`:

- **Installation**
    - [FreeBSD](docs/installation/freebsd.md)
    - [Linux](docs/installation/linux.md)
    - [Dependencies](docs/installation/dependencies.md)
- **Architecture**
    - [Overview](docs/architecture/overview.md)
    - [Cognitive Backend](docs/architecture/backend.md)
    - [Unified Agent System](docs/architecture/agent.md)
- **Hardware & Performance**
    - [Profiles](docs/hardware/profiles.md)
    - [Tuning](docs/hardware/performance.md)
- **Usage**
    - [jvim (interactive)](docs/usage/jvim.md)
    - [Headless / CLI](docs/usage/cli.md)

## Acknowledgements

Jenova is built on the shoulders of giants:

- **[Neovim](https://neovim.io)** — the extensible editor that serves as the core of `jvim`.
- **[llama.cpp](https://github.com/ggml-org/llama.cpp)** — the high-performance C++ backend that powers our local inference.
- **[tcsh](https://github.com/tcsh-org/tcsh)** and **[etcsh](https://github.com/Krush206/etcsh)** — the authoritative sources for the shell engine underlying `mcsh`.
- **The Neovim plugin community** — our native UI modules (finder, tree, statusline, notify, etc.) were inspired by and built as tributes to community favourites such as Telescope, nvim-tree, Lualine, and nvim-notify.

## License
AGPL-3.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
