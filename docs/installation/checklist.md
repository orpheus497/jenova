# Jenova Installation Checklist

A comprehensive, step-by-step guide to installing Jenova on your system.

## Prerequisites

### Step 1: System Requirements
- [ ] Running a supported OS (FreeBSD 15+, Linux, or macOS)
- [ ] At least 20GB of free disk space (10GB for builds + 10GB for models)
- [ ] ~2 hours for first-time build (depends on CPU/GPU)
- [ ] Stable internet connection (for downloading models)

### Step 2: Pre-flight Checks
```bash
# Run comprehensive pre-installation verification
./scripts/preflight-check.sh --verbose

# If issues are found, attempt auto-fix:
./scripts/preflight-check.sh --fix
```

This verifies:
- ✓ Operating system compatibility
- ✓ Required dependencies (git, cmake, luajit, gettext, curl, vulkan)
- ✓ Disk space availability
- ✓ Network connectivity
- ✓ User permissions
- ✓ Git repository status

## Installation (4 Steps)

### Step 3: Clone & Prepare
```bash
# Clone the repository (already done if you're reading this)
git clone https://github.com/orpheus497/jenova
cd jenova
```

llama.cpp and other dependencies are now bundled in the repository's `external/` directory, so no further downloads are required.

### Step 4: Build Everything
```bash
# Full build: jvim + web UI + jenova-ui
make

# Or build individually:
make jvim               # Editor
make web                # Web UI (requires npm/Node.js)
make jenova-ui          # Desktop Manager

# Advanced users can build the backend from source:
make llama              # Inference backend (Vulkan)
make llama-hybrid       # Vulkan + CUDA (if multi-GPU)

# Clean and rebuild if needed:
make clean
make
```

**⏱️ Expected times:**
- jvim: 5-15 minutes
- web UI: 2-5 minutes (if npm available)

### Step 5: Deploy to System
```bash
# Standard installation (copies to ~/.local/bin, deploys config)
make install

# Or use custom install flags:
./scripts/install.sh --force          # Overwrite existing config
./scripts/install.sh --link           # Dev workflow (symlinks instead of copy)
./scripts/install.sh --skip-lsp       # Skip LSP server installation
./scripts/install.sh --client-only    # LAN client (no backend)
```

You can also run the full end-to-end workflow:
```bash
./scripts/install-complete.sh
```

> Note: `install-complete.sh` skips optional LSP installation by default.

Installation will:
- ✓ Check system dependencies
- ✓ Create runtime directories (~/.jenova, var/log, var/cache)
- ✓ Auto-detect and apply hardware profile
- ✓ Deploy jvim config to ~/.config/jvim/
- ✓ Install symlinks to PATH (~/.local/bin/)
- ✓ Attempt to install LSP servers, linters, formatters
- ✓ Display next-step instructions

### Step 6: Post-Installation Setup
```bash
# Verify installation succeeded
./scripts/verify-install.sh --full --verbose

# Download required AI models (interactive)
./scripts/model_dl.sh

# Auto-detect and apply hardware profile (Vulkan tuning, memory settings)
./hardware-profiles/detect-hardware.sh --info   # Show detected profile
./hardware-profiles/detect-hardware.sh --apply  # Apply profile config

# Run system tuning (requires sudo for kernel parameters)
sudo ./scripts/jenova-setup
```

**Model downloads (~5-10 GB):**
- Agent model (4-9B, Qwen3, Q8_0 quantization)
- Embedding model (0.6B, for semantic search)
- Draft model (optional, 0.5B, for speculative decoding)

## Launch

### Step 7: First Run
```bash
# Jenova Manager (Operational TUI)
jenova-tui

# Full environment (backend daemons + editor)
jenova
...
# Or just the editor (no backend management)
jvim

# Or just the backend (headless/server mode)
jenova-ca

# Server mode on LAN (listen on all interfaces)
jenova-ca --daemon --lan
```

## Verification

### Step 8: Verify Everything Works
```bash
# Check installation status
./scripts/verify-install.sh

# View hardware profile applied
cat etc/jenova.conf

# Check daemon health
jenova-ca status

# View logs
tail -f var/log/llama-server.log
tail -f var/log/proxy.log
```

## Configuration & Troubleshooting

### PATH Configuration
Ensure `~/.local/bin` is in your `$PATH`:
```bash
# Check if already in PATH
echo $PATH | grep -q ~/.local/bin && echo "OK" || echo "NOT SET"

# Add to shell config if needed
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc  # Bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # Zsh
```

### jvim Configuration Location
- **Config:** `~/.config/jvim/`
- **Plugins:** `~/.local/share/nvim/lazy/`
- **State:** `~/.local/state/nvim/` (undo, shada, chat history)

### Hardware Profile Issues
```bash
# List available profiles
./hardware-profiles/detect-hardware.sh --list

# Show detection details
./hardware-profiles/detect-hardware.sh --info

# Apply a specific profile manually
./scripts/jenova-setup --profile AMD/Ryzen
```

### Model Download Troubleshooting
```bash
# If downloads fail (network issues), manually try:
curl -L https://huggingface.co/... -o models/agent/model.gguf

# Or use Hugging Face CLI:
pip install huggingface-hub
huggingface-cli download Qwen/Qwen3.5-4B-GGUF \
  Qwen3.5-4B-Q6_K.gguf --local-dir models/agent
```

### Build Failures
```bash
# Common issues:
# 1. "No space left on device" — Clean up and try again:
make clean
df -h /tmp  # Ensure /tmp has space

# 2. Missing Vulkan headers (advanced builds only)
# Ubuntu: sudo apt install vulkan-headers
# Arch: sudo pacman -S vulkan-headers
# FreeBSD: pkg install vulkan-headers

# 3. NPM not found — Web UI build will be skipped (optional)
# Install Node.js if you want the Web UI

# 4. Permission errors on .git/
sudo chown -R $(id -u):$(id -g) .git
make clean && make
```

## Updates & Maintenance

### Updating Jenova
```bash
# Pull latest changes and rebuild
./scripts/update.sh

# Or customize the update:
./scripts/update.sh --upgrade-plugins  # Update Neovim plugins
./scripts/update.sh --apply-profile    # Re-apply hardware profile
```

### Uninstalling
```bash
# Remove installed files (preserves ~/.local/state/)
./scripts/uninstall.sh

# Also purge plugin data and Mason LSPs
./scripts/uninstall.sh --purge

# Also clean runtime artifacts and builds
./scripts/uninstall.sh --clean-runtime --clean-builds

# Non-interactive (skip confirmations)
./scripts/uninstall.sh --yes
```

## Support & Diagnostics

### System Status Report
```bash
# Generate diagnostic report
./scripts/preflight-check.sh --verbose
./scripts/verify-install.sh --full --verbose

# Check logs
ls -lh var/log/

# Monitor running processes
ps aux | grep -E 'jenova-ca|llama-server|proxy'

# Test network connectivity
curl -I http://localhost:8080/health
```

### Getting Help
- **Installation issues:** Run `./scripts/preflight-check.sh --verbose`
- **Build failures:** Check `var/log/` and `UPSTREAM-COPYRIGHT`
- **Runtime issues:** Check `~/.local/state/nvim/` for chat history
- **Hardware profile:** Run `./hardware-profiles/detect-hardware.sh --info`

## Next Steps After Installation

### Essential
1. ✓ Configure your hardware profile
2. ✓ Download AI models
3. ✓ Run system tuning (`sudo jenova-setup`)

### Recommended
1. Set `jvim` as your `$EDITOR`
2. Configure shell keybindings for Jenova CLI
3. Set up remote access if using LAN client mode

### Optional
1. Install additional LSP servers (`:Mason` in jvim)
2. Configure `.config/jvim/init.lua` for custom plugins
3. Set up GitHub integration (OAuth token in `.jenova/auth`)
4. Enable web search (API key in `.jenova/config`)
