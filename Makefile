# Jenova Cognitive Architecture — Unified Build System
#
# Builds the three components that make up Jenova as a single terminal IDE:
#   1. llama.cpp        — Vulkan-accelerated inference backend
#   2. cli-agent        — C + Lua 5.4 terminal agent (`jenova` binary)
#   3. jvim             — Neovim-based editor (`jvim` binary, in-tree fork)
#
# All targets are self-contained: nothing relies on system-installed nvim or
# a separately cloned jvim repository. The bundled jvim/ tree is the canonical
# source for the editor.
#
# Common usage:
#   make            # Build everything (llama.cpp + cli-agent + jvim)
#   make jvim       # Build only the bundled jvim editor
#   make cli-agent  # Build only the cli-agent
#   make llama      # Build only llama.cpp
#   make install    # Run scripts/install.sh (system-aware deploy)
#   make clean      # Remove build artifacts from all three components

.PHONY: all llama cli-agent jvim install clean help

JENOVA_ROOT := $(CURDIR)
JOBS        := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

all: llama cli-agent jvim
	@echo ""
	@echo "✅ Jenova build complete (llama.cpp + cli-agent + jvim)"
	@echo "   Run 'make install' (or scripts/install.sh) to deploy."

llama:
	@echo "🔨 Building llama.cpp (Vulkan)..."
	@./bin/build-llama-jenova

cli-agent:
	@echo "🔨 Building cli-agent..."
	@$(MAKE) -C cli-agent

jvim:
	@echo "🔨 Building jvim (in-tree editor)..."
	@if [ ! -f jvim/CMakeLists.txt ]; then \
		echo "ERROR: jvim/ source tree missing." >&2; exit 1; \
	fi
	@$(MAKE) -C jvim \
		CMAKE_BUILD_TYPE=RelWithDebInfo \
		CMAKE_INSTALL_PREFIX="$(JENOVA_ROOT)/jvim/install"
	@echo "   jvim built: jvim/build/bin/nvim"

install:
	@./scripts/install.sh

clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf llama.cpp/build jvim/build jvim/install
	@$(MAKE) -C cli-agent clean 2>/dev/null || true

help:
	@echo "Jenova Cognitive Architecture — build targets"
	@echo ""
	@echo "  make            Build llama.cpp + cli-agent + jvim"
	@echo "  make llama      Build only llama.cpp (Vulkan)"
	@echo "  make cli-agent  Build only the cli-agent"
	@echo "  make jvim       Build only the bundled jvim editor"
	@echo "  make install    Run scripts/install.sh"
	@echo "  make clean      Remove build artifacts"
