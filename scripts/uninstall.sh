#!/bin/sh
# uninstall.sh: Jenova Cognitive Architecture — Uninstall Script
#
# Removes the files this monorepo's installer deployed: the Neovim config in
# ~/.config/jenova/ and the launcher symlinks (jenova, jenova, jenova-ca) that
# install.sh placed on PATH. Optional flags also clear plugin data, runtime
# state, and the in-tree jenova/llama.cpp build outputs.
#
# Usage: ./uninstall.sh [--purge] [--clean-runtime] [--clean-builds] [--yes]
#
#   --purge          Also remove Neovim plugin data (~/.local/share/nvim/lazy/)
#                    and Mason data (~/.local/share/nvim/mason/).
#                    Does NOT remove undo files or shada (user data).
#   --clean-runtime  Remove runtime artifacts within the project directory:
#                    .jenova/ (PID/lock files), var/log/, var/cache/, and the
#                    models/jenova.gguf convenience symlink.
#   --clean-builds   Remove in-tree build outputs: bin/jenova-ui/, bin/jenova-ui/,
#                    external/llama.cpp/build/. Does NOT touch source.
#   --yes            Skip all confirmation prompts (non-interactive mode).
#
# What this removes:
#   - ~/.config/jenova/init.lua, lazy-lock.json, and lua/{plugins,jenova}/*.lua
#     that were deployed by install.sh
#   - ~/.local/bin/{jenova,jenova,jenova-ca} symlinks (only those pointing into
#     this Jenova checkout)
#   - ~/bin/{jenova,jenova,jenova-ca} symlinks (same scope)
#
# What this preserves (user data, never touched by install/update):
#   - ~/.local/state/nvim/ (undo files, shada, jenova chat history)
#   - $JCA_HOME/models/*.gguf (actual GGUF files; only the symlink is removed)
#   - The Jenova project directory itself (source code, configs, models)

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
JCA_HOME="${JCA_HOME:-$HOME/JCA}"

CLEAN_RUNTIME=0
CLEAN_BUILDS=0
YES=0

for _arg in "$@"; do
    case "$_arg" in
        --clean-runtime) CLEAN_RUNTIME=1 ;;
        --clean-builds)  CLEAN_BUILDS=1 ;;
        --yes)           YES=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    _G=$(printf '\033[0;32m'); _Y=$(printf '\033[0;33m'); _R=$(printf '\033[0;31m'); _B=$(printf '\033[1;34m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _N=""
fi

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y} WARN${_N}  %s\n" "$1"; }
info() { printf "${_B} INFO${_N}  %s\n" "$1"; }

echo ""
printf "${_R}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_R}║  Jenova Cognitive Architecture — Uninstall           ║${_N}\n"
printf "${_R}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

# ---------------------------------------------------------------------------
# Stop running daemons first
# ---------------------------------------------------------------------------
info "Stopping Jenova CA backend (if running)..."
JENOVA_CA="$JENOVA_ROOT/bin/jenova-ca"
if [ -f "$JENOVA_CA" ]; then
    "$JENOVA_CA" stop 2>/dev/null && ok "Jenova CA stopped" || warn "jenova-ca stop returned non-zero (may not have been running)"
else
    warn "jenova-ca not found at $JENOVA_CA — skipping daemon stop"
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [ "$YES" = "0" ]; then
    echo ""
    warn "This will remove:"
    echo "    ~/.local/bin/jenova, ~/.local/bin/jenova-ca (symlinks)"
    echo "    ~/bin/jenova, ~/bin/jenova-ca (symlinks)"
    if [ "$CLEAN_RUNTIME" = "1" ]; then
        echo "    $JENOVA_ROOT/.jenova/ (PID files, locks — --clean-runtime)"
        echo "    $JCA_HOME/var/log/ (log files — --clean-runtime)"
        echo "    $JCA_HOME/var/cache/ (cache — --clean-runtime)"
        echo "    $JCA_HOME/models/jenova.gguf (symlink — --clean-runtime)"
    fi
    if [ "$CLEAN_BUILDS" = "1" ]; then
        echo "    $JENOVA_ROOT/bin/jenova-ui/ (in-tree jenova build — --clean-builds)"
        echo "    $JENOVA_ROOT/bin/jenova-ui/ (in-tree jenova install — --clean-builds)"
        echo "    $JENOVA_ROOT/bin/jenova-ui/ (jenova build — --clean-builds)"
        echo "    $JENOVA_ROOT/external/llama.cpp/build/ (llama.cpp build — --clean-builds)"
    fi
    echo ""
    printf "  Continue? [y/N] "
    read -r _ans
    case "$_ans" in
        y|Y|yes|YES) ;;
        *)
            echo "  Aborted."
            exit 0
            ;;
    esac
fi


# ---------------------------------------------------------------------------
# Remove jenova / jenova symlinks from PATH bin dirs
# ---------------------------------------------------------------------------
info "Removing launcher symlinks and binaries..."
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    for _bin in jenova jenova-ca jenova-ui jenova-tui jenova-swap-mount; do
        _sym="$_d/$_bin"
        if [ -L "$_sym" ]; then
            _target=$(readlink "$_sym")
            if echo "$_target" | grep -qF "$JCA_HOME" || echo "$_target" | grep -qF "$JENOVA_ROOT"; then
                rm -f "$_sym"
                ok "Removed $_sym -> $_target"
            fi
        fi
    done
done

# Remove binaries from JCA_HOME/bin
if [ -d "$JCA_HOME/bin" ]; then
    for _bin in jenova jenova-ca jenova-ui jenova-tui jenova-swap-mount; do
        if [ -f "$JCA_HOME/bin/$_bin" ]; then
            rm -f "$JCA_HOME/bin/$_bin"
            ok "Removed $JCA_HOME/bin/$_bin"
        fi
    done
    rmdir "$JCA_HOME/bin" 2>/dev/null && ok "Removed empty $JCA_HOME/bin dir" || true
fi


# ---------------------------------------------------------------------------
# Clean runtime artifacts (--clean-runtime only)
# ---------------------------------------------------------------------------
if [ "$CLEAN_RUNTIME" = "1" ]; then
    info "Cleaning runtime artifacts from $JCA_HOME (--clean-runtime)..."

    # Remove PID files and locks
    if [ -d "$JCA_HOME/.system" ]; then
        rm -f "$JCA_HOME/.system/"*.pid "$JCA_HOME/.system/"*.pid.lock 2>/dev/null
        ok "Cleared PID/lock files from $JCA_HOME/.system/"
        rmdir "$JCA_HOME/.system" 2>/dev/null && ok "Removed empty $JCA_HOME/.system dir" || true
    fi

    # Legacy support
    if [ -d "$JENOVA_ROOT/.jenova" ]; then
        rm -rf "$JENOVA_ROOT/.jenova"
        ok "Removed legacy $JENOVA_ROOT/.jenova"
    fi

    # Remove log files
    if [ -d "$JCA_HOME/var/log" ]; then
        rm -rf "$JCA_HOME/var/log"
        ok "Removed $JCA_HOME/var/log"
    fi

    # Remove cache
    if [ -d "$JCA_HOME/var/cache" ]; then
        rm -rf "$JCA_HOME/var/cache"
        ok "Removed $JCA_HOME/var/cache"
    fi

    # Remove run dir
    if [ -d "$JCA_HOME/var/run" ]; then
        rm -rf "$JCA_HOME/var/run"
        ok "Removed $JCA_HOME/var/run"
    fi

    # Clean up empty JCA_HOME/var dir
    if [ -d "$JCA_HOME/var" ]; then
        rmdir "$JCA_HOME/var" 2>/dev/null && ok "Removed empty $JCA_HOME/var dir" || true
    fi

    # Remove model convenience symlink
    if [ -L "$JCA_HOME/models/jenova.gguf" ]; then
        rm -f "$JCA_HOME/models/jenova.gguf"
        ok "Removed $JCA_HOME/models/jenova.gguf symlink"
    fi
fi

# ---------------------------------------------------------------------------
# Remove in-tree build outputs (--clean-builds only)
# ---------------------------------------------------------------------------
if [ "$CLEAN_BUILDS" = "1" ]; then
    info "Removing in-tree build outputs (--clean-builds)..."
    for _bd in \
        "$JENOVA_ROOT/bin/jenova-ui" \
        "$JENOVA_ROOT/external/llama.cpp/build"
    do
        if [ -d "$_bd" ]; then
            rm -rf "$_bd"
            ok "Removed $_bd"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
ok "Uninstall complete."
echo ""
info "Preserved (user data):"
echo "    ~/.local/state/nvim/  (undo files, shada, jenova chats)"
if [ "$CLEAN_RUNTIME" = "0" ]; then
    echo "    $JENOVA_ROOT/.jenova/ (runtime state — use --clean-runtime to remove)"
    echo "    $JENOVA_ROOT/var/     (logs, cache — use --clean-runtime to remove)"
fi
if [ "$CLEAN_BUILDS" = "0" ]; then
    echo "    $JENOVA_ROOT/bin/jenova-ui/, external/llama.cpp/build/ (use --clean-builds to remove)"
fi
echo "    $JENOVA_ROOT/          (project directory — source, configs, models)"
echo ""
info "To fully remove the Jenova project directory:"
echo "    rm -rf $JENOVA_ROOT"
echo ""
