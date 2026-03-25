#!/bin/sh
SCRIPT_DIR=$(dirname "$(realpath "$0")")
. "$SCRIPT_DIR/../etc/jenova.conf"

export LD_LIBRARY_PATH="$JENOVA_ROOT/llama.cpp/build/bin:$LD_LIBRARY_PATH"
LLAMA_CLI="$JENOVA_ROOT/llama.cpp/build/bin/llama-cli"

"$LLAMA_CLI" \
  -m "$MODEL_7B" \
  -dev Vulkan0 \
  -ngl "$NGL_7B" \
  -c 8192 \
  -p "Write a hello world in C" \
  -n 32
