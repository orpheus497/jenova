#!/bin/sh
SCRIPT_DIR=$(dirname "$(realpath "$0")")
LLAMA_CLI="$SCRIPT_DIR/../llama.cpp/build/bin/llama-cli"
MODEL_PATH="$SCRIPT_DIR/../models/Qwen2.5-Coder-7B-Q5_K_M.gguf"

"$LLAMA_CLI" -m "$MODEL_PATH" -dev Vulkan0 -ngl 22 -c 8192 -p "Write a hello world in C" -n 32
