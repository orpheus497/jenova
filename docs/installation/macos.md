# macOS Installation

Jenova on macOS supports Apple Silicon (Metal) and Intel Macs.
Metal is the preferred GPU backend on Apple Silicon; MoltenVK is available
as a Vulkan compatibility layer but is optional.

## System Dependencies

```sh
brew install cmake luajit gettext lua@5.4 curl git

# Optional (for Web UI and development tools)
brew install node shaderc llvm
```

> **Note:** Xcode Command Line Tools are required. Install with:
> `xcode-select --install`

## Quick Install

```sh
git clone https://github.com/orpheus497/jenova
cd jenova

# Verify dependencies
./scripts/preflight-check.sh --verbose

# Build everything
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
make llama          # llama.cpp with Metal support
make jvim           # Bundled Neovim hard-fork
make web            # Web UI (requires Node.js)
```

## Hardware Profiles

Two macOS profiles are available:

### `macOS/Metal/generic` — Apple Silicon GPU (recommended)

| Setting | Value |
|---------|-------|
| Model | Qwen3.5-4B Q6_K (~3.5 GiB) |
| Backend | Metal (full GPU offload via unified memory) |
| Context | 16K |
| Drafter | Enabled (speculative decoding) |

Best for M1/M2/M3/M4 Macs. Uses Metal for GPU acceleration with unified
memory — no VRAM limitations.

### `macOS/CPU/generic` — CPU-only (battery efficient)

| Setting | Value |
|---------|-------|
| Model | Qwen3.5-0.8B Q8 (~0.8 GiB) |
| Backend | CPU-only |
| Context | 8K |
| Drafter | Disabled |

Designed for maximum battery life. Uses a smaller model with half the thread
count and context window of the standard configurations.

### Apply a Profile

```sh
./hardware-profiles/detect-hardware.sh --info    # Show detection report
./hardware-profiles/detect-hardware.sh --apply   # Apply best-match profile
```

## Troubleshooting

### Homebrew not found
Install Homebrew first: <https://brew.sh>

### Vulkan not available on Apple Silicon
Apple Silicon uses **Metal** natively — Vulkan is not required. The `make llama`
target auto-detects Metal support. MoltenVK (`brew install molten-vk`) is only
needed if you specifically want the Vulkan backend.

### PATH not configured
If `jenova` is not found after install:
```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Build failures
Ensure Xcode Command Line Tools are installed:
```sh
xcode-select --install
```

## Limitations

- macOS support is **experimental** — FreeBSD and Linux are primary targets.
- Metal is strongly preferred over MoltenVK for performance.
- Some system tuning features (`jenova-setup`) may not apply on macOS
  (they target kernel parameters specific to FreeBSD/Linux).
