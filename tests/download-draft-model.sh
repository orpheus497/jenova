#!/bin/sh

# download-draft-model.sh: Fetch a small Qwen2.5-Coder draft model for speculative decoding
# Speculative decoding uses a tiny fast model to draft tokens, verified by the main model.
# This can give 1.5-2x speed improvement on token generation.

SCRIPT_DIR=$(dirname "$(realpath "$0")")
MODEL_DIR="$SCRIPT_DIR/../models"

DRAFT_MODEL="Qwen2.5-Coder-0.5B-Q8_0.gguf"
DRAFT_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q8_0.gguf"

mkdir -p "$MODEL_DIR"

if [ -f "$MODEL_DIR/$DRAFT_MODEL" ]; then
    echo "Draft model already exists: $MODEL_DIR/$DRAFT_MODEL"
    ls -lh "$MODEL_DIR/$DRAFT_MODEL"
    exit 0
fi

echo "Downloading draft model for speculative decoding..."
echo "  Model: $DRAFT_MODEL"
echo "  Size:  ~530MB"
echo "  From:  $DRAFT_URL"
echo ""

# Try fetch with llama.cpp's built-in HF downloader first, then curl
if command -v curl >/dev/null 2>&1; then
    curl -L -o "$MODEL_DIR/$DRAFT_MODEL" "$DRAFT_URL"
elif command -v fetch >/dev/null 2>&1; then
    fetch -o "$MODEL_DIR/$DRAFT_MODEL" "$DRAFT_URL"
else
    echo "Error: No download tool available (need curl or fetch)"
    echo "Alternatively, download the draft model from llama-server directly:"
    echo "  $SCRIPT_DIR/llama.cpp/build/bin/llama-server -hfrd Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF:q8_0"
    exit 1
fi

if [ -f "$MODEL_DIR/$DRAFT_MODEL" ]; then
    echo ""
    echo "Done! Draft model saved to: $MODEL_DIR/$DRAFT_MODEL"
    ls -lh "$MODEL_DIR/$DRAFT_MODEL"
    echo ""
    echo "Speculative decoding will be automatically enabled on next server start."
else
    echo "Error: Download failed"
    exit 1
fi
