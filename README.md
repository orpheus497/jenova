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

## License
AGPL-3.0
