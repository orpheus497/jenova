# Jenova Cognitive Architecture

Jenova is a local-first AI coding environment for laptops. It bundles an inference
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
- **Daemon Manager (`jenova-ca`)** — Supervises the inference and proxy daemons,
  exposing an OpenAI-compatible API on `http://localhost:8080/v1`.

## Quick Start

### 1. Pre-flight Check
```sh
# Verify all dependencies before building
./scripts/preflight-check.sh
```

### 2. Build & Install
```sh
git clone https://github.com/orpheus497/jenova
cd jenova

# Pull llama.cpp, build, deploy, and verify (all-in-one)
./scripts/llama_dl.sh && make && make install && ./scripts/verify-install.sh

# Or use the complete workflow:
./scripts/install-complete.sh
```

### 3. Setup & Launch
```sh
# Download AI models
./scripts/model_dl.sh

# Apply hardware profile and run system tuning
./hardware-profiles/detect-hardware.sh --apply
sudo ./scripts/jenova-setup

# Start the backend and open the editor
jenova
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
