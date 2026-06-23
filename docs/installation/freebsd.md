# FreeBSD Installation

Jenova is primarily developed and optimized for FreeBSD 15.

## Quick Install

```sh
# 1. Install system dependencies (gmake is required to build jenova-ui)
pkg install luajit-openresty git gmake cmake vulkan-loader curl lua54 gettext-tools

# 2. Clone the repo
git clone https://github.com/orpheus497/jenova
cd jenova

# 3. Run a pre-flight check before building
./scripts/preflight-check.sh --verbose

# 4. Build everything: llama.cpp (Vulkan) + jenova-ui
make

# If you want the optional Web UI, install Node.js/npm and run:
# make web

# 5. Run the installer (hardware-aware)
# This deploys a standalone system to ~/JCA and symlinks to ~/.local/bin/
make install
```

You can also use the streamlined installation script:

```sh
./install-jenova.sh
```


## Manual Installation Steps

### 1. Build Components
You can build components individually if needed:
- `make llama` — build `llama.cpp` with Vulkan support (calls `bin/build-llama-jenova`).
- `make clean` — wipe build artifacts from all three subsystems.
- `make clean-root` — remove leftover artifacts in the repo root.

### 2. Run the Installer
`scripts/install.sh` handles the deployment. It supports several flags:

| Flag | Action |
|------|--------|
| `--force` | Overwrite existing config / symlinks; force jenova-ui rebuild. |
| `--skip-jenova-ui` | Skip building the bundled jenova-ui editor. |
| `--skip-llama` | Skip the llama.cpp build check. |
| `--skip-lsp` | Skip optional LSP server setup. |
| `--client-only` | LAN client install — implies `--skip-llama --skip-jenova-ui`; talks to a remote backend. |

### 3. Hardware Profile Deployment
After the main installation, you must configure your hardware profile:

```sh
# Auto-detect and show report
./hardware-profiles/detect-hardware.sh --info

# Apply the matched profile
./hardware-profiles/detect-hardware.sh --apply

# Run system tuning (requires sudo)
sudo scripts/jenova-setup
```

## AMD GPU Requirements
If using an AMD APU (e.g., Ryzen 7 5700U), install the kernel drivers:

```sh
pkg install drm-kmod gpu-firmware-amd-kmod
sysrc kld_list+=amdgpu
# Reboot, then verify
vulkaninfo --summary
```

## ZFS Tuning
For ZFS systems, it is recommended to cap the ARC to free up memory for LLM inference:
Add `vfs.zfs.arc_max=2147483648` (2 GiB) to `/etc/sysctl.conf`.
