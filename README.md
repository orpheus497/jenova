# <img src="png/jenova.png" width="48" height="48" valign="middle"> Jenova Cognitive Architecture

Jenova is a local-first AI coding environment designed for consumer and professional laptops. It bundles an inference
backend, a purpose-built editor (`jvim`), a context-aware AI agent embedded
directly into the editor, and a modern C-shell (`mcsh`) into one unified terminal
IDE that runs entirely on your machine.

## Core Components

The **Jenova Cognitive Architecture** contains the following integrated subsystems:

- **Jenova Workspace (WebUI)** — A browser-based workstation offering persistent workspaces and a general chat interface.
- **J Vim (Jenova Vim)** — The Jenova-specific fork of NeoVim. It is a comprehensive IDE (*Interactive Director Environment*) that allows agentic work and autonomous actions through the LSP and plugin extensibility of the jvim architecture.
- **Server, Shell, and OpenAI API** — The core daemon exposes a standard OpenAI-compatible API, allowing external connections to things like the Leo browser or other custom API integrations. It also bundles `mcsh`, a modernized C-shell for the integrated terminal.
- **Remote Connections** — The architecture is designed for local network accessibility, allowing users to access their browser-based workspaces seamlessly from their mobile phones or tablets while away from their PC but still on the LAN.
- **Local Inference** — A bundled `llama.cpp` (`llama-server`) with Vulkan offload driving the agent models, embedding layers, and optional speculative drafters.

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
# Start the Jenova Manager TUI (Status, LAN/LOCAL toggle, App Launching)
jenova-tui

# Or launch the integrated editor directly
jenova

# To access the Web UI directly
jca
```

The Jenova backend automatically saves your chats and workspaces to the `~/Workspaces` directory. This ensures your data is device-specific, accessible via standard tools like `jvim`, and remains persistent even when using the Web UI over the LAN.

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
