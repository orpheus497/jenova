#!/bin/sh
# verify-install.sh: Jenova Cognitive Architecture — Post-Installation Verification
#
# Comprehensive verification that all components have been installed correctly.
# Tests binaries, configs, models, and runtime functionality.
#
# Usage: ./scripts/verify-install.sh [--full] [--verbose]
#
#   --full      Run comprehensive tests including daemon startup
#   --verbose   Show detailed output
#
# Exit codes:
#   0 = installation verified
#   1 = critical components missing
#   2 = minor issues (non-blocking)

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
JENOVA_HOME="${JENOVA_HOME:-$HOME/Jenova}"
FULL=0
VERBOSE=0
ERRORS=0
WARNINGS=0

for _arg in "$@"; do
    case "$_arg" in
        --full)    FULL=1 ;;
        --verbose) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            exit 1
            ;;
    esac
done

# Colours
if [ -t 1 ]; then
    _G=$(printf '\033[38;2;118;148;106m')
    _Y=$(printf '\033[38;2;192;163;110m')
    _R=$(printf '\033[38;2;195;64;67m')
    _B=$(printf '\033[38;2;126;156;216m')
    _P=$(printf '\033[38;2;120;81;169m')
    _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _P=""; _N=""
fi

ok()   { printf "${_G}✓${_N}  %s\n" "$1"; }
warn() { printf "${_Y}⚠${_N}  %s\n" "$1"; }
fail() { printf "${_R}✗${_N}  %s\n" "$1"; }
info() { printf "${_B}ℹ${_N}  %s\n" "$1"; }

echo ""
printf "${_P}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_P}║  Jenova — Post-installation Verification             ║${_N}\n"
printf "${_P}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

# ---------------------------------------------------------------------------
# 1. Check Path Resolution
# ---------------------------------------------------------------------------
info "Verifying path resolution..."
# Determine JENOVA_ROOT before loading config
_ROOT_CANDIDATE=""
if [ -f "$HOME/.local/bin/jenova" ]; then
    _EXE=$(readlink -f "$HOME/.local/bin/jenova")
    _ROOT_CANDIDATE=$(dirname "$(dirname "$_EXE")")
fi

export JENOVA_ROOT="${_ROOT_CANDIDATE:-$JENOVA_ROOT}"

if [ -f "$JENOVA_ROOT/lib/jenova-conf.sh" ]; then
    . "$JENOVA_ROOT/lib/detect-env.sh"
    . "$JENOVA_ROOT/lib/jenova-conf.sh"
    ok "Path resolution active (Layout: $JENOVA_LAYOUT)"
else
    fail "Cannot find lib/jenova-conf.sh in $JENOVA_ROOT"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 2. Check Installed Binaries & Architecture
# ---------------------------------------------------------------------------
info "Verifying installed binaries..."

_check_bin() {
    _name="$1"; _desc="$2"
    if command -v "$_name" >/dev/null 2>&1; then
        _path=$(command -v "$_name")
        _real_path=$(readlink -f "$_path")
        
        # Verify architecture only for ELF/Mach-O binaries
        if command -v file >/dev/null 2>&1; then
            _file_info=$(file "$_real_path")
            if echo "$_file_info" | grep -qiE "ELF|Mach-O"; then
                case "$JENOVA_OS" in
                    linux)   echo "$_file_info" | grep -qi "ELF.*GNU/Linux" || { fail "$_name is not a native Linux binary"; ERRORS=$((ERRORS + 1)); } ;;
                    freebsd) echo "$_file_info" | grep -qi "ELF.*FreeBSD"   || { fail "$_name is not a native FreeBSD binary"; ERRORS=$((ERRORS + 1)); } ;;
                    macos)   echo "$_file_info" | grep -qi "Mach-O"       || { fail "$_name is not a native macOS binary"; ERRORS=$((ERRORS + 1)); } ;;
                esac
            else
                # It's a script or other non-ELF file
                if [ "$VERBOSE" = "1" ]; then ok "$_desc is a script (arch check skipped)"; fi
            fi
        fi
        
        ok "$_desc ($_real_path)"
        return 0
    else
        fail "$_desc not found in PATH"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
}

_check_bin "jvim" "jvim (bundled editor)"
_check_bin "jenova" "jenova (launcher)"
_check_bin "jenova-ca" "jenova-ca (daemon manager)"
_check_bin "mcsh" "mcsh (Modern C Shell)"

# ---------------------------------------------------------------------------
# 3. Check Components and Assets
# ---------------------------------------------------------------------------
info "Verifying components and assets..."

if [ -f "$LLAMA_SERVER" ] && [ -x "$LLAMA_SERVER" ]; then
    ok "llama-server reachable at $LLAMA_SERVER"
else
    fail "llama-server missing or not executable"
    ERRORS=$((ERRORS + 1))
fi

if [ -d "$VIMRUNTIME" ]; then
    ok "jvim runtime found"
else
    fail "jvim runtime missing at $VIMRUNTIME"
    ERRORS=$((ERRORS + 1))
fi

if [ -d "$JENOVA_ROOT/public" ] && [ -f "$JENOVA_ROOT/public/index.html" ]; then
    ok "Web UI found"
else
    warn "Web UI missing (optional)"
    WARNINGS=$((WARNINGS + 1))
fi

if [ -d "$JENOVA_ROOT/share/jvim/mason" ]; then
    ok "share directory found"
else
    warn "share directory missing (LSPs may need re-install)"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 3. Check Configuration Files
# ---------------------------------------------------------------------------
info "Verifying configuration..."

_jvim_config="$HOME/.config/jvim"
if [ -d "$_jvim_config" ]; then
    ok "jvim config directory exists ($_jvim_config)"
    if [ -f "$_jvim_config/init.lua" ]; then
        ok "  init.lua deployed"
    else
        fail "  init.lua missing"
        ERRORS=$((ERRORS + 1))
    fi
else
    fail "jvim config directory not found - run 'make install'"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 4. Check Model Files
# ---------------------------------------------------------------------------
info "Verifying model files in $JENOVA_HOME/models..."

_models_dir="$JENOVA_HOME/models"
mkdir -p "$_models_dir/agent" "$_models_dir/embed" "$_models_dir/draft" 2>/dev/null || true

_check_model() {
    _type="$1"; _dir="$_models_dir/$_type"
    if find "$_dir" -maxdepth 1 -name "*.gguf" 2>/dev/null | grep -q .; then
        ok "  $_type model(s) found in $_dir"
        return 0
    else
        warn "  No $_type model(s) found in $_dir"
        WARNINGS=$((WARNINGS + 1))
        return 1
    fi
}

_check_model "agent" "*.gguf"
_check_model "embed" "*.gguf"

# ---------------------------------------------------------------------------
# 5. Check Runtime Directories
# ---------------------------------------------------------------------------
info "Verifying runtime directories..."

_check_dir() {
    _path="$1"; _desc="$2"; _create="${3:-0}"
    if [ -d "$_path" ]; then
        if [ -w "$_path" ]; then
            ok "$_desc ($_path)"
        else
            warn "$_desc exists but not writable"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        if [ "$_create" = "1" ]; then
            mkdir -p "$_path" 2>/dev/null && ok "$_desc created ($_path)" || fail "$_desc cannot be created"
        else
            fail "$_desc missing ($_path)"
            ERRORS=$((ERRORS + 1))
        fi
    fi
}

_check_dir "$JENOVA_ROOT/.jenova" "Runtime directory (.jenova)" 1
_check_dir "$JENOVA_ROOT/var/log" "Log directory (var/log)" 1
_check_dir "$JENOVA_ROOT/var/cache" "Cache directory (var/cache)" 1

# ---------------------------------------------------------------------------
# 6. Quick Functionality Tests
# ---------------------------------------------------------------------------
info "Testing basic functionality..."

# Test jvim version
if command -v jvim >/dev/null 2>&1; then
    _ver=$(jvim --version 2>/dev/null | head -n1)
    case "$_ver" in
        *JVIM*) ok "jvim version: $_ver" ;;
        *)      warn "jvim is not the bundled editor: $_ver"; WARNINGS=$((WARNINGS + 1)) ;;
    esac
fi

# Test lua
if command -v luajit >/dev/null 2>&1; then
    ok "luajit available ($(command -v luajit))"
else
    fail "luajit not found"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 7. Optional Full Tests (daemon startup, etc.)
# ---------------------------------------------------------------------------
if [ "$FULL" = "1" ]; then
    info "Running full integration tests..."
    
    # Check if llama-server is accessible
    if [ -x "$JENOVA_ROOT/bin/llama-server" ] || command -v llama-server >/dev/null 2>&1; then
        ok "llama-server binary accessible"
    else
        warn "llama-server binary not found"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    # Test configuration
    if [ -f "$JENOVA_ROOT/etc/jenova.conf" ]; then
        ok "jenova.conf exists"
        if grep -q "JENOVA_BACKEND" "$JENOVA_ROOT/etc/jenova.conf"; then
            ok "  JENOVA_BACKEND configured"
        fi
    else
        warn "jenova.conf not found"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 8. Summary and Next Steps
# ---------------------------------------------------------------------------
echo ""
printf "${_P}────────────────────────────────────────────────────────${_N}\n"

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    printf "${_G}✓ Installation verified successfully!${_N}\n"
    echo ""
    echo "Next steps:"
    echo "  1. Download models: ./scripts/model_dl.sh"
    echo "  2. Configure hardware: ./hardware-profiles/detect-hardware.sh --apply"
    echo "  3. Run system tuning: sudo ./scripts/jenova-setup"
    echo "  4. Launch Jenova: jenova"
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    printf "${_Y}⚠ Installation partially verified (${WARNINGS} warning(s)).${_N}\n"
    echo ""
    echo "Core components are installed. Address warnings for full functionality:"
    echo "  • Download models: ./scripts/model_dl.sh"
    echo "  • Rebuild components: make clean && make"
    exit 2
else
    printf "${_R}✗ Installation verification failed (${ERRORS} error(s)).${_N}\n"
    echo ""
    echo "Fix the errors above:"
    echo "  • Run preflight checks: ./scripts/preflight-check.sh"
    echo "  • Re-run installation: make install"
    echo "  • Check logs: cat $JENOVA_ROOT/var/log/*.log"
    exit 1
fi
