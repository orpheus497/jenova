#!/bin/bash

# build-desktop.sh: Checks for dependencies required for the Jenova tray icon.
# 
# This script verifies that the necessary tools and libraries for compiling
# the C-based tray icon are present on the system.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
JENOVA_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo "🔎 Checking for required system dependencies..."

# Check for gcc
if ! command -v gcc >/dev/null 2>&1; then
    echo "❌ Error: 'gcc' is not installed. Please install it to continue." >&2
    exit 1
fi

# Check for pkg-config
if ! command -v pkg-config >/dev/null 2>&1; then
    echo "❌ Error: 'pkg-config' is not installed. Please install it to continue." >&2
    exit 1
fi

# Check for GTK and AppIndicator libraries
if ! pkg-config --exists gtk+-3.0 appindicator3-0.1; then
    echo "❌ Error: Required libraries for the tray icon are not installed." >&2
    echo "   Please install libgtk-3-dev and libappindicator3-dev." >&2
    exit 1
fi

echo "✅ All required dependencies for the tray icon are present."
echo "   The tray icon will be compiled on-the-fly when you run 'jenova-ca tray'."
echo ""
echo "You can now launch the application from your desktop menu, or by running:"
echo "  \$ $JENOVA_ROOT/bin/jenova.desktop"

exit 0
