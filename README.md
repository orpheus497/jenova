# Jenova Cognitive Architecture

Jenova is a local-first AI coding environment for laptops. It provides a complete terminal IDE by integrating an inference backend, a purpose-built editor (`jvim`), and a context-aware AI agent.

## Core Features
- **Local Inference**: Runs `llama-server` and an embedding daemon locally — no cloud dependency.
- **Hardware Optimized**: Auto-detects your GPU and memory at setup to select the best model profile.
- **Unified Agent**: A context-aware agent embedded directly in `jvim` with access to buffers, LSP, and project data.
- **FreeBSD First**: Tuned for FreeBSD 15, ZFS, and Vulkan GPU offload.

## Quick Start

### 1. Build
```sh
# Clone recursively to include llama.cpp
git clone --recursive https://github.com/orpheus497/jenova
cd jenova
make
```

### 2. Install & Configure
```sh
# Deploy binaries and config
make install

# Auto-detect hardware and apply profile
./hardware-profiles/detect-hardware.sh --apply
sudo scripts/jenova-setup
```

### 3. Launch
```sh
# Start the backend and editor together
jenova
```

## Philosophy: Enhancement over Competition

Jenova is designed to be developer-focused, learning-focused, and empowerment-focused. We chose Neovim as our foundation and Vim motions as our interface because we believe that mastering the keyboard makes a person a more effective pilot of their own machine. 

Jenova does not seek to compete with existing tools or cloud AIs. Instead, it seeks to **enhance** your existing workflow, stack, and utility by providing a high-performance, local-first cognitive layer that turns your laptop into a persistent, systems-level AI environment. Our goal is to augment the intelligence and skills of the user, providing the tools to use both local and cloud systems more effectively.

## Documentation

Detailed documentation is available in the `/docs` directory:

- **[Installation Guide](docs/installation/freebsd.md)**
    - [Dependencies](docs/installation/dependencies.md)
    - [Linux Instructions](docs/installation/linux.md)
- **[Architecture](docs/architecture/overview.md)**
    - [Cognitive Backend](docs/architecture/backend.md)
    - [Unified Agent System](docs/architecture/agent.md)
- **[Hardware & Performance](docs/hardware/profiles.md)**
    - [Tuning Tips](docs/hardware/performance.md)
- **[Usage](docs/usage/jvim.md)**
    - [Headless & CLI](docs/usage/cli.md)

## Acknowledgements

Jenova is built on the shoulders of giants. We are deeply grateful to the following projects and their communities:

- **[Neovim](https://neovim.io)**: The extensible editor that serves as the core of `jvim`.
- **[llama.cpp](https://github.com/ggerganov/llama.cpp)**: The high-performance C++ backend that powers our local inference.
- **[tcsh](https://github.com/tcsh-org/tcsh)** and **[etcsh](https://github.com/Krush206/etcsh)**: The authoritative sources for the shell engine underlying `mcsh`.
- **The Neovim Plugin Community**: Our native UI modules (finder, tree, statusline, etc.) were inspired by and built as tributes to community favorites like Telescope, nvim-tree, and Lualine.

## License
AGPL-3.0
