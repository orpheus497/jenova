#!/bin/sh
# lib/jenova-conf.sh: Path resolution and configuration for Jenova.
# Safely source optional Jenova local configuration overrides.
#
# This script detects if Jenova is running from a source repository or a
# standalone installation and exports absolute paths to critical components.
#
# Must be sourced AFTER JENOVA_ROOT is exported. Sources the first of:
#   1. $JENOVA_ROOT/etc/jenova.local.conf
#   2. $JENOVA_ROOT/external/llama.cpp/build/jenova.local.conf
#
# The resolved path is validated with realpath to ensure it stays within
# JENOVA_ROOT, preventing directory-traversal via symlinks or env var injection.
#
# Exports:
#   LLAMA_SERVER      Path to the llama-server binary
#   LLAMA_LIB_DIR     Path to llama.cpp shared libraries
#   JCA_HOME       Path to the user's Jenova directory (models, state)
#   JENOVA_STATE      Path to the system state directory
#   LOG_DIR           Path to the log directory
#   CACHE_DIR         Path to the cache directory

# ── Layout Detection ──────────────────────────────────────────────────────────

if [ -f "$JENOVA_ROOT/bin/llama-server" ] && [ ! -d "$JENOVA_ROOT/external/llama.cpp" ]; then
    # Standalone Installation Layout
    JENOVA_LAYOUT="installed"; export JENOVA_LAYOUT
    LLAMA_SERVER="$JENOVA_ROOT/bin/llama-server"; export LLAMA_SERVER
    LLAMA_LIB_DIR="$JENOVA_ROOT/bin"; export LLAMA_LIB_DIR
else
    # Source Repository Layout
    JENOVA_LAYOUT="source"; export JENOVA_LAYOUT
    LLAMA_SERVER="${LLAMA_SERVER:-$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server}"; export LLAMA_SERVER
    LLAMA_LIB_DIR="$JENOVA_ROOT/external/llama.cpp/build/bin"; export LLAMA_LIB_DIR
fi

# ── Defaults ──────────────────────────────────────────────────────────────────

JCA_HOME="${JCA_HOME:-$HOME/JCA}"; export JCA_HOME
JENOVA_STATE="${JENOVA_STATE:-$JCA_HOME/.system}"; export JENOVA_STATE
JENOVA_WORKSPACES="${JENOVA_WORKSPACES:-$JCA_HOME/Workspaces}"; export JENOVA_WORKSPACES
LOG_DIR="${LOG_DIR:-$JCA_HOME/var/log}"; export LOG_DIR
CACHE_DIR="${CACHE_DIR:-$JCA_HOME/var/cache}"; export CACHE_DIR
PID_FILE="${PID_FILE:-$JENOVA_STATE/jenova-ca.pid}"; export PID_FILE

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
