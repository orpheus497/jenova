#!/bin/sh
# lib/jenova-conf.sh: Safely source optional Jenova local configuration overrides.
#
# Must be sourced AFTER JENOVA_ROOT is exported. Sources the first of:
#   1. $JENOVA_ROOT/etc/jenova.local.conf
#   2. $JENOVA_ROOT/llama.cpp/build/jenova.local.conf
#
# The resolved path is validated with realpath to ensure it stays within
# JENOVA_ROOT, preventing directory-traversal via symlinks or env var injection.
#
# Usage:
#   # In any script that has JENOVA_ROOT set:
#   . "$JENOVA_ROOT/lib/jenova-conf.sh"

_jenova_local_candidate="$JENOVA_ROOT/etc/jenova.local.conf"
if [ ! -f "$_jenova_local_candidate" ]; then
    _jenova_local_candidate="$JENOVA_ROOT/llama.cpp/build/jenova.local.conf"
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
        "$_jenova_real_root"/llama.cpp/build/jenova.local.conf)
            # shellcheck disable=SC1090
            . "$_jenova_real_local"
            ;;
        *)
            echo "Warning: refusing to source '$_jenova_real_local' (outside JENOVA_ROOT)" >&2
            ;;
    esac
fi

unset _jenova_local_candidate _jenova_real_local _jenova_real_root
