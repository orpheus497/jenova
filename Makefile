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

.PHONY: all llama cli-agent jvim sync-modules install clean help

all: llama cli-agent sync-modules jvim
	@echo ""
	@echo "✅ Jenova build complete (llama.cpp + cli-agent + jvim)"
	@echo "   Run 'make install' (or scripts/install.sh) to deploy."

llama:
	@echo "🔨 Building llama.cpp (Vulkan)..."
	@./bin/build-llama-jenova

cli-agent:
	@echo "🔨 Building cli-agent..."
	@$(MAKE) -C cli-agent

# SHARED_MODULES — cli-agent/lua/ subset synced into jvim's runtime at build time.
# jvim-native overrides in jenova/agent/ shadow these via Lua module resolution.
SHARED_MODULES = \
  engine/query_engine.lua \
  tools/registry.lua \
  tools/bash.lua \
  tools/brief.lua \
  tools/file_edit.lua \
  tools/file_read.lua \
  tools/file_write.lua \
  tools/git.lua \
  tools/glob.lua \
  tools/grep.lua \
  tools/local_search.lua \
  tools/multiedit.lua \
  tools/web_fetch.lua \
  tools/web_search.lua \
  providers/base.lua \
  providers/init.lua \
  providers/jenova_backend.lua \
  providers/llamacpp.lua \
  config/loader.lua \
  history/manager.lua \
  context/manager.lua \
  context/file_tracker.lua \
  permissions/manager.lua \
  services/tool_verifier.lua \
  utils/array.lua \
  utils/embed.lua \
  utils/http.lua \
  utils/json_fallback.lua \
  utils/paths.lua \
  utils/shell.lua \
  utils/string.lua \
  utils/trio.lua \
  constants/prompts.lua \
  state/app_state.lua

sync-modules:
	@echo "🔄 Syncing shared Lua modules cli-agent → jvim runtime..."
	@sh scripts/sync-modules.sh

jvim: sync-modules
	@echo "🔨 Building jvim (in-tree editor)..."
	@if [ ! -f jvim/CMakeLists.txt ]; then \
		echo "ERROR: jvim/ source tree missing." >&2; exit 1; \
	fi
	@$(MAKE) -C jvim \
		CMAKE_BUILD_TYPE=RelWithDebInfo \
		CMAKE_INSTALL_PREFIX="$(CURDIR)/jvim/install"
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
	@echo "  make jvim         Build only the bundled jvim editor (also runs sync-modules)"
	@echo "  make sync-modules Copy shared Lua modules from cli-agent to jvim runtime"
	@echo "  make install      Run scripts/install.sh"
	@echo "  make clean        Remove build artifacts"
