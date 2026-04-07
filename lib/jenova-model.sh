#!/bin/sh
# jenova-model.sh: Shared model auto-discovery helper for jenova.conf files.
#
# Sourced by etc/jenova.conf and all hardware profile jenova.conf files after
# JENOVA_ROOT is set, so that the _find_model helper and the MODEL_* discovery
# logic live in exactly one place.  Environment variable overrides
# (JENOVA_MODEL, JENOVA_EMBED_MODEL, JENOVA_DRAFT_MODEL) are applied by the
# calling conf file after sourcing this helper, keeping the conf as the
# authoritative override point.
#
# Usage (in jenova.conf, after JENOVA_ROOT is set):
#   . "$JENOVA_ROOT/lib/jenova-model.sh"

# --- Model Auto-Discovery ---
# Helper function: find first .gguf file in a directory (alphabetically).
_find_model() {
    _dir="$1"
    if [ -d "$_dir" ]; then
        find "$_dir" -maxdepth 1 -name "*.gguf" -type f 2>/dev/null | sort | head -n 1
    fi
}

# --- Model Discovery ---
# Scans each type-specific folder and falls back to legacy flat paths.
# Priority (overrides applied by calling conf after sourcing this file):
#   1. First .gguf in models/agent|embed|draft/ (alphabetically)
#   2. Legacy flat path under models/ for backward compatibility
#   3. Empty string if no model found

# Agent model (main inference)
_AGENT_MODEL_AUTO="$(_find_model "$JENOVA_ROOT/models/agent")"
if [ -n "$_AGENT_MODEL_AUTO" ]; then
    MODEL_7B="$_AGENT_MODEL_AUTO"
elif [ -f "$JENOVA_ROOT/models/Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf" ]; then
    MODEL_7B="$JENOVA_ROOT/models/Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf"
else
    MODEL_7B=""
fi

# Draft model (speculative decoding)
_DRAFT_MODEL_AUTO="$(_find_model "$JENOVA_ROOT/models/draft")"
if [ -n "$_DRAFT_MODEL_AUTO" ]; then
    MODEL_DRAFT="$_DRAFT_MODEL_AUTO"
elif [ -f "$JENOVA_ROOT/models/Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf" ]; then
    MODEL_DRAFT="$JENOVA_ROOT/models/Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf"
else
    MODEL_DRAFT=""
fi

# Embed model (RAG and semantic search)
_EMBED_MODEL_AUTO="$(_find_model "$JENOVA_ROOT/models/embed")"
if [ -n "$_EMBED_MODEL_AUTO" ]; then
    MODEL_EMBED="$_EMBED_MODEL_AUTO"
elif [ -f "$JENOVA_ROOT/models/nomic-embed-text-v1.5.Q8_0.gguf" ]; then
    MODEL_EMBED="$JENOVA_ROOT/models/nomic-embed-text-v1.5.Q8_0.gguf"
else
    MODEL_EMBED=""
fi
