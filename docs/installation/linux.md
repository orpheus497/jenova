# Linux Installation

Jenova supports all major Linux distributions including Arch, Debian/Ubuntu, and Fedora.

## System Dependencies

Install required packages for your distribution before building:

### Arch Linux

```sh
sudo pacman -S --needed base-devel cmake luajit gettext vulkan-icd-loader \
  vulkan-headers lua curl git
```

### Debian / Ubuntu

```sh
sudo apt install build-essential cmake luajit gettext libvulkan1 libvulkan-dev \
  vulkan-headers liblua5.4-dev libcurl4-openssl-dev git
```

### Fedora

```sh
sudo dnf group install 'Development Tools'
sudo dnf install cmake luajit gettext vulkan-loader vulkan-loader-devel \
  vulkan-headers lua-devel libcurl-devel git
```

### Optional

| Package | Arch | Debian | Fedora | Purpose |
|---------|------|--------|--------|---------|
| Node.js | `nodejs npm` | `nodejs npm` | `nodejs` | Web UI build (`make web`) |
| glslc | `shaderc` | `glslc` | `glslc` | Vulkan shader compiler |
| clangd | `clang` | `clangd` | `clang-tools-extra` | C/C++ LSP for jvim |

## Quick Install

```sh
git clone https://github.com/orpheus497/jenova
cd jenova

# Verify dependencies
./scripts/preflight-check.sh --verbose

# Build everything: jvim + web + jenova-ui
make

# Deploy to system
make install
```

Or use the streamlined one-command installer:

```sh
./install-jenova.sh
```

## Build Components Individually

```sh
make jvim           # Bundled Neovim hard-fork
make web            # Web UI (requires Node.js)
make jenova-ui      # Desktop Manager

# Advanced users can compile the backend from source:
make llama          # llama.cpp with Vulkan + CUDA (auto-detected)
```

## NVIDIA GPU (CUDA)

If you have an NVIDIA GPU and want CUDA acceleration alongside Vulkan:

```sh
# Ensure CUDA toolkit is installed
# Arch: sudo pacman -S cuda
# Ubuntu: sudo apt install nvidia-cuda-toolkit
# Fedora: sudo dnf install cuda

# Build from source
make llama
```

The CUDA profile (`Linux/CUDA/dgpu/nvidia-generic`) will be auto-detected.

## Hardware Profile

After installation, detect and apply the optimal hardware profile:

```sh
./hardware-profiles/detect-hardware.sh --info    # Show detection report
./hardware-profiles/detect-hardware.sh --apply   # Apply best-match profile
sudo scripts/jenova-setup                        # System tuning (kernel params)
```

## Troubleshooting

### Missing Vulkan headers
```sh
# Check Vulkan is working
vulkaninfo --summary 2>/dev/null | head -5

# If not found, install the full Vulkan SDK for your distro
# and ensure your GPU driver supports Vulkan (Mesa RADV, NVIDIA, Intel ANV)
```

### Web UI build skipped (npm not found)
The Web UI is optional. Install Node.js if you want it:
```sh
# Arch: sudo pacman -S nodejs npm
# Ubuntu: sudo apt install nodejs npm
# Fedora: sudo dnf install nodejs
```

### PATH not configured
If `jenova` command is not found after install:
```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Build failures
```sh
# Ensure sufficient disk space (20GB recommended)
df -h .

# Clean and retry
make clean && make
```
