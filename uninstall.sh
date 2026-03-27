#!/bin/sh
# uninstall.sh: Jenova Cognitive Architecture — Uninstall Script
#
# Usage: ./uninstall.sh [--purge] [--yes]
#
#   --purge   Also remove Neovim plugin data (~/.local/share/nvim/lazy/)
#             and Mason data (~/.local/share/nvim/mason/).
#             Does NOT remove undo files or shada (user data).
#   --yes     Skip all confirmation prompts (non-interactive mode).
#
# What this removes:
#   - ~/.config/nvim/init.lua and lua/plugins/*.lua deployed by install.sh
#   - ~/.local/bin/jvim and ~/.local/bin/jenova symlinks (if present)
#   - ~/bin/jvim and ~/bin/jenova symlinks (if present)
#
# What this preserves (user data, not overwritten by install):
#   - ~/.local/state/nvim/ (undo files, shada, gp.nvim chat history)
#   - The Jenova project directory itself (models, config, logs)

set -e

JENOVA_ROOT="$(dirname "$(realpath "$0")")"
NVIM_CONFIG_DST="$HOME/.config/nvim"

PURGE=0
YES=0

for _arg in "$@"; do
    case "$_arg" in
        --purge) PURGE=1 ;;
        --yes)   YES=1 ;;
        -h|--help)
            sed -n '2,25p' "$0"
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
    _G="\033[0;32m"; _Y="\033[0;33m"; _R="\033[0;31m"; _B="\033[1;34m"; _N="\033[0m"
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
    echo "    $NVIM_CONFIG_DST/init.lua"
    echo "    $NVIM_CONFIG_DST/lua/plugins/*.lua"
    echo "    $NVIM_CONFIG_DST/lazy-lock.json"
    echo "    ~/.local/bin/jvim, ~/.local/bin/jenova (symlinks)"
    echo "    ~/bin/jvim, ~/bin/jenova (symlinks)"
    if [ "$PURGE" = "1" ]; then
        echo "    ~/.local/share/nvim/lazy/ (plugin data — --purge)"
        echo "    ~/.local/share/nvim/mason/ (Mason data — --purge)"
    fi
    echo ""
    printf "  Continue? [y/N] "
    read _ans
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
    "$NVIM_CONFIG_DST/init.lua" \
    "$NVIM_CONFIG_DST/lazy-lock.json"
do
    if [ -e "$_f" ] || [ -L "$_f" ]; then
        rm -f "$_f"
        ok "Removed $_f"
        _removed=$((_removed + 1))
    fi
done

if [ -d "$NVIM_CONFIG_DST/lua/plugins" ]; then
    for _f in "$NVIM_CONFIG_DST/lua/plugins/"*.lua; do
        [ -e "$_f" ] || [ -L "$_f" ] || continue
        rm -f "$_f"
        ok "Removed $_f"
        _removed=$((_removed + 1))
    done
    rmdir "$NVIM_CONFIG_DST/lua/plugins" 2>/dev/null && ok "Removed empty plugins/ dir" || true
fi
if [ -d "$NVIM_CONFIG_DST/lua/jenova" ]; then
    for _f in "$NVIM_CONFIG_DST/lua/jenova/"*.lua; do
        [ -e "$_f" ] || [ -L "$_f" ] || continue
        rm -f "$_f"
        ok "Removed $_f"
        _removed=$((_removed + 1))
    done
    rmdir "$NVIM_CONFIG_DST/lua/jenova" 2>/dev/null && ok "Removed empty jenova/ dir" || true
fi
if [ -d "$NVIM_CONFIG_DST/lua" ]; then
    rmdir "$NVIM_CONFIG_DST/lua" 2>/dev/null && ok "Removed empty lua/ dir" || true
fi
if [ -d "$NVIM_CONFIG_DST" ]; then
    rmdir "$NVIM_CONFIG_DST" 2>/dev/null && ok "Removed empty ~/.config/nvim/ dir" || true
fi

if [ "$_removed" = "0" ]; then
    warn "No Neovim config files found to remove (already clean)"
fi

# ---------------------------------------------------------------------------
# Remove jvim / jenova symlinks from PATH bin dirs
# ---------------------------------------------------------------------------
info "Removing launcher symlinks..."
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    for _bin in jvim jenova; do
        _sym="$_d/$_bin"
        if [ -L "$_sym" ]; then
            _target=$(readlink "$_sym")
            if echo "$_target" | grep -q "$JENOVA_ROOT"; then
                rm -f "$_sym"
                ok "Removed $_sym -> $_target"
            else
                warn "Skipping $_sym (points to $_target, not this Jenova install)"
            fi
        fi
    done
done

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
# Summary
# ---------------------------------------------------------------------------
echo ""
ok "Uninstall complete."
echo ""
info "Preserved (user data):"
echo "    ~/.local/state/nvim/  (undo files, shada, gp.nvim chats)"
echo "    $JENOVA_ROOT/          (project directory — models, config, logs)"
echo ""
info "To fully remove the Jenova project directory:"
echo "    rm -rf $JENOVA_ROOT"
echo ""
