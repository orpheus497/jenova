#!/bin/sh
# install-dependencies.sh: Intelligent dependency installer for Jenova
#
# Automatically detects OS and package manager, installs required and optional
# dependencies with graceful skipping and user notification.
#
# Usage: ./scripts/install-dependencies.sh [--required-only] [--dry-run] [--verbose]
#
#   --required-only  Install only required dependencies (skip optional ones)
#   --dry-run        Show what would be installed without actually installing
#   --verbose        Show detailed installation progress
#
# Exit codes:
#   0 = all dependencies installed successfully
#   1 = critical failure (some required dependencies failed)
#   2 = partial success (some optional dependencies failed)

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# Shared OS/hardware detection
. "$JENOVA_ROOT/lib/detect-env.sh"

REQUIRED_ONLY=0
DRY_RUN=0
VERBOSE=0

for _arg in "$@"; do
    case "$_arg" in
        --required-only) REQUIRED_ONLY=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        --verbose)       VERBOSE=1 ;;
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
printf "${_P}║  Jenova — Dependency Installation                    ║${_N}\n"
printf "${_P}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

# Detect package manager
info "Detected OS: $JENOVA_OS ($JENOVA_DISTRO)"
info "Package manager: $JENOVA_PKG_MGR"

if [ "$JENOVA_PKG_MGR" = "none" ]; then
    fail "No supported package manager detected"
    echo ""
    echo "This could mean:"
    echo "  • You're running in a container/sandboxed environment (Flatpak, Docker, etc.)"
    echo "  • Your Linux distribution is not supported"
    echo "  • Package manager is not installed"
    echo ""
    echo "Please install dependencies manually. See docs/installation/dependencies.md"
    echo "Required: git, cmake, luajit, gettext, vulkan-loader, spirv-headers, lua54, curl"
    echo "Optional: glslc, dialog, clangd, stylua, node"
    exit 1
fi

# Package mapping for different managers
# Format: binary_name:package_name
get_packages_for_manager() {
    case "$1" in
        pkg)
            # FreeBSD
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit-openresty
gettext:gettext-tools
spirv-headers:spirv-headers
vulkan:vulkan-loader
lua54:lua54
curl:curl
realpath:coreutils
gmake:gmake
glslc:shaderc
clangd:llvm
stylua:stylua
node:node
npm:npm
pkg-config:pkgconf
gtk3:gtk3
appindicator:libappindicator
EOF
            ;;
        pacman)
            # Arch Linux
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
spirv-headers:spirv-headers
vulkan-icd-loader:vulkan-icd-loader
lua54:lua54
curl:curl
make:make
realpath:coreutils
glslc:glslc
clang:clang
stylua:stylua
nodejs:nodejs
npm:npm
pkg-config:pkgconf
gtk3:gtk3
appindicator:libappindicator-gtk3
EOF
            ;;
        apt)
            # Debian/Ubuntu
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
spirv-headers:spirv-headers
libvulkan1:libvulkan1
liblua5.4-dev:liblua5.4-dev
libcurl4-openssl-dev:libcurl4-openssl-dev
make:make
realpath:coreutils
glslc:glslc
clangd:clangd
cargo:cargo
nodejs:nodejs
npm:npm
pkg-config:pkg-config
gtk3:libgtk-3-dev
appindicator:libappindicator3-dev
EOF
            ;;
        dnf)
            # Fedora/RHEL
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
spirv-headers:spirv-headers-devel
vulkan-loader:vulkan-loader
lua-devel:lua-devel
libcurl-devel:libcurl-devel
make:make
realpath:coreutils
glslc:glslc
clang-tools-extra:clang-tools-extra
cargo:cargo
nodejs:nodejs
npm:npm
pkg-config:pkgconf-pkg-config
gtk3:gtk3-devel
appindicator:libappindicator-gtk3-devel
EOF
            ;;
        brew)
            # macOS Homebrew
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
spirv-headers:spirv-headers
molten-vk:molten-vk
lua@5.4:lua@5.4
curl:curl
make:make
realpath:coreutils
shaderc:shaderc
llvm:llvm
stylua:stylua
node:node
npm:node
pkg-config:pkg-config
gtk3:gtk+3
appindicator:libappindicator
EOF
            ;;
        zypper)
            # openSUSE zypper
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
spirv-headers:spirv-headers
libvulkan1:libvulkan1
lua54-devel:lua54-devel
libcurl-devel:libcurl-devel
make:make
realpath:coreutils
glslc:glslc
clang:clang-tools
cargo:cargo
nodejs:nodejs
npm:npm
pkg-config:pkg-config
gtk3:gtk3-devel
appindicator:libappindicator-gtk3-devel
EOF
            ;;
        xbps)
            # Void Linux xbps
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
spirv-headers:SPIRV-Headers
vulkan-loader:vulkan-loader
lua54-devel:lua54-devel
curl-devel:curl-devel
make:make
realpath:coreutils
glslc:glslc
clang:clang
cargo:cargo
nodejs:nodejs
npm:npm
pkg-config:pkg-config
gtk3:gtk+3-devel
appindicator:libappindicator-devel
EOF
            ;;
        *)
            echo ""
            ;;
    esac
}

# Check if a binary is already installed
is_installed() {
    if [ "$1" = "gtk3" ]; then
        command -v pkg-config >/dev/null 2>&1 && pkg-config --exists gtk+-3.0 >/dev/null 2>&1
        return $?
    elif [ "$1" = "appindicator" ]; then
        command -v pkg-config >/dev/null 2>&1 && pkg-config --exists appindicator3-0.1 >/dev/null 2>&1
        return $?
    elif [ "$1" = "spirv-headers" ]; then
        [ -f "/usr/include/spirv/unified1/spirv.h" ] || [ -f "/usr/local/include/spirv/unified1/spirv.h" ]
        return $?
    fi
    command -v "$1" >/dev/null 2>&1
}

# Install a package using the detected package manager
install_package() {
    _ip_pkg="$1"
    _ip_mgr="$JENOVA_PKG_MGR"

    if [ "$DRY_RUN" = "1" ]; then
        echo "Would install: $_ip_pkg (via $_ip_mgr)"
        return 0
    fi

    case "$_ip_mgr" in
        pkg)
            if [ "$VERBOSE" = "1" ]; then
                sudo pkg install -y "$_ip_pkg"
            else
                sudo pkg install -y "$_ip_pkg" >/dev/null 2>&1
            fi
            ;;
        pacman)
            _ip_pacman="sudo pacman"
            if command -v yay >/dev/null 2>&1; then
                _ip_pacman="yay"
            fi
            if [ "$VERBOSE" = "1" ]; then
                $_ip_pacman -S --noconfirm "$_ip_pkg"
            else
                $_ip_pacman -S --noconfirm "$_ip_pkg" >/dev/null 2>&1
            fi
            ;;
        apt)
            if [ "$VERBOSE" = "1" ]; then
                sudo apt-get update && sudo apt-get install -y "$_ip_pkg"
            else
                sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y "$_ip_pkg" >/dev/null 2>&1
            fi
            ;;
        dnf)
            if [ "$VERBOSE" = "1" ]; then
                sudo dnf install -y "$_ip_pkg"
            else
                sudo dnf install -y "$_ip_pkg" >/dev/null 2>&1
            fi
            ;;
        zypper)
            if [ "$VERBOSE" = "1" ]; then
                sudo zypper install -y "$_ip_pkg"
            else
                sudo zypper install -y "$_ip_pkg" >/dev/null 2>&1
            fi
            ;;
        xbps)
            if [ "$VERBOSE" = "1" ]; then
                sudo xbps-install -y "$_ip_pkg"
            else
                sudo xbps-install -y "$_ip_pkg" >/dev/null 2>&1
            fi
            ;;
        brew)
            if [ "$VERBOSE" = "1" ]; then
                brew install "$_ip_pkg"
            else
                brew install "$_ip_pkg" >/dev/null 2>&1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# Handle special cases (like cargo installs)
install_special() {
    _is_bin="$1"
    _is_pkg="$2"

    case "$_is_bin" in
        stylua)
            if [ "$JENOVA_PKG_MGR" = "apt" ] || [ "$JENOVA_PKG_MGR" = "dnf" ]; then
                if [ "$DRY_RUN" = "1" ]; then
                    echo "Would install: $_is_bin (via cargo install $_is_pkg)"
                    return 0
                fi
                if command -v cargo >/dev/null 2>&1; then
                    if [ "$VERBOSE" = "1" ]; then
                        cargo install "$_is_pkg"
                    else
                        cargo install "$_is_pkg" >/dev/null 2>&1
                    fi
                else
                    return 1
                fi
            fi
            ;;
    esac
}

# Main installation logic
PACKAGES="$(get_packages_for_manager "$JENOVA_PKG_MGR")"

if [ -z "$PACKAGES" ]; then
    fail "No package mapping available for $JENOVA_PKG_MGR"
    exit 1
fi

# Required dependencies
REQUIRED_DEPS="git cmake luajit gettext vulkan lua54 curl realpath pkg-config gtk3 appindicator"
OPTIONAL_DEPS="gmake glslc clangd stylua node spirv-headers"

if [ "$REQUIRED_ONLY" = "1" ]; then
    info "Installing required dependencies only..."
    DEPS_TO_CHECK="$REQUIRED_DEPS"
else
    info "Installing required and optional dependencies..."
    DEPS_TO_CHECK="$REQUIRED_DEPS $OPTIONAL_DEPS"
fi

FAILED_REQUIRED=0
FAILED_OPTIONAL=0

while IFS=: read -r binary pkg; do
    # Skip empty lines or comments
    [ -z "$binary" ] || [ "${binary#\#}" != "$binary" ] && continue

    # Skip if not in our list to check
    case " $DEPS_TO_CHECK " in
        *" $binary "*) ;;
        *) continue ;;
    esac

    if is_installed "$binary"; then
        ok "$binary already installed"
        continue
    fi

    # Check if it's required
    case " $REQUIRED_DEPS " in
        *" $binary "*)
            is_required=1
            ;;
        *)
            is_required=0
            ;;
    esac

    info "Installing $binary ($pkg)..."

    if install_package "$pkg"; then
        ok "$binary installed successfully"
    elif install_special "$binary" "$pkg"; then
        ok "$binary installed successfully (via special method)"
    else
        if [ "$is_required" = "1" ]; then
            fail "Failed to install required dependency: $binary"
            FAILED_REQUIRED=$((FAILED_REQUIRED + 1))
        else
            warn "Failed to install optional dependency: $binary (skipping)"
            FAILED_OPTIONAL=$((FAILED_OPTIONAL + 1))
        fi
    fi
done <<EOF
$PACKAGES
EOF

# ---------------------------------------------------------------------------
# FreeBSD-specific "First Class citizen" workarounds
# ---------------------------------------------------------------------------
if [ "$JENOVA_OS" = "freebsd" ]; then
    # We now bundle spirv-headers in external/spirv-headers and include them
    # during the build process, so no system-wide symlink workaround is needed.
    :
fi

echo ""
if [ "$FAILED_REQUIRED" = "0" ]; then
    ok "All required dependencies installed"
    if [ "$FAILED_OPTIONAL" = "0" ]; then
        ok "All optional dependencies installed"
        exit 0
    else
        warn "$FAILED_OPTIONAL optional dependencies failed (but installation can proceed)"
        exit 2
    fi
else
    fail "$FAILED_REQUIRED required dependencies failed"
    echo ""
    echo "Please install missing dependencies manually. See docs/installation/dependencies.md"
    exit 1
fi