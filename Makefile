# Jenova Cognitive Architecture — Unified Build System
#
# Four components make up Jenova as a single terminal IDE:
#   1. external/llama.cpp        — Vulkan-accelerated inference backend
#   2. jvim                      — Neovim-based editor (`jvim` binary, in-tree fork)
#   3. external/mcsh             — Modern C Shell (in-tree fork of tcsh)
#   4. jca_web                   — Web-based UI
#
# The agent is embedded inside jvim — it lives at jvim-config/lua/jenova/agent/.
# There is no separate cli-agent any more.
#
# Common usage:
#   make            # Build everything (external/llama.cpp + jvim + mcsh + web)
#   make jvim       # Build only the bundled jvim editor
#   make llama      # Build only external/llama.cpp
#   make web        # Build only the Web UI
#   make install    # Run scripts/install.sh (system-aware deploy)
#   make clean      # Remove build artifacts from both components

.PHONY: all llama llama-hybrid jvim mcsh web jenova-ui install preflight verify clean help clean-root

all: preflight llama jvim mcsh jenova-ui web
	@echo ""
	@echo "✅ Jenova build complete (external/llama.cpp + jvim + mcsh + jenova-ui + web)"
	@echo "   Run 'make install' (or scripts/install.sh) to deploy."

llama:
	@echo "🔨 Building external/llama.cpp (Vulkan)..."
	@./bin/build-llama-jenova

llama-hybrid:
	@echo "🔨 Building external/llama.cpp (Vulkan + CUDA)..."
	@./bin/build-llama-hybrid

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
	@if [ ! -f external/mcsh/configure ]; then \
		echo "WARN: external/mcsh/ source tree missing — skipping mcsh build" >&2; \
	else \
		mkdir -p external/mcsh/build || exit 1; \
		if [ ! -f external/mcsh/build/Makefile ]; then \
			(cd external/mcsh/build && ../configure) || exit 1; \
		fi; \
		if [ "$$(uname -s)" = "FreeBSD" ]; then \
			if ! command -v gmake >/dev/null 2>&1; then \
				echo "FreeBSD requires 'gmake' to build mcsh. Please run 'pkg install gmake'" >&2; \
				exit 1; \
			fi; \
			gmake -C external/mcsh/build || exit 1; \
		else \
			$(MAKE) -C external/mcsh/build || exit 1; \
		fi; \
		mkdir -p bin || exit 1; \
		cp external/mcsh/build/mcsh bin/mcsh || exit 1; \
		echo "   mcsh built: bin/mcsh"; \
	fi

jca_web/node_modules: jca_web/package.json
	@echo "📦 Installing JCA Web UI dependencies..."
	@cd jca_web && npm install
	@touch jca_web/node_modules

web: jca_web/node_modules
	@if [ -f public/bundle.js ] && [ -f public/index.html ]; then \
		echo "✅ JCA Web UI already built (public/bundle.js found)."; \
	else \
		echo "🔨 Building JCA Web UI..."; \
		if [ ! -d jca_web ]; then \
			echo "ERROR: jca_web/ source tree missing." >&2; exit 1; \
		fi; \
		cd jca_web && npm run build; \
		echo "   Web UI built: public/"; \
	fi

jenova-ui:
	@echo "🔨 Building jenova-ui..."
	@$(MAKE) -C jenova-ui
	@mkdir -p bin || exit 1
	@cp jenova-ui/jenova-ui bin/jenova-ui || exit 1
	@echo "   jenova-ui built: bin/jenova-ui"

install: preflight llama jvim mcsh jenova-ui web
	@./scripts/install.sh

install-jenova:
	@./install-jenova.sh

clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf external/llama.cpp/build jvim/build jvim/install external/mcsh/build bin/mcsh public/

clean-root:
	@echo "🧹 Cleaning root directory bloat..."
	@rm -f *.o gethost config.h config.log config.status atconfig atlocal
	@rm -f shellcheck_report.txt INSTALLATION-AUDIT.md INSTALLATION-FINAL-REPORT.md
	@rm -f tc.const.h.tmp tc.defs.c.tmp
	@rm -rf autom4te.cache po/*.gmo nls/*.cat
	@echo "   Root directory cleaned."

preflight:
	@./scripts/preflight-check.sh

verify:
	@./scripts/verify-install.sh --full

help:
	@echo "Jenova Cognitive Architecture — build targets"
	@echo ""
	@echo "  Build targets:"
	@echo "    make                Build external/llama.cpp + jvim + mcsh + web"
	@echo "    make llama          Build only external/llama.cpp (Vulkan)"
	@echo "    make llama-hybrid   Build external/llama.cpp (Vulkan + CUDA)"
	@echo "    make jvim           Build only the bundled jvim editor"
	@echo "    make mcsh           Build only the mcsh shell"
	@echo "    make web            Build only the Web UI"
	@echo ""
	@echo "  Installation & verification:"
	@echo "    make preflight      Check dependencies before building"
	@echo "    make install        Run scripts/install.sh (deploy to system)"
	@echo "    make install-jenova Run streamlined installation for all platforms"
	@echo "    make verify         Verify installation succeeded"
	@echo ""
	@echo "  Cleanup:"
	@echo "    make clean          Remove build artifacts"
	@echo "    make clean-root     Remove root directory artifacts"
