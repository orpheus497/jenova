# Linux Installation

Jenova supports all major Linux distributions (Arch, Debian/Ubuntu, Fedora, NixOS).

## Quick Install

```sh
# 1. Install system dependencies (build-essential, cmake, luajit, vulkan-loader)
# Use your package manager (apt, pacman, dnf)

# 2. Clone the repo
git clone https://github.com/orpheus497/jenova
cd jenova

# 3. Run a pre-flight check before building
./scripts/preflight-check.sh --verbose

# 4. Build everything: llama.cpp (Vulkan) + jvim + mcsh
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
- `make llama` — build `llama.cpp` with Vulkan support.
- `make jvim` — build the bundled Neovim hard-fork.
- `make mcsh` — build the Modern C Shell.

### 2. Run the Installer
`scripts/install.sh` handles deployment to `~/Jenova` and symlinking to `~/.local/bin`.

### 3. Hardware Profile
```sh
./hardware-profiles/detect-hardware.sh --apply
sudo scripts/jenova-setup
```
