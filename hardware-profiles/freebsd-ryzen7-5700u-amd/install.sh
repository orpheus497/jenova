#!/bin/sh
# install.sh: Jenova Cognitive Architecture — Installation Script
# HP Laptop 15s-eq2xxx | FreeBSD 15 | AMD Ryzen 7 5700U | AMD Lucienne (Vega 8)
#
# PLACEHOLDER — based on researched optimal settings for this hardware.
# Validates against the specific hardware requirements of the AMD Lucienne platform.
#
# Usage: ./install.sh [--force] [--link] [--skip-nvim] [--skip-llama]

set -e

JENOVA_ROOT="$(dirname "$(realpath "$0")")/../.."
NVIM_CONFIG_SRC="$JENOVA_ROOT/nvim"
NVIM_CONFIG_DST="$HOME/.config/nvim"

FORCE=0
LINK=0
SKIP_NVIM=0
SKIP_LLAMA=0

for _arg in "$@"; do
    case "$_arg" in
        --force)      FORCE=1 ;;
        --link)       LINK=1 ;;
        --skip-nvim)  SKIP_NVIM=1 ;;
        --skip-llama) SKIP_LLAMA=1 ;;
        -h|--help)
            sed -n '2,10p' "$0"
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

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y} WARN${_N}  %s\n" "$1"; }
fail() { printf "${_R} FAIL${_N}  %s\n" "$1"; }
info() { printf "${_B} INFO${_N}  %s\n" "$1"; }

echo ""
printf "${_B}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_B}║  Jenova CA — HP 15s-eq2xxx / Ryzen 7 5700U Install  ║${_N}\n"
printf "${_B}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

ERRORS=0
WARNINGS=0

# ---------------------------------------------------------------------------
# 1. OS Check
# ---------------------------------------------------------------------------
info "Checking operating system..."
_OS=$(uname -s)
case "$_OS" in
    FreeBSD)
        _VER=$(uname -r | cut -d. -f1)
        if [ "$_VER" -ge 15 ] 2>/dev/null; then
            ok "FreeBSD ${_VER} — fully supported"
        else
            warn "FreeBSD ${_VER} — recommended FreeBSD 15+; AMD GPU support improved in 15.x"
            WARNINGS=$((WARNINGS + 1))
        fi
        ;;
    *)
        warn "This profile is designed for FreeBSD 15. Detected: $_OS"
        WARNINGS=$((WARNINGS + 1))
        ;;
esac

# ---------------------------------------------------------------------------
# 2. CPU Verification
# ---------------------------------------------------------------------------
info "Verifying CPU..."
_CPU_MODEL=$(sysctl -n hw.model 2>/dev/null || cat /proc/cpuinfo 2>/dev/null | grep "model name" | head -1 | cut -d: -f2)
case "$_CPU_MODEL" in
    *5700U*|*Ryzen*7*5700*)
        ok "AMD Ryzen 7 5700U detected"
        ;;
    *)
        warn "Expected AMD Ryzen 7 5700U, detected: $_CPU_MODEL"
        warn "This profile is optimized for the 5700U — settings may not be optimal"
        WARNINGS=$((WARNINGS + 1))
        ;;
esac

# ---------------------------------------------------------------------------
# 3. AMD GPU / Vulkan Check
# ---------------------------------------------------------------------------
info "Checking AMD GPU and Vulkan..."

if [ "$_OS" = "FreeBSD" ]; then
    # Check for DRM kernel module
    if kldstat -q -m amdgpu 2>/dev/null; then
        ok "amdgpu kernel module loaded"
    else
        fail "amdgpu kernel module not loaded"
        fail "Install: pkg install drm-kmod gpu-firmware-amd-kmod"
        fail "Enable:  sysrc kld_list+=amdgpu && reboot"
        ERRORS=$((ERRORS + 1))
    fi

    # Check Vulkan
    if [ -f /usr/local/lib/libvulkan.so ] || ldconfig -r 2>/dev/null | grep -q libvulkan; then
        ok "libvulkan (Vulkan loader)"
    else
        fail "libvulkan not found — install: pkg install vulkan-loader mesa-dri"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 4. Runtime directories
# ---------------------------------------------------------------------------
info "Creating runtime directories..."
mkdir -p "$JENOVA_ROOT/.jenova" 2>/dev/null || {
    fail "Cannot create $JENOVA_ROOT/.jenova directory"
    ERRORS=$((ERRORS + 1))
}
mkdir -p "$JENOVA_ROOT/var/log" || true
mkdir -p "$JENOVA_ROOT/var/cache" || true
mkdir -p "$JENOVA_ROOT/models" || true
ok "Runtime directories created"

# ---------------------------------------------------------------------------
# 5. Required binaries
# ---------------------------------------------------------------------------
info "Checking required binaries..."

check_bin() {
    _name="$1"; _pkg="$2"
    if command -v "$_name" >/dev/null 2>&1; then
        ok "$_name"
    else
        fail "$_name not found — install: $_pkg"
        ERRORS=$((ERRORS + 1))
    fi
}

check_optional() {
    _name="$1"; _pkg="$2"
    if command -v "$_name" >/dev/null 2>&1; then
        ok "$_name (optional)"
    else
        warn "$_name not found (optional) — install: $_pkg"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_bin  "luajit"  "pkg install luajit-openresty"
check_bin  "git"     "pkg install git"

if [ "$SKIP_NVIM" = "0" ]; then
    check_bin  "nvim"    "pkg install neovim"
    check_optional "gmake"  "pkg install gmake"
fi

check_optional "cmake"   "pkg install cmake"
check_optional "curl"    "pkg install curl"

# ---------------------------------------------------------------------------
# 5b. llama.cpp build check
# ---------------------------------------------------------------------------
info "Checking llama.cpp build..."
LLAMA_BIN="$JENOVA_ROOT/llama.cpp/build/bin/llama-server"
if [ -f "$LLAMA_BIN" ]; then
    ok "llama-server binary found at $LLAMA_BIN"
else
    warn "llama-server not found at $LLAMA_BIN"
    warn "Build llama.cpp with Vulkan support (requires cmake, gmake, vulkan-loader):"
    warn "  cd $JENOVA_ROOT/llama.cpp"
    warn "  cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release"
    warn "  cmake --build build --config Release -j\$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 8)"
    warn "For AMD on FreeBSD, also install: pkg install drm-kmod gpu-firmware-amd-kmod"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 6. Deploy profile config
# ---------------------------------------------------------------------------
info "Installing hardware profile configuration..."
PROFILE_DIR="$(dirname "$(realpath "$0")")"
PROFILE_CONF="$PROFILE_DIR/jenova.conf"

if [ -f "$PROFILE_CONF" ]; then
    if [ -f "$JENOVA_ROOT/etc/jenova.conf" ]; then
        _ts=$(date +%Y%m%d_%H%M%S)
        cp "$JENOVA_ROOT/etc/jenova.conf" "$JENOVA_ROOT/etc/jenova.conf.bak.${_ts}"
        ok "Backed up existing config to etc/jenova.conf.bak.${_ts}"
    fi
    mkdir -p "$JENOVA_ROOT/etc"
    cp "$PROFILE_CONF" "$JENOVA_ROOT/etc/jenova.conf"
    ok "Deployed AMD Ryzen 7 5700U configuration to etc/jenova.conf"
else
    warn "Profile jenova.conf not found at $PROFILE_DIR"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
printf "${_B}  Installation Summary${_N}\n"
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
echo "  Profile:  freebsd-ryzen7-5700u-amd"
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo ""
if [ "$ERRORS" -gt 0 ]; then
    fail "Installation incomplete — resolve errors above."
    exit 1
else
    ok "Profile installation complete."
fi

echo ""
info "Next steps:"
echo "  1. Run: sudo $PROFILE_DIR/jenova-setup  (one-time system tuning)"
echo "  2. Build llama.cpp with Vulkan: cd llama.cpp && cmake -B build -DGGML_VULKAN=ON"
echo "  3. Download models to $JENOVA_ROOT/models/"
echo "  4. Start: bin/jenova-ca --daemon"
echo ""
info "AMD Lucienne notes:"
echo "  - Ensure drm-kmod and gpu-firmware-amd-kmod are installed"
echo "  - BIOS: set UMA Frame Buffer to 4GB+ for better GPU offload"
echo "  - This profile offloads 18/28 layers to Vulkan (adjust NGL_7B in jenova.conf)"
echo "  - Monitor with: sysctl dev.amdgpu.0 (FreeBSD AMD GPU stats)"
echo ""
