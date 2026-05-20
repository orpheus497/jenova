# macOS Installation

Jenova on macOS is experimental but supports Apple Silicon (Metal) and Intel (Vulkan/MoltenVK).

## Quick Install

```sh
# 1. Install dependencies (Homebrew)
brew install cmake luajit vulkan-loader molten-vk

# 2. Clone the repo
git clone https://github.com/orpheus497/jenova
cd jenova

# 3. Run a pre-flight check before building
./scripts/preflight-check.sh --verbose

# 4. Build everything
make

# 5. Run the installer
make install
```

You can also use the streamlined installation script:

```sh
./install-jenova.sh
```

## Manual Installation Steps

### 1. Build Components
- `make llama` — build `llama.cpp` with Metal/Vulkan support.
- `make jvim` — build the bundled Neovim hard-fork.
- `make mcsh` — build the Modern C Shell.

### 2. Run the Installer
`scripts/install.sh` handles deployment to `~/Jenova` and symlinking to `~/.local/bin`.
