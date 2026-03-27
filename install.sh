#!/bin/sh
# install.sh: Jenova Cognitive Architecture — System Installation Script
# FreeBSD 15 | Dual Vulkan GPU (GTX 1650 Ti + Intel Iris Xe) | Optane NVMe
#
# Usage: ./install.sh [--force] [--link] [--skip-nvim] [--skip-llama]
#
#   --force       Overwrite existing ~/.config/nvim without prompting
#   --link        Install Neovim config as symlinks (for development workflow)
#   --skip-nvim   Skip Neovim config installation
#   --skip-llama  Skip llama.cpp build check
#
# This script:
#   1. Verifies required system dependencies
#   2. Creates required runtime directories (var/log, var/cache, models, .jenova)
#   3. Checks for llama.cpp build
#   4. Installs the Neovim configuration to ~/.config/nvim/
#   5. Installs bin/jvim symlink to ~/bin/ or ~/.local/bin/ if on PATH
#   6. Prints a summary of what is ready and what still needs manual setup

set -e

JENOVA_ROOT="$(dirname "$(realpath "$0")")"
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
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            echo "Run: $0 --help" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours (disabled if not a terminal)
# ---------------------------------------------------------------------------
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
printf "${_B}║  Jenova Cognitive Architecture — Install             ║${_N}\n"
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
            warn "FreeBSD ${_VER} — recommended FreeBSD 15+; some features may differ"
            WARNINGS=$((WARNINGS + 1))
        fi
        ;;
    Linux)
        warn "Linux detected — Jenova is optimised for FreeBSD 15. BSD socket constants and Vulkan paths may differ."
        warn "Replace 'Vulkan0,Vulkan1' device names in etc/jenova.conf with your Vulkan device names."
        WARNINGS=$((WARNINGS + 1))
        ;;
    *)
        warn "Unsupported OS: $_OS — proceeding but results may vary."
        WARNINGS=$((WARNINGS + 1))
        ;;
esac

# ---------------------------------------------------------------------------
# 2. Required binaries
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
    check_optional "gmake"  "pkg install gmake  (needed for telescope-fzf-native)"
fi

check_optional "curl"    "pkg install curl      (used by jenova-ca health probe fallback)"

# Vulkan loader
if [ "$_OS" = "FreeBSD" ]; then
    if [ -f /usr/local/lib/libvulkan.so ] || ldconfig -r 2>/dev/null | grep -q libvulkan; then
        ok "libvulkan (Vulkan loader)"
    else
        warn "libvulkan not found — install: pkg install vulkan-loader"
        warn "Without Vulkan, llama-server falls back to CPU-only inference."
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 3. Optional LSP servers / formatters
# ---------------------------------------------------------------------------
info "Checking optional LSP servers..."

check_optional "clangd"               "pkg install llvm (provides clangd)"
check_optional "rust-analyzer"        "pkg install rust-analyzer  OR  rustup component add rust-analyzer"
check_optional "lua-language-server"  "pkg install lua-language-server"
check_optional "pyright"              "pkg install py311-pyright"
check_optional "zls"                  "pkg install zig  (includes zls on some versions)"
check_optional "bash-language-server" "npm install -g bash-language-server"
check_optional "stylua"               "cargo install stylua  OR  pkg install stylua"
check_optional "goimports"            "go install golang.org/x/tools/cmd/goimports@latest"

# ---------------------------------------------------------------------------
# 4. Runtime directories
# ---------------------------------------------------------------------------
info "Creating runtime directories..."

for _d in \
    "$JENOVA_ROOT/models" \
    "$JENOVA_ROOT/var/log" \
    "$JENOVA_ROOT/var/cache" \
    "$JENOVA_ROOT/.jenova"
do
    mkdir -p "$_d"
    ok "$_d"
done

# ---------------------------------------------------------------------------
# 5. llama.cpp build check
# ---------------------------------------------------------------------------
if [ "$SKIP_LLAMA" = "0" ]; then
    info "Checking llama.cpp build..."
    LLAMA_BIN="$JENOVA_ROOT/llama.cpp/build/bin/llama-server"
    if [ -f "$LLAMA_BIN" ]; then
        ok "llama-server binary found at $LLAMA_BIN"
    else
        warn "llama-server not found at $LLAMA_BIN"
        warn "Build llama.cpp with Vulkan support:"
        warn "  cd $JENOVA_ROOT/llama.cpp"
        warn "  cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release"
        warn "  cmake --build build --config Release -j\$(nproc)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 6. Model files
# ---------------------------------------------------------------------------
info "Checking model files..."
. "$JENOVA_ROOT/etc/jenova.conf" 2>/dev/null || true

check_model() {
    _path="$1"; _name="$2"
    if [ -f "$_path" ]; then
        ok "$_name"
    else
        warn "$_name not found at $_path"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_model "${MODEL_7B:-$JENOVA_ROOT/models/Qwen2.5-Coder-7B-Q5_K_M.gguf}"             "7B agent model (Qwen2.5-Coder-7B-Q5_K_M)"
check_model "${MODEL_EMBED:-$JENOVA_ROOT/models/nomic-embed-text-v1.5.Q8_0.gguf}"        "Embedding model (nomic-embed-text-v1.5)"
if [ -f "${MODEL_DRAFT:-$JENOVA_ROOT/models/Qwen2.5-Coder-0.5B-Q8_0.gguf}" ]; then
    ok "Draft model (Qwen2.5-Coder-0.5B-Q8_0) — speculative decoding enabled"
else
    warn "Draft model not found — speculative decoding disabled (set JENOVA_DRAFT=0 in conf)"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 7. Neovim config installation
# ---------------------------------------------------------------------------
if [ "$SKIP_NVIM" = "0" ] && command -v nvim >/dev/null 2>&1; then
    info "Installing Neovim configuration..."

    if [ -d "$NVIM_CONFIG_DST" ] && [ "$FORCE" = "0" ]; then
        printf "  ~/.config/nvim already exists. Overwrite? [y/N] "
        read _ans
        case "$_ans" in
            y|Y|yes|YES) ;;
            *)
                warn "Skipping Neovim config installation (use --force to override)"
                SKIP_NVIM=1
                ;;
        esac
    fi

    if [ "$SKIP_NVIM" = "0" ]; then
        # Backup existing config
        if [ -d "$NVIM_CONFIG_DST" ]; then
            _TS=$(date +%Y%m%d_%H%M%S)
            _BAK="${NVIM_CONFIG_DST}.bak.${_TS}"
            mv "$NVIM_CONFIG_DST" "$_BAK"
            ok "Backed up existing config to $_BAK"
        fi

        mkdir -p "$NVIM_CONFIG_DST/lua/plugins"
        mkdir -p "$NVIM_CONFIG_DST/lua/jenova"

        if [ "$LINK" = "1" ]; then
            # Symlink mode — changes in repo instantly reflected in Neovim
            ln -sf "$NVIM_CONFIG_SRC/init.lua"        "$NVIM_CONFIG_DST/init.lua"
            ln -sf "$NVIM_CONFIG_SRC/lazy-lock.json"  "$NVIM_CONFIG_DST/lazy-lock.json"
            for _f in "$NVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$NVIM_CONFIG_DST/lua/plugins/$(basename "$_f")"
            done
            for _f in "$NVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$NVIM_CONFIG_DST/lua/jenova/$(basename "$_f")"
            done
            ok "Symlinked Neovim config (--link mode, edits in $NVIM_CONFIG_SRC take effect immediately)"
        else
            # Copy mode — stable snapshot
            cp "$NVIM_CONFIG_SRC/init.lua"       "$NVIM_CONFIG_DST/init.lua"
            cp "$NVIM_CONFIG_SRC/lazy-lock.json" "$NVIM_CONFIG_DST/lazy-lock.json"
            cp "$NVIM_CONFIG_SRC/lua/plugins/"*.lua "$NVIM_CONFIG_DST/lua/plugins/"
            for _f in "$NVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$NVIM_CONFIG_DST/lua/jenova/"
            done
            ok "Copied Neovim config to $NVIM_CONFIG_DST"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 8. Install bin/jvim to PATH
# ---------------------------------------------------------------------------
info "Installing jvim launcher..."

_BIN_DIR=""
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    if echo "$PATH" | grep -q "$_d"; then
        _BIN_DIR="$_d"
        break
    fi
done

if [ -n "$_BIN_DIR" ]; then
    mkdir -p "$_BIN_DIR"
    ln -sf "$JENOVA_ROOT/bin/jvim" "$_BIN_DIR/jvim"
    ln -sf "$JENOVA_ROOT/bin/jenova" "$_BIN_DIR/jenova"
    ok "Symlinked jvim + jenova to $_BIN_DIR"
else
    warn "No writable bin dir found on PATH (~/.local/bin or ~/bin)."
    warn "Add '$JENOVA_ROOT/bin' to your PATH or manually symlink:"
    warn "  ln -sf $JENOVA_ROOT/bin/jvim ~/.local/bin/jvim"
fi

# ---------------------------------------------------------------------------
# 9. jenova-setup (system tuning) reminder
# ---------------------------------------------------------------------------
if [ "$_OS" = "FreeBSD" ]; then
    info "System tuning..."
    warn "Run 'sudo $JENOVA_ROOT/jenova-setup' once to tune vm.* sysctls and ZFS ARC"
    warn "for optimal Optane swap / Iris Xe UMA performance."
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------------------------
echo ""
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
printf "${_B}  Installation Summary${_N}\n"
printf "${_B}══════════════════════════════════════════════════════${_N}\n"
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo ""
if [ "$ERRORS" -gt 0 ]; then
    fail "Installation incomplete — resolve errors above before running Jenova."
    echo ""
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    warn "Installation complete with warnings (see above). Core features will work;"
    warn "some optional features (LSP servers, formatters, speculative decoding)"
    warn "may be unavailable until dependencies are installed."
else
    ok "Installation complete — all required dependencies found."
fi

echo ""
info "Next steps:"
echo "  1. Place model GGUF files in: $JENOVA_ROOT/models/"
echo "  2. Build llama.cpp if not done: cd llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build -j\$(nproc)"
echo "  3. Start the backend:  $JENOVA_ROOT/bin/jenova-ca --daemon"
echo "     Or launch agent:    $JENOVA_ROOT/bin/jenova"
echo "     Or launch editor:   $JENOVA_ROOT/bin/jvim  (or just: jvim)"
if [ "$SKIP_NVIM" = "0" ]; then
    echo "  4. Inside Neovim:      :Lazy install   (install plugins on first launch)"
fi
echo ""
