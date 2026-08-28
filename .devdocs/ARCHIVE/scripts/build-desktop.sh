#!/bin/sh
# Script function and purpose: Verify that the tools and libraries needed to
# compile the C-based jenova-ui tray icon are present on this FreeBSD host.

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

echo "🔎 Checking for required system dependencies..."

# cc(1) is the FreeBSD base compiler (clang).
if command -v cc >/dev/null 2>&1; then
    _CC="cc"
else
    echo "❌ Error: No C compiler found. cc(1) should be in the FreeBSD base system." >&2
    exit 1
fi
echo "  ✓ C compiler: $_CC"

# jenova-ui/Makefile uses GNU make constructs; base make(1) will not build it.
if ! command -v gmake >/dev/null 2>&1; then
    echo "❌ Error: gmake is required to build jenova-ui." >&2
    echo "   pkg install gmake" >&2
    exit 1
fi
echo "  ✓ gmake found"

if command -v pkg-config >/dev/null 2>&1; then
    echo "  ✓ pkg-config found"
else
    echo "❌ Error: pkg-config is not installed." >&2
    echo "   pkg install pkgconf" >&2
    exit 1
fi

if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
    echo "❌ Error: GTK 3.0 development libraries are not installed." >&2
    echo "   pkg install gtk3" >&2
    exit 1
fi
echo "  ✓ gtk+-3.0 found"

# Action purpose: FreeBSD carries both the original application-indicator
# library and the maintained ayatana fork, under different pkg-config names.
# jenova-ui/Makefile builds against whichever is present, so accept either.
if pkg-config --exists appindicator3-0.1 2>/dev/null; then
    echo "  ✓ appindicator3-0.1 found"
elif pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null; then
    echo "  ✓ ayatana-appindicator3-0.1 found"
else
    echo "❌ Error: No application-indicator library is installed." >&2
    echo "   pkg install libappindicator" >&2
    echo "   or: pkg install ayatana-appindicator" >&2
    exit 1
fi

if ! pkg-config --exists ncurses 2>/dev/null; then
    echo "❌ Error: ncurses development files are not installed." >&2
    echo "   pkg install ncurses" >&2
    exit 1
fi
echo "  ✓ ncurses found"

if ! pkg-config --exists luajit 2>/dev/null; then
    echo "❌ Error: LuaJIT development files are not installed." >&2
    echo "   pkg install luajit-openresty" >&2
    exit 1
fi
echo "  ✓ luajit found"

echo ""
echo "✅ All required dependencies for the tray icon are present."
echo ""
echo "Build it with:"
echo "  \$ gmake -C \"$JENOVA_ROOT/jenova-ui\""
echo ""
echo "Then launch from your desktop menu, or by running:"
echo "  \$ jenova-ui"

exit 0
