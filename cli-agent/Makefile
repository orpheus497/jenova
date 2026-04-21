# ============================================================================
# cli-agent — Pure C + Lua + llama.cpp
# Top-level Makefile
#
# Architecture:
#   Lua (agent + tools + UI) + C (all services) + llama.cpp (local inference)
#   Zero Rust dependency. Everything compiles with a C11 toolchain + libcurl.
# ============================================================================

.PHONY: all clean release install test lint help
.PHONY: build-agent build-lua
.PHONY: test-lua test-c test-integration

# ── Configuration ──────────────────────────────────────────────────────────

PREFIX     ?= /usr/local
BUILD_DIR  := build
CMAKE_BUILD:= $(BUILD_DIR)/cmake

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Linux)
  PLATFORM := linux
endif
ifeq ($(UNAME_S),Darwin)
  PLATFORM := macos
endif
ifeq ($(UNAME_S),FreeBSD)
  PLATFORM := freebsd
endif

BUILD_TYPE ?= Debug

# ── Primary Targets ───────────────────────────────────────────────────────

all: build-agent
	@echo "✓ Build complete: $(BUILD_DIR)/cli-agent"

release: BUILD_TYPE := Release
release: all

# ── C Build (CMake) ──────────────────────────────────────────────────────
# Builds ALL service code in pure C: HTTP, auth, crypto, sandbox, JSON,
# filesystem, process, MCP, llama.cpp bindings, agent core, plus Lua VM.

build-agent: $(CMAKE_BUILD)/Makefile
	@cmake --build $(CMAKE_BUILD) --parallel
	@cp $(CMAKE_BUILD)/cli-agent $(BUILD_DIR)/cli-agent 2>/dev/null || true

$(CMAKE_BUILD)/Makefile:
	@mkdir -p $(CMAKE_BUILD)
	@cmake -S . -B $(CMAKE_BUILD) \
		-DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
		-DCMAKE_EXPORT_COMPILE_COMMANDS=ON

# ── Lua (syntax check only — runtime interpreted) ────────────────────────

build-lua:
	@echo "Checking Lua syntax..."
	@find lua/ -name '*.lua' -exec luac -p {} \;
	@echo "✓ All Lua files pass syntax check"

# ── Testing ──────────────────────────────────────────────────────────────

test: test-lua test-c test-integration

test-lua:
	@echo "Running Lua tests..."
	@LUA_PATH="lua/?.lua;lua/?/init.lua;;" \
		lua tests/lua/run_tests.lua

test-c: build-agent
	@cd $(CMAKE_BUILD) && ctest --output-on-failure

test-integration: build-agent
	@echo "Running integration tests..."
	@bash tests/integration/run.sh

# ── Lint ─────────────────────────────────────────────────────────────────

lint:
	@echo "Linting Lua..."
	@command -v luacheck >/dev/null && luacheck lua/ --no-unused-args || echo "(luacheck not installed)"
	@echo "Linting C..."
	@command -v cppcheck >/dev/null && cppcheck --enable=warning src/ include/ || echo "(cppcheck not installed)"

# ── Install ──────────────────────────────────────────────────────────────

install: release
	@install -d $(PREFIX)/bin
	@install -m 755 $(BUILD_DIR)/cli-agent $(PREFIX)/bin/cli-agent
	@install -d $(PREFIX)/share/cli-agent/lua
	@cp -r lua/* $(PREFIX)/share/cli-agent/lua/
	@echo "✓ Installed to $(PREFIX)"

# ── Clean ────────────────────────────────────────────────────────────────

clean:
	@rm -rf $(BUILD_DIR)
	@echo "✓ Clean"

# ── Help ─────────────────────────────────────────────────────────────────

help:
	@echo "cli-agent — Pure C + Lua + llama.cpp Build System"
	@echo ""
	@echo "Architecture:"
	@echo "  Lua (agent + tools + UI) + C (services) + llama.cpp (inference)"
	@echo "  NO Rust. Compiles with C11 toolchain + libcurl + optional OpenSSL."
	@echo ""
	@echo "Targets:"
	@echo "  all             Build everything (debug)"
	@echo "  release         Build optimized release"
	@echo "  build-agent     Build C host + services"
	@echo "  build-lua       Check Lua syntax"
	@echo "  test            Run all tests"
	@echo "  test-lua        Run Lua tests"
	@echo "  test-c          Run C unit tests"
	@echo "  lint            Lint all code"
	@echo "  install         Install to PREFIX (default: /usr/local)"
	@echo "  clean           Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  BUILD_TYPE=Release  Optimized build"
	@echo "  PREFIX=/usr/local   Install prefix"
	@echo ""
	@echo "Optional CMake flags:"
	@echo "  -DAGENT_WITH_LLAMA=ON    Enable llama.cpp integration"
	@echo "  -DAGENT_WITH_OPENSSL=ON  Enable OpenSSL crypto (default ON)"
	@echo "  -DAGENT_USE_LUAJIT=ON    Use LuaJIT instead of Lua 5.4"
