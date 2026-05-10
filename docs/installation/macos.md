# macOS Installation

Jenova is supported on macOS via Homebrew. It is tested primarily on Apple Silicon (M1/M2/M3) but should function on Intel Macs with a compatible backend.

## Required Packages

Install the following using `brew`:

```bash
brew install \
    cmake \
    git \
    luajit \
    lua@5.4 \
    curl \
    gettext \
    molten-vk \
    shaderc
```

## Build Instructions

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/orpheus497/jenova
    cd jenova
    ```

2.  **Pull `llama.cpp`**:
    ```bash
    scripts/llama_dl.sh
    ```

3.  **Run a pre-flight check** before building:
    ```bash
    ./scripts/preflight-check.sh --verbose
    ```

4.  **Build everything**:
    ```bash
    make
    ```
    *Note: On macOS, `make` will build `llama.cpp` with Metal support by default unless Vulkan/MoltenVK is explicitly requested in `bin/build-llama-jenova`.*

    If you want the optional Web UI, install Node.js/npm and run `make web`.

5.  **Run the installer**:
    ```bash
    ./scripts/install.sh
    ```

    Or use the combined workflow:
    ```bash
    ./scripts/install-complete.sh
    ```

    > Note: `install-complete.sh` skips optional LSP installation by default.

## Post-Installation

### PATH Configuration
Ensure `~/.local/bin` is in your `PATH`. Add this to your `.zshrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Metal vs Vulkan
By default, Jenova on macOS utilizes the Metal backend for optimal performance on Apple Silicon. If you specifically require Vulkan (via MoltenVK), ensure `JENOVA_BACKEND=vulkan` is set during the build or in your `etc/jenova.conf`.

## Troubleshooting

### "molten-vk" not found
If `molten-vk` is not found, ensure it is linked correctly:
```bash
brew link molten-vk
```

### Missing `gettext`
If `msgfmt` is missing during the `jvim` build, ensure `gettext` is in your PATH:
```bash
export PATH="/usr/local/opt/gettext/bin:$PATH"  # Intel
export PATH="/opt/homebrew/opt/gettext/bin:$PATH"  # Apple Silicon
```
