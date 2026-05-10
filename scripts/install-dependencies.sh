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

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"

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
printf "${_B}║  Jenova — Dependency Installation                    ║${_N}\n"
printf "${_B}╚══════════════════════════════════════════════════════╝${_N}\n"
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
    echo "Required: git, cmake, luajit, gettext, vulkan-loader, lua54, curl"
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
vulkan:vulkan-loader
lua54:lua54
curl:curl
gmake:gmake
glslc:shaderc
dialog:dialog
clangd:llvm
stylua:stylua
node:node
npm:npm
EOF
            ;;
        pacman)
            # Arch Linux
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
vulkan-icd-loader:vulkan-icd-loader
lua54:lua54
curl:curl
make:make
glslc:glslc
dialog:dialog
clang:clang
stylua:stylua
nodejs:nodejs
npm:npm
EOF
            ;;
        apt)
            # Debian/Ubuntu
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
libvulkan1:libvulkan1
liblua5.4-dev:liblua5.4-dev
libcurl4-openssl-dev:libcurl4-openssl-dev
make:make
glslc:glslc
dialog:dialog
clangd:clangd
cargo:cargo
nodejs:nodejs
npm:npm
EOF
            ;;
        dnf)
            # Fedora/RHEL
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
vulkan-loader:vulkan-loader
lua-devel:lua-devel
libcurl-devel:libcurl-devel
make:make
glslc:glslc
dialog:dialog
clang-tools-extra:clang-tools-extra
cargo:cargo
nodejs:nodejs
npm:npm
EOF
            ;;
        brew)
            # macOS Homebrew
            cat << 'EOF'
git:git
cmake:cmake
luajit:luajit
gettext:gettext
molten-vk:molten-vk
lua@5.4:lua@5.4
curl:curl
make:make
shaderc:shaderc
dialog:dialog
llvm:llvm
stylua:stylua
node:node
npm:node
EOF
            ;;
        *)
            echo ""
            ;;
    esac
}

# Check if a binary is already installed
is_installed() {
    command -v "$1" >/dev/null 2>&1
}

# Install a package using the detected package manager
install_package() {
    local pkg="$1"
    local manager="$JENOVA_PKG_MGR"

    if [ "$DRY_RUN" = "1" ]; then
        echo "Would install: $pkg (via $manager)"
        return 0
    fi

    case "$manager" in
        pkg)
            if [ "$VERBOSE" = "1" ]; then
                sudo pkg install -y "$pkg"
            else
                sudo pkg install -y "$pkg" >/dev/null 2>&1
            fi
            ;;
        pacman)
            local pacman_cmd="sudo pacman"
            if command -v yay >/dev/null 2>&1; then
                pacman_cmd="yay"
            fi
            if [ "$VERBOSE" = "1" ]; then
                $pacman_cmd -S --noconfirm "$pkg"
            else
                $pacman_cmd -S --noconfirm "$pkg" >/dev/null 2>&1
            fi
            ;;
        apt)
            if [ "$VERBOSE" = "1" ]; then
                sudo apt-get update && sudo apt-get install -y "$pkg"
            else
                sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y "$pkg" >/dev/null 2>&1
            fi
            ;;
        dnf)
            if [ "$VERBOSE" = "1" ]; then
                sudo dnf install -y "$pkg"
            else
                sudo dnf install -y "$pkg" >/dev/null 2>&1
            fi
            ;;
        brew)
            if [ "$VERBOSE" = "1" ]; then
                brew install "$pkg"
            else
                brew install "$pkg" >/dev/null 2>&1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# Handle special cases (like cargo installs)
install_special() {
    local binary="$1"
    local pkg="$2"

    case "$binary" in
        stylua)
            if [ "$JENOVA_PKG_MGR" = "apt" ] || [ "$JENOVA_PKG_MGR" = "dnf" ]; then
                if [ "$DRY_RUN" = "1" ]; then
                    echo "Would install: $binary (via cargo install $pkg)"
                    return 0
                fi
                if [ "$VERBOSE" = "1" ]; then
                    cargo install "$pkg"
                else
                    cargo install "$pkg" >/dev/null 2>&1
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
REQUIRED_DEPS="git cmake luajit gettext vulkan lua54 curl"
OPTIONAL_DEPS="gmake glslc dialog clangd stylua node"

if [ "$REQUIRED_ONLY" = "1" ]; then
    info "Installing required dependencies only..."
    DEPS_TO_CHECK="$REQUIRED_DEPS"
else
    info "Installing required and optional dependencies..."
    DEPS_TO_CHECK="$REQUIRED_DEPS $OPTIONAL_DEPS"
fi

FAILED_REQUIRED=0
FAILED_OPTIONAL=0

echo "$PACKAGES" | while IFS=: read -r binary pkg; do
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
done

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