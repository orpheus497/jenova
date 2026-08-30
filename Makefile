# Jenova Cognitive Architecture — Unified Build System
#
# FreeBSD only. Builds with the base system make(1). GNU make is not used and is
# not a dependency.
#
# This Makefile is the single entry point. Every build target depends on `deps`,
# so dependencies are always installed before anything is built.
#
# Common usage:
#   make            # Install dependencies, then build everything
#   make deps       # Install dependencies only
#   make llama      # Build external/llama.cpp
#   make jenova-ui  # Build the desktop manager
#   make web        # Build the Web UI
#   make install    # Build everything and deploy to $JCA_HOME
#   make clean      # Remove build artifacts

.PHONY: all deps llama web jenova-ui core install clean clean-root help

# The FreeBSD lang/nim port installs the compiler to /usr/local/nim/bin, which is
# not on the default PATH. Probe PATH first so a user-installed compiler wins.
NIM     ?= nim
NIMPATH  = /usr/local/nim/bin/nim
NIMFLAGS ?= -d:release --hints:off

# The build is serial by design: `deps` must complete before any other target
# runs, or a rule can invoke a tool that is not installed yet. Declaring that
# here is safer than giving every target a `deps` prerequisite — doing so on
# the file target jca_web/node_modules would make it depend on a .PHONY target,
# which is never up to date, forcing `npm install` on every single build.
.NOTPARALLEL:

all: deps llama jenova-ui web
	@echo ""
	@echo "✅ Jenova build complete (llama.cpp + jenova-ui + web)"
	@echo "   Run 'make install' to deploy."

# Install every dependency. Idempotent — packages already present are skipped,
# so this is a fast no-op on a configured machine. There is no optional tier:
# if a dependency cannot be installed, the build stops here.
deps:
	@./scripts/install-dependencies.sh

llama: deps
	@echo "🔨 Building external/llama.cpp..."
	@./scripts/build-llama.sh

# Prerequisite is package.json alone, so npm install re-runs only when the
# manifest changes. .NOTPARALLEL above guarantees deps has already run.
jca_web/node_modules: jca_web/package.json
	@echo "📦 Installing JCA Web UI dependencies..."
	@cd jca_web && npm install
	@touch jca_web/node_modules

web: deps jca_web/node_modules
	@echo "🔨 Building JCA Web UI..."
	@if [ ! -d jca_web ]; then \
		echo "ERROR: jca_web/ source tree missing." >&2; exit 1; \
	fi
	@cd jca_web && npm run build
	@echo "   Web UI built: public/"

jenova-ui: deps
	@echo "🔨 Building jenova-ui..."
	@$(MAKE) -C jenova-ui
	@mkdir -p bin || exit 1
	@cp jenova-ui/jenova-ui bin/jenova-ui || exit 1
	@echo "   jenova-ui built: bin/jenova-ui"

# Action purpose: build the Nim core (PLANS.md Plan B). Deliberately does NOT
# depend on `deps` — nim is not yet in the dependency list, and adding it is a
# dependency change awaiting approval (TODOS.md N-11). Until then this target
# locates an already-installed compiler and fails loudly if there is none.
core:
	@echo "🔨 Building jenova-core..."
	@_nim=`command -v $(NIM) 2>/dev/null || echo $(NIMPATH)`; \
	if [ ! -x "$$_nim" ]; then \
		echo "ERROR: nim compiler not found on PATH or at $(NIMPATH)." >&2; \
		echo "       Install it with: pkg install nim" >&2; \
		exit 1; \
	fi; \
	mkdir -p bin || exit 1; \
	"$$_nim" c $(NIMFLAGS) --out:bin/jenova-core src/jenova_core.nim || exit 1
	@echo "   jenova-core built: bin/jenova-core"

install: all
	@./scripts/install.sh

clean:
	@echo "🧹 Cleaning build artifacts..."
	@if [ -d jenova-ui ]; then $(MAKE) -C jenova-ui clean; fi
	@rm -f bin/jenova-ui bin/jenova-core
	@rm -rf -- external/llama.cpp/build external/ext_bin/ public/ nimcache/

clean-root:
	@echo "🧹 Cleaning root directory bloat..."
	@rm -f *.o gethost config.h config.log config.status atconfig atlocal
	@rm -f shellcheck_report.txt INSTALLATION-AUDIT.md INSTALLATION-FINAL-REPORT.md
	@rm -f tc.const.h.tmp tc.defs.c.tmp
	@rm -rf autom4te.cache po/*.gmo nls/*.cat
	@echo "   Root directory cleaned."

help:
	@echo "Jenova Cognitive Architecture — build targets (FreeBSD, make)"
	@echo ""
	@echo "  Build:"
	@echo "    make               Install dependencies, then build everything"
	@echo "    make deps          Install all dependencies (no optional tier)"
	@echo "    make llama         Build external/llama.cpp"
	@echo "    make jenova-ui     Build the desktop manager"
	@echo "    make core          Build the Nim core (jenova-core)"
	@echo "    make web           Build the Web UI"
	@echo ""
	@echo "  Deploy:"
	@echo "    make install       Build everything and deploy to \$$JCA_HOME"
	@echo ""
	@echo "  Cleanup:"
	@echo "    make clean         Remove build artifacts"
	@echo "    make clean-root    Remove root directory artifacts"
