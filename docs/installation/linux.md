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

### Fedora
Install the following using `dnf`:

```bash
sudo dnf groupinstall "Development Tools"
sudo dnf install -y \
    cmake \
    git \
    luajit \
    lua-devel \
    libcurl-devel \
    openssl-devel \
    gettext \
    vulkan-loader-devel \
    vulkan-tools \
    glslc
```

## Build Instructions

1.  **Clone the repository** (no submodules — `llama.cpp` is fetched separately):
    ```bash
    git clone https://github.com/orpheus497/jenova
    cd jenova
    ```

2.  **Pull `llama.cpp`** into `./llama.cpp` (idempotent — clones or pulls):
    ```bash
    scripts/llama_dl.sh
    ```

3.  **Build everything** (or build subsystems individually):
    ```bash
    make            # llama.cpp + jvim + mcsh
    # or
    make llama      # just the inference backend (Vulkan)
    make llama-hybrid # build for BOTH Vulkan and CUDA (multi-GPU)
    make jvim       # just the editor
    make mcsh       # just the Modern C Shell
    ```

    *Use `make llama-hybrid` if you have both an NVIDIA and an AMD/Intel GPU, or if you want to switch between backends without rebuilding.*

4.  **Run the installer**:
    ```bash
    make install
    ```

5.  **Apply your hardware profile** and run system tuning:
    ```bash
    ./hardware-profiles/detect-hardware.sh --info
    ./hardware-profiles/detect-hardware.sh --apply
    sudo scripts/jenova-setup
    ```

## Post-Installation

### PATH Configuration
Ensure `~/.local/bin` is in your `PATH`. Add this to your `.bashrc` or `.zshrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### jvim Configuration
The deployed config lives at `~/.config/jvim/`. The `jvim` launcher sets
`NVIM_APPNAME=jvim` and prefers `jvim/build/bin/nvim` (the in-tree fork) over
any system `nvim` on `PATH`.

### Installing `mcsh` as a login shell (optional)
After `make install`, the bundled Modern C Shell is at `bin/mcsh`. To use it
as your login shell:
```bash
sudo cp bin/mcsh /usr/local/bin/mcsh
sudo ln -sf /usr/local/bin/mcsh /usr/local/bin/tcsh   # legacy compat
echo /usr/local/bin/mcsh | sudo tee -a /etc/shells
chsh -s /usr/local/bin/mcsh
```

## Troubleshooting

### "No space left on device" during link
The linker may use `/tmp` or `/dev/shm`. Ensure you have enough free space (at least 2-4GB) on these partitions during the build, or increase your swap space if using a memory-backed `/tmp`.

### missing `spirv.hpp`
If `llama.cpp` fails to build with a missing `spirv.hpp` error, ensure `spirv-headers` is installed. On Arch, it provides `/usr/include/spirv/unified1/spirv.hpp`.
