# FreeBSD Installation

Jenova is primarily developed and optimized for FreeBSD 15.

## Quick Install

```sh
# 1. Install system dependencies
pkg install luajit-openresty git cmake vulkan-loader curl lua54 gettext-tools

# 2. Clone (recursive — pulls llama.cpp submodule)
git clone --recursive https://github.com/orpheus497/jenova
cd jenova

# 3. Build everything
make

# 4. Run the installer (hardware-aware)
make install
```

## Manual Installation Steps

### 1. Build Components
You can build components individually if needed:
- `make llama`: Build llama.cpp with Vulkan support.
- `make jvim`: Build the bundled Neovim hard-fork.

### 2. Run the Installer
`scripts/install.sh` handles the deployment. It supports several flags:

| Flag | Action |
|---|---|
| `--force` | Overwrite existing config/symlinks; force jvim rebuild |
| `--link` | Install nvim config as symlinks (dev workflow) |
| `--skip-nvim` | Skip deploying config to `~/.config/nvim/` |
| `--skip-jvim` | Skip building the bundled jvim editor |
| `--client-only` | LAN client install (no local backend/models) |

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
