#!/bin/sh
# install-complete.sh: Jenova Complete Installation Workflow
#
# One-command installation: deps → checks → build → deploy → models → verify
# This wraps install-dependencies.sh, preflight-check.sh, build steps,
# install.sh, model_dl.sh, and verify-install.sh
#
# Usage: ./scripts/install-complete.sh [--skip-web] [--skip-models] [--no-verify]
#
#   --skip-web     Skip Web UI build (if npm not available or not desired)
#   --skip-models  Skip automatic model downloads
#   --no-verify    Skip post-installation verification
#   --force        Overwrite existing config without prompting
#
# Exit codes:
#   0 = successful installation
#   1 = critical failure (installation halted)
#   2 = partial success (warnings, but usable)

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"

SKIP_WEB=0
SKIP_MODELS=0
NO_VERIFY=0
FORCE=0
START_TIME=$(date +%s)

for _arg in "$@"; do
    case "$_arg" in
        --skip-web)     SKIP_WEB=1 ;;
        --skip-models)  SKIP_MODELS=1 ;;
        --no-verify)    NO_VERIFY=1 ;;
        --force)        FORCE=1 ;;
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
    _G="\033[0;32m"; _Y="\033[0;33m"; _R="\033[0;31m"; _B="\033[1;34m"; _N="\033[0m"
else
    _G=""; _Y=""; _R=""; _B=""; _N=""
fi

ok()   { printf "${_G}✓${_N}  %s\n" "$1"; }
warn() { printf "${_Y}⚠${_N}  %s\n" "$1"; }
fail() { printf "${_R}✗${_N}  %s\n" "$1"; }
info() { printf "${_B}ℹ${_N}  %s\n" "$1"; }

_elapsed() {
    _now=$(date +%s)
    _diff=$(( _now - START_TIME ))
    printf "%02d:%02d" $(( _diff / 60 )) $(( _diff % 60 ))
}

echo ""
printf "${_B}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_B}║  Jenova — Complete Installation Workflow             ║${_N}\n"
printf "${_B}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Install Dependencies
# ---------------------------------------------------------------------------
echo ""
info "[1/6] Installing system dependencies..."
if "$JENOVA_ROOT/scripts/install-dependencies.sh" >/dev/null 2>&1; then
    ok "Dependencies installed ($(_elapsed))"
else
    warn "Some optional dependencies failed to install (continuing...)"
fi

# ---------------------------------------------------------------------------
# Phase 2: Pre-flight Checks
# ---------------------------------------------------------------------------
echo ""
info "[2/6] Running pre-flight checks..."
if "$JENOVA_ROOT/scripts/preflight-check.sh" --verbose 2>&1 | grep -q "critical issue"; then
    fail "Pre-flight check failed"
    exit 1
fi
ok "Pre-flight checks passed ($(_elapsed))"

# ---------------------------------------------------------------------------
# Phase 3: Build Components
# ---------------------------------------------------------------------------
echo ""
info "[3/6] Building Jenova components..."

_build_component() {
    _name="$1"; _target="$2"; _cmd="$3"
    info "  Building $_name..."
    if $"$_cmd"; then
        ok "    $_name complete"
        return 0
    else
        fail "    $_name build failed"
        return 1
    fi
}

cd "$JENOVA_ROOT"

# Fetch llama.cpp if not already present
if [ ! -d "$JENOVA_ROOT/llama.cpp/.git" ]; then
    info "  Fetching llama.cpp source..."
    "$JENOVA_ROOT/scripts/llama_dl.sh" >/dev/null 2>&1 || {
        fail "Could not fetch llama.cpp"
        exit 1
    }
    ok "    llama.cpp source ready"
fi

# Build llama.cpp
_build_component "llama.cpp" "llama" "make llama" || {
    fail "llama.cpp build failed — check var/log/ for details"
    exit 1
}

# Build jvim
_build_component "jvim" "jvim" "make jvim" || {
    fail "jvim build failed — check var/log/ for details"
    exit 1
}

# Build mcsh
_build_component "mcsh" "mcsh" "make mcsh" || {
    fail "mcsh build failed — check var/log/ for details"
    exit 1
}

# Build Web UI (optional)
if [ "$SKIP_WEB" = "0" ]; then
    if command -v npm >/dev/null 2>&1; then
        _build_component "Web UI" "web" "make web" || {
            warn "Web UI build failed — skipping"
        }
    else
        warn "npm not found — skipping Web UI build (use --skip-web to suppress)"
    fi
fi

ok "Build phase complete ($(_elapsed))"

# ---------------------------------------------------------------------------
# Phase 4: Deploy to System
# ---------------------------------------------------------------------------
echo ""
info "[4/6] Deploying to system..."

_install_args=""
[ "$FORCE" = "1" ] && _install_args="--force"

if "$JENOVA_ROOT/scripts/install.sh" $_install_args --skip-lsp >/dev/null 2>&1; then
    ok "Installation deployed to ~/.local/bin and ~/.config/jvim ($(_elapsed))"
else
    fail "Install.sh deployment failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 5: Download Models (optional)
# ---------------------------------------------------------------------------
echo ""
if [ "$SKIP_MODELS" = "0" ]; then
    info "[5/6] Downloading AI models..."
    if command -v curl >/dev/null 2>&1 || command -v fetch >/dev/null 2>&1; then
        if "$JENOVA_ROOT/scripts/model_dl.sh" <<< "y" >/dev/null 2>&1; then
            ok "Models downloaded ($(_elapsed))"
        else
            warn "Model download had issues — you can re-run: ./scripts/model_dl.sh"
        fi
    else
        warn "curl/fetch not found — skipping automatic model download"
        warn "Download models manually: ./scripts/model_dl.sh"
    fi
else
    info "[5/6] Skipping model download (--skip-models)"
fi

# ---------------------------------------------------------------------------
# Phase 6: Verify Installation
# ---------------------------------------------------------------------------
echo ""
if [ "$NO_VERIFY" = "0" ]; then
    info "[6/6] Verifying installation..."
    if "$JENOVA_ROOT/scripts/verify-install.sh" >/dev/null 2>&1; then
        ok "Installation verified ($(_elapsed))"
    else
        warn "Installation verification had warnings"
    fi
else
    info "[5/5] Skipping verification (--no-verify)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
printf "${_B}────────────────────────────────────────────────────────${_N}\n"
_total=$(_elapsed)
printf "${_G}✓ Installation complete in $_total${_N}\n"
echo ""
echo "Next steps:"
echo "  1. Apply hardware profile: ./hardware-profiles/detect-hardware.sh --apply"
echo "  2. Run system tuning: sudo ./scripts/jenova-setup"
echo "  3. Ensure ~/.local/bin is in PATH"
echo "  4. Launch Jenova: jenova"
echo ""
echo "Configuration:"
echo "  • Config: ~/.config/jvim/"
echo "  • Plugins: ~/.local/share/nvim/lazy/"
echo "  • Logs: $JENOVA_ROOT/var/log/"
echo "  • Models: $JENOVA_ROOT/models/"
