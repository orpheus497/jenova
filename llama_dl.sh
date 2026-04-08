#!/bin/sh
# llama_dl.sh: Clone or update llama.cpp into the repo (or $JENOVA_ROOT/llama.cpp).
# Idempotent: updates an existing checkout instead of failing.

REPO_URL="https://github.com/ggml-org/llama.cpp.git"

if [ -n "$JENOVA_ROOT" ]; then
    TARGET_DIR="$JENOVA_ROOT/llama.cpp"
else
    TARGET_DIR="./llama.cpp"
fi

if [ -d "$TARGET_DIR/.git" ]; then
    git -C "$TARGET_DIR" pull --ff-only
elif [ -e "$TARGET_DIR" ]; then
    echo "Error: target path '$TARGET_DIR' already exists and is not a git repository." >&2
    exit 1
else
    git clone "$REPO_URL" "$TARGET_DIR"
fi
