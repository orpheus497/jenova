#!/bin/sh
# install.sh: Jenova Cognitive Architecture — Generic Vulkan Full Offload Profile
# Generic installation script for systems with 8GB+ VRAM Vulkan GPU
#
# Usage: ./install.sh [--force] [--link] [--skip-nvim] [--skip-llama]

set -e

PROFILE_DIR="$(dirname "$(realpath "$0")")"
JENOVA_ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$PROFILE_DIR")")")")"
PROFILE_CONF="$PROFILE_DIR/jenova.conf"

echo "================================================================"
echo "  Jenova Hardware Profile: Vulkan Full Offload"
echo "  Profile: Generic 8GB+ VRAM GPU (NVIDIA/AMD/Intel)"
echo "================================================================"
echo ""
echo "This script deploys the Vulkan full-offload profile to:"
echo "  $JENOVA_ROOT/etc/jenova.conf"
echo ""
echo "Prerequisites:"
echo "  • Vulkan-capable GPU with 8GB+ VRAM"
echo "  • Vulkan drivers and SDK installed"
echo "  • llama.cpp built with Vulkan support"
echo ""

# Check for Vulkan
if ! command -v vulkaninfo >/dev/null 2>&1; then
    echo "WARNING: vulkaninfo not found. Vulkan SDK may not be installed."
    echo "         Install Vulkan SDK before running Jenova."
    echo ""
fi

# Copy profile config to main etc/jenova.conf
echo "Deploying profile configuration..."
if [ -f "$JENOVA_ROOT/etc/jenova.conf" ]; then
    echo "  Backing up existing jenova.conf..."
    cp "$JENOVA_ROOT/etc/jenova.conf" "$JENOVA_ROOT/etc/jenova.conf.bak.$(date +%Y%m%d-%H%M%S)"
fi

cp "$PROFILE_CONF" "$JENOVA_ROOT/etc/jenova.conf"
echo "  Profile deployed: $JENOVA_ROOT/etc/jenova.conf"
echo ""

# Create model subdirectories so auto-discovery works immediately
echo "Creating model directories..."
mkdir -p "$JENOVA_ROOT/models/agent" || true
mkdir -p "$JENOVA_ROOT/models/embed" || true
mkdir -p "$JENOVA_ROOT/models/draft" || true
echo "  Model directories ready."
echo ""

echo "Profile installation complete!"
echo ""
echo "Next steps:"
echo "  1. Build llama.cpp with Vulkan:"
echo "     cd $JENOVA_ROOT"
echo "     ./bin/build-llama-jenova"
echo ""
echo "  2. Download or place models in type-specific folders:"
echo "       Agent:  $JENOVA_ROOT/models/agent/"
echo "       Embed:  $JENOVA_ROOT/models/embed/"
echo "       Draft:  $JENOVA_ROOT/models/draft/"
echo "     (or run main installer: ./install.sh)"
echo ""
echo "  3. Start Jenova:"
echo "     ./bin/jenova-ca start"
echo ""
echo "To verify your setup:"
echo "  ./bin/jenova-ca status"
echo "  vulkaninfo --summary | grep deviceName"
echo ""
