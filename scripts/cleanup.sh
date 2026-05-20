#!/bin/sh
# cleanup.sh: Jenova Cognitive Architecture — Runtime Cleanup
#
# Usage: ./cleanup.sh [--logs] [--cache] [--state] [--all] [--yes]
#
#   --logs    Remove log files from var/log/ (or rotate with --rotate)
#   --cache   Clear the var/cache/ directory
#   --state   Remove stale PID and lock files from .jenova/
#   --all     All of the above
#   --rotate  When used with --logs, rotate instead of delete (keeps .1 backup)
#   --yes     Skip confirmation prompts
#
# This script only cleans runtime artifacts. It does NOT:
#   - Remove installed files (use uninstall.sh for that)
#   - Remove models or configuration
#   - Stop running daemons (warns if they are active)

set -e

_REAL_SCRIPT="$(realpath "$0" 2>/dev/null || echo "$0")"
_SCRIPT_DIR="$(cd "$(dirname "$_REAL_SCRIPT")" && pwd)"
JENOVA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
JENOVA_DIR="${JENOVA_STATE:-$JENOVA_ROOT/.jenova}"
LOG_DIR="$JENOVA_ROOT/var/log"
CACHE_DIR="$JENOVA_ROOT/var/cache"
PID_FILE="$JENOVA_DIR/jenova-ca.pid"

DO_LOGS=0
DO_CACHE=0
DO_STATE=0
ROTATE=0
YES=0

if [ $# -eq 0 ]; then
    sed -n '2,17p' "$0"
    exit 0
fi

for _arg in "$@"; do
    case "$_arg" in
        --logs)    DO_LOGS=1 ;;
        --cache)   DO_CACHE=1 ;;
        --state)   DO_STATE=1 ;;
        --all)     DO_LOGS=1; DO_CACHE=1; DO_STATE=1 ;;
        --rotate)  ROTATE=1 ;;
        --yes)     YES=1 ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $_arg" >&2
            exit 1
            ;;
    esac
done

# Colours
if [ -t 1 ]; then
    _G=$(printf '\033[0;32m'); _Y=$(printf '\033[0;33m'); _B=$(printf '\033[1;34m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _B=""; _N=""
fi

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y} WARN${_N}  %s\n" "$1"; }
info() { printf "${_B} INFO${_N}  %s\n" "$1"; }

# Check if daemons are running
_DAEMONS_ACTIVE=false
if [ -f "$PID_FILE" ]; then
    read -r _LP _PP _EP < "$PID_FILE" 2>/dev/null || true
    for _P in $_LP $_PP $_EP; do
        if [ -n "$_P" ] && kill -0 "$_P" 2>/dev/null; then
            _DAEMONS_ACTIVE=true
            break
        fi
    done
fi

if $_DAEMONS_ACTIVE; then
    warn "Jenova CA daemons are currently running!"
    if [ "$DO_STATE" = "1" ]; then
        warn "Cannot clean state files while daemons are active."
        warn "Run 'bin/jenova-ca stop' first, or skip --state."
        DO_STATE=0
    fi
fi

# Confirmation
if [ "$YES" = "0" ]; then
    echo ""
    info "Will clean:"
    [ "$DO_LOGS" = "1" ] && echo "    $LOG_DIR/*.log"
    [ "$DO_CACHE" = "1" ] && echo "    $CACHE_DIR/"
    [ "$DO_STATE" = "1" ] && echo "    $JENOVA_DIR/*.pid, *.pid.lock"
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
# Clean logs
# ---------------------------------------------------------------------------
if [ "$DO_LOGS" = "1" ]; then
    if [ -d "$LOG_DIR" ]; then
        _count=0
        for _f in "$LOG_DIR"/*.log; do
            [ -f "$_f" ] || continue
            if [ "$ROTATE" = "1" ]; then
                mv "$_f" "${_f}.1"
                ok "Rotated $(basename "$_f") -> $(basename "$_f").1"
            else
                rm -f "$_f"
                ok "Removed $(basename "$_f")"
            fi
            _count=$((_count + 1))
        done
        # Also clean old rotated logs when not rotating
        if [ "$ROTATE" = "0" ]; then
            for _f in "$LOG_DIR"/*.log.1; do
                [ -f "$_f" ] || continue
                rm -f "$_f"
                _count=$((_count + 1))
            done
        fi
        if [ "$_count" = "0" ]; then
            ok "No log files to clean"
        else
            ok "Cleaned $_count log file(s)"
        fi
    else
        ok "No log directory found (already clean)"
    fi
fi

# ---------------------------------------------------------------------------
# Clean cache
# ---------------------------------------------------------------------------
if [ "$DO_CACHE" = "1" ]; then
    if [ -d "$CACHE_DIR" ]; then
        rm -rf "$CACHE_DIR"
        mkdir -p "$CACHE_DIR"
        ok "Cleared cache directory"
    else
        ok "No cache directory found (already clean)"
    fi
fi

# ---------------------------------------------------------------------------
# Clean state (PID/lock files)
# ---------------------------------------------------------------------------
if [ "$DO_STATE" = "1" ]; then
    if [ -d "$JENOVA_DIR" ]; then
        _count=0
        for _f in "$JENOVA_DIR"/*.pid "$JENOVA_DIR"/*.pid.lock "$JENOVA_DIR"/*.lock; do
            [ -f "$_f" ] || continue
            rm -f "$_f"
            ok "Removed $(basename "$_f")"
            _count=$((_count + 1))
        done
        if [ "$_count" = "0" ]; then
            ok "No stale state files found"
        else
            ok "Cleaned $_count state file(s)"
        fi
    else
        ok "No state directory found (already clean)"
    fi
fi

echo ""
ok "Cleanup complete."
