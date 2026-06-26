#!/bin/sh
# install.sh: Jenova Cognitive Architecture — System Installation Script
# Supports all Vulkan hardware profiles (auto-detected via detect-hardware.sh)
#
# This is the single installer for the whole monorepo: it builds (or verifies)
# llama.cpp, downloads missing model GGUFs,
# and symlinks `jenova`, and `jenova-ca` onto your PATH.
#
# Usage: ./install.sh [--force] [--skip-llama] [--skip-web] [--client-only]
#
#   --force        Overwrite existing config without prompting
#   --skip-llama   Skip llama.cpp build check
#   --skip-llama   Skip llama.cpp build check
#   --skip-web     Skip building the JCA Web UI (jca_web/)
#   --client-only  LAN client install: skip llama.cpp, skip model downloads,
#                  skip web UI. Use when this host will only ever
#                  connect to a remote Jenova CA.
#
# This script:
#   1. Verifies required system dependencies
#   2. Creates required runtime directories (var/log, var/cache, models, .jenova)
#   3. Checks for llama.cpp build (skipped with --client-only)
#   4. Checks for Web UI build (skipped with --client-only or --skip-web)
#   5. Downloads required model files (skipped with --client-only)
#   6. Installs bin/jenova, bin/jenova-ca symlinks to PATH
#   9. Prints a summary plus next-step commands

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

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
SKIP_LLAMA=0
SKIP_WEB=0
CLIENT_ONLY=0

for _arg in "$@"; do
    case "$_arg" in
        --force)       FORCE=1 ;;
        --skip-llama)  SKIP_LLAMA=1 ;;
        --skip-web)    SKIP_WEB=1 ;;
        --client-only) CLIENT_ONLY=1; SKIP_LLAMA=1; SKIP_WEB=1 ;;
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
JCA_HOME="${JCA_HOME:-$HOME/JCA}"
info "Creating runtime directories in $JCA_HOME..."

mkdir -p "$JCA_HOME/.system" 2>/dev/null || {
    fail "Cannot create $JCA_HOME/.system directory"
    fail "Do not run install.sh with sudo — run as regular user"
    ERRORS=$((ERRORS + 1))
}
mkdir -p "$JCA_HOME/var/log" || true
mkdir -p "$JCA_HOME/var/cache" || true
mkdir -p "$JCA_HOME/var/run" || true
mkdir -p "$JCA_HOME/models/agent" || true
mkdir -p "$JCA_HOME/models/embed" || true
mkdir -p "$JCA_HOME/models/draft" || true
mkdir -p "$JCA_HOME/bin" || true
mkdir -p "$JCA_HOME/etc" || true

if [ -w "$JCA_HOME/.system" ]; then
    ok "Runtime directories created in $JCA_HOME"
else
    warn "$JCA_HOME/.system directory exists but may have permission issues"
    WARNINGS=$((WARNINGS + 1))
fi

# Check for root-owned build artifacts that block regular-user builds

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
# 5. llama.cpp build check
# ---------------------------------------------------------------------------
if [ "$CLIENT_ONLY" = "1" ]; then
    info "Skipping llama.cpp build check (--client-only)"
elif [ "$SKIP_LLAMA" = "0" ]; then
    info "Checking llama.cpp build..."
    LLAMA_BIN="$JENOVA_ROOT/external/ext_bin/bin/llama-server"
    if [ -f "$LLAMA_BIN" ]; then
        if "$LLAMA_BIN" --help >/dev/null 2>&1; then
            ok "llama-server binary is present and compatible."
        else
            warn "The vendored llama-server binary is incompatible with your system."
            printf "Would you like to compile it from source now? [Y/n] "
            read -r _ans
            if [ -z "$_ans" ] || [ "$_ans" = "y" ] || [ "$_ans" = "Y" ]; then
                info "Compiling llama.cpp from source..."
                make -C "$JENOVA_ROOT" llama || { fail "Failed to compile llama.cpp."; exit 1; }
            else
                warn "Skipping llama.cpp build. You may need to run 'make llama' later."
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        warn "llama-server not found. Build it using the Makefile:"
        warn "  make llama"
        warn "This will build llama.cpp with the appropriate backend (Vulkan, CUDA, Metal)"
        warn "based on your detected hardware profile."
        warn "For manual builds, see llama.cpp/docs/build.md"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check for Vulkan SDK components (needed for build)
    case "$JENOVA_PKG_MGR" in
        pkg)    _spirv_hint="pkg install spirv-headers" ;;
        pacman) _spirv_hint="pacman -S spirv-headers" ;;
        apt)    _spirv_hint="apt-get install spirv-headers" ;;
        dnf)    _spirv_hint="dnf install spirv-headers-devel" ;;
        zypper) _spirv_hint="zypper install spirv-headers" ;;
        xbps)   _spirv_hint="xbps-install SPIRV-Headers" ;;
        brew)   _spirv_hint="brew install spirv-headers" ;;
        *)      _spirv_hint="install the spirv-headers package for your OS" ;;
    esac

    # On FreeBSD, spirv-headers might be missing from the binary repo but 
    # we have a workaround in install-dependencies.sh using spirv-cross.
    if [ "$JENOVA_OS" = "freebsd" ] && [ ! -f "/usr/local/include/spirv/unified1/spirv.hpp" ]; then
        warn "spirv-headers missing — check if install-dependencies.sh was run"
    else
        check_optional "spirv-headers" "$_spirv_hint"
    fi

    if [ "$JENOVA_GLSLC_OK" = "0" ]; then
        case "$JENOVA_PKG_MGR" in
            pkg)    _glslc_hint="pkg install shaderc" ;;
            pacman) _glslc_hint="pacman -S shaderc (or yay -S shaderc)" ;;
            apt)    _glslc_hint="apt install glslc" ;;
            dnf)    _glslc_hint="dnf install glslc" ;;
            zypper) _glslc_hint="zypper install shaderc" ;;
            xbps)   _glslc_hint="xbps-install shaderc" ;;
            brew)   _glslc_hint="brew install shaderc" ;;
            *)      _glslc_hint="install the shaderc/glslc package for your OS" ;;
        esac
        warn "glslc (Vulkan shader compiler) not found — ${_glslc_hint}"
        warn "Without glslc, llama.cpp cannot be built with Vulkan GPU support."
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------





# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 8. Deploy to JCA_HOME (Strict Separation)
# ---------------------------------------------------------------------------
info "Deploying standalone system to $JCA_HOME..."

# 8.1 Create directory structure
for _d in bin etc lib public scripts hardware-profiles share var/log var/cache var/run models/agent models/embed models/draft; do
    mkdir -p "$JCA_HOME/$_d"
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
for _bin in jenova jenova-ui jenova-ca jenova-tui jenova-swap-mount; do
    if [ -f "$JENOVA_ROOT/bin/$_bin" ]; then
        install -m 755 "$JENOVA_ROOT/bin/$_bin" "$JCA_HOME/bin/$_bin"
    fi
done

# Built artifacts (llama-server, jenova-ui)
_LLAMA_BUILD_BIN="$JENOVA_ROOT/external/ext_bin/bin/llama-server"
if [ -f "$_LLAMA_BUILD_BIN" ]; then
    _verify_and_copy_bin "$_LLAMA_BUILD_BIN" "$JCA_HOME/bin/llama-server"
    # Copy shared libs if they exist
    for _lib in "$JENOVA_ROOT/external/ext_bin/bin/"*.so* "$JENOVA_ROOT/external/ext_bin/bin/"*.dylib*; do
        if [ -f "$_lib" ]; then
            install -m 755 "$_lib" "$JCA_HOME/bin/"
        fi
    done
    ok "Deployed llama.cpp artifacts to $JCA_HOME/bin"
fi


if [ -f "$JENOVA_ROOT/jenova-ui/jenova-ui" ]; then
    _verify_and_copy_bin "$JENOVA_ROOT/jenova-ui/jenova-ui" "$JCA_HOME/bin/jenova-ui"
fi



# 8.3 Deploy Assets, Scripts, and Config
cp -R "$JENOVA_ROOT/lib/"* "$JCA_HOME/lib/"
cp -R "$JENOVA_ROOT/scripts/"* "$JCA_HOME/scripts/"
cp -R "$JENOVA_ROOT/hardware-profiles/"* "$JCA_HOME/hardware-profiles/"
[ -d "$JENOVA_ROOT/public" ] && cp -R "$JENOVA_ROOT/public/"* "$JCA_HOME/public/"
ok "Deployed libraries, scripts, hardware profiles, runtime, and web assets"

# 8.4 Generate Path-Locked Config
cat > "$JCA_HOME/etc/jenova.local.conf" <<EOF
#!/bin/sh
# Path-locked configuration generated by install.sh on $(date)
# This ensures the installation is decoupled from the source repository.

JENOVA_ROOT="$JCA_HOME"
LLAMA_SERVER="\$JENOVA_ROOT/bin/llama-server"
LLAMA_LIB_DIR="\$JENOVA_ROOT/bin"
EOF

# Copy base config if missing
if [ ! -f "$JCA_HOME/etc/jenova.conf" ]; then
    cp "$JENOVA_ROOT/etc/jenova.conf" "$JCA_HOME/etc/"
fi
ok "Deployed path-locked configuration to $JCA_HOME/etc"

# 8.5 Symlink to PATH
_LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$_LOCAL_BIN"

for _bin in jenova jenova-ui jenova-ca jenova-tui jenova-swap-mount; do
    if [ -f "$JCA_HOME/bin/$_bin" ]; then
        ln -sf "$JCA_HOME/bin/$_bin" "$_LOCAL_BIN/$_bin"
    fi
done


ok "Symlinked launchers from $JCA_HOME/bin to $_LOCAL_BIN"

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
    mkdir -p "$JCA_HOME/png"
    _ICON_DIR="$HOME/.local/share/icons"
    mkdir -p "$_ICON_DIR"

    if [ -d "$JENOVA_ROOT/png" ]; then
        # Copy all source icons to deployment directory
        cp "$JENOVA_ROOT/png/"* "$JCA_HOME/png/" 2>/dev/null || true

        for icon in jenova jca jca_grey; do
            # Determine the best available icon format
            _icon_deployed=""
            if [ -f "$JENOVA_ROOT/png/$icon.png" ]; then
                cp "$JENOVA_ROOT/png/$icon.png" "$_ICON_DIR/$icon.png"
                cp "$JENOVA_ROOT/png/$icon.png" "$JCA_HOME/png/$icon.png"
                _icon_deployed="$icon.png"
            elif [ -f "$JENOVA_ROOT/png/$icon.jpg" ]; then
                # Try to convert jpg→png for desktop compatibility
                if command -v convert >/dev/null 2>&1; then
                    convert "$JENOVA_ROOT/png/$icon.jpg" "$JCA_HOME/png/$icon.png"
                    cp "$JCA_HOME/png/$icon.png" "$_ICON_DIR/$icon.png"
                    _icon_deployed="$icon.png"
                elif command -v magick >/dev/null 2>&1; then
                    magick "$JENOVA_ROOT/png/$icon.jpg" "$JCA_HOME/png/$icon.png"
                    cp "$JCA_HOME/png/$icon.png" "$_ICON_DIR/$icon.png"
                    _icon_deployed="$icon.png"
                else
                    # No converter — use jpg directly (most DEs support it)
                    cp "$JENOVA_ROOT/png/$icon.jpg" "$_ICON_DIR/$icon.jpg"
                    cp "$JENOVA_ROOT/png/$icon.jpg" "$JCA_HOME/png/$icon.jpg"
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
        ok "Installed icons to $_ICON_DIR and $JCA_HOME/png"
    fi

    # ISS-08: Rewrite desktop entries with targeted Exec= line replacement
    # instead of global substring sed which corrupted Name= and Comment= fields.
    for _dfile in jenova.desktop; do
        if [ -f "$JENOVA_ROOT/bin/$_dfile" ]; then
            _icon_name=$(grep "^Icon=" "$JENOVA_ROOT/bin/$_dfile" | cut -d= -f2)

            # Resolve the actual icon path (prefer .png, fall back to .jpg)
            if [ -f "$JCA_HOME/png/$_icon_name.png" ]; then
                _icon_path="$JCA_HOME/png/$_icon_name.png"
            elif [ -f "$JCA_HOME/png/$_icon_name.jpg" ]; then
                _icon_path="$JCA_HOME/png/$_icon_name.jpg"
            else
                _icon_path="$_icon_name"  # Fall back to theme name lookup
            fi

            _JHBIN="$JCA_HOME/bin"
            sed -e "/^Exec=/{ \
                s|jenova-ui|$_JHBIN/jenova-ui|g; \
                s|jenova-ca|$_JHBIN/jenova-ca|g; \
                s|Exec=jenova|Exec=$_JHBIN/jenova|g; \
            }" \
                -e "s|^Icon=.*|Icon=$_icon_path|" \
                "$JENOVA_ROOT/bin/$_dfile" > "$_APP_DIR/$_dfile"
        fi
    done
    update-desktop-database "$_APP_DIR" 2>/dev/null || true
    ok "Installed and path-locked desktop entries to $_APP_DIR"
fi

# ---------------------------------------------------------------------------
# 9. System Tuning Reminders
# ---------------------------------------------------------------------------
if [ -n "$_PROFILE" ]; then
    _PROFILE_DIR="$JCA_HOME/hardware-profiles/$_PROFILE"
    if [ -f "$_PROFILE_DIR/jenova-setup" ]; then
        warn "Run 'sudo $_PROFILE_DIR/jenova-setup' once to tune system for this hardware."
    fi
elif [ "$JENOVA_OS" = "freebsd" ]; then
    info "System tuning..."
    warn "Run 'sudo $JCA_HOME/scripts/jenova-setup' once to tune vm.* sysctls and ZFS ARC"
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
    echo ""
    echo "  Make sure the server has JENOVA_HOST=0.0.0.0 in etc/jenova.conf and"
    echo "  the firewall allows ports 8080, 8081, and 8082 from this host."
else
    echo "  1. Place model GGUF files in type-specific folders:"
    echo "       Agent:  $JCA_HOME/models/agent/"
    echo "       Embed:  $JCA_HOME/models/embed/"
    echo "       Draft:  $JCA_HOME/models/draft/"
    echo "  2. Build llama.cpp if not done:"
    echo "       make llama"
    echo "  3. Start the backend:  jenova-ca --daemon"
    echo "     Or launch manager:  jenova-tui"
    echo "     Or use Web UI:      Open http://localhost:8080 in a browser"
    echo ""
    echo "  Maintenance:"
    echo "    scripts/update.sh             — pull latest jenova + sync nvim config"
    echo "    scripts/cleanup.sh --all      — clear logs and cache"
    echo "    scripts/uninstall.sh          — remove deployed files (preserves models)"
fi
echo