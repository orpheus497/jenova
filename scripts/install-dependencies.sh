#!/bin/sh
# Script function and purpose: Install every Jenova dependency from FreeBSD
# pkg(8). There are no tiers -- every package listed here is required to build
# and run Jenova. Anything that cannot be installed is a failure.
#
# Usage: ./scripts/install-dependencies.sh [--dry-run] [--verbose]
#
#   --dry-run   Show what would be installed without installing
#   --verbose   Show detailed pkg output
#
# Exit codes:
#   0 = every dependency is present
#   1 = one or more dependencies are missing

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

. "$JENOVA_ROOT/lib/detect-env.sh"

DRY_RUN=0
VERBOSE=0

for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=1 ;;
        --verbose) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            exit 1
            ;;
    esac
done

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
fail() { printf "${_R}✗${_N}  %s\n" "$1"; }
info() { printf "${_B}ℹ${_N}  %s\n" "$1"; }

echo ""
printf "${_P}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_P}║  Jenova — Dependencies                               ║${_N}\n"
printf "${_P}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

info "FreeBSD ${JENOVA_OS_RELEASE} (${JENOVA_ARCH})"

if [ "$JENOVA_PKG_MGR" != "pkg" ]; then
    fail "pkg(8) not found"
    echo ""
    echo "Bootstrap it with:  /usr/sbin/pkg bootstrap"
    exit 1
fi

# Every dependency, in probe:package form. There is no optional tier.
#
# make(1), cc(1), realpath(1), fetch(1), sysctl(8), swapinfo(8), pciconf(8),
# nvmecontrol(8), zpool(8), ifconfig(8), route(8), mdmfs(8), nc(1) and stat(1)
# are in the FreeBSD base system and are deliberately absent -- they are never
# packages. In particular Jenova builds with the base make(1); GNU make is not a
# dependency.
#
# cmake is listed because external/llama.cpp uses it as its build system. That
# is upstream's choice, not Jenova's -- nothing in this repository is built with
# cmake directly.
# pkgconf MUST be first: the probes for lua54, gtk3, appindicator and ncurses
# call pkg-config, so on a bare system every one of them would misreport until
# it is installed.
DEPS=$(cat <<'EOF'
pkg-config:pkgconf
git:git
cmake:cmake
sqlite3:sqlite3
luajit:luajit-openresty
lua54:lua54
gettext:gettext-tools
vulkan:vulkan-loader
glslc:shaderc
spirv-headers:spirv-headers
gtk3:gtk3
appindicator:libappindicator
ncurses:ncurses
node:node
npm:npm
curl:curl
xdg-open:xdg-utils
clangd:llvm
stylua:stylua
EOF
)

# Function purpose: Decide whether a dependency is satisfied. Several entries are
# libraries with no command of their own, so they are probed through pkg-config
# or a known header path rather than command -v.
is_installed() {
    case "$1" in
        gtk3)
            pkg-config --exists gtk+-3.0 2>/dev/null
            ;;
        appindicator)
            # FreeBSD ships both libappindicator and the ayatana fork;
            # jenova-ui builds against whichever is present.
            pkg-config --exists appindicator3-0.1 2>/dev/null ||
            pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null
            ;;
        ncurses)
            pkg-config --exists ncurses 2>/dev/null
            ;;
        lua54)
            pkg-config --exists lua-5.4 2>/dev/null
            ;;
        spirv-headers)
            [ -f /usr/local/include/spirv/unified1/spirv.h ]
            ;;
        vulkan)
            # Probe the filesystem, not $JENOVA_VULKAN_OK — that was computed
            # once when detect-env.sh was sourced and would still read 0 on the
            # re-check immediately after vulkan-loader is installed.
            [ -f /usr/local/lib/libvulkan.so ] ||
            [ -f /usr/local/lib/libvulkan.so.1 ] ||
            ldconfig -r 2>/dev/null | grep -q libvulkan
            ;;
        clangd)
            # The llvm port installs versioned binaries (clangd19, ...), so an
            # unversioned `command -v clangd` fails even on a good install.
            # Ask pkg whether the package itself is present.
            pkg info -e llvm 2>/dev/null
            ;;
        *)
            command -v "$1" >/dev/null 2>&1
            ;;
    esac
}

install_package() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "    would install: $1"
        return 0
    fi
    if [ "$VERBOSE" = "1" ]; then
        sudo pkg install -y "$1"
    else
        sudo pkg install -y "$1" >/dev/null 2>&1
    fi
}

_MISSING_FILE="${TMPDIR:-/tmp}/.jenova-deps-missing.$$"
rm -f "$_MISSING_FILE"

echo "$DEPS" | while IFS=: read -r probe pkgname; do
    [ -n "$probe" ] || continue

    if is_installed "$probe"; then
        ok "$probe"
        continue
    fi

    info "installing $pkgname"
    if install_package "$pkgname" && { [ "$DRY_RUN" = "1" ] || is_installed "$probe"; }; then
        ok "$probe"
    else
        fail "$probe — pkg install $pkgname failed"
        echo "$pkgname" >> "$_MISSING_FILE"
    fi
done

# The loop above runs in a subshell, so failures are recorded in a scratch file
# and tallied once the pipeline has finished.
echo ""
if [ -f "$_MISSING_FILE" ]; then
    _COUNT=$(wc -l < "$_MISSING_FILE" | tr -d ' ')
    fail "$_COUNT dependencies could not be installed:"
    sed 's/^/    /' "$_MISSING_FILE"
    rm -f "$_MISSING_FILE"
    echo ""
    echo "Install them manually, then re-run. See docs/install.md"
    exit 1
fi

ok "All dependencies present"
exit 0
