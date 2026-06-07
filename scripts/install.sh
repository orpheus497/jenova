#!/bin/sh
# install.sh: Jenova Cognitive Architecture — System Installation Script
# Supports all Vulkan hardware profiles (auto-detected via detect-hardware.sh)
#
# This is the single installer for the whole monorepo: it builds (or verifies)
# llama.cpp, builds the bundled jvim editor (which contains the embedded
# Jenova agent), downloads missing model GGUFs, deploys the jvim user config,
# and symlinks `jvim`, `jenova`, and `jenova-ca` onto your PATH.
#
# Usage: ./install.sh [--force] [--link] [--skip-config] [--skip-jvim]
#                     [--skip-llama] [--skip-web] [--client-only]
#
#   --force        Overwrite existing ~/.config/jvim without prompting and
#                  force a fresh jvim rebuild even if jvim/build/ exists
#   --link         Install Jenova jvim config as symlinks into ~/.config/jvim
#                  (development workflow — edits in repo apply immediately)
#   --skip-config  Skip the jvim user-config deployment step
#   --skip-jvim    Skip building the bundled jvim editor (jvim/)
#   --skip-llama   Skip llama.cpp build check
#   --skip-web     Skip building the JCA Web UI (jca_web/)
#   --client-only  LAN client install: skip llama.cpp, skip jvim build,
#                  skip model downloads, skip web UI. Use when this host will only ever
#                  connect to a remote Jenova CA via 'jvim --remote <host>'.
#
# This script:
#   1. Verifies required system dependencies
#   2. Creates required runtime directories (var/log, var/cache, models, .jenova)
#   3. Checks for llama.cpp build (skipped with --client-only)
#   4. Checks for Web UI build (skipped with --client-only or --skip-web)
#   5. Downloads required model files (skipped with --client-only)
#   6. Detects whether the installed nvim is jvim or upstream Neovim
#   7. Installs the Jenova nvim configuration to ~/.config/jvim/
#   8. Installs bin/jvim, bin/jenova, bin/jenova-ca symlinks to PATH
#   9. Prints a summary plus next-step commands

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
JVIM_CONFIG_SRC="$JENOVA_ROOT/jvim-config"
JVIM_CONFIG_DST="$HOME/.config/jvim"

# Shared OS/hardware detection — populates JENOVA_OS, JENOVA_DISTRO,
# JENOVA_PKG_MGR, JENOVA_VULKAN_OK, JENOVA_GH_ARCH_*, etc.
. "$JENOVA_ROOT/lib/detect-env.sh"
# Backward-compat alias used by legacy case-statements in this file.
case "$JENOVA_OS" in
    freebsd) _OS="FreeBSD" ;;
    linux)   _OS="Linux" ;;
    macos)   _OS="Darwin" ;;
    *)       _OS="$(uname -s)" ;;
esac

FORCE=0
LINK=0
SKIP_NVIM=0
SKIP_JVIM=0
SKIP_LLAMA=0
SKIP_WEB=0
CLIENT_ONLY=0

for _arg in "$@"; do
    case "$_arg" in
        --force)       FORCE=1 ;;
        --link)        LINK=1 ;;
        --skip-config|--skip-nvim) SKIP_NVIM=1 ;;
        --skip-jvim)   SKIP_JVIM=1 ;;
        --skip-llama)  SKIP_LLAMA=1 ;;
        --skip-web)    SKIP_WEB=1 ;;
        --client-only) CLIENT_ONLY=1; SKIP_LLAMA=1; SKIP_JVIM=1; SKIP_WEB=1 ;;
        -h|--help)
            sed -n '2,32p' "$0"
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
    _G=$(printf '\033[38;2;118;148;106m')
    _Y=$(printf '\033[38;2;192;163;110m')
    _R=$(printf '\033[38;2;195;64;67m')
    _B=$(printf '\033[38;2;126;156;216m')
    _P=$(printf '\033[38;2;120;81;169m')
    _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _P=""; _N=""
fi

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y} WARN${_N}  %s\n" "$1"; }
fail() { printf "${_R} FAIL${_N}  %s\n" "$1"; }
info() { printf "${_B} INFO${_N}  %s\n" "$1"; }

echo ""
printf "${_P}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_P}║  Jenova Cognitive Architecture — Install             ║${_N}\n"
printf "${_P}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

ERRORS=0
WARNINGS=0

# ---------------------------------------------------------------------------
# 1. OS Check & Hardware Profile Detection
# ---------------------------------------------------------------------------
info "Performing system audit..."
if [ "$JENOVA_OS" = "unknown" ]; then
    fail "Unsupported Operating System: $(uname -s)"
    exit 1
fi

case "$JENOVA_OS" in
    freebsd)
        _VER="$(uname -r | cut -d. -f1)"
        if [ "$_VER" -ge 15 ]; then
            ok "FreeBSD ${_VER} (1st Class Citizen) — fully supported"
        else
            warn "FreeBSD ${_VER} — recommended FreeBSD 15+; proceeding with caution"
            WARNINGS=$((WARNINGS + 1))
        fi
        ;;
    linux)
        if [ "$JENOVA_WSL" = "1" ]; then
            ok "Linux (WSL) — 2nd Class Citizen (Experimental Support)"
            warn "WSL environment detected. Some native GPU features may require specific drivers."
        else
            ok "Linux — 2nd Class Citizen (Fully Supported)"
        fi
        info "Replace 'Vulkan0,Vulkan1' device names in etc/jenova.conf with your Vulkan device names (run: vulkaninfo --summary)"
        ;;
    macos)
        warn "macOS detected — experimental, not regularly tested"
        WARNINGS=$((WARNINGS + 1))
        ;;
esac

info "Hardware: $JENOVA_CPU_MODEL ($JENOVA_CPU_THREADS threads, $JENOVA_RAM_GIB GiB RAM)"

info "Detecting hardware profile..."
DETECT_SCRIPT="$JENOVA_ROOT/hardware-profiles/detect-hardware.sh"
_PROFILE=""
if [ -f "$DETECT_SCRIPT" ] && [ -x "$DETECT_SCRIPT" ]; then
    _PROFILE=$("$DETECT_SCRIPT" 2>/dev/null) || _PROFILE=""
    if [ -n "$_PROFILE" ]; then
        ok "Matched hardware profile: $_PROFILE"
        # Automatically apply the profile configuration
        if ! "$DETECT_SCRIPT" --apply; then
            warn "Failed to apply hardware profile: $_PROFILE"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        warn "No hardware profile matched this system."
        warn "Run: $DETECT_SCRIPT --info  to see detection details."
        WARNINGS=$((WARNINGS + 1))
    fi
else
    warn "Hardware detection script not found at $DETECT_SCRIPT"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 2. Create required runtime directories & Permission checks
# ---------------------------------------------------------------------------
JENOVA_HOME="${JENOVA_HOME:-$HOME/Jenova}"
info "Creating runtime directories in $JENOVA_HOME..."

mkdir -p "$JENOVA_HOME/.system" 2>/dev/null || {
    fail "Cannot create $JENOVA_HOME/.system directory"
    fail "Do not run install.sh with sudo — run as regular user"
    ERRORS=$((ERRORS + 1))
}
mkdir -p "$JENOVA_HOME/var/log" || true
mkdir -p "$JENOVA_HOME/var/cache" || true
mkdir -p "$JENOVA_HOME/var/run" || true
mkdir -p "$JENOVA_HOME/models/agent" || true
mkdir -p "$JENOVA_HOME/models/embed" || true
mkdir -p "$JENOVA_HOME/models/draft" || true
mkdir -p "$JENOVA_HOME/bin" || true
mkdir -p "$JENOVA_HOME/etc" || true

if [ -w "$JENOVA_HOME/.system" ]; then
    ok "Runtime directories created in $JENOVA_HOME"
else
    warn "$JENOVA_HOME/.system directory exists but may have permission issues"
    WARNINGS=$((WARNINGS + 1))
fi

# Check for root-owned build artifacts that block regular-user builds
if [ -d "$JENOVA_ROOT/jvim/build" ] && [ ! -w "$JENOVA_ROOT/jvim/build" ]; then
    _owner=$(ls -ld "$JENOVA_ROOT/jvim/build" | awk '{print $3}')
    if [ "$_owner" = "root" ]; then
        fail "jvim/build is owned by root. This will cause the build to fail."
        fail "Run: sudo chown -R $(id -u):$(id -g) $JENOVA_ROOT/jvim"
        ERRORS=$((ERRORS + 1))
    fi
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
    # Prefer the in-tree jvim build (jvim/build/bin/nvim) which the unified
    # `make jvim` target produces. Fall back to whatever `nvim` is on PATH
    # (warn if it's not jvim) and finally fail with a build hint.
    _JVIM_BIN="$JENOVA_ROOT/jvim/build/bin/nvim"
    if [ -x "$_JVIM_BIN" ]; then
        _NVIM_VLINE=$("$_JVIM_BIN" --version 2>/dev/null | head -n 1)
        case "$_NVIM_VLINE" in
            *JVIM*) ok "in-tree jvim build ($_NVIM_VLINE) — fully integrated" ;;
            *)      warn "in-tree binary $_JVIM_BIN is not jvim ($_NVIM_VLINE)"; WARNINGS=$((WARNINGS + 1)) ;;
        esac
    elif command -v jvim >/dev/null 2>&1; then
        _NVIM_VLINE=$(jvim --version 2>/dev/null | head -n 1)
        case "$_NVIM_VLINE" in
            *JVIM*)
                ok "system nvim is jvim ($_NVIM_VLINE) — fully integrated"
                ;;
            *)
                warn "system nvim is upstream Neovim ($_NVIM_VLINE), not jvim."
                warn "Build the bundled jvim editor: make jvim"
                WARNINGS=$((WARNINGS + 1))
                ;;
        esac
    else
        if [ "$SKIP_JVIM" = "0" ]; then
            info "No editor found — will build bundled jvim later in this script"
        else
            fail "No editor found. Build the bundled jvim: make jvim"
            ERRORS=$((ERRORS + 1))
        fi
    fi
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
if [ "$JENOVA_VULKAN_OK" = "1" ]; then
    ok "libvulkan (Vulkan loader)"
else
    case "$JENOVA_PKG_MGR" in
        pkg)    _vhint="pkg install vulkan-loader" ;;
        pacman) _vhint="pacman -S vulkan-icd-loader (or yay -S vulkan-icd-loader)" ;;
        apt)    _vhint="apt-get install libvulkan-dev" ;;
        dnf)    _vhint="dnf install vulkan-loader" ;;
        zypper) _vhint="zypper install libvulkan1" ;;
        xbps)   _vhint="xbps-install vulkan-loader" ;;
        brew)   _vhint="brew install molten-vk" ;;
        *)      _vhint="install the vulkan-loader package for your OS" ;;
    esac
    warn "libvulkan not found — ${_vhint}"
    warn "Without Vulkan, llama-server falls back to CPU-only inference."
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 5. llama.cpp build check
# ---------------------------------------------------------------------------
if [ "$CLIENT_ONLY" = "1" ]; then
    info "Skipping llama.cpp build check (--client-only)"
elif [ "$SKIP_LLAMA" = "0" ]; then
    info "Checking llama-server binary..."
    LLAMA_BIN="$JENOVA_ROOT/bin/llama-server"
    if [ -f "$LLAMA_BIN" ]; then
        ok "llama-server binary found at $LLAMA_BIN"
    else
        warn "llama-server binary not found at $LLAMA_BIN"
        if [ -f "$JENOVA_ROOT/external/llama.cpp/CMakeLists.txt" ]; then
            info "Submodule external/llama.cpp is present. Auto-building..."
            if (cd "$JENOVA_ROOT" && git submodule update --init external/llama.cpp) && "$JENOVA_ROOT/bin/build-llama"; then
                cp "$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server" "$LLAMA_BIN"
                ok "Successfully built and deployed llama-server."
            else
                fail "Failed to build llama-server from source."
                ERRORS=$((ERRORS + 1))
            fi
        else
                *)
                    printf "${_B}  ?${_N} Initialize submodule and build from source? [y/N] "
                    read -r _ans_build < /dev/tty || _ans_build="N"
                    case "$_ans_build" in
                        y|Y|yes|YES)
                            info "Initializing submodule and building..."
                            if (cd "$JENOVA_ROOT" && git submodule update --init external/llama.cpp) && "$JENOVA_ROOT/bin/build-llama"; then
                                cp "$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server" "$LLAMA_BIN"
                                ok "Successfully built and deployed llama-server."
                            else
                                fail "Failed to build llama-server from source."
                                ERRORS=$((ERRORS + 1))
                            fi
                            ;;
                        *)
                            warn "llama-server not found and no action taken."
                            warn "You must deploy it to $LLAMA_BIN or run installer again."
                            WARNINGS=$((WARNINGS + 1))
                            ;;
                    esac
                    ;;
            esac
        fi
    fi
fi

# ---------------------------------------------------------------------------



# ---------------------------------------------------------------------------
# 6. Model files — check and offer to download missing models
# ---------------------------------------------------------------------------
if [ "$CLIENT_ONLY" = "1" ] || [ "${JENOVA_SKIP_MODELS:-0}" = "1" ]; then
    info "Skipping model checks..."
else
    if [ -x "$JENOVA_ROOT/scripts/model_dl.sh" ]; then
        "$JENOVA_ROOT/scripts/model_dl.sh" "$_PROFILE" || {
            warn "Model download process was incomplete or skipped."
            WARNINGS=$((WARNINGS + 1))
        }
    else
        warn "Model download script not found at scripts/model_dl.sh"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 7. Neovim config installation
# ---------------------------------------------------------------------------
    info "Installing jvim configuration..."

    if [ -d "$JVIM_CONFIG_DST" ] && [ "$FORCE" = "0" ]; then
        printf "  ~/.config/jvim already exists. Overwrite? [y/N] "
        read -r _ans
        case "$_ans" in
            y|Y|yes|YES) ;;
            *)
                warn "Skipping jvim config installation (use --force to override)"
                SKIP_NVIM=1
                ;;
        esac
    fi

    if [ "$SKIP_NVIM" = "0" ]; then
        # Backup existing config
        if [ -d "$JVIM_CONFIG_DST" ]; then
            _TS=$(date +%Y%m%d_%H%M%S)
            _BAK="${JVIM_CONFIG_DST}.bak.${_TS}"
            mv "$JVIM_CONFIG_DST" "$_BAK"
            ok "Backed up existing config to $_BAK"
        fi

        mkdir -p "$JVIM_CONFIG_DST/lua/plugins"
        mkdir -p "$JVIM_CONFIG_DST/lua/jenova"

        if [ "$LINK" = "1" ]; then
            # Symlink mode — changes in repo instantly reflected in jvim
            ln -sf "$JVIM_CONFIG_SRC/init.lua" "$JVIM_CONFIG_DST/init.lua"
            for _f in "$JVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$JVIM_CONFIG_DST/lua/plugins/$(basename "$_f")"
            done
            # jenova/ contains both leaf .lua modules AND the agent/ subtree
            for _f in "$JVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && ln -sf "$_f" "$JVIM_CONFIG_DST/lua/jenova/$(basename "$_f")"
            done
            ln -sfn "$JVIM_CONFIG_SRC/lua/jenova/agent" \
                "$JVIM_CONFIG_DST/lua/jenova/agent"
            ok "Symlinked jvim user config (--link mode, edits in $JVIM_CONFIG_SRC take effect immediately)"
        else
            # Copy mode — stable snapshot
            cp "$JVIM_CONFIG_SRC/init.lua" "$JVIM_CONFIG_DST/init.lua"
            for _f in "$JVIM_CONFIG_SRC/lua/plugins/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$JVIM_CONFIG_DST/lua/plugins/"
            done
            for _f in "$JVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$JVIM_CONFIG_DST/lua/jenova/"
            done
            cp -r "$JVIM_CONFIG_SRC/lua/jenova/agent" \
                "$JVIM_CONFIG_DST/lua/jenova/"
            ok "Copied jvim user config to $JVIM_CONFIG_DST"
        fi
        info "Plugins ship vendored inside jvim/runtime/pack/jenova/start/ — no network fetch required."
    fi
fi

# ---------------------------------------------------------------------------
# 8. Deploy to JENOVA_HOME (Strict Separation)
# ---------------------------------------------------------------------------
info "Deploying standalone system to $JENOVA_HOME..."

# 8.1 Create directory structure
for _d in bin etc lib public hardware-profiles share var/log var/cache var/run models/agent models/embed models/draft jvim/runtime; do
    mkdir -p "$JENOVA_HOME/$_d"
done

# 8.2 Verify and Deploy Binaries
_verify_and_copy_bin() {
    _src="$1"; _dst="$2"
    [ -f "$_src" ] || return 1
    
    # OS/Arch verification
    if command -v file >/dev/null 2>&1; then
        _file_info=$(file "$_src")
        case "$JENOVA_OS" in
            linux)   echo "$_file_info" | grep -qi "ELF.*GNU/Linux" || { info "Skipping Linux-only binary: $(basename "$_src")"; return 0; } ;;
            freebsd) echo "$_file_info" | grep -qi "ELF.*FreeBSD"   || { info "Skipping non-FreeBSD binary: $(basename "$_src")"; return 0; } ;;
            macos)   echo "$_file_info" | grep -qi "Mach-O"       || { info "Skipping non-macOS binary: $(basename "$_src")"; return 0; } ;;
        esac
    fi
    
    # Use 'install' to handle 'Text file busy' and set permissions
    install -m 755 "$_src" "$_dst"
    return 0
}

# wrappers
for _bin in jvim jenova jenova-ui jenova-ca jenova-tui jenova-term jenova-swap-mount; do
    if [ -f "$JENOVA_ROOT/bin/$_bin" ]; then
        install -m 755 "$JENOVA_ROOT/bin/$_bin" "$JENOVA_HOME/bin/$_bin"
    fi
done

# Built artifacts (llama-server, jenova-ui)
_LLAMA_BUILD_BIN="$JENOVA_ROOT/bin/llama-server"
if [ ! -f "$_LLAMA_BUILD_BIN" ] && [ -f "$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server" ]; then
    _LLAMA_BUILD_BIN="$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server"
fi

if [ -f "$_LLAMA_BUILD_BIN" ]; then
    _verify_and_copy_bin "$_LLAMA_BUILD_BIN" "$JENOVA_HOME/bin/llama-server"
    # Copy shared libs if they exist (only really applicable for source builds)
    for _lib in "$JENOVA_ROOT/external/llama.cpp/build/bin/"*.so* "$JENOVA_ROOT/external/llama.cpp/build/bin/"*.dylib*; do
        if [ -f "$_lib" ]; then
            install -m 755 "$_lib" "$JENOVA_HOME/bin/"
        fi
    done
    ok "Deployed llama.cpp backend to $JENOVA_HOME/bin"
fi


if [ -f "$JENOVA_ROOT/jenova-ui/jenova-ui" ]; then
    _verify_and_copy_bin "$JENOVA_ROOT/jenova-ui/jenova-ui" "$JENOVA_HOME/bin/jenova-ui"
fi

# jvim core (nvim)
_JVIM_CORE="$JENOVA_ROOT/jvim/build/bin/nvim"
if [ ! -f "$_JVIM_CORE" ]; then _JVIM_CORE="$JENOVA_ROOT/jvim/build/bin/jvim"; fi
if [ -f "$_JVIM_CORE" ]; then
    _verify_and_copy_bin "$_JVIM_CORE" "$JENOVA_HOME/bin/jvim-core"
fi

# 8.3 Deploy Assets, Scripts, and Config
cp -R "$JENOVA_ROOT/lib/"* "$JENOVA_HOME/lib/"
cp -R "$JENOVA_ROOT/hardware-profiles/"* "$JENOVA_HOME/hardware-profiles/"
cp -R "$JENOVA_ROOT/jvim/runtime/"* "$JENOVA_HOME/jvim/runtime/"
[ -d "$JENOVA_ROOT/public" ] && cp -R "$JENOVA_ROOT/public/"* "$JENOVA_HOME/public/"

ok "Deployed libraries, hardware profiles, runtime, and web assets"

# 8.4 Generate Path-Locked Config
cat > "$JENOVA_HOME/etc/jenova.local.conf" <<EOF
#!/bin/sh
# Path-locked configuration generated by install.sh on $(date)
# This ensures the installation is decoupled from the source repository.

JENOVA_ROOT="$JENOVA_HOME"
LLAMA_SERVER="\$JENOVA_ROOT/bin/llama-server"
LLAMA_LIB_DIR="\$JENOVA_ROOT/bin"
VIMRUNTIME="\$JENOVA_ROOT/jvim/runtime"
EOF

# Copy base config if missing
if [ ! -f "$JENOVA_HOME/etc/jenova.conf" ]; then
    cp "$JENOVA_ROOT/etc/jenova.conf" "$JENOVA_HOME/etc/"
fi
ok "Deployed path-locked configuration to $JENOVA_HOME/etc"

# 8.5 Symlink to PATH
_LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$_LOCAL_BIN"

for _bin in jvim jenova jenova-ui jenova-ca jenova-tui jenova-term jenova-swap-mount; do
    if [ -f "$JENOVA_HOME/bin/$_bin" ]; then
        ln -sf "$JENOVA_HOME/bin/$_bin" "$_LOCAL_BIN/$_bin"
    fi
done


ok "Symlinked launchers from $JENOVA_HOME/bin to $_LOCAL_BIN"

# Warn if ~/.local/bin is not on PATH
_ON_PATH=0
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    echo "$PATH" | grep -q "$_d" && _ON_PATH=1
done
if [ "$_ON_PATH" = "0" ]; then
    warn "$_LOCAL_BIN is not on your PATH."
    warn "Add this to your shell rc file (~/.bashrc, ~/.zshrc, etc.):"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    WARNINGS=$((WARNINGS + 1))
fi

# Install Desktop Entries & Icons (always — these don't depend on PATH)
if [ "$JENOVA_OS" = "linux" ] || [ "$JENOVA_OS" = "freebsd" ]; then
    _APP_DIR="$HOME/.local/share/applications"
    mkdir -p "$_APP_DIR"

    # Cleanup obsolete entries
    rm -f "$_APP_DIR/jenova-manager.desktop"

    # Install Icons and PNGs FIRST so desktop entries can reference them
    mkdir -p "$JENOVA_HOME/png"
    _ICON_DIR="$HOME/.local/share/icons"
    mkdir -p "$_ICON_DIR"

    if [ -d "$JENOVA_ROOT/png" ]; then
        # Copy all source icons to deployment directory
        cp "$JENOVA_ROOT/png/"* "$JENOVA_HOME/png/" 2>/dev/null || true

        for icon in jenova jca jca_grey jvim; do
            # Determine the best available icon format
            _icon_deployed=""
            if [ -f "$JENOVA_ROOT/png/$icon.png" ]; then
                cp "$JENOVA_ROOT/png/$icon.png" "$_ICON_DIR/$icon.png"
                cp "$JENOVA_ROOT/png/$icon.png" "$JENOVA_HOME/png/$icon.png"
                _icon_deployed="$icon.png"
            elif [ -f "$JENOVA_ROOT/png/$icon.jpg" ]; then
                # Try to convert jpg→png for desktop compatibility
                if command -v convert >/dev/null 2>&1; then
                    convert "$JENOVA_ROOT/png/$icon.jpg" "$JENOVA_HOME/png/$icon.png"
                    cp "$JENOVA_HOME/png/$icon.png" "$_ICON_DIR/$icon.png"
                    _icon_deployed="$icon.png"
                elif command -v magick >/dev/null 2>&1; then
                    magick "$JENOVA_ROOT/png/$icon.jpg" "$JENOVA_HOME/png/$icon.png"
                    cp "$JENOVA_HOME/png/$icon.png" "$_ICON_DIR/$icon.png"
                    _icon_deployed="$icon.png"
                else
                    # No converter — use jpg directly (most DEs support it)
                    cp "$JENOVA_ROOT/png/$icon.jpg" "$_ICON_DIR/$icon.jpg"
                    cp "$JENOVA_ROOT/png/$icon.jpg" "$JENOVA_HOME/png/$icon.jpg"
                    _icon_deployed="$icon.jpg"
                fi
            fi

            # Create extensionless symlink for icon theme lookups
            if [ -n "$_icon_deployed" ] && [ -f "$_ICON_DIR/$_icon_deployed" ]; then
                ln -sf "$_ICON_DIR/$_icon_deployed" "$_ICON_DIR/$icon"
            fi
        done

        # Update icon cache
        gtk-update-icon-cache -f -t "$_ICON_DIR" 2>/dev/null || true
        ok "Installed icons to $_ICON_DIR and $JENOVA_HOME/png"
    fi

    # ISS-08: Rewrite desktop entries with targeted Exec= line replacement
    # instead of global substring sed which corrupted Name= and Comment= fields.
    for _dfile in jenova.desktop jvim.desktop; do
        if [ -f "$JENOVA_ROOT/bin/$_dfile" ]; then
            _icon_name=$(grep "^Icon=" "$JENOVA_ROOT/bin/$_dfile" | cut -d= -f2)

            # Resolve the actual icon path (prefer .png, fall back to .jpg)
            if [ -f "$JENOVA_HOME/png/$_icon_name.png" ]; then
                _icon_path="$JENOVA_HOME/png/$_icon_name.png"
            elif [ -f "$JENOVA_HOME/png/$_icon_name.jpg" ]; then
                _icon_path="$JENOVA_HOME/png/$_icon_name.jpg"
            else
                _icon_path="$_icon_name"  # Fall back to theme name lookup
            fi

            # Read original, rewrite only Exec= and Icon= lines
            # This avoids corrupting Name=, Comment=, or other fields
            # that happen to contain binary name substrings.
            _JHBIN="$JENOVA_HOME/bin"
            sed -e "/^Exec=/{ \
                s|jenova-term|$_JHBIN/jenova-term|g; \
                s|jenova-ui|$_JHBIN/jenova-ui|g; \
                s|jenova-ca|$_JHBIN/jenova-ca|g; \
                s| jvim | $_JHBIN/jvim |g; \
            }" \
                -e "s|^Icon=.*|Icon=$_icon_path|" \
                "$JENOVA_ROOT/bin/$_dfile" > "$_APP_DIR/$_dfile"
        fi
    done
    ok "Installed and path-locked desktop entries to $_APP_DIR"
fi

# ---------------------------------------------------------------------------
# 9. System Tuning Reminders
# ---------------------------------------------------------------------------
if [ -n "$_PROFILE" ]; then
    _PROFILE_DIR="$JENOVA_HOME/hardware-profiles/$_PROFILE"
    if [ -f "$_PROFILE_DIR/jenova-setup" ]; then
        warn "Run 'sudo $_PROFILE_DIR/jenova-setup' once to tune system for this hardware."
    fi
elif [ "$JENOVA_OS" = "freebsd" ]; then
    info "System tuning..."
    warn "Run 'sudo $JENOVA_ROOT/scripts/jenova-setup' once to tune vm.* sysctls and ZFS ARC"
    warn "for optimal Optane swap / Iris Xe UMA performance."
    WARNINGS=$((WARNINGS + 1))
fi


# ---------------------------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------------------------
echo ""
printf "${_P}══════════════════════════════════════════════════════${_N}\n"
printf "${_P}  Installation Summary${_N}\n"
printf "${_P}══════════════════════════════════════════════════════${_N}\n"
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
if [ "$CLIENT_ONLY" = "1" ]; then
    echo "  This is a LAN-client install. To connect to a remote Jenova CA:"
    echo "      jvim --remote <server-ip>            # default ports 8080/8081/8082"
    echo "      jvim --remote <server-ip> --remote-port 8080 --llama-port 8081"
    echo ""
    echo "  Make sure the server has JENOVA_HOST=0.0.0.0 in etc/jenova.conf and"
    echo "  the firewall allows ports 8080, 8081, and 8082 from this host."
else
    echo "  1. Place model GGUF files in type-specific folders:"
    echo "       Agent:  $JENOVA_HOME/models/agent/"
    echo "       Embed:  $JENOVA_HOME/models/embed/"
    echo "       Draft:  $JENOVA_HOME/models/draft/"
    echo "  2. Build llama.cpp if not done:"
    echo "       make llama"
    echo "  3. Start the backend:  jenova-ca --daemon"
    echo "     Or launch agent:    jenova"
    echo "     Or use Web UI:      Open http://localhost:8080 in a browser"
    echo "     Or launch editor:   jvim"
    echo "     LAN client mode:    jvim --remote <host>"
    if [ "$SKIP_NVIM" = "0" ]; then
        echo "  4. Inside the editor:  :checkhealth jenova"
        echo "                         (plugins are vendored under jvim/runtime/pack/jenova/start/)"
    fi
    echo ""
    echo "  Maintenance:"
    echo "    bin/jvim --check        — print resolved env without launching editor"
fi
echo