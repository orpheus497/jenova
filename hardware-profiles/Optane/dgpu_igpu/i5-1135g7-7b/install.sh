#!/bin/sh
# install.sh: Jenova Cognitive Architecture — Dual-GPU 7B Profile Installation (Optane)
# FreeBSD 15 | Dual Vulkan GPU (GTX 1650 Ti + Intel Iris Xe) | Optane NVMe
# Model: Qwen2.5-Coder-7B-Instruct-Q5_K_M (~4.8 GiB)
#
# Usage: ./install.sh [--force] [--link] [--skip-nvim] [--skip-llama]

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")")")"
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
            sed -n '2,6p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            exit 1
            ;;
    esac
done

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
printf "${_B}║  Jenova CA — 7B Dual-GPU Optane Profile Install      ║${_N}\n"
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
            ok "FreeBSD ${_VER}"
        else
            warn "FreeBSD ${_VER} — recommended FreeBSD 15+"
            WARNINGS=$((WARNINGS + 1))
        fi
        ;;
    *)
        warn "Unsupported OS: $_OS — this profile is FreeBSD-specific (Optane swap, mdmfs)"
        WARNINGS=$((WARNINGS + 1))
        ;;
esac

# ---------------------------------------------------------------------------
# 2. Runtime directories
# ---------------------------------------------------------------------------
info "Creating runtime directories..."
mkdir -p "$JENOVA_ROOT/.jenova" 2>/dev/null || {
    fail "Cannot create $JENOVA_ROOT/.jenova — do not run with sudo"
    ERRORS=$((ERRORS + 1))
}
mkdir -p "$JENOVA_ROOT/var/log" || true
mkdir -p "$JENOVA_ROOT/var/cache" || true
mkdir -p "$JENOVA_ROOT/models/agent" || true
mkdir -p "$JENOVA_ROOT/models/embed" || true
mkdir -p "$JENOVA_ROOT/models/draft" || true
ok "Runtime directories"

# ---------------------------------------------------------------------------
# 3. Required binaries
# ---------------------------------------------------------------------------
info "Checking required binaries..."

check_bin() {
    if command -v "$1" >/dev/null 2>&1; then ok "$1"
    else fail "$1 not found — install: $2"; ERRORS=$((ERRORS + 1)); fi
}
check_optional() {
    if command -v "$1" >/dev/null 2>&1; then ok "$1 (optional)"
    else warn "$1 not found (optional) — install: $2"; WARNINGS=$((WARNINGS + 1)); fi
}

check_bin "luajit" "pkg install luajit-openresty"
check_bin "git" "pkg install git"
[ "$SKIP_NVIM" = "0" ] && check_bin "nvim" "pkg install neovim"
check_optional "cmake" "pkg install cmake"

if [ "$_OS" = "FreeBSD" ]; then
    if [ -f /usr/local/lib/libvulkan.so ] || ldconfig -r 2>/dev/null | grep -q libvulkan; then
        ok "libvulkan (Vulkan loader)"
    else
        fail "libvulkan not found — pkg install vulkan-loader (required for dual-GPU)"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 4. Swap-backed mount check
# ---------------------------------------------------------------------------
info "Checking swap-backed model filesystem..."
MOUNT_DIR="/mnt/jenova-models"
if mount | grep -q "on $MOUNT_DIR "; then
    ok "$MOUNT_DIR mounted"
    df -h "$MOUNT_DIR" | tail -1 | awk '{printf "     %s used / %s total (%s)\n", $3, $2, $5}'
else
    warn "$MOUNT_DIR not mounted — model needs swap-backed mdmfs"
    warn "  Run: sudo ./hardware-profiles/Optane/dgpu_igpu/i5-1135g7-7b/jenova-setup"
    warn "  Or:  sudo mdmfs -S -s 8G md $MOUNT_DIR && chmod 775 $MOUNT_DIR"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 5. llama.cpp build
# ---------------------------------------------------------------------------
if [ "$SKIP_LLAMA" = "0" ]; then
    info "Checking llama.cpp build..."
    LLAMA_BIN="$JENOVA_ROOT/llama.cpp/build/bin/llama-server"
    if [ -f "$LLAMA_BIN" ]; then
        ok "llama-server found"
    else
        warn "llama-server not found — build with Vulkan:"
        warn "  cd $JENOVA_ROOT/llama.cpp"
        warn "  cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release"
        warn "  cmake --build build --config Release -j\$(sysctl -n hw.ncpu)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 6. Model files
# ---------------------------------------------------------------------------
info "Checking model files..."
. "$JENOVA_ROOT/etc/jenova.conf" 2>/dev/null || true

_agent_model="${MODEL_PATH:-$JENOVA_ROOT/models/agent/Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf}"
if [ -f "$_agent_model" ] || [ -L "$_agent_model" ]; then
    ok "Agent model (7B): $(basename "$_agent_model")"
    if [ -L "$_agent_model" ]; then
        _target=$(realpath "$_agent_model" 2>/dev/null)
        if [ -f "$_target" ]; then
            ok "  -> $_target (symlink valid)"
        else
            fail "  -> $_target (symlink BROKEN — target missing)"
            ERRORS=$((ERRORS + 1))
        fi
    fi
else
    fail "Agent model not found at $_agent_model"
    echo "     Place a 7B GGUF model in models/agent/ or symlink from $MOUNT_DIR"
    echo "     e.g.: ln -s $MOUNT_DIR/Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf models/agent/"
    ERRORS=$((ERRORS + 1))
fi

_embed_model="${MODEL_EMBED:-$JENOVA_ROOT/models/embed/nomic-embed-text-v1.5.Q8_0.gguf}"
if [ -f "$_embed_model" ]; then
    ok "Embedding model: $(basename "$_embed_model")"
else
    warn "Embedding model not found — RAG/indexing unavailable"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 7. Deploy profile config
# ---------------------------------------------------------------------------
info "Deploying 7B profile configuration..."
_PROFILE_DIR="$(dirname "$(realpath "$0")")"
_PROFILE_CONF="$_PROFILE_DIR/jenova.conf"

if [ -f "$_PROFILE_CONF" ]; then
    if [ -f "$JENOVA_ROOT/etc/jenova.conf" ]; then
        _ts=$(date +%Y%m%d_%H%M%S)
        cp "$JENOVA_ROOT/etc/jenova.conf" "$JENOVA_ROOT/etc/jenova.conf.bak.${_ts}"
        ok "Backed up existing config to etc/jenova.conf.bak.${_ts}"
    fi
    cp "$_PROFILE_CONF" "$JENOVA_ROOT/etc/jenova.conf"
    ok "Deployed 7B profile to etc/jenova.conf"
else
    fail "Profile jenova.conf not found at $_PROFILE_CONF"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 8. Neovim config
# ---------------------------------------------------------------------------
if [ "$SKIP_NVIM" = "0" ] && command -v nvim >/dev/null 2>&1; then
    info "Installing Neovim configuration..."
    if [ -d "$NVIM_CONFIG_DST" ] && [ "$FORCE" = "0" ]; then
        warn "~/.config/nvim exists — use --force to overwrite"
        SKIP_NVIM=1
    fi
    if [ "$SKIP_NVIM" = "0" ]; then
        if [ -d "$NVIM_CONFIG_DST" ]; then
            _TS=$(date +%Y%m%d_%H%M%S)
            mv "$NVIM_CONFIG_DST" "${NVIM_CONFIG_DST}.bak.${_TS}"
            ok "Backed up existing nvim config"
        fi
        mkdir -p "$NVIM_CONFIG_DST/lua/plugins" "$NVIM_CONFIG_DST/lua/jenova"
        if [ "$LINK" = "1" ]; then
            ln -sf "$NVIM_CONFIG_SRC/init.lua" "$NVIM_CONFIG_DST/init.lua"
            ln -sf "$NVIM_CONFIG_SRC/lazy-lock.json" "$NVIM_CONFIG_DST/lazy-lock.json"
            for _f in "$NVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$NVIM_CONFIG_DST/lua/plugins/"
            done
            for _f in "$NVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$NVIM_CONFIG_DST/lua/jenova/"
            done
            ok "Symlinked Neovim config (--link mode)"
        else
            cp "$NVIM_CONFIG_SRC/init.lua" "$NVIM_CONFIG_DST/"
            cp "$NVIM_CONFIG_SRC/lazy-lock.json" "$NVIM_CONFIG_DST/"
            for _f in "$NVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$NVIM_CONFIG_DST/lua/plugins/"
            done
            for _f in "$NVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$NVIM_CONFIG_DST/lua/jenova/"
            done
            ok "Copied Neovim config"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 9. Launchers
# ---------------------------------------------------------------------------
info "Installing launchers to PATH..."
_BIN_DIR=""
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in *:"$_d":*) _BIN_DIR="$_d"; break ;; esac
done
if [ -n "$_BIN_DIR" ]; then
    mkdir -p "$_BIN_DIR"
    ln -sf "$JENOVA_ROOT/bin/jvim" "$_BIN_DIR/jvim"
    ln -sf "$JENOVA_ROOT/bin/jenova" "$_BIN_DIR/jenova"
    ln -sf "$JENOVA_ROOT/bin/jenova-ca" "$_BIN_DIR/jenova-ca"
    ok "Symlinked jvim, jenova, jenova-ca to $_BIN_DIR"
else
    warn "No bin dir on PATH — add $JENOVA_ROOT/bin to PATH manually"
fi

# ---------------------------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------------------------
echo ""
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
printf "${_B}  Installation Summary (7B Profile)${_N}\n"
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo ""
if [ "$ERRORS" -gt 0 ]; then
    fail "Resolve errors above before running."
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    warn "Complete with warnings — see above."
else
    ok "Installation complete."
fi

echo ""
info "Next steps:"
echo "  1. Run system tuning (once):  sudo ./hardware-profiles/Optane/dgpu_igpu/i5-1135g7-7b/jenova-setup"
echo "  2. Ensure swap mount is up:   df -h /mnt/jenova-models"
echo "  3. Copy 7B model to mount:    cp <model>.gguf /mnt/jenova-models/"
echo "  4. Symlink into models/agent:  ln -sf /mnt/jenova-models/<model>.gguf models/agent/"
echo "  5. Start backend:             jenova-ca start"
echo "  6. Launch editor:             jvim"
echo ""
