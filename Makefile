# Jenova Cognitive Architecture — Unified Build System
#
# Three components make up Jenova as a single terminal IDE:
#   1. external/llama.cpp        — Vulkan-accelerated inference backend
#   2. jca_web                   — Web-based UI
#
# Common usage:
#   make            # Build everything (external/llama.cpp + web)
#   make llama      # Build only external/llama.cpp
#   make web        # Build only the Web UI
#   make install    # Run scripts/install.sh (system-aware deploy)
#   make clean      # Remove build artifacts from both components

.PHONY: all llama web jenova-ui install preflight verify clean help clean-root

all: preflight llama jenova-ui web
	@echo ""
	@echo "✅ Jenova build complete (external/llama.cpp + jenova-ui + web)"
	@echo "   Run 'make install' (or scripts/install.sh) to deploy."

llama:
	@echo "🔨 Building external/llama.cpp (auto)..."
	@./bin/build-llama-jenova



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

install: preflight llama jenova-ui web
	@./scripts/install.sh

install-jenova:
	@./install-jenova.sh

clean:
	@echo "🧹 Cleaning build artifacts..."
	@if [ -d jenova-ui ]; then $(MAKE) -C jenova-ui clean; fi
	@rm -f bin/jenova-ui
	@rm -rf -- external/llama.cpp/build external/ext_bin/ public/

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
	@echo "    make                Build external/llama.cpp + web"
	@echo "    make llama          Build external/llama.cpp (auto)"
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
