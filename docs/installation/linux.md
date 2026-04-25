# Linux Installation Guide

Jenova is optimized for FreeBSD 15, but it is fully functional on Linux (tested on Arch Linux and Debian/Ubuntu).

## Required Packages

### Arch Linux
Install the following using `pacman`:

```bash
sudo pacman -S --needed \
    base-devel \
    cmake \
    git \
    luajit \
    lua54 \
    curl \
    gettext \
    vulkan-headers \
    vulkan-icd-loader \
    spirv-headers \
    vulkan-utility-libraries \
    shaderc
```

### Debian / Ubuntu
Install the following using `apt`:

```bash
sudo apt update
sudo apt install -y \
    build-essential \
    cmake \
    git \
    luajit \
    liblua5.4-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    gettext \
    vulkan-tools \
    libvulkan-dev \
    glslc
```

## Build Instructions

1.  **Clone the repository recursively**:
    ```bash
    git clone --recursive https://github.com/orpheus497/jenova
    cd jenova
    ```

2.  **Initialize llama.cpp** (if not already present):
    ```bash
    git clone https://github.com/ggml-org/llama.cpp.git
    ```

3.  **Build components**:
    ```bash
    make llama
    make jvim
    ```

4.  **Run the installer**:
    ```bash
    make install
    ```

## Post-Installation

### PATH Configuration
Ensure `~/.local/bin` is in your `PATH`. Add this to your `.bashrc` or `.zshrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### jvim Configuration
If you prefer standard Neovim paths, the config lives in `~/.config/jvim/`. The `jvim` launcher is configured to use this path by setting `NVIM_APPNAME=jvim`.

## Troubleshooting

### "No space left on device" during link
The linker may use `/tmp` or `/dev/shm`. Ensure you have enough free space (at least 2-4GB) on these partitions during the build, or increase your swap space if using a memory-backed `/tmp`.

### missing `spirv.hpp`
If `llama.cpp` fails to build with a missing `spirv.hpp` error, ensure `spirv-headers` is installed. On Arch, it provides `/usr/include/spirv/unified1/spirv.hpp`.
