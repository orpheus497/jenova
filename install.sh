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
# 2. Create required runtime directories
# ---------------------------------------------------------------------------
info "Creating runtime directories..."

mkdir -p "$JENOVA_ROOT/.jenova" 2>/dev/null || {
    fail "Cannot create $JENOVA_ROOT/.jenova directory"
    fail "Do not run install.sh with sudo — run as regular user"
    ERRORS=$((ERRORS + 1))
}
mkdir -p "$JENOVA_ROOT/var/log" || true
mkdir -p "$JENOVA_ROOT/var/cache" || true
mkdir -p "$JENOVA_ROOT/models" || true

if [ -w "$JENOVA_ROOT/.jenova" ]; then
    ok "Runtime directories created with proper permissions"
else
    warn ".jenova directory exists but may have permission issues"
    warn "Run: chmod -R u+w $JENOVA_ROOT/.jenova"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 3. Required binaries
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

check_optional "cmake"   "pkg install cmake     (needed to build llama.cpp)"
check_optional "curl"    "pkg install curl      (used by jenova-ca health probe fallback)"

# Web search dependency: FreeBSD 'fetch' (base system) or curl fallback
if command -v fetch >/dev/null 2>&1; then
    ok "fetch (web search: native FreeBSD fetch available)"
elif command -v curl >/dev/null 2>&1; then
    ok "curl (web search: curl fallback available)"
else
    warn "Neither fetch nor curl found — web search (<leader>as) and health probe fallback unavailable"
    warn "Install curl to enable web search: pkg install curl  OR  apt install curl"
    WARNINGS=$((WARNINGS + 1))
fi

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
# 4. Optional LSP servers / formatters
# ---------------------------------------------------------------------------
info "Checking optional LSP servers..."

# On FreeBSD, LLVM installs versioned clangd (clangd19, clangd18, …) without
# an unversioned symlink; try them all before falling back to plain 'clangd'.
if [ "$_OS" = "FreeBSD" ]; then
    _CLANGD_BIN=""
    for _c in clangd clangd19 clangd18 clangd17 clangd16 clangd15; do
        if command -v "$_c" >/dev/null 2>&1; then
            _CLANGD_BIN="$_c"
            break
        fi
    done
    if [ -n "$_CLANGD_BIN" ]; then
        ok "clangd (found as $_CLANGD_BIN) (optional)"
    else
        warn "clangd not found (optional) — install: pkg install llvm (provides clangd)"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    check_optional "clangd"               "pkg install llvm (provides clangd)"
fi
check_optional "rust-analyzer"        "pkg install rust-analyzer  OR  rustup component add rust-analyzer"
check_optional "lua-language-server"  "pkg install lua-language-server"
check_optional "pyright"              "pkg install py311-pyright"
check_optional "zls"                  "pkg install zig  (includes zls on some versions)"
check_optional "bash-language-server" "npm install -g bash-language-server"
check_optional "stylua"               "cargo install stylua  OR  pkg install stylua"
check_optional "goimports"            "go install golang.org/x/tools/cmd/goimports@latest"

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
        warn "  cmake --build build --config Release -j\$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 6. Model files — check and offer to download missing models
# ---------------------------------------------------------------------------
info "Checking model files..."
. "$JENOVA_ROOT/etc/jenova.conf" 2>/dev/null || true

# Determine which download tool is available
_DL_CMD=""
if command -v curl >/dev/null 2>&1; then
    _DL_CMD="curl"
elif command -v fetch >/dev/null 2>&1; then
    _DL_CMD="fetch"
fi

# Download a model file if missing. Args: path, name, url, size_hint [, required]
# Pass required=1 for models that are mandatory; failures increment ERRORS.
# Optional/recommended models (default) increment WARNINGS on failure so a
# transient download problem does not mark the whole install as failed.
download_model() {
    _path="$1"; _name="$2"; _url="$3"; _size="$4"; _required="${5:-0}"
    if [ -f "$_path" ]; then
        ok "$_name ($(basename "$_path"))"
        return 0
    fi
    if [ -z "$_DL_CMD" ]; then
        warn "$_name not found at $_path"
        warn "  Install curl or fetch, then re-run install.sh to auto-download"
        if [ "$_required" = "1" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
        return 0
    fi
    warn "$_name not found at $_path"
    printf "  Download %s (~%s)? [y/N] " "$(basename "$_path")" "$_size"
    read _ans
    case "$_ans" in
        y|Y|yes|YES)
            mkdir -p "$(dirname "$_path")"
            info "Downloading $(basename "$_path") (~$_size) ..."
            _tmp=$(mktemp "${_path}.tmp.XXXXXX")
            _dl_timeout="${JENOVA_DL_TIMEOUT:-14400}"
            if [ "$_DL_CMD" = "curl" ]; then
                if ! curl -L --fail --max-time "$_dl_timeout" --connect-timeout 30 --progress-bar -o "$_tmp" "$_url"; then
                    rm -f "$_tmp"
                    fail "Download failed for $_name"
                    if [ "$_required" = "1" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
                    return 0
                fi
            else
                if ! fetch -T "$_dl_timeout" -o "$_tmp" "$_url"; then
                    rm -f "$_tmp"
                    fail "Download failed for $_name"
                    if [ "$_required" = "1" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
                    return 0
                fi
            fi
            if [ -s "$_tmp" ]; then
                mv "$_tmp" "$_path"
                ok "$_name downloaded successfully"
                return 0
            else
                rm -f "$_tmp"
                fail "Download failed for $_name (empty file)"
                if [ "$_required" = "1" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
                return 0
            fi
            ;;
        *)
            warn "Skipping $_name download"
            if [ "$_required" = "1" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
            return 0
            ;;
    esac
}

# Agent model (required)
_agent_model="${MODEL_PATH:-${JENOVA_MODEL:-$JENOVA_ROOT/models/Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf}}"
download_model "$_agent_model" \
    "Agent model (Qwen2.5-Coder-7B-Instruct)" \
    "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q5_k_m.gguf" \
    "5.1GB" \
    "1"
if [ ! -s "$_agent_model" ]; then
    warn "Required agent model is missing: $_agent_model"
    warn "Core backend functionality is blocked until the agent model is installed"
fi

# Ensure Neovim health check default model path stays in sync.
# When JENOVA_MODEL is unset, Neovim expects $JENOVA_ROOT/models/jenova.gguf.
# Create or refresh a symlink pointing to the chosen agent model path.
if [ -f "$_agent_model" ]; then
    _jenova_link="$JENOVA_ROOT/models/jenova.gguf"
    mkdir -p "$(dirname "$_jenova_link")"
    if [ -L "$_jenova_link" ] || [ ! -e "$_jenova_link" ]; then
        ln -sf "$_agent_model" "$_jenova_link"
        ok "Symlinked models/jenova.gguf -> $(basename "$_agent_model")"
    fi
fi

# Embedding model (recommended for RAG)
download_model "${MODEL_EMBED:-$JENOVA_ROOT/models/nomic-embed-text-v1.5.Q8_0.gguf}" \
    "Embedding model (nomic-embed-text-v1.5)" \
    "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf" \
    "134MB"

# Draft model (optional — enables speculative decoding for ~1.5-2x speedup)
_draft_path="${MODEL_DRAFT:-$JENOVA_ROOT/models/Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf}"
if [ -f "$_draft_path" ]; then
    ok "Draft model — speculative decoding enabled"
else
    download_model "$_draft_path" \
        "Draft model (Qwen2.5-Coder-0.5B)" \
        "https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q8_0.gguf" \
        "530MB"
    if [ ! -f "$_draft_path" ]; then
        warn "Speculative decoding disabled without draft model (set JENOVA_DRAFT=0 in conf)"
    fi
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
            for _f in "$NVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$NVIM_CONFIG_DST/lua/plugins/"
            done
            for _f in "$NVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$NVIM_CONFIG_DST/lua/jenova/"
            done
            ok "Copied Neovim config to $NVIM_CONFIG_DST"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 8. Install launchers to PATH
# ---------------------------------------------------------------------------
info "Installing launchers to PATH..."

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
    ln -sf "$JENOVA_ROOT/bin/jenova-ca" "$_BIN_DIR/jenova-ca"
    ok "Symlinked jvim, jenova, and jenova-ca to $_BIN_DIR"
else
    warn "No writable bin dir found on PATH (~/.local/bin or ~/bin)."
    warn "Add '$JENOVA_ROOT/bin' to your PATH or manually symlink:"
    warn "  mkdir -p ~/.local/bin"
    warn "  ln -sf $JENOVA_ROOT/bin/jvim ~/.local/bin/jvim"
    warn "  ln -sf $JENOVA_ROOT/bin/jenova ~/.local/bin/jenova"
    warn "  ln -sf $JENOVA_ROOT/bin/jenova-ca ~/.local/bin/jenova-ca"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"  # Add to ~/.bashrc or ~/.zshrc"
fi

# ---------------------------------------------------------------------------
# 9. Hardware profile detection
# ---------------------------------------------------------------------------
info "Detecting hardware profile..."
DETECT_SCRIPT="$JENOVA_ROOT/hardware-profiles/detect-hardware.sh"
_PROFILE=""
if [ -f "$DETECT_SCRIPT" ] && [ -x "$DETECT_SCRIPT" ]; then
    _PROFILE=$("$DETECT_SCRIPT" 2>/dev/null) || _PROFILE=""
    if [ -n "$_PROFILE" ]; then
        ok "Matched hardware profile: $_PROFILE"
        _PROFILE_DIR="$JENOVA_ROOT/hardware-profiles/$_PROFILE"
        if [ -f "$_PROFILE_DIR/jenova-setup" ]; then
            warn "Run 'sudo $_PROFILE_DIR/jenova-setup' once to tune system for this hardware."
        fi
    else
        warn "No hardware profile matched this system."
        warn "Run: $DETECT_SCRIPT --info  to see detection details."
        warn "You can create a new profile in hardware-profiles/<name>/"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    warn "Hardware detection script not found at $DETECT_SCRIPT"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 9b. jenova-setup (system tuning) reminder — fallback for unmatched profiles
# ---------------------------------------------------------------------------
if [ "$_OS" = "FreeBSD" ] && [ -z "$_PROFILE" ]; then
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
echo "  2. Build llama.cpp if not done: cd llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build -j\$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "  3. Start the backend:  $JENOVA_ROOT/bin/jenova-ca --daemon"
echo "     Or launch agent:    $JENOVA_ROOT/bin/jenova"
echo "     Or launch editor:   $JENOVA_ROOT/bin/jvim  (or just: jvim)"
if [ "$SKIP_NVIM" = "0" ]; then
    echo "  4. Inside Neovim:      :Lazy install   (install plugins on first launch)"
fi
echo ""
