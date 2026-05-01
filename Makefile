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

.PHONY: all llama jvim mcsh install clean help clean-root

all: llama jvim mcsh
	@echo ""
	@echo "✅ Jenova build complete (llama.cpp + jvim + mcsh)"
	@echo "   Run 'make install' (or scripts/install.sh) to deploy."

llama:
	@echo "🔨 Building llama.cpp (Vulkan)..."
	@./bin/build-llama-jenova

jvim:
	@echo "🔨 Building jvim (in-tree editor)..."
	@if [ ! -f jvim/CMakeLists.txt ]; then \
		echo "ERROR: jvim/ source tree missing." >&2; exit 1; \
	fi
	@if [ "$$(uname -s)" = "FreeBSD" ]; then \
		if ! command -v gmake >/dev/null 2>&1; then \
			echo "FreeBSD requires 'gmake' to build jvim. Please run 'pkg install gmake'" >&2; \
			exit 1; \
		fi; \
		gmake -C jvim CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX="$(CURDIR)/jvim/install"; \
	else \
		$(MAKE) -C jvim CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX="$(CURDIR)/jvim/install"; \
	fi
	@echo "   jvim built: jvim/build/bin/nvim"

mcsh:
	@echo "🔨 Building mcsh (Modern C Shell)..."
	@if [ ! -f mcsh/configure ]; then \
		echo "ERROR: mcsh/ source tree missing." >&2; exit 1; \
	fi
	@mkdir -p mcsh/build
	@if [ ! -f mcsh/build/Makefile ]; then \
		cd mcsh/build && ../configure; \
	fi
	@if [ "$$(uname -s)" = "FreeBSD" ]; then \
		if ! command -v gmake >/dev/null 2>&1; then \
			echo "FreeBSD requires 'gmake' to build mcsh. Please run 'pkg install gmake'" >&2; \
			exit 1; \
		fi; \
		cd mcsh/build && gmake; \
	else \
		cd mcsh/build && $(MAKE); \
	fi
	@cp mcsh/build/mcsh bin/mcsh
	@echo "   mcsh built: bin/mcsh"

install:
	@./scripts/install.sh

clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf llama.cpp/build jvim/build jvim/install mcsh/build bin/mcsh

clean-root:
	@echo "🧹 Cleaning root directory bloat..."
	@rm -f *.o gethost config.h config.log config.status atconfig atlocal
	@rm -rf autom4te.cache po/*.gmo nls/*.cat
	@echo "   Root directory cleaned."

help:
	@echo "Jenova Cognitive Architecture — build targets"
	@echo ""
	@echo "  make            Build llama.cpp + jvim + mcsh"
	@echo "  make llama      Build only llama.cpp (Vulkan)"
	@echo "  make jvim       Build only the bundled jvim editor"
	@echo "  make mcsh       Build only the mcsh shell"
	@echo "  make clean-root Remove build artifacts from the root directory"
	@echo "  make install    Run scripts/install.sh"
	@echo "  make clean      Remove build artifacts"
