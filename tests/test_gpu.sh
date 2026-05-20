#!/bin/sh
SCRIPT_DIR=$(dirname "$(realpath "$0")")
if [ ! -f "$SCRIPT_DIR/../etc/jenova.conf" ]; then
    echo "Error: jenova.conf not found at $SCRIPT_DIR/../etc/jenova.conf" >&2
    exit 1
fi
. "$SCRIPT_DIR/../etc/jenova.conf"

export LD_LIBRARY_PATH="$JENOVA_ROOT/external/llama.cpp/build/bin:$LD_LIBRARY_PATH"
LLAMA_CLI="$JENOVA_ROOT/external/llama.cpp/build/bin/llama-cli"

# Preflight checks
if [ -z "$JENOVA_ROOT" ]; then
    echo "Error: JENOVA_ROOT is not set" >&2
    exit 1
fi
if [ ! -x "$LLAMA_CLI" ]; then
    echo "Error: llama-cli not found or not executable at $LLAMA_CLI" >&2
    exit 1
fi
if [ ! -f "$MODEL_AGENT" ]; then
    echo "Error: MODEL_AGENT not found at $MODEL_AGENT" >&2
    exit 1
fi

# Build device args from conf (same multi-GPU config used by jenova-ca)
DEV_ARGS=""
if [ -n "$DEVICES" ]; then
    DEV_ARGS="-dev $DEVICES"
fi

"$LLAMA_CLI" \
  -m "$MODEL_AGENT" \
  $DEV_ARGS \
  -sm layer \
  -fitt "$FIT_TARGET" \
  -c 8192 \
  -p "Write a hello world in C" \
  -n 32
