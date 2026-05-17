#!/bin/sh
# update.sh: Jenova Cognitive Architecture — Update Script
#
# Single-repo update: pulls the latest jenova source, rebuilds llama.cpp and
# the in-tree jvim editor when their sources have moved, restarts a running
# jenova-ca, and resyncs the Neovim plugin set.
#
# Usage: ./update.sh [--upgrade-plugins] [--skip-nvim] [--skip-rebuild]
#                    [--skip-jvim] [--link] [--apply-profile]
#                    [--mcsh] [--ui] [--web] [--all] [--no-pull]
#
#   --upgrade-plugins   Run :Lazy update (move to latest plugin versions).
#                       Without this flag, runs :Lazy restore (pin to lock file).
#   --skip-nvim         Skip Neovim config redeployment.
#   --skip-rebuild      Skip llama.cpp rebuild check.
#   --skip-jvim         Skip the in-tree jvim rebuild check.
#   --link              Re-establish symlinks from ~/.config/jvim into the repo
#                       if a previous --link install was clobbered by a copy.
#   --apply-profile     Re-apply the detected hardware profile (overwrites
#                       etc/jenova.conf). Skipped by default to preserve any
#                       manual edits or pinned profile configs.
#   --mcsh              Force rebuild of mcsh.
#   --ui                Force rebuild of jenova-ui (Desktop Manager).
#   --web               Force rebuild of Web UI.
#   --all               Update and rebuild all components.
#   --no-pull           Skip git pull operations.
#
# Steps:
#   1. git pull (update repo from origin) - skipped with --no-pull
#   2. Restart or reload jenova-ca if currently running
#   3. Rebuild llama.cpp if its checkout moved or binary is missing
#   4. Rebuild bundled jvim if its sources changed or binary is missing
#   5. Redeploy Jenova nvim config to ~/.config/jvim/
#   6. Sync nvim plugins (headless :Lazy restore or update)
#   7. Print changelog summary (last 10 commits)

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
JENOVA_HOME="${JENOVA_HOME:-$HOME/Jenova}"
JVIM_CONFIG_SRC="$JENOVA_ROOT/jvim-config"
JVIM_CONFIG_DST="$HOME/.config/jvim"

# Shared OS/hardware detection
. "$JENOVA_ROOT/lib/detect-env.sh"

UPGRADE_PLUGINS=0
SKIP_NVIM=0
SKIP_REBUILD=0
SKIP_JVIM=0
LINK=0
APPLY_PROFILE=0
NO_PULL=0

for _arg in "$@"; do
    case "$_arg" in
        --upgrade-plugins) UPGRADE_PLUGINS=1 ;;
        --skip-nvim)       SKIP_NVIM=1 ;;
        --skip-rebuild)    SKIP_REBUILD=1 ;;
        --skip-jvim)       SKIP_JVIM=1 ;;
        --link)            LINK=1 ;;
        --apply-profile)   APPLY_PROFILE=1 ;;
        --mcsh)            UPDATE_MCSH=1 ;;
        --ui)              UPDATE_UI=1 ;;
        --web)             UPDATE_WEB=1 ;;
        --all)             UPDATE_MCSH=1; UPDATE_UI=1; UPDATE_WEB=1; APPLY_PROFILE=1 ;;
        --no-pull)         NO_PULL=1 ;;
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

# Initialize missing variables if not set by flags
UPDATE_MCSH="${UPDATE_MCSH:-0}"
UPDATE_UI="${UPDATE_UI:-0}"
UPDATE_WEB="${UPDATE_WEB:-0}"

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
printf "${_B}╔══════════════════════════════════════════════════════╗${_N}\n"
printf "${_B}║  Jenova Cognitive Architecture — Update              ║${_N}\n"
printf "${_B}╚══════════════════════════════════════════════════════╝${_N}\n"
echo ""

# ---------------------------------------------------------------------------
# 1. Git pull
# ---------------------------------------------------------------------------
if [ "$NO_PULL" = "0" ]; then
    info "Pulling latest changes from origin..."
    cd "$JENOVA_ROOT"
    _branch=$(git branch --show-current 2>/dev/null || echo "main")
    git pull origin "${_branch:-main}" && ok "git pull complete" || {
        warn "git pull failed — continuing with current code"
    }

    # Re-apply hardware profile only when explicitly requested via --apply-profile.
    # By default we skip this to avoid overwriting user-customised etc/jenova.conf.
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
    . "$JENOVA_ROOT/etc/jenova.conf" 2>/dev/null || true
    if [ -f "${PID_FILE:-$JENOVA_ROOT/.jenova/jenova-ca.pid}" ]; then
        read _LP _PP _EP < "${PID_FILE:-$JENOVA_ROOT/.jenova/jenova-ca.pid}" 2>/dev/null || true
        _ANY_ALIVE=false
        for _P in $_LP $_PP $_EP; do
            [ -n "$_P" ] && kill -0 "$_P" 2>/dev/null && _ANY_ALIVE=true && break
        done
        if $_ANY_ALIVE; then
            warn "Jenova CA is currently running. Restarting to pick up any config changes..."
            "$JENOVA_CA" restart 2>/dev/null && ok "Jenova CA restarted" || warn "Restart failed — restart manually with: bin/jenova-ca restart"
        else
            ok "Jenova CA not running (will start fresh next time)"
        fi
    else
        ok "Jenova CA not running (will start fresh next time)"
    fi
else
    warn "jenova-ca not found at $JENOVA_CA"
fi

# ---------------------------------------------------------------------------
# 3. llama.cpp rebuild check
# ---------------------------------------------------------------------------
if [ "$SKIP_REBUILD" = "0" ]; then
    info "Checking llama.cpp for updates..."
    LLAMA_BIN="$JENOVA_ROOT/external/llama.cpp/build/bin/llama-server"
    LLAMA_SRC="$JENOVA_ROOT/llama.cpp"

    _need_rebuild=0
    if [ ! -x "$LLAMA_BIN" ]; then
        warn "llama-server binary missing — forcing rebuild"
        _need_rebuild=1
    fi

    if [ "$NO_PULL" = "0" ] && [ -d "$LLAMA_SRC/.git" ]; then
        cd "$LLAMA_SRC"
        _BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        git pull origin "$(git branch --show-current 2>/dev/null || echo main)" 2>/dev/null || true
        _AFTER=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        cd "$JENOVA_ROOT"

        if [ "$_BEFORE" != "$_AFTER" ]; then
            warn "llama.cpp source updated ($(echo "$_BEFORE" | cut -c1-8) → $(echo "$_AFTER" | cut -c1-8))"
            _need_rebuild=1
        fi
    fi

    if [ "$_need_rebuild" = "1" ]; then
        if [ -d "$LLAMA_SRC/build" ]; then
            info "Rebuilding llama.cpp in existing build directory..."
            cmake --build "$LLAMA_SRC/build" --config Release -j"${JENOVA_CPU_THREADS:-4}" \
                && ok "llama.cpp rebuilt successfully" \
                || warn "llama.cpp rebuild failed — check $LLAMA_SRC/build for errors"
        else
            info "No build directory found — running full build script..."
            "$JENOVA_ROOT/bin/build-llama-jenova" && ok "llama.cpp built successfully" || warn "llama.cpp build failed"
        fi
    else
        ok "llama.cpp up to date"
    fi
fi

# ---------------------------------------------------------------------------
# 3b. jvim rebuild check
# ---------------------------------------------------------------------------
if [ "$SKIP_JVIM" = "0" ]; then
    info "Checking bundled jvim editor..."
    JVIM_SRC="$JENOVA_ROOT/jvim"
    JVIM_BIN="$JVIM_SRC/build/bin/nvim"
    if [ ! -f "$JVIM_SRC/CMakeLists.txt" ]; then
        warn "jvim/ source tree missing — skipping jvim rebuild"
    elif ! command -v cmake >/dev/null 2>&1; then
        warn "cmake not found — cannot rebuild jvim"
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
            info "jvim sources changed (or no build present) — rebuilding..."
            _JOBS="${JENOVA_CPU_THREADS:-4}"
            (
                cd "$JVIM_SRC" && \
                cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
                      -DCMAKE_INSTALL_PREFIX="$JVIM_SRC/install" >/dev/null && \
                cmake --build build -j"$_JOBS"
            ) && ok "jvim rebuilt: $JVIM_BIN" \
              || warn "jvim rebuild failed — re-run: make jvim"
        else
            ok "jvim up to date"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 3c. mcsh rebuild check
# ---------------------------------------------------------------------------
if [ "$UPDATE_MCSH" = "1" ] || [ ! -x "$JENOVA_ROOT/bin/mcsh" ]; then
    info "Checking mcsh for updates..."
    MCSH_SRC="$JENOVA_ROOT/mcsh"
    if [ -d "$MCSH_SRC/.git" ]; then
        cd "$MCSH_SRC"
        _BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        git pull origin "$(git branch --show-current 2>/dev/null || echo main)" 2>/dev/null || true
        _AFTER=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        cd "$JENOVA_ROOT"
        if [ "$_BEFORE" != "$_AFTER" ] || [ ! -x "$JENOVA_ROOT/bin/mcsh" ]; then
            warn "mcsh updated — rebuilding..."
            if make mcsh; then
                ok "mcsh rebuilt successfully"
            else
                warn "mcsh rebuild failed"
            fi
        else
            ok "mcsh up to date"
        fi
    elif [ -f "$MCSH_SRC/configure" ]; then
        info "mcsh source present but not a git repo — rebuilding if missing binary"
        if [ ! -x "$JENOVA_ROOT/bin/mcsh" ]; then
             make mcsh && ok "mcsh built" || warn "mcsh build failed"
        else
             ok "mcsh up to date"
        fi
    else
        warn "mcsh source missing — skipping"
    fi
fi

# ---------------------------------------------------------------------------
# 3d. jenova-ui rebuild check
# ---------------------------------------------------------------------------
if [ "$UPDATE_UI" = "1" ] || [ ! -x "$JENOVA_ROOT/bin/jenova-ui" ]; then
    info "Updating jenova-ui..."
    if [ -d "$JENOVA_ROOT/jenova-ui" ]; then
        if make jenova-ui; then
            ok "jenova-ui updated"
        else
            warn "jenova-ui update failed"
        fi
    else
        warn "jenova-ui source missing — skipping"
    fi
fi

# ---------------------------------------------------------------------------
# 3e. web rebuild check
# ---------------------------------------------------------------------------
if [ "$UPDATE_WEB" = "1" ] || [ ! -f "$JENOVA_ROOT/public/bundle.js" ]; then
    info "Updating Web UI..."
    if [ -d "$JENOVA_ROOT/jca_web" ]; then
        if command -v npm >/dev/null 2>&1; then
            if make web; then
                ok "Web UI updated"
            else
                warn "Web UI update failed"
            fi
        else
            warn "npm not found — cannot update Web UI"
        fi
    else
        warn "jca_web source missing — skipping"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Redeploy Neovim config
# ---------------------------------------------------------------------------
if [ "$SKIP_NVIM" = "0" ] && command -v jvim >/dev/null 2>&1; then
    info "Redeploying Jenova nvim configuration..."

    # Friendly warning if the active editor is upstream Neovim instead of jvim
    _NVIM_VLINE=$(nvim --version 2>/dev/null | head -n 1)
    case "$_NVIM_VLINE" in
        *JVIM*) ok "Editor: $_NVIM_VLINE" ;;
        *)
            warn "Editor is upstream Neovim ($_NVIM_VLINE), not jvim."
            warn "Build the in-tree jvim with: make jvim"
            ;;
    esac

    if [ ! -d "$JVIM_CONFIG_DST" ]; then
        warn "~/.config/jvim/ not found — run install.sh first to do the initial setup"
        SKIP_NVIM=1
    fi

    if [ "$SKIP_NVIM" = "0" ]; then
        # Detect whether we're in symlink mode (init.lua is a symlink into the repo)
        if [ "$LINK" = "1" ]; then
            info "--link given: (re)establishing symlinks into $JVIM_CONFIG_SRC"
            mkdir -p "$JVIM_CONFIG_DST/lua/plugins" "$JVIM_CONFIG_DST/lua/jenova"
            ln -sf "$JVIM_CONFIG_SRC/init.lua"       "$JVIM_CONFIG_DST/init.lua"
            for _dir in plugins jenova; do
                for _f in "$JVIM_CONFIG_SRC/lua/$_dir/"*.lua; do
                    [ -f "$_f" ] && ln -sf "$_f" "$JVIM_CONFIG_DST/lua/$_dir/$(basename "$_f")"
                done
            done
            ln -sfn "$JVIM_CONFIG_SRC/lua/jenova/agent" \
                "$JVIM_CONFIG_DST/lua/jenova/agent"
            ok "Symlinked Jenova jvim config — edits in $JVIM_CONFIG_SRC are live"
        elif [ -L "$JVIM_CONFIG_DST/init.lua" ]; then
            _LINK_TGT=$(realpath "$JVIM_CONFIG_DST/init.lua" 2>/dev/null || readlink -f "$JVIM_CONFIG_DST/init.lua" 2>/dev/null || readlink "$JVIM_CONFIG_DST/init.lua")
            _NVIM_SRC_REAL=$(realpath "$JVIM_CONFIG_SRC" 2>/dev/null || readlink -f "$JVIM_CONFIG_SRC" 2>/dev/null || echo "$JVIM_CONFIG_SRC")
            case "$_LINK_TGT" in
                "$_NVIM_SRC_REAL"/*|"$_NVIM_SRC_REAL")
                    ok "Symlink mode active — files auto-updated via git pull"
                    ;;
                *)
                    warn "init.lua symlink points outside this repo: $_LINK_TGT"
                    warn "Run: ./update.sh --link  to re-anchor it to $JVIM_CONFIG_SRC"
                    ;;
            esac
        else
            mkdir -p "$JVIM_CONFIG_DST/lua/plugins"
            mkdir -p "$JVIM_CONFIG_DST/lua/jenova"
            cp "$JVIM_CONFIG_SRC/init.lua"       "$JVIM_CONFIG_DST/init.lua"
            cp "$JVIM_CONFIG_SRC/lua/plugins/"*.lua "$JVIM_CONFIG_DST/lua/plugins/"
            for _f in "$JVIM_CONFIG_SRC/lua/jenova/"*.lua; do
                [ -f "$_f" ] && cp "$_f" "$JVIM_CONFIG_DST/lua/jenova/"
            done
            rm -rf "$JVIM_CONFIG_DST/lua/jenova/agent"
            cp -r "$JVIM_CONFIG_SRC/lua/jenova/agent" \
                "$JVIM_CONFIG_DST/lua/jenova/"
            ok "Jenova jvim config redeployed to $JVIM_CONFIG_DST"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Sync Neovim plugins
# ---------------------------------------------------------------------------
if [ "$SKIP_NVIM" = "0" ] && command -v jvim >/dev/null 2>&1 && [ -d "$JVIM_CONFIG_DST" ]; then
    info "Syncing Neovim plugins..."
    if [ "$UPGRADE_PLUGINS" = "1" ]; then
        warn "Running :Lazy update (moving plugins to latest versions — ignores lock file)"
        nvim --headless "+Lazy update" +qa 2>/dev/null \
            && ok "Plugins updated to latest" \
            || warn "Plugin update failed — run :Lazy update inside Neovim manually"
    else
        info "Running :Lazy restore (pinning plugins to lazy-lock.json versions)"
        nvim --headless "+Lazy restore" +qa 2>/dev/null \
            && ok "Plugins restored to pinned versions" \
            || warn "Plugin restore failed — run :Lazy restore inside Neovim manually"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Redeploy binaries to JENOVA_HOME/bin
# ---------------------------------------------------------------------------
info "Redeploying updated binaries to $JENOVA_HOME/bin..."
mkdir -p "$JENOVA_HOME/bin"
for _bin in jvim jenova jenova-ui jenova-ca jenova-tui jenova-term jenova-swap-mount; do
    if [ -f "$JENOVA_ROOT/bin/$_bin" ]; then
        cp "$JENOVA_ROOT/bin/$_bin" "$JENOVA_HOME/bin/$_bin"
        chmod +x "$JENOVA_HOME/bin/$_bin"
    fi
done
if [ -f "$JENOVA_ROOT/bin/mcsh" ]; then
    cp "$JENOVA_ROOT/bin/mcsh" "$JENOVA_HOME/bin/mcsh"
    chmod +x "$JENOVA_HOME/bin/mcsh"
fi
ok "Binaries redeployed to $JENOVA_HOME/bin"

# ---------------------------------------------------------------------------
# 6. Refresh Desktop Entries & Icons (Linux/FreeBSD)
# ---------------------------------------------------------------------------
if [ "$JENOVA_OS" = "linux" ] || [ "$JENOVA_OS" = "freebsd" ]; then
    info "Refreshing desktop entries and icons..."
    _APP_DIR="$HOME/.local/share/applications"
    _ICON_DIR="$HOME/.local/share/icons"
    mkdir -p "$_APP_DIR" "$_ICON_DIR"

    [ -f "$JENOVA_ROOT/bin/jenova.desktop" ] && cp "$JENOVA_ROOT/bin/jenova.desktop" "$_APP_DIR/jenova.desktop"
    [ -f "$JENOVA_ROOT/bin/jenova-manager.desktop" ] && cp "$JENOVA_ROOT/bin/jenova-manager.desktop" "$_APP_DIR/jenova-manager.desktop"
    [ -f "$JENOVA_ROOT/bin/jvim.desktop" ] && cp "$JENOVA_ROOT/bin/jvim.desktop" "$_APP_DIR/jvim.desktop"

    if [ -d "$JENOVA_ROOT/png" ]; then
        [ -f "$JENOVA_ROOT/png/jenova.jpg" ] && cp "$JENOVA_ROOT/png/jenova.jpg" "$_ICON_DIR/jenova.jpg"
        [ -f "$JENOVA_ROOT/png/jca.jpg" ] && cp "$JENOVA_ROOT/png/jca.jpg" "$_ICON_DIR/jca.jpg"
        [ -f "$JENOVA_ROOT/png/jvim.jpg" ] && cp "$JENOVA_ROOT/png/jvim.jpg" "$_ICON_DIR/jvim.jpg"
        ln -sf "$_ICON_DIR/jenova.jpg" "$_ICON_DIR/jenova" 2>/dev/null || true
        ln -sf "$_ICON_DIR/jca.jpg" "$_ICON_DIR/jca" 2>/dev/null || true
        ln -sf "$_ICON_DIR/jvim.jpg" "$_ICON_DIR/jvim" 2>/dev/null || true
    fi
    ok "Desktop integration refreshed"
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
ok "Update complete."
echo ""
info "To launch Jenova:"
echo "    jenova                — CLI agent (auto-starts backend)"
echo "    jvim [file]           — jvim editor (auto-starts backend)"
echo "    jvim --remote H       — connect to a remote Jenova CA on host H"
echo "    jvim --check          — print resolved env without launching editor"
echo "    jenova-ca status      — check backend daemon status"
echo ""
