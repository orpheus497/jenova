#!/bin/bash

# build-desktop.sh: Build the Jenova Tauri Desktop Application
# 
# This script builds the native desktop wrapper for the Jenova Web UI.
# It requires Cargo and Node.js to be installed.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
JENOVA_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$JENOVA_ROOT/jca_web"

echo "📦 Installing web dependencies..."
npm install

if [ ! -f "src-tauri/icons/tray.png" ] || [ ! -f "src-tauri/icons/icon.png" ] || [ ! -f "src-tauri/icons/tray-bw.png" ]; then
    echo "🎨 Generating Jenova application icons..."
    if command -v magick >/dev/null 2>&1; then
        magick "../png/jenova.jpg" "../png/jenova.png"
        magick "../png/jca.jpg" "src-tauri/icons/tray.png"
        magick "../png/jca.jpg" -colorspace Gray "src-tauri/icons/tray-bw.png"
    elif command -v convert >/dev/null 2>&1; then
        convert "../png/jenova.jpg" "../png/jenova.png"
        convert "../png/jca.jpg" "src-tauri/icons/tray.png"
        convert "../png/jca.jpg" -colorspace Gray "src-tauri/icons/tray-bw.png"
    fi

    if [ -f "../png/jenova.png" ]; then
        npm run tauri icon "../png/jenova.png"
    fi
else
    echo "🎨 Application icons already exist. Skipping generation."
fi

echo "🏗️ Building Jenova Desktop Application (Tauri)..."

npm run tauri build

echo "✅ Build complete!"
echo "Copying binary to bin/jenova-desktop..."
if [ -f "src-tauri/target/release/jenova" ]; then
    cp "src-tauri/target/release/jenova" "../bin/jenova-desktop"
elif [ -f "src-tauri/target/release/app" ]; then
    cp "src-tauri/target/release/app" "../bin/jenova-desktop"
else
    echo "❌ Error: Could not find the compiled binary."
    exit 1
fi
echo "The binary can be found in bin/jenova-desktop"
