## **✨ The Monorepo Strategy: Building Jenova as a Unified Terminal IDE**

This is **actually a brilliant idea** and solves many of the architectural issues I identified. Let me break down why this works and how to execute it:

---

## **🎯 Why This Makes Sense**

### **1. Eliminates the "Documentation vs. Reality" Gap**
Right now, your README says "three repositories" but `jenova-cli` is already dead and rewritten as `cli-agent/` inside jenova. **Merging jvim completes the unification** — everything is in one place.

### **2. Single Build System**
Currently:
- `jenova/` has its own install.sh + hardware detection + llama.cpp build
- `jvim/` has its own CMake build system + dependency management

**After merge**: One unified `make` command that:
1. Detects hardware (existing `detect-hardware.sh`)
2. Builds llama.cpp with the right flags (existing `bin/build-llama-jenova`)
3. Builds jvim with bundled Lua modules
4. Builds cli-agent
5. Deploys everything to `~/.local/bin/`

### **4. Simplifies Installation**
**Current (confusing)**:
```sh
# Install backend
git clone https://github.com/orpheus497/jenova
cd jenova && ./scripts/install.sh

# Install editor (separate repo)
git clone https://github.com/orpheus497/jvim
cd jvim && make && sudo make install
```

**After merge (clean)**:
```sh
git clone https://github.com/orpheus497/jenova
cd jenova && ./scripts/install.sh --full
# ☝️ Builds llama.cpp, cli-agent, jvim, and wires them together
```

---

## **📐 Proposed Directory Structure**

```
orpheus497/jenova/
├── bin/
│   ├── jenova-ca              # Daemon supervisor (existing)
│   ├── jenova                 # CLI agent wrapper (existing)
│   └── jvim                   # Editor wrapper (existing)
│
├── jenova-cli/                 # C + Lua 5.4 terminal agent (existing)
│   ├── src/                   # C service layer
│   ├── lua/                   # Lua agent logic
│   └── Makefile
│
├── jvim/                      # ← NEW: jvim fork moved here
│   ├── src/nvim/              # C editor core
│   ├── runtime/               # Lua modules, docs, colorschemes
│   │   ├── lua/jvim/          # Native UI modules (finder, tree, statusline)
│   │   └── lua/jenova/        # Jenova integration (existing nvim/ config)
│   ├── CMakeLists.txt         # jvim build config
│   └── build/                 # Build artifacts (gitignored)
│
├── llama.cpp/                 # llama.cpp submodule (existing)
│
├── lib/                       # LuaJIT proxy, FFI defs (existing)
│   ├── proxy.lua
│   ├── ffi_defs.lua
│   └── jenova-model.sh
│
├── etc/                       # Runtime config (existing)
│   └── jenova.conf
│
├── hardware-profiles/         # Hardware detection (existing)
│   └── detect-hardware.sh
│
├── scripts/
│   ├── install.sh             # ← UPDATED: unified installer
│   ├── jenova-setup           # System tuning (existing)
│   └── build-jvim.sh          # ← NEW: jvim build wrapper
│
├── models/                    # GGUF files (existing)
│   ├── agent/
│   ├── embed/
│   └── draft/
│
├── Makefile                   # ← NEW: top-level build orchestration
└── README.md                  # ← UPDATED: single-repo docs
```

---

## **🔧 How to Execute the Merge**

### **Phase 1: Move jvim into jenova**

### **Phase 2: Unified Build System**

Create `Makefile` at the root:

```makefile name=Makefile
# Jenova Cognitive Architecture — Unified Build System
# Builds llama.cpp, jvim, and cli-agent with hardware-aware configuration

.PHONY: all deps llama jvim cli-agent install clean help

# Detect hardware and load config
JENOVA_ROOT := $(shell pwd)
HARDWARE_PROFILE := $(shell ./hardware-profiles/detect-hardware.sh)

all: deps llama jvim cli-agent
	@echo "✅ Jenova build complete"
	@echo "   Run: ./scripts/install.sh to deploy"

deps:
	@echo "🔍 Detecting hardware..."
	./hardware-profiles/detect-hardware.sh --info
	./hardware-profiles/detect-hardware.sh --apply

llama: deps
	@echo "🔨 Building llama.cpp (Vulkan)..."
	./bin/build-llama-jenova

jvim: deps
	@echo "🔨 Building jvim..."
	cd jvim && \
	  cmake -B build -G Ninja \
	    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
	    -DCMAKE_INSTALL_PREFIX=$(JENOVA_ROOT)/jvim/install && \
	  cmake --build build --target jvim -j$(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

cli-agent: deps
	@echo "🔨 Building cli-agent..."
	cd cli-agent && $(MAKE)

install: all
	./scripts/install.sh --unified

clean:
	rm -rf llama.cpp/build jvim/build cli-agent/build
	rm -f bin/jvim bin/jenova bin/jenova-ca

help:
	@echo "Jenova Cognitive Architecture — Build Targets"
	@echo ""
	@echo "  make all         - Build everything (llama.cpp + jvim + cli-agent)"
	@echo "  make llama       - Build llama.cpp only"
	@echo "  make jvim        - Build jvim editor only"
	@echo "  make cli-agent   - Build CLI agent only"
	@echo "  make install     - Install binaries to ~/.local/bin/"
	@echo "  make clean       - Remove build artifacts"
```

### **Phase 3: Update install.sh**

Modify `scripts/install.sh` to build jvim:

```bash name=scripts/install.sh
#!/bin/sh
# Jenova Cognitive Architecture — Unified Installer
# Builds and installs llama.cpp, jvim, cli-agent as a single system

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$JENOVA_ROOT"

# ... (existing hardware detection code) ...

# ---------------------------------------------------------------------------
# Step 1: Detect hardware and deploy config
# ---------------------------------------------------------------------------
info "Detecting hardware..."
./hardware-profiles/detect-hardware.sh --apply

# ---------------------------------------------------------------------------
# Step 2: Build llama.cpp
# ---------------------------------------------------------------------------
if [ "$SKIP_LLAMA" = "0" ]; then
    info "Building llama.cpp..."
    ./bin/build-llama-jenova
fi

# ---------------------------------------------------------------------------
# Step 3: Build jvim (NEW)
# ---------------------------------------------------------------------------
if [ "$SKIP_JVIM" = "0" ]; then
    info "Building jvim..."
    cd jvim
    cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX="$JENOVA_ROOT/jvim/install"
    cmake --build build --target jvim -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    cd "$JENOVA_ROOT"
    ok "jvim built successfully"
fi

# ---------------------------------------------------------------------------
# Step 4: Build cli-agent
# ---------------------------------------------------------------------------
info "Building cli-agent..."
cd cli-agent && make && cd "$JENOVA_ROOT"

# ---------------------------------------------------------------------------
# Step 5: Symlink binaries to PATH
# ---------------------------------------------------------------------------
info "Installing binaries..."
_BIN_DIR="$HOME/.local/bin"
mkdir -p "$_BIN_DIR"

# Symlink jvim binary
ln -sf "$JENOVA_ROOT/jvim/build/bin/jvim" "$_BIN_DIR/jvim"
ln -sf "$JENOVA_ROOT/bin/jenova" "$_BIN_DIR/jenova"
ln -sf "$JENOVA_ROOT/bin/jenova-ca" "$_BIN_DIR/jenova-ca"

ok "Installed jvim, jenova, jenova-ca to $(_BIN_DIR)"

# ---------------------------------------------------------------------------
# Step 6: Deploy jvim runtime config
# ---------------------------------------------------------------------------
info "Deploying jvim configuration..."
# Copy jvim/runtime/lua/jenova/* → ~/.config/jvim/lua/jenova/
# (This is the Jenova integration layer)
# ...
```

### **Phase 4: Branding & Naming**


**Option A: Keep `jvim` as the editor binary**
```sh
jvim myfile.lua          # Opens editor
jenova "Refactor this"   # Runs CLI agent
jenova-ca --daemon       # Starts backend
```

---

## **📚 Updated README Structure**

```markdown name=README.md
# Jenova Cognitive Architecture

**A FreeBSD-first, hardware-aware local AI coding environment powered by llama.cpp, LuaJIT, and jvim.**

Jenova is a **unified terminal IDE** consisting of:
- **jvim** — Neovim-based editor with native UI and Jenova integration
- **jenova-cli** — C + Lua 5.4 agentic assistant with 43 tools
- **jenova-ca** — Daemon supervisor for llama-server + intelligence proxy
- **llama.cpp** — Vulkan/CUDA/Metal inference backend

---

## Installation

```sh
git clone https://github.com/orpheus497/jenova
cd jenova
make          # Builds llama.cpp + jvim + cli-agent
make install  # Installs to ~/.local/bin/
```

Or use the interactive installer:
```sh
./scripts/install.sh
```

---

## Components

### jvim (Editor)
A Neovim fork with:
- **Native UI modules** (no telescope/nvim-tree/lualine dependencies)
- Deep Jenova integration (`:JenovaChat`, `:JenovaMonitor`)
- Bundled treesitter parsers + LSP configs

```sh
jvim myfile.lua
```

### jenova-cli (Terminal Agent)
A C-based agentic assistant with:
- 43 built-in tools (Edit, Read, Grep, Shell, LocalSearch)
- Plan→Execute→Reflect loop
- Sandbox with interactive permission prompts

```sh
jenova "Refactor all error handling to use Result<T>"
```

### jenova-ca (Backend Daemon)
Manages:
- `llama-server` (port 8081) — main inference
- `proxy.lua` (port 8080) — RAG + intent routing
- `llama-server --embedding` (port 8082) — semantic search

```sh
jenova-ca --daemon
jenova-ca status
```

---

## Hardware Profiles

Jenova auto-detects your hardware and optimizes for:
- Dual-GPU (NVIDIA + Intel)
- Single-GPU (NVIDIA/AMD/Intel)
- CPU-only
- Optane-backed swap (for 7B models on 4GB VRAM)

```sh
./hardware-profiles/detect-hardware.sh --info   # Show detected hardware
./hardware-profiles/detect-hardware.sh --apply  # Deploy optimized config
sudo ./scripts/jenova-setup                     # One-time system tuning
```

See [`hardware-profiles/`](hardware-profiles/) for details.

---

## Architecture

```
┌─────────────────────────────────────────┐
│  jvim (Editor Frontend)                 │
│  - Native UI (finder, tree, statusline) │
│  - Jenova chat integration              │
│  - FIM completions (llama.vim)          │
└──────────────┬──────────────────────────┘
               │ HTTP (port 8080/8081)
┌──────────────▼──────────────────────────┐
│  jenova-ca (Backend Daemon)             │
│  ├─ llama-server (8081)                 │
│  ├─ proxy.lua (8080) — RAG + routing    │
│  └─ embedding server (8082)             │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  jenova-cli (Terminal Agent)             │
│  - C service layer + Lua query engine   │
│  - 43 tools, sandbox, permission gate   │
└─────────────────────────────────────────┘
```

---

## Building from Source

```sh
# 1. Clone
git clone --recursive https://github.com/orpheus497/jenova
cd jenova

# 2. Install dependencies (FreeBSD example)
pkg install luajit-openresty cmake neovim vulkan-loader curl lua54

# 3. Build
make all

# 4. Install
make install
```

See [`BUILD.md`](BUILD.md) for platform-specific instructions.

---

## License
jvim — a hard fork of Neovim purpose-built for the Jenova Cognitive
Architecture.

Copyright © 2025 orpheus497.

This software consists of:

1. CODE INHERITED FROM NEOVIM (Apache 2.0):
   - All code in src/nvim/ not marked "jvim-specific"
   - Licensed under Apache License, Version 2.0
   - Copyright Neovim contributors
   - See full Apache 2.0 license below

2. JVIM-SPECIFIC CODE (AGPL-3.0):
   - All files under runtime/lua/jvim/
   - All jvim branding, dashboard, native UI modules
   - Licensed under GNU Affero General Public License v3.0
   - Copyright © 2025 orpheus497
   - See full AGPL-3.0 license below

THE COMBINED WORK IS DISTRIBUTED UNDER AGPL-3.0.
Users must comply with both Apache 2.0 attribution requirements
AND AGPL-3.0 network service provisions.

======================================================================
APACHE LICENSE 2.0 (Neovim Upstream Code)
======================================================================
[... full Apache 2.0 text ...]

======================================================================
GNU AFFERO GENERAL PUBLIC LICENSE v3.0 (jvim Contributions)
======================================================================
[... full AGPL-3.0 text ...]
```

---

## **🚀 Benefits Summary**

| Aspect | Before (2 repos) | After (monorepo) |
|--------|------------------|------------------|
| **Installation** | Clone 2 repos, build separately | `make && make install` |
| **Documentation** | Stale (references dead `jenova-cli` submodule) | Single source of truth |
| **Fork justification** | Weak (just bundled plugins) | Strong (official Jenova IDE) |
| **CI/Testing** | 2 separate pipelines | Unified tests, one build matrix |
| **Version sync** | Manual (jvim version ≠ jenova version) | Single version number |
| **User confusion** | "Which repo do I clone?" | One repo, one install command |

---
---
## **✅ Final Recommendation**

**Do it.** Merge jvim into jenova as `jenova/jvim/`.

**Why**:
1. **Aligns with reality** — jvim is already tightly coupled to Jenova (the nvim/ config is in jenova repo)
2. **Simplifies the story** — "Jenova is a terminal IDE" is clearer than "Jenova is 3 repos"
3. **Reduces maintenance** — one CI pipeline, one installer, one version number
4. **Justifies the fork** — jvim becomes "the Jenova editor", not "a Neovim fork with some plugins"

**What to rename**:
- Keep the binary as `jvim` (already established)
- Rename the repo from "jvim" → "jenova" (already done)
- Brand it as **"Jenova Terminal IDE 
