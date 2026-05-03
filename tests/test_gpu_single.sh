#!/bin/sh
SCRIPT_DIR=$(dirname "$(realpath "$0")")
if [ ! -f "$SCRIPT_DIR/../etc/jenova.conf" ]; then
    echo "Error: jenova.conf not found at $SCRIPT_DIR/../etc/jenova.conf" >&2
    exit 1
fi
. "$SCRIPT_DIR/../etc/jenova.conf"

export LD_LIBRARY_PATH="$JENOVA_ROOT/llama.cpp/build/bin:$LD_LIBRARY_PATH"
LLAMA_CLI="$JENOVA_ROOT/llama.cpp/build/bin/llama-cli"

if [ ! -x "$LLAMA_CLI" ]; then
    echo "Error: llama-cli not found or not executable at $LLAMA_CLI" >&2
    exit 1
fi
if [ ! -f "$MODEL_AGENT" ]; then
    echo "Error: MODEL_AGENT not found at $MODEL_AGENT" >&2
    exit 1
fi

# Single-GPU test: use first device from DEVICES (Vulkan0) for isolation
DEV_SINGLE=$(echo "${DEVICES:-Vulkan0}" | cut -d, -f1)

"$LLAMA_CLI" \
  -m "$MODEL_AGENT" \
  -dev "$DEV_SINGLE" \
  -ngl all \
  -c 8192 \
  -p "Write a hello world in C" \
  -n 32
