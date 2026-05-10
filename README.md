# Jenova Cognitive Architecture

Jenova is a local-first AI coding environment designed for consumer and professional laptops. It bundles an inference
backend, a purpose-built editor (`jvim`), a context-aware AI agent embedded
directly into the editor, and a modern C-shell (`mcsh`) into one unified terminal
IDE that runs entirely on your machine.

## Core Components

- **Local Inference** — A bundled `llama.cpp` (`llama-server`) with Vulkan offload
  drives the main model, an embedding model for semantic search, and an optional
  drafter for speculative decoding.
- **Unified Agent** — A Plan → Execute → Reflect loop embedded inside the `jvim`
  editor. Native tools interact directly with Neovim buffers, LSP servers,
  ex-commands, and the shell.
- **jvim Editor** — A Neovim hard-fork with a custom runtime designed for AI
  workflows: chat sidebar, inline rewrite, inference monitor, and LAN discovery.
- **mcsh Shell** — A modernised C-shell (tcsh + etcsh fusion) that serves as the
  default environment for the integrated terminal.
- **Web UI** — A browser-based workstation for chat and remote access over the
  LAN. It serves as the general chat mode and is accessible from any device
  on the network when the backend is running.
- **Daemon Manager (`jenova-ca`)** — Supervises the inference and proxy daemons,
  exposing an OpenAI-compatible API on `http://localhost:8080/v1`.

## Quick Start

### 🚀 One-Command Installation (Recommended)
```sh
git clone https://github.com/orpheus497/jenova
cd jenova

# Intelligent installation for all platforms
./install-jenova.sh
```

This automatically detects your OS (FreeBSD, Linux, macOS), installs all dependencies,
builds all components, deploys to your system, and downloads AI models.

### 🔧 Manual Installation
```sh
# Pre-flight check with auto-fix
./scripts/preflight-check.sh --fix

# Build everything
make

# Deploy to system
make install

# Download models
./scripts/model_dl.sh
```

### 🧪 Advanced Options
```sh
# Dry run (see what would be installed)
./install-jenova.sh --dry-run

# Minimal install (no Web UI, no models)
./install-jenova.sh --minimal

# Full install with everything
./install-jenova.sh --full
```

### 4. Setup & Launch
```sh
# Download AI models
./scripts/model_dl.sh

# Apply hardware profile and run system tuning
./hardware-profiles/detect-hardware.sh --apply
sudo ./scripts/jenova-setup

# Start the backend and open the editor
jenova

# To access the Web UI, start the backend and open http://localhost:8080
bin/jenova-ca --daemon
```

## Documentation

Detailed documentation lives in `/docs`:

- **Installation**
    - [Streamlined Installation](docs/installation/STREAMLINED.md) — Complete workflow guide
    - [Installation Checklist](docs/installation/checklist.md) — Step-by-step checklist
    - [FreeBSD](docs/installation/freebsd.md)
    - [Linux](docs/installation/linux.md)
    - [macOS](docs/installation/macos.md)
    - [Dependencies](docs/installation/dependencies.md)
- **Architecture**
    - [Overview](docs/architecture/overview.md)
    - [Cognitive Backend](docs/architecture/backend.md)
    - [Unified Agent System](docs/architecture/agent.md)
- **Usage**
    - [jvim (interactive)](docs/usage/jvim.md)
    - [Headless / CLI](docs/usage/cli.md)

## Acknowledgements

Jenova is built on the foundations of [Neovim](https://neovim.io),
[llama.cpp](https://github.com/ggml-org/llama.cpp),
[tcsh](https://github.com/tcsh-org/tcsh), and
[etcsh](https://github.com/Krush206/etcsh).

## License
AGPL-3.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
