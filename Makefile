# Jenova Cognitive Architecture — Unified Build System
#
# Two components make up Jenova as a single terminal IDE:
#   1. llama.cpp        — Vulkan-accelerated inference backend
#   2. jvim             — Neovim-based editor (`jvim` binary, in-tree fork)
#
# The agent is embedded inside jvim — it lives at jvim-config/lua/jenova/agent/.
# There is no separate cli-agent any more.
#
# Common usage:
#   make            # Build everything (llama.cpp + jvim)
#   make jvim       # Build only the bundled jvim editor
#   make llama      # Build only llama.cpp
#   make install    # Run scripts/install.sh (system-aware deploy)
#   make clean      # Remove build artifacts from both components

# Detect OS to use correct make command (FreeBSD requires gmake for jvim)
UNAME_S != uname -s 2>/dev/null || echo unknown
.if $(UNAME_S) == "FreeBSD"
GMAKE != command -v gmake 2>/dev/null || echo ""
.if empty(GMAKE)
.error "FreeBSD requires 'gmake' to build jvim. Please run 'pkg install gmake'"
.endif
SUBMAKE = $(GMAKE)
.else
SUBMAKE = $(MAKE)
.endif

.PHONY: all llama jvim install clean help

all: llama jvim
	@echo ""
	@echo "✅ Jenova build complete (llama.cpp + jvim)"
	@echo "   Run 'make install' (or scripts/install.sh) to deploy."

llama:
	@echo "🔨 Building llama.cpp (Vulkan)..."
	@./bin/build-llama-jenova

jvim:
	@echo "🔨 Building jvim (in-tree editor)..."
	@if [ ! -f jvim/CMakeLists.txt ]; then \
		echo "ERROR: jvim/ source tree missing." >&2; exit 1; \
	fi
	@$(SUBMAKE) -C jvim \
		CMAKE_BUILD_TYPE=RelWithDebInfo \
		CMAKE_INSTALL_PREFIX="$(CURDIR)/jvim/install"
	@echo "   jvim built: jvim/build/bin/nvim"

install:
	@./scripts/install.sh

clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf llama.cpp/build jvim/build jvim/install

help:
	@echo "Jenova Cognitive Architecture — build targets"
	@echo ""
	@echo "  make            Build llama.cpp + jvim"
	@echo "  make llama      Build only llama.cpp (Vulkan)"
	@echo "  make jvim       Build only the bundled jvim editor"
	@echo "  make install    Run scripts/install.sh"
	@echo "  make clean      Remove build artifacts"
