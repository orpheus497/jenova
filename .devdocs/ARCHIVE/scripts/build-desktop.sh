#!/bin/sh

# build-desktop.sh: Checks for dependencies required for the Jenova tray icon.
# 
# This script verifies that the necessary tools and libraries for compiling
# the C-based tray icon are present on the system.
# Supports FreeBSD, Linux, and macOS.

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

echo "🔎 Checking for required system dependencies..."

# Check for a C compiler (prefer cc on FreeBSD, gcc elsewhere)
if command -v cc >/dev/null 2>&1; then
    _CC="cc"
elif command -v gcc >/dev/null 2>&1; then
    _CC="gcc"
else
    echo "❌ Error: No C compiler found. Please install gcc or clang." >&2
    exit 1
fi
echo "  ✓ C compiler: $_CC"

# Check for pkg-config (pkgconf on FreeBSD)
if command -v pkg-config >/dev/null 2>&1; then
    echo "  ✓ pkg-config found"
elif command -v pkgconf >/dev/null 2>&1; then
    echo "  ✓ pkgconf found"
else
    echo "❌ Error: 'pkg-config' is not installed. Please install it to continue." >&2
    exit 1
fi

# Check for GTK and AppIndicator libraries
if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
    echo "❌ Error: GTK 3.0 development libraries are not installed." >&2
    echo "   FreeBSD: pkg install gtk3" >&2
    echo "   Debian/Ubuntu: apt install libgtk-3-dev" >&2
    echo "   Arch: pacman -S gtk3" >&2
    exit 1
fi
echo "  ✓ gtk+-3.0 found"

if ! pkg-config --exists appindicator3-0.1 2>/dev/null; then
    echo "❌ Error: AppIndicator library is not installed." >&2
    echo "   FreeBSD: pkg install libappindicator" >&2
    if [ "$JENOVA_DISTRO" = "debian" ] && [ "${JENOVA_DISTRO_VERSION:-0}" -ge 12 ] 2>/dev/null; then
        echo "   Debian/Ubuntu: apt install libayatana-appindicator3-dev" >&2
    else
        echo "   Debian/Ubuntu: apt install libappindicator3-dev" >&2
    fi
    echo "   Arch: pacman -S libappindicator-gtk3" >&2
    exit 1
fi
echo "  ✓ appindicator3-0.1 found"

echo ""
echo "✅ All required dependencies for the tray icon are present."
echo "   The tray icon will be compiled on-the-fly when you run 'jenova-ca tray'."
echo ""
echo "You can now launch the application from your desktop menu, or by running:"
echo "  \$ jenova-ui"

exit 0
