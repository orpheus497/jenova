#!/bin/sh
# uninstall.sh: Jenova Cognitive Architecture — Uninstall Script
#
# Removes the files this monorepo's installer deployed: the Neovim config in
# ~/.config/jvim/ and the launcher symlinks (jvim, jenova, jenova-ca) that
# install.sh placed on PATH. Optional flags also clear plugin data, runtime
# state, and the in-tree jvim/llama.cpp build outputs.
#
# Usage: ./uninstall.sh [--purge] [--clean-runtime] [--clean-builds] [--yes]
#
#   --purge          Also remove Neovim plugin data (~/.local/share/nvim/lazy/)
#                    and Mason data (~/.local/share/nvim/mason/).
#                    Does NOT remove undo files or shada (user data).
#   --clean-runtime  Remove runtime artifacts within the project directory:
#                    .jenova/ (PID/lock files), var/log/, var/cache/, and the
#                    models/jenova.gguf convenience symlink.
#   --clean-builds   Remove in-tree build outputs: jvim/build/, jvim/install/,
#                    external/llama.cpp/build/. Does NOT touch source.
#   --yes            Skip all confirmation prompts (non-interactive mode).
#
# What this removes:
#   - ~/.config/jvim/init.lua, lazy-lock.json, and lua/{plugins,jenova}/*.lua
#     that were deployed by install.sh
#   - ~/.local/bin/{jvim,jenova,jenova-ca} symlinks (only those pointing into
#     this Jenova checkout)
#   - ~/bin/{jvim,jenova,jenova-ca} symlinks (same scope)
#
# What this preserves (user data, never touched by install/update):
#   - ~/.local/state/nvim/ (undo files, shada, jenova chat history)
#   - $JENOVA_ROOT/models/*.gguf (actual GGUF files; only the symlink is removed)
#   - The Jenova project directory itself (source code, configs, models)

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
JENOVA_HOME="${JENOVA_HOME:-$HOME/Jenova}"
JVIM_CONFIG_DST="$HOME/.config/jvim"

PURGE=0
CLEAN_RUNTIME=0
CLEAN_BUILDS=0
YES=0

for _arg in "$@"; do
    case "$_arg" in
        --purge)         PURGE=1 ;;
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
    echo "    $JVIM_CONFIG_DST/init.lua"
    echo "    $JVIM_CONFIG_DST/lua/plugins/*.lua"
    echo "    $JVIM_CONFIG_DST/lazy-lock.json"
    echo "    ~/.local/bin/jvim, ~/.local/bin/jenova, ~/.local/bin/jenova-ca (symlinks)"
    echo "    ~/bin/jvim, ~/bin/jenova, ~/bin/jenova-ca (symlinks)"
    if [ "$PURGE" = "1" ]; then
        echo "    ~/.local/share/nvim/lazy/ (plugin data — --purge)"
        echo "    ~/.local/share/nvim/mason/ (Mason data — --purge)"
    fi
    if [ "$CLEAN_RUNTIME" = "1" ]; then
        echo "    $JENOVA_ROOT/.jenova/ (PID files, locks — --clean-runtime)"
        echo "    $JENOVA_ROOT/var/log/ (log files — --clean-runtime)"
        echo "    $JENOVA_ROOT/var/cache/ (cache — --clean-runtime)"
        echo "    $JENOVA_ROOT/models/jenova.gguf (symlink — --clean-runtime)"
    fi
    if [ "$CLEAN_BUILDS" = "1" ]; then
        echo "    $JENOVA_ROOT/jvim/build/ (in-tree jvim build — --clean-builds)"
        echo "    $JENOVA_ROOT/jvim/install/ (in-tree jvim install — --clean-builds)"
        echo "    $JENOVA_ROOT/jvim/build/ (jvim build — --clean-builds)"
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
# Remove Neovim config files
# ---------------------------------------------------------------------------
info "Removing Neovim configuration files..."

_removed=0
for _f in \
    "$JVIM_CONFIG_DST/init.lua" \
    "$JVIM_CONFIG_DST/lazy-lock.json"
do
    if [ -e "$_f" ] || [ -L "$_f" ]; then
        rm -f "$_f"
        ok "Removed $_f"
        _removed=$((_removed + 1))
    fi
done

if [ -d "$JVIM_CONFIG_DST/lua/plugins" ]; then
    for _f in "$JVIM_CONFIG_DST/lua/plugins/"*.lua; do
        [ -e "$_f" ] || [ -L "$_f" ] || continue
        rm -f "$_f"
        ok "Removed $_f"
        _removed=$((_removed + 1))
    done
    rmdir "$JVIM_CONFIG_DST/lua/plugins" 2>/dev/null && ok "Removed empty plugins/ dir" || true
fi
if [ -d "$JVIM_CONFIG_DST/lua/jenova" ]; then
    for _f in "$JVIM_CONFIG_DST/lua/jenova/"*.lua; do
        [ -e "$_f" ] || [ -L "$_f" ] || continue
        rm -f "$_f"
        ok "Removed $_f"
        _removed=$((_removed + 1))
    done
    rmdir "$JVIM_CONFIG_DST/lua/jenova" 2>/dev/null && ok "Removed empty jenova/ dir" || true
fi
if [ -d "$JVIM_CONFIG_DST/lua/jenova/agent" ]; then
    rm -rf "$JVIM_CONFIG_DST/lua/jenova/agent"
    ok "Removed embedded agent tree"
    _removed=$((_removed + 1))
fi
if [ -d "$JVIM_CONFIG_DST/lua" ]; then
    rmdir "$JVIM_CONFIG_DST/lua" 2>/dev/null && ok "Removed empty lua/ dir" || true
fi
if [ -d "$JVIM_CONFIG_DST" ]; then
    rmdir "$JVIM_CONFIG_DST" 2>/dev/null && ok "Removed empty ~/.config/jvim/ dir" || true
fi

if [ "$_removed" = "0" ]; then
    warn "No jvim config files found to remove (already clean)"
fi

# ---------------------------------------------------------------------------
# Remove jvim / jenova symlinks from PATH bin dirs
# ---------------------------------------------------------------------------
info "Removing launcher symlinks and binaries..."
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    for _bin in jvim jenova jenova-ca jenova-ui jenova-tui jenova-term jenova-swap-mount; do
        _sym="$_d/$_bin"
        if [ -L "$_sym" ]; then
            _target=$(readlink "$_sym")
            if echo "$_target" | grep -qF "$JENOVA_HOME" || echo "$_target" | grep -qF "$JENOVA_ROOT"; then
                rm -f "$_sym"
                ok "Removed $_sym -> $_target"
            fi
        fi
    done
done

# Remove binaries from JENOVA_HOME/bin
if [ -d "$JENOVA_HOME/bin" ]; then
    for _bin in jvim jenova jenova-ca jenova-ui jenova-tui jenova-term jenova-swap-mount; do
        if [ -f "$JENOVA_HOME/bin/$_bin" ]; then
            rm -f "$JENOVA_HOME/bin/$_bin"
            ok "Removed $JENOVA_HOME/bin/$_bin"
        fi
    done
    rmdir "$JENOVA_HOME/bin" 2>/dev/null && ok "Removed empty $JENOVA_HOME/bin dir" || true
fi

# ---------------------------------------------------------------------------
# Purge plugin data (--purge only)
# ---------------------------------------------------------------------------
if [ "$PURGE" = "1" ]; then
    info "Purging plugin data (--purge)..."

    for _d in \
        "$HOME/.local/share/nvim/lazy" \
        "$HOME/.local/share/nvim/mason"
    do
        if [ -d "$_d" ]; then
            rm -rf "$_d"
            ok "Removed $_d"
        else
            warn "$_d not found (already clean)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Clean runtime artifacts (--clean-runtime only)
# ---------------------------------------------------------------------------
if [ "$CLEAN_RUNTIME" = "1" ]; then
    info "Cleaning runtime artifacts from $JENOVA_HOME (--clean-runtime)..."

    # Remove PID files and locks
    if [ -d "$JENOVA_HOME/.system" ]; then
        rm -f "$JENOVA_HOME/.system/"*.pid "$JENOVA_HOME/.system/"*.pid.lock 2>/dev/null
        ok "Cleared PID/lock files from $JENOVA_HOME/.system/"
        rmdir "$JENOVA_HOME/.system" 2>/dev/null && ok "Removed empty $JENOVA_HOME/.system dir" || true
    fi

    # Legacy support
    if [ -d "$JENOVA_ROOT/.jenova" ]; then
        rm -rf "$JENOVA_ROOT/.jenova"
        ok "Removed legacy $JENOVA_ROOT/.jenova"
    fi

    # Remove log files
    if [ -d "$JENOVA_HOME/var/log" ]; then
        rm -rf "$JENOVA_HOME/var/log"
        ok "Removed $JENOVA_HOME/var/log"
    fi

    # Remove cache
    if [ -d "$JENOVA_HOME/var/cache" ]; then
        rm -rf "$JENOVA_HOME/var/cache"
        ok "Removed $JENOVA_HOME/var/cache"
    fi

    # Remove run dir
    if [ -d "$JENOVA_HOME/var/run" ]; then
        rm -rf "$JENOVA_HOME/var/run"
        ok "Removed $JENOVA_HOME/var/run"
    fi

    # Clean up empty JENOVA_HOME/var dir
    if [ -d "$JENOVA_HOME/var" ]; then
        rmdir "$JENOVA_HOME/var" 2>/dev/null && ok "Removed empty $JENOVA_HOME/var dir" || true
    fi

    # Remove model convenience symlink
    if [ -L "$JENOVA_HOME/models/jenova.gguf" ]; then
        rm -f "$JENOVA_HOME/models/jenova.gguf"
        ok "Removed $JENOVA_HOME/models/jenova.gguf symlink"
    fi
fi

# ---------------------------------------------------------------------------
# Remove in-tree build outputs (--clean-builds only)
# ---------------------------------------------------------------------------
if [ "$CLEAN_BUILDS" = "1" ]; then
    info "Removing in-tree build outputs (--clean-builds)..."
    for _bd in \
        "$JENOVA_ROOT/jvim/build" \
        "$JENOVA_ROOT/jvim/install" \
        "$JENOVA_ROOT/jvim/build" \
        "$JENOVA_ROOT/jvim/install" \
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
    echo "    $JENOVA_ROOT/jvim/build/, external/llama.cpp/build/ (use --clean-builds to remove)"
fi
echo "    $JENOVA_ROOT/          (project directory — source, configs, models)"
echo ""
info "To fully remove the Jenova project directory:"
echo "    rm -rf $JENOVA_ROOT"
echo ""
