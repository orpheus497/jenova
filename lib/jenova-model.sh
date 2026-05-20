#!/bin/sh
# jenova-model.sh: Shared model auto-discovery helper for jenova.conf files.
#
# Sourced by etc/jenova.conf and all hardware profile jenova.conf files after
# JENOVA_ROOT is set, so that the _find_model helper and the MODEL_* discovery
# logic live in exactly one place. Environment variable overrides
# (JENOVA_DRAFT_MODEL, JENOVA_EMBED_MODEL) are applied here, while JENOVA_MODEL
# is typically handled in the calling conf via MODEL_PATH.
#
# Usage (in jenova.conf, after JENOVA_ROOT is set):
#   . "$JENOVA_ROOT/lib/jenova-model.sh"

# --- Model Auto-Discovery ---
# This script handles the automated discovery of model files within the system.
# It employs an alphabetical scanning fallback logic: it will search the designated
# directories for .gguf files, sort them alphabetically, and select the first one.
# This ensures a predictable default if multiple models exist in the same directory.
#
# Environment overrides (JENOVA_MODEL, JENOVA_DRAFT_MODEL, JENOVA_EMBED_MODEL)
# can be set by the user to bypass this discovery and force the use of a specific file.
#
# Helper function: find first .gguf file in a directory (alphabetically).
_find_model() {
    _dir="$1"
    if [ -d "$_dir" ]; then
        # Find all .gguf files (including symlinks), sort them, and take the first one.
        find "$_dir" -maxdepth 1 -name "*.gguf" \( -type f -o -type l \) 2>/dev/null | sort | head -n 1
    fi
}

# --- Model Discovery ---
JENOVA_HOME="${JENOVA_HOME:-$HOME/Jenova}"
_MODELS_DIR="${JENOVA_HOME}/models"

# Scans each type-specific folder. Overrides can be applied later.
# Priority:
#   1. First .gguf in JENOVA_HOME/models/agent|embed|draft/ (alphabetically)
#   2. Legacy flat path under JENOVA_ROOT/models/ (alphabetically)
#   3. Empty string if no model found

# Agent model (main inference) - Fallback to root models/ directory if type-specific folder is empty
MODEL_AGENT="$(_find_model "$_MODELS_DIR/agent")"
if [ -z "$MODEL_AGENT" ]; then
    MODEL_AGENT="$(_find_model "$JENOVA_ROOT/models/agent")"
fi
if [ -z "$MODEL_AGENT" ]; then
    # Fallback to root models/ directory
    MODEL_AGENT="$(_find_model "$_MODELS_DIR")"
fi
if [ -z "$MODEL_AGENT" ]; then
    MODEL_AGENT="$(_find_model "$JENOVA_ROOT/models")"
fi

# Draft model (speculative decoding) - supports JENOVA_DRAFT_MODEL override
MODEL_DRAFT="${JENOVA_DRAFT_MODEL:-$(_find_model "$_MODELS_DIR/draft")}"
if [ -z "$MODEL_DRAFT" ]; then
    MODEL_DRAFT="$(_find_model "$JENOVA_ROOT/models/draft")"
fi

# Embed model (RAG and semantic search) - supports JENOVA_EMBED_MODEL override
MODEL_EMBED="${JENOVA_EMBED_MODEL:-$(_find_model "$_MODELS_DIR/embed")}"
if [ -z "$MODEL_EMBED" ]; then
    MODEL_EMBED="$(_find_model "$JENOVA_ROOT/models/embed")"
fi

# Legacy alias for backward compatibility
MODEL_7B="$MODEL_AGENT"

# --- Shared Device Utilities ---
# count_devices: count comma-separated entries in a device string.
# Usage: DEVICE_COUNT=$(count_devices "$DEVICES")
count_devices() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1" | awk -F',' '{ print NF }'
    else
        echo 0
    fi
}
