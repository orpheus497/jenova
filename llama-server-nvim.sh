#!/bin/sh
# llama-server-nvim: Launch llama-server for llama.vim
# Optimized for: FreeBSD 15 | GTX 1650 Ti (Vulkan)

SCRIPT_DIR=$(dirname "$(realpath "$0")")
. "$SCRIPT_DIR/etc/coder.conf"

LLAMA_SERVER="$CODER_ROOT/llama.cpp/build/bin/llama-server"
MODEL_PATH="$MODEL_7B"

if [ ! -f "$LLAMA_SERVER" ]; then
    echo "Error: llama-server not found at $LLAMA_SERVER"
    exit 1
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "Error: 7B Model missing at $MODEL_PATH"
    exit 1
fi

# Neovim port is 8012 by default for llama.vim
# Using 7B for instant FIM/Instruction results
"$LLAMA_SERVER" \
    -m "$MODEL_PATH" \
    -dev Vulkan0 \
    -ngl all \
    --host 127.0.0.1 \
    --port 8012 \
    -c 8192 \
    -b 512 \
    -ub 512 \
    -cb \
    --spm-infill \
    --offline \
    "$@"
