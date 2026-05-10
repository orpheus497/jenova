# Jenova Installation Guide (Streamlined)

This guide walks through the complete installation process with all quality checks, verifications, and best practices built in.

## Quick Start (5 Steps)

### 1. Clone and Install
```bash
git clone https://github.com/orpheus497/jenova
cd jenova

# Intelligent one-command installation
./install-jenova.sh
```

**What it does:**
- ✓ Detects your OS and package manager automatically
- ✓ Installs all required system dependencies
- ✓ Builds Jenova components (llama.cpp, jvim, mcsh, Web UI)
- ✓ Deploys to your system (~/.local/bin/, ~/.config/jvim/)
- ✓ Downloads AI models (~5-10GB)
- ✓ Verifies everything works

### Advanced Installation Options
```bash
# Dry run (see what would be installed)
./install-jenova.sh --dry-run

# Minimal install (no Web UI, no models)
./install-jenova.sh --minimal

# Full install with everything
./install-jenova.sh --full
```

### Legacy Installation (Manual)

For a fully automated, end-to-end installation:

```bash
# All-in-one: checks → build → deploy → verify
./scripts/install-complete.sh

# With options:
./scripts/install-complete.sh --skip-web      # Skip Web UI build
./scripts/install-complete.sh --skip-models   # Skip model downloads
./scripts/install-complete.sh --no-verify     # Skip verification
./scripts/install-complete.sh --force         # Overwrite config
```

> Note: `install-complete.sh` deploys the install with `--skip-lsp` by default,
> so optional language server installation is not performed in the one-command
> flow.

This is equivalent to:
1. `./scripts/preflight-check.sh`
2. `make clean && make`
3. `make install`
4. `./scripts/model_dl.sh`
5. `./scripts/verify-install.sh --full`

## Post-Installation Setup

### Download AI Models
```bash
# Interactive model selection (required for inference)
./scripts/model_dl.sh

# Or manually download specific models:
curl -L https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/qwen3-4b-instruct-q8_0.gguf \
  -o models/agent/Qwen3-Instruct-4B-Q8_0.gguf

# Expected downloads: ~5-10 GB total
# - Agent model (4-9B) → models/agent/
# - Embedding model (0.6B) → models/embed/
# - Draft model (optional, 0.5B) → models/draft/
```

### Apply Hardware Profile
```bash
# Auto-detect your GPU and apply optimizations
./hardware-profiles/detect-hardware.sh --info   # Show detection
./hardware-profiles/detect-hardware.sh --apply  # Apply profile

# Or manually apply a specific profile:
./scripts/jenova-setup --profile AMD/Ryzen
./scripts/jenova-setup --profile Intel/Arc
./scripts/jenova-setup --profile Vulkan
```

### Run System Tuning (Optional but Recommended)
```bash
# Apply kernel parameters, memory tuning, etc. (requires sudo)
sudo ./scripts/jenova-setup

# This may set:
# - Kernel memory limits
# - ZFS ARC cache size (if applicable)
# - Swap configuration
# - GPU memory allocation
```

### Verify Everything Works
```bash
# Check installation status
./scripts/verify-install.sh --full

# View applied configuration
cat etc/jenova.conf

# Check daemon health
jenova-ca status

# Monitor logs
tail -f var/log/llama-server.log
tail -f var/log/proxy.log
```

## Launch Jenova

### First Run
```bash
# Full environment (backend + editor)
jenova

# Or just the editor (no daemon management)
jvim

# Or just the backend (headless/server)
jenova-ca

# Server on LAN (accessible from other hosts)
jenova-ca --host 0.0.0.0
```

### After First Run
```bash
# Check if PATH is correct
which jvim
which jenova
which jenova-ca

# Verify backend status
curl http://localhost:8080/v1/models

# View chat history and state
~/.local/state/nvim/
```

## Troubleshooting

### Build Issues
```bash
# Run pre-flight checks to identify issues
./scripts/preflight-check.sh --verbose

# Common issues:
# 1. No space: df -h && make clean
# 2. Permission denied: sudo chown -R $(id) .
# 3. Vulkan not found: install vulkan-loader / molten-vk / vulkan-icd-loader
# 4. npm not found: apt install npm  (Web UI will be skipped)
```

### Installation Issues
```bash
# Check install logs
tail -f var/log/install.log

# Verify individual components
./scripts/verify-install.sh --verbose

# Re-run installation with verbose output
./scripts/install.sh --force
```

### Runtime Issues
```bash
# Check daemon status
jenova-ca status

# Monitor logs
tail -f var/log/llama-server.log
tail -f var/log/proxy.log
tail -f var/log/jenova-ca.log

# Test connectivity
curl http://localhost:8080/health
curl http://localhost:8081/health
curl http://localhost:8082/health
```

### Model Download Issues
```bash
# If automatic download fails:
./scripts/model_dl.sh

# Or use Hugging Face CLI:
pip install huggingface-hub
huggingface-cli download Qwen/Qwen3-4B-GGUF qwen3-4b-instruct-q8_0.gguf \
  --local-dir models/agent
```

## Configuration

### PATH Setup
```bash
# Ensure ~/.local/bin is in PATH
echo $PATH | grep -q ~/.local/bin && echo "OK" || echo "MISSING"

# Add to shell config:
export PATH="$HOME/.local/bin:$PATH"  # .bashrc / .zshrc
setenv PATH "$HOME/.local/bin:$PATH"  # .tcshrc / .mcshrc
```

### Config Locations
| Item | Location |
|------|----------|
| **jvim config** | `~/.config/jvim/` |
| **Plugins** | `~/.local/share/nvim/lazy/` |
| **User state** | `~/.local/state/nvim/` |
| **Runtime logs** | `$JENOVA_ROOT/var/log/` |
| **Models** | `$JENOVA_ROOT/models/` |
| **Project config** | `$JENOVA_ROOT/etc/jenova.conf` |

### Hardware Profile
```bash
# View current profile
cat etc/jenova.conf

# Show available profiles
./hardware-profiles/detect-hardware.sh --list

# Re-apply a profile
./scripts/jenova-setup --profile AMD/Ryzen7-5700U
```

## Updates & Maintenance

### Updating
```bash
# Pull latest code and rebuild
./scripts/update.sh

# With options:
./scripts/update.sh --upgrade-plugins   # Update nvim plugins
./scripts/update.sh --apply-profile     # Re-apply hardware profile
./scripts/update.sh --skip-rebuild      # Skip llama.cpp rebuild
```

### Uninstalling
```bash
# Remove installed files (preserves user data)
./scripts/uninstall.sh

# Also purge plugins and Mason LSPs:
./scripts/uninstall.sh --purge

# Also clean runtime artifacts:
./scripts/uninstall.sh --clean-runtime --clean-builds

# Non-interactive:
./scripts/uninstall.sh --yes
```

## Need Help?

1. **Pre-installation:** Run `./scripts/preflight-check.sh --verbose`
2. **Post-installation:** Run `./scripts/verify-install.sh --full --verbose`
3. **Hardware issues:** Run `./hardware-profiles/detect-hardware.sh --info`
4. **Build failures:** Check `var/log/` and `UPSTREAM-COPYRIGHT` for upstream issues
5. **Runtime problems:** Check daemon logs and `jenova-ca status`

## Next Steps

- [ ] Download AI models: `./scripts/model_dl.sh`
- [ ] Apply hardware profile: `./hardware-profiles/detect-hardware.sh --apply`
- [ ] Run system tuning: `sudo ./scripts/jenova-setup`
- [ ] Set jvim as editor: `export EDITOR=jvim`
- [ ] Launch Jenova: `jenova`

---

**Happy coding!** 🚀

Questions? Check the docs:
- [Installation Checklist](checklist.md) — Step-by-step walkthrough
- [Dependencies](dependencies.md) — Detailed package lists
- [Architecture](../architecture/) — How Jenova works
- [Usage](../usage/) — How to use Jenova
