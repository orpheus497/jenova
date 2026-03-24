#!/bin/sh

# Script function and purpose:
# Launches llama-server for Neovim llama.vim plugin integration.
# Provides HTTP API on port 8012 for FIM completions and instruction editing.
# Optimized for FreeBSD 15.0 with GTX 1650 Ti (Vulkan).

# Get the script directory for relative paths
SCRIPT_DIR=$(dirname "$(realpath "$0")")

LLAMA_SERVER="$SCRIPT_DIR/llama.cpp/build/bin/llama-server"
MODEL_PATH="$SCRIPT_DIR/models/Qwen2.5-Coder-7B-Q5_K_M.gguf"

# Condition purpose: Verify llama-server binary exists
if [ ! -f "$LLAMA_SERVER" ]; then
    echo "Error: llama-server not found at $LLAMA_SERVER"
    echo "Make sure you have built llama.cpp with -DGGML_VULKAN=ON."
    exit 1
fi

# Condition purpose: Verify model file exists
if [ ! -f "$MODEL_PATH" ]; then
    echo "Error: Model not found at $MODEL_PATH"
    exit 1
fi

# Action purpose: Launch llama-server with dual-GPU Vulkan offloading
# Port 8012 is the default llama.vim expects
# --host 127.0.0.1 ensures the server is only accessible locally.
# --offline prevents any automatic model/cache downloads.
# --spm-infill uses the Suffix/Prefix/Middle pattern for FIM (correct for Qwen2.5-Coder).
# -ngl all: Offload all layers to GPUs.
# -sm row: Split mode row for better performance across different GPU types.
# -ts 10,1: Weighted split between GTX 1650 Ti (Vulkan0) and Intel Xe (Vulkan1).
"$LLAMA_SERVER" \
    -m "$MODEL_PATH" \
    -dev Vulkan0,Vulkan1 \
    -ngl all \
    -sm row \
    -ts 1.45,1.05 \
    --host 127.0.0.1 \
    --port 8012 \
    -c 8192 \
    -b 512 \
    -ub 512 \
    -cb \
    --spm-infill \
    --offline \
    "$@"
