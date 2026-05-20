#!/bin/bash

# Development script for JCA webui
# 
# This script starts the webui development server (Vite).
#
# Usage:
#   bash scripts/dev.sh
#   npm run dev

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$PROJECT_ROOT"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up..."
    exit
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

echo "🚀 Starting development server..."
echo "📝 Note: Make sure to start your local llamacpp server"

npx vite dev --host 0.0.0.0
