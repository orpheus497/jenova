#!/bin/sh
# preflight-check.sh: Jenova Cognitive Architecture — Pre-installation Verification
#
# Comprehensive pre-flight checks before building and installing Jenova.
# Verifies OS compatibility, required dependencies, disk space, network, and more.
#
# Usage: ./scripts/preflight-check.sh [--fix] [--verbose]
#
#   --fix      Attempt to install missing required dependencies automatically
#   --verbose  Show detailed output for all checks
#
# Exit codes:
#   0 = all checks passed
#   1 = critical failures found (do not proceed)
#   2 = warnings found (proceed with caution)

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"

# Shared OS/hardware detection
. "$JENOVA_ROOT/lib/detect-env.sh"

FIX=0
VERBOSE=0
ERRORS=0
WARNINGS=0

for _arg in "$@"; do
    case "$_arg" in
        --fix)      FIX=1 ;;
        --verbose)  VERBOSE=1 ;;
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
    _G=$(printf '\033[0;32m'); _Y=$(printf '\033[0;33m'); _R=$(printf '\033[0;31m'); _B=$(printf '\033[1;34m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _N=""
fi

ok()   { printf "${_G}✓${_N}  %s\n" "$1"; }
warn() { printf "${_Y}⚠${_N}  %s\n" "$1"; }
fail() { printf "${_R}✗${_N}  %s\n" "$1"; }
info() { printf "${_B}ℹ${_N}  %s\n" "$1"; }

echo ""
printf "${_B}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_B}║  Jenova — Pre-installation Checks                    ║${_N}\n"
printf "${_B}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

# ---------------------------------------------------------------------------
# 1. Operating System Check
# ---------------------------------------------------------------------------
info "Checking operating system..."
case "$JENOVA_OS" in
    freebsd) ok "FreeBSD $(uname -r)" ;;
    linux)   ok "Linux - ${JENOVA_DISTRO:-Unknown} / pkg: ${JENOVA_PKG_MGR:-Unknown}" ;;
    macos)   warn "macOS $(uname -r) - experimental, use with caution"; WARNINGS=$((WARNINGS + 1)) ;;
    *)       fail "Unsupported OS: $(uname -s)"; ERRORS=$((ERRORS + 1)) ;;
esac

# ---------------------------------------------------------------------------
# 2. Disk Space Check
# ---------------------------------------------------------------------------
info "Checking disk space..."
_free=$(df -BG "$JENOVA_ROOT" | tail -1 | awk '{print $4}' | sed 's/G//')
_needed=20  # conservative estimate: 10GB for builds + 10GB for models
if [ "${_free:-0}" -ge "$_needed" ]; then
    ok "Sufficient disk space: ${_free}GB free (need ~${_needed}GB)"
else
    warn "Low disk space: only ${_free}GB free (recommended: ${_needed}GB minimum)"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 3. Git Repository Status
# ---------------------------------------------------------------------------
info "Checking git repository..."
if [ -d "$JENOVA_ROOT/.git" ]; then
    ok "Git repository detected"
    _branch=$(cd "$JENOVA_ROOT" && git branch --show-current 2>/dev/null || echo "unknown")
    [ "$VERBOSE" = "1" ] && info "  Current branch: $_branch"
else
    fail "Not a git repository - install.sh requires git for history tracking"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 4. Required Binaries
# ---------------------------------------------------------------------------
info "Checking required binaries..."

_check_bin() {
    _name="$1"; _pkg="$2"; _optional="${3:-0}"
    if command -v "$_name" >/dev/null 2>&1; then
        _ver=$($name --version 2>/dev/null | head -n1 || echo "unknown version")
        ok "$_name"
        [ "$VERBOSE" = "1" ] && info "  Path: $(command -v "$_name")"
        return 0
    else
        if [ "$_optional" = "1" ]; then
            warn "$_name not found (optional) — install: $_pkg"
            WARNINGS=$((WARNINGS + 1))
        else
            fail "$_name not found (required) — install: $_pkg"
            ERRORS=$((ERRORS + 1))
            if [ "$FIX" = "1" ]; then
                info "  Attempting to install $_name..."
                if "$JENOVA_ROOT/scripts/install-dependencies.sh" --required-only >/dev/null 2>&1; then
                    ok "  Dependencies installed successfully"
                    # Re-check after installation
                    if command -v "$_name" >/dev/null 2>&1; then
                        ok "  $_name now available"
                        ERRORS=$((ERRORS - 1))
                        return 0
                    fi
                fi
                fail "  Failed to install $_name"
            fi
        fi
        return 1
    fi
}

_check_bin "git"      "git" 0
_check_bin "cmake"    "cmake" 0
_check_bin "luajit"   "luajit" 0
_check_bin "curl"     "curl" 1
_check_bin "gmake"    "gmake" 1

# ---------------------------------------------------------------------------
# 5. Vulkan Support Check
# ---------------------------------------------------------------------------
info "Checking Vulkan support..."
if [ "$JENOVA_VULKAN_OK" = "1" ]; then
    ok "Vulkan loader detected"
else
    warn "Vulkan loader not found - CPU-only fallback will be used"
    WARNINGS=$((WARNINGS + 1))
    [ "$VERBOSE" = "1" ] && info "  Install vulkan-loader to enable GPU acceleration"
fi

# ---------------------------------------------------------------------------
# 6. Node.js / npm Check (for Web UI)
# ---------------------------------------------------------------------------
info "Checking Node.js (required for Web UI)..."
if command -v npm >/dev/null 2>&1; then
    _npmver=$(npm --version)
    ok "npm $($_npmver) detected"
else
    warn "npm not found - Web UI build will be skipped"
    warn "Install Node.js to build the Web UI: $(
        case "$JENOVA_PKG_MGR" in
            pkg)    echo "pkg install node npm" ;;
            pacman) echo "pacman -S nodejs npm" ;;
            apt)    echo "apt install npm" ;;
            dnf)    echo "dnf install npm" ;;
            brew)   echo "brew install node" ;;
            *)      echo "https://nodejs.org/" ;;
        esac
    )"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 7. Network Connectivity Check
# ---------------------------------------------------------------------------
info "Checking network connectivity..."
if command -v curl >/dev/null 2>&1; then
    if curl -s -m 3 https://huggingface.co > /dev/null 2>&1; then
        ok "Network connectivity to model hub confirmed"
    else
        warn "Cannot reach model hub (huggingface.co) - model downloads will fail"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    info "Skipping network check (curl not available)"
fi

# ---------------------------------------------------------------------------
# 8. User Permissions Check
# ---------------------------------------------------------------------------
info "Checking permissions..."
if [ -w "$JENOVA_ROOT" ]; then
    ok "Write permission to $JENOVA_ROOT"
else
    fail "No write permission to $JENOVA_ROOT - run as owner or with sudo"
    ERRORS=$((ERRORS + 1))
fi

if [ -d "$JENOVA_ROOT/.git" ] && [ ! -w "$JENOVA_ROOT/.git" ]; then
    fail "No write permission to .git directory"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 9. Existing Build Artifacts Check
# ---------------------------------------------------------------------------
info "Checking for existing build artifacts..."
_build_dirs="jvim/build llama.cpp/build mcsh/build public/bundle"
_clean_needed=0
for _dir in $_build_dirs; do
    if [ -d "$JENOVA_ROOT/$_dir" ]; then
        warn "Existing build: $JENOVA_ROOT/$_dir"
        _clean_needed=1
    fi
done
if [ "$_clean_needed" = "1" ]; then
    info "Run 'make clean' to remove old builds, or proceed to do an incremental rebuild"
fi

# ---------------------------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------------------------
echo ""
printf "${_B}────────────────────────────────────────────────────────${_N}\n"

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    printf "${_G}✓ All checks passed!${_N}\n"
    echo ""
    echo "You're ready to build Jenova. Run:"
    echo "  scripts/llama_dl.sh   # fetch llama.cpp source"
    echo "  make                  # build everything"
    echo "  make install          # deploy to ~/.local/bin"
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    printf "${_Y}⚠ ${WARNINGS} warning(s) found.${_N}\n"
    echo ""
    echo "Installation will likely succeed, but some features may be unavailable."
    exit 2
else
    printf "${_R}✗ ${ERRORS} critical issue(s) found.${_N}\n"
    echo ""
    echo "Fix the errors above before proceeding. Use --fix to attempt auto-installation."
    exit 1
fi
