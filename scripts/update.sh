#!/bin/sh
# update.sh: Jenova Cognitive Architecture — Update Script
#
# Single-repo update: pulls the latest jenova source (which now includes 
# llama.cpp and SPIRV-Headers as in-tree components), rebuilds 
# components when sources have moved, restarts jenova-ca, and resyncs 
# the Neovim plugin set.
#
# Usage: ./update.sh [--upgrade-plugins] [--skip-nvim] [--skip-rebuild]
#                    [] [--link] [--apply-profile]
#                    [--ui] [--web] [--all] [--no-pull]

set -e

# POSIX-compliant script. No bashisms allowed.

_REAL_SCRIPT=$(realpath "$0" 2>/dev/null || echo "$0")
_SCRIPT_DIR=$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)
JENOVA_ROOT=$(cd "$_SCRIPT_DIR/.." && pwd)
JCA_HOME="${JCA_HOME:-$HOME/JCA}"
JVIM_CONFIG_SRC="$JENOVA_ROOT/jenova-config"
JVIM_CONFIG_DST="$HOME/.config/jenova"

# Shared OS/hardware detection
. "$JENOVA_ROOT/lib/detect-env.sh"

UPGRADE_PLUGINS=0
SKIP_NVIM=0
SKIP_REBUILD=0
SKIP_JVIM=0
LINK=0
APPLY_PROFILE=0
NO_PULL=0
UPDATE_UI=0
UPDATE_WEB=0

for _arg in "$@"; do
    case "$_arg" in
        --upgrade-plugins) UPGRADE_PLUGINS=1 ;;
        --skip-nvim)       SKIP_NVIM=1 ;;
        --skip-rebuild)    SKIP_REBUILD=1 ;;
        )       SKIP_JVIM=1 ;;
        --link)            LINK=1 ;;
        --apply-profile)   APPLY_PROFILE=1 ;;
        --ui)              UPDATE_UI=1 ;;
        --web)             UPDATE_WEB=1 ;;
        --all)             UPDATE_UI=1; UPDATE_WEB=1; APPLY_PROFILE=1 ;;
        --no-pull)         NO_PULL=1 ;;
        -h|--help)
            # Portable head-like behavior with sed
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours (POSIX compliant colour definitions)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    _G=$(printf '\033[0;32m'); _Y=$(printf '\033[0;33m'); _R=$(printf '\033[0;31m'); _B=$(printf '\033[1;34m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _N=""
fi

ok()   { printf "%s  OK%s  %s\n" "${_G}" "${_N}" "$1"; }
warn() { printf "%s WARN%s  %s\n" "${_Y}" "${_N}" "$1"; }
info() { printf "%s INFO%s  %s\n" "${_B}" "${_N}" "$1"; }

echo ""
printf "%s╔══════════════════════════════════════════════════════╗%s\n" "${_B}" "${_N}"
printf "%s║  Jenova Cognitive Architecture — Update              ║%s\n" "${_B}" "${_N}"
printf "%s╚══════════════════════════════════════════════════════╝%s\n" "${_B}" "${_N}"
echo ""

# ---------------------------------------------------------------------------
# 1. Git pull
# ---------------------------------------------------------------------------
if [ "$NO_PULL" = "0" ]; then
    info "Pulling latest changes from origin..."
    cd "$JENOVA_ROOT"
    _branch=$(git branch --show-current 2>/dev/null || echo "main")
    git pull origin "${_branch}" && ok "git pull complete" || {
        warn "git pull failed — continuing with current code"
    }

    DETECT_SCRIPT="$JENOVA_ROOT/hardware-profiles/detect-hardware.sh"
    if [ "$APPLY_PROFILE" = "1" ] && [ -f "$DETECT_SCRIPT" ] && [ -x "$DETECT_SCRIPT" ]; then
        info "Re-applying hardware profile (--apply-profile)..."
        "$DETECT_SCRIPT" --apply || warn "Failed to re-apply hardware profile"
    fi

    echo ""
    info "Recent changes (last 10 commits):"
    git log --oneline -10 2>/dev/null | sed 's/^/    /'
    echo ""
else
    info "Skipping git pull (--no-pull)"
fi

# ---------------------------------------------------------------------------
# 2. Reload backend if running
# ---------------------------------------------------------------------------
info "Checking Jenova CA backend..."
JENOVA_CA="$JENOVA_ROOT/bin/jenova-ca"
if [ -f "$JENOVA_CA" ]; then
    # Portable sourcing
    [ -f "$JENOVA_ROOT/etc/jenova.conf" ] && . "$JENOVA_ROOT/etc/jenova.conf"
    
    _PID_FILE="${PID_FILE:-$JENOVA_ROOT/.jenova/jenova-ca.pid}"
    if [ -f "$_PID_FILE" ]; then
        # Read PIDs into positional parameters for POSIX compliance
        set -- $(cat "$_PID_FILE" 2>/dev/null)
        _ANY_ALIVE=false
        for _P in "$@"; do
            if [ -n "$_P" ] && kill -0 "$_P" 2>/dev/null; then
                _ANY_ALIVE=true
                break
            fi
        done
        if [ "$_ANY_ALIVE" = "true" ]; then
            warn "Jenova CA is currently running. Restarting..."
            "$JENOVA_CA" restart 2>/dev/null && ok "Jenova CA restarted" || warn "Restart failed"
        else
            ok "Jenova CA not running"
        fi
    else
        ok "Jenova CA not running"
    fi
else
    warn "jenova-ca not found at $JENOVA_CA"
fi

# ---------------------------------------------------------------------------
# 3. llama.cpp rebuild check
# ---------------------------------------------------------------------------
if [ "$SKIP_REBUILD" = "0" ]; then
    info "Checking llama.cpp..."
    LLAMA_DIR="$JENOVA_ROOT/external/llama.cpp"
    LLAMA_BIN="$LLAMA_DIR/build/bin/llama-server"

    _need_rebuild=0
    if [ ! -x "$LLAMA_BIN" ]; then
        warn "llama-server binary missing — forcing rebuild"
        _need_rebuild=1
    elif [ -n "$(find "$LLAMA_DIR/src" "$LLAMA_DIR/include" "$LLAMA_DIR/ggml" \
                      "$LLAMA_DIR/CMakeLists.txt" -newer "$LLAMA_BIN" \
                      -print -quit 2>/dev/null)" ]; then
        warn "llama.cpp sources updated — forcing rebuild"
        _need_rebuild=1
    fi

    if [ "$_need_rebuild" = "1" ]; then
        info "Building llama.cpp..."
        "$JENOVA_ROOT/bin/build-llama-jenova" && ok "llama.cpp built" || warn "llama.cpp build failed"
    else
        ok "llama.cpp up to date"
    fi
fi

# ---------------------------------------------------------------------------
# 3b. jenova rebuild check
# ---------------------------------------------------------------------------
if [ "$SKIP_JVIM" = "0" ]; then
    info "Checking bundled jenova editor..."
    JVIM_SRC="$JENOVA_ROOT/jenova"
    JVIM_BIN="$JVIM_SRC/build/bin/nvim"
    if [ ! -f "$JVIM_SRC/CMakeLists.txt" ]; then
        warn "jenova/ source tree missing"
    elif ! command -v cmake >/dev/null 2>&1; then
        warn "cmake not found"
    else
        _need_rebuild=0
        if [ ! -x "$JVIM_BIN" ]; then
            _need_rebuild=1
        elif [ -n "$(find "$JVIM_SRC/src" "$JVIM_SRC/runtime" "$JVIM_SRC/cmake" \
                          "$JVIM_SRC/CMakeLists.txt" -newer "$JVIM_BIN" \
                          -print -quit 2>/dev/null)" ]; then
            _need_rebuild=1
        fi
        if [ "$_need_rebuild" = "1" ]; then
            info "jenova sources changed — rebuilding..."
            _JOBS="${JENOVA_CPU_THREADS:-4}"
            (
                cd "$JVIM_SRC" && \
                cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
                      -DCMAKE_INSTALL_PREFIX="$JVIM_SRC/install" >/dev/null && \
                cmake --build build -j"$_JOBS"
            ) && ok "jenova rebuilt" || warn "jenova rebuild failed"
        else
            ok "jenova up to date"
        fi
    fi
fi



# ---------------------------------------------------------------------------
# 3d. jenova-ui rebuild check
# ---------------------------------------------------------------------------
if [ "$UPDATE_UI" = "1" ] || [ ! -x "$JENOVA_ROOT/bin/jenova-ui" ]; then
    info "Updating jenova-ui..."
    if [ -d "$JENOVA_ROOT/jenova-ui" ]; then
        make jenova-ui && ok "jenova-ui updated" || warn "jenova-ui update failed"
    fi
fi

# ---------------------------------------------------------------------------
# 3e. web rebuild check
# ---------------------------------------------------------------------------
if [ "$UPDATE_WEB" = "1" ] || [ ! -f "$JENOVA_ROOT/public/bundle.js" ]; then
    info "Updating Web UI..."
    if [ -d "$JENOVA_ROOT/jca_web" ]; then
        if command -v npm >/dev/null 2>&1; then
            make web && ok "Web UI updated" || warn "Web UI update failed"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 4. Redeploy Neovim config
# ---------------------------------------------------------------------------
if [ "$SKIP_NVIM" = "0" ] && command -v jenova >/dev/null 2>&1; then
    info "Redeploying jenova configuration..."
    if [ ! -d "$JVIM_CONFIG_DST" ]; then
        warn "~/.config/jenova/ not found"
        SKIP_NVIM=1
    fi

    if [ "$SKIP_NVIM" = "0" ]; then
        if [ "$LINK" = "1" ]; then
            mkdir -p "$JVIM_CONFIG_DST/lua/plugins" "$JVIM_CONFIG_DST/lua/jenova"
            ln -sf "$JVIM_CONFIG_SRC/init.lua" "$JVIM_CONFIG_DST/init.lua"
            for _dir in plugins jenova; do
                for _f in "$JVIM_CONFIG_SRC/lua/$_dir/"*.lua; do
                    [ -f "$_f" ] && ln -sf "$_f" "$JVIM_CONFIG_DST/lua/$_dir/$(basename "$_f")"
                done
            done
            ln -sfn "$JVIM_CONFIG_SRC/lua/jenova/agent" "$JVIM_CONFIG_DST/lua/jenova/agent"
            ok "Symlinked jenova config"
        elif [ -L "$JVIM_CONFIG_DST/init.lua" ]; then
            ok "Symlink mode active"
        else
            mkdir -p "$JVIM_CONFIG_DST/lua/plugins" "$JVIM_CONFIG_DST/lua/jenova"
            cp "$JVIM_CONFIG_SRC/init.lua" "$JVIM_CONFIG_DST/init.lua"
            cp "$JVIM_CONFIG_SRC/lua/plugins/"*.lua "$JVIM_CONFIG_DST/lua/plugins/"
            for _f in "$JVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$JVIM_CONFIG_DST/lua/jenova/"
            done
            rm -rf "$JVIM_CONFIG_DST/lua/jenova/agent"
            cp -r "$JVIM_CONFIG_SRC/lua/jenova/agent" "$JVIM_CONFIG_DST/lua/jenova/"
            ok "Config redeployed"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Sync Neovim plugins
# ---------------------------------------------------------------------------
if [ "$SKIP_NVIM" = "0" ] && command -v jenova >/dev/null 2>&1 && [ -d "$JVIM_CONFIG_DST" ]; then
    info "Syncing Neovim plugins..."
    if [ "$UPGRADE_PLUGINS" = "1" ]; then
        jenova --headless "+Lazy update" +qa 2>/dev/null && ok "Plugins updated" || warn "Plugin update failed"
    else
        jenova --headless "+Lazy restore" +qa 2>/dev/null && ok "Plugins restored" || warn "Plugin restore failed"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Redeploy binaries to JCA_HOME/bin
# ---------------------------------------------------------------------------
info "Redeploying binaries to $JCA_HOME/bin..."
mkdir -p "$JCA_HOME/bin"
for _bin in jenova jenova jenova-ui jenova-ca jenova-tui jenova-term jenova-swap-mount; do
    if [ -f "$JENOVA_ROOT/bin/$_bin" ]; then
        cp "$JENOVA_ROOT/bin/$_bin" "$JCA_HOME/bin/$_bin"
        chmod +x "$JCA_HOME/bin/$_bin"
    fi
done

ok "Binaries redeployed"

echo ""
ok "Update complete."
echo ""
