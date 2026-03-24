#!/bin/sh
SCRIPT_DIR=$(dirname "$(realpath "$0")")
LLAMA_CLI="$SCRIPT_DIR/llama.cpp/build/bin/llama-cli"
MODEL_PATH="$SCRIPT_DIR/models/Qwen2.5-Coder-7B-Q5_K_M.gguf"

chmod +x "$LLAMA_CLI"

"$LLAMA_CLI" \
  -m "$MODEL_PATH" \
  -dev Vulkan0,Vulkan1 \
  -ngl all \
  -sm layer \
  -ts 1.45,1.05 \
  -fitt 1024,1024 \
  -c 8192 \
  -p "Write a hello world in C" \
  -n 32
