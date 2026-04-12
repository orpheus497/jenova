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
        find "$_dir" -maxdepth 1 -name "*.gguf" \( -type f -o -type l \) 2>/dev/null | sort | head -n 1
    fi
}

# --- Model Discovery ---
# Scans each type-specific folder for the first .gguf file (alphabetically).
# Model-agnostic: drop any .gguf into models/agent/, models/draft/, or
# models/embed/ and it will be picked up automatically. No hardcoded filenames.
MODEL_7B="$(_find_model "$JENOVA_ROOT/models/agent")"
MODEL_DRAFT="$(_find_model "$JENOVA_ROOT/models/draft")"
MODEL_EMBED="$(_find_model "$JENOVA_ROOT/models/embed")"

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
