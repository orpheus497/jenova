#!/bin/sh
# lib/jenova-conf.sh: Path resolution and configuration for Jenova.
#
# This script detects if Jenova is running from a source repository or a
# standalone installation and exports absolute paths to critical components.
#
# Must be sourced AFTER JENOVA_ROOT is exported.
#
# Exports:
#   LLAMA_SERVER      Path to the llama-server binary
#   LLAMA_LIB_DIR     Path to directory containing shared libraries (Vulkan/CUDA)
#   VIMRUNTIME        Path to the Neovim runtime files (for jvim)
#   JENOVA_HOME       Path to the user's Jenova directory (models, state)
#   JENOVA_STATE      Path to the system state directory
#   LOG_DIR           Path to the log directory
#   CACHE_DIR         Path to the cache directory

# ── Layout Detection ──────────────────────────────────────────────────────────

if [ -f "$JENOVA_ROOT/bin/llama-server" ] && [ ! -d "$JENOVA_ROOT/external/llama.cpp" ]; then
    # Standalone Installation Layout
    export JENOVA_LAYOUT="installed"
    export LLAMA_SERVER="$JENOVA_ROOT/bin/llama-server"
    export LLAMA_LIB_DIR="$JENOVA_ROOT/bin"
    export VIMRUNTIME="$JENOVA_ROOT/jvim/runtime"
else
    # Source Repository Layout
    export JENOVA_LAYOUT="source"
    export LLAMA_SERVER="${LLAMA_SERVER:-$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server}"
    export LLAMA_LIB_DIR="$JENOVA_ROOT/external/llama.cpp/build/bin"
    export VIMRUNTIME="$JENOVA_ROOT/jvim/runtime"
fi

# ── Defaults ──────────────────────────────────────────────────────────────────

export JENOVA_HOME="${JENOVA_HOME:-$HOME/Jenova}"
export JENOVA_STATE="${JENOVA_STATE:-$JENOVA_HOME/.system}"
export JENOVA_WORKSPACES="${JENOVA_WORKSPACES:-$JENOVA_HOME/Workspaces}"
export LOG_DIR="${LOG_DIR:-$JENOVA_HOME/var/log}"
export CACHE_DIR="${CACHE_DIR:-$JENOVA_HOME/var/cache}"
export PID_FILE="${PID_FILE:-$JENOVA_STATE/jenova-ca.pid}"

# ── Local Configuration Overrides ─────────────────────────────────────────────

_jenova_local_candidate="$JENOVA_ROOT/etc/jenova.local.conf"
if [ ! -f "$_jenova_local_candidate" ] && [ "$JENOVA_LAYOUT" = "source" ]; then
    _jenova_local_candidate="$JENOVA_ROOT/external/llama.cpp/build/jenova.local.conf"
fi

if [ -f "$_jenova_local_candidate" ]; then
    _jenova_real_local=$(realpath "$_jenova_local_candidate" 2>/dev/null) || {
        echo "Warning: cannot resolve $_jenova_local_candidate — skipping" >&2
        unset _jenova_local_candidate _jenova_real_local
        return 0
    }
    _jenova_real_root=$(realpath "$JENOVA_ROOT" 2>/dev/null) || {
        echo "Warning: cannot resolve JENOVA_ROOT='$JENOVA_ROOT' — skipping local conf" >&2
        unset _jenova_local_candidate _jenova_real_local _jenova_real_root
        return 0
    }
    case "$_jenova_real_local" in
        "$_jenova_real_root"/etc/jenova.local.conf|\
        "$_jenova_real_root"/external/llama.cpp/build/jenova.local.conf)
            # shellcheck disable=SC1090
            . "$_jenova_real_local"
            ;;
        *)
            echo "Warning: refusing to source '$_jenova_real_local' (outside JENOVA_ROOT)" >&2
            ;;
    esac
fi

unset _jenova_local_candidate _jenova_real_local _jenova_real_root
