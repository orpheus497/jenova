#!/bin/sh
# model_dl.sh: Interactive, hardware-profile-aware model downloader for Jenova.
#
# Usage: ./scripts/model_dl.sh [profile_name]
#
# If profile_name is omitted, it will attempt auto-detection.

set -e

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
export JENOVA_ROOT

# Shared OS/hardware detection and profile loader.
. "$JENOVA_ROOT/lib/detect-env.sh"

# Colours
if [ -t 1 ]; then
    _G=$(printf '\033[0;32m'); _Y=$(printf '\033[0;33m'); _R=$(printf '\033[0;31m'); _B=$(printf '\033[1;34m'); _N=$(printf '\033[0m')
else
    _G=""; _Y=""; _R=""; _B=""; _N=""
fi

ok()   { printf "${_G}  OK${_N}  %s\n" "$1"; }
warn() { printf "${_Y} WARN${_N}  %s\n" "$1"; }
fail() { printf "${_R} FAIL${_N}  %s\n" "$1"; }
info() { printf "${_B} INFO${_N}  %s\n" "$1"; }

# 1. Determine Profile
PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
    DETECT_SCRIPT="$JENOVA_ROOT/hardware-profiles/detect-hardware.sh"
    if [ -x "$DETECT_SCRIPT" ]; then
        PROFILE=$("$DETECT_SCRIPT" 2>/dev/null) || PROFILE="generic"
    else
        PROFILE="generic"
    fi
fi

info "Hardware Profile: $PROFILE"

# 2. Define Model Defaults (Generic/Fallback)
AGENT_FILE="Qwen2.5-3B-Instruct-Q8_0.gguf"
AGENT_URL="https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q8_0.gguf"
AGENT_SIZE="3.2GB"

EMBED_FILE="Qwen3.5-0.8B-Instruct-Q8_0.gguf"
EMBED_URL="https://huggingface.co/Qwen/Qwen3.5-0.8B-Instruct-GGUF/resolve/main/qwen3.5-0.8b-instruct-q8_0.gguf"
EMBED_SIZE="850MB"

DRAFT_FILE="Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf"
DRAFT_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q8_0.gguf"
DRAFT_SIZE="530MB"

# 3. Source Profile Recommendations
if [ -n "$PROFILE" ]; then
    _P_CONF="$JENOVA_ROOT/hardware-profiles/$PROFILE/profile.conf"
    if [ -f "$_P_CONF" ]; then
        # Robustly load profile variables by sourcing after path validation
        if load_jenova_profile "$_P_CONF"; then
            [ -n "${RECOMMENDED_AGENT_MODEL:-}" ] && AGENT_FILE="$RECOMMENDED_AGENT_MODEL"
            [ -n "${RECOMMENDED_AGENT_URL:-}" ] && AGENT_URL="$RECOMMENDED_AGENT_URL"
            [ -n "${RECOMMENDED_EMBED_MODEL:-}" ] && EMBED_FILE="$RECOMMENDED_EMBED_MODEL"
            [ -n "${RECOMMENDED_EMBED_URL:-}" ] && EMBED_URL="$RECOMMENDED_EMBED_URL"
        fi

        # Adjust sizes based on known patterns
        case "$AGENT_FILE" in
            *9B*Q8*) AGENT_SIZE="9.5GB" ;;
            *9B*Q4*) AGENT_SIZE="5.5GB" ;;
            *4B*) AGENT_SIZE="4.4GB" ;;
            *3B*) AGENT_SIZE="3.1GB" ;;
            *0.8B*) AGENT_SIZE="800MB" ;;
        esac
    fi
fi

# 4. Download Tool Detection
_DL_CMD=""
if command -v curl >/dev/null 2>&1; then
    _DL_CMD="curl"
elif command -v fetch >/dev/null 2>&1; then
    _DL_CMD="fetch"
fi

download_model() {
    _path="$1"; _name="$2"; _url="$3"; _size="$4"; _required="${5:-0}"
    if [ -f "$_path" ]; then
        ok "$_name model already exists ($(basename "$_path"))"
        return 0
    fi
    if [ -z "$_DL_CMD" ]; then
        warn "$_name not found. Install curl or fetch to auto-download."
        return 1
    fi
    
    printf "${_B}  ?${_N} Download %s (~%s)? [y/N] " "$(basename "$_path")" "$_size"
    read -r _ans
    case "$_ans" in
        y|Y|yes|YES)
            mkdir -p "$(dirname "$_path")"
            info "Downloading $(basename "$_path") ..."
            _tmp=$(mktemp "${_path}.tmp.XXXXXX")
            _dl_timeout="${JENOVA_DL_TIMEOUT:-14400}"
            if [ "$_DL_CMD" = "curl" ]; then
                curl -L --fail --max-time "$_dl_timeout" --connect-timeout 30 --progress-bar -o "$_tmp" "$_url"
            else
                fetch -T "$_dl_timeout" -o "$_tmp" "$_url"
            fi
            if [ -s "$_tmp" ]; then
                mv "$_tmp" "$_path"
                ok "$_name downloaded successfully"
            else
                rm -f "$_tmp"
                fail "Download failed for $_name"
                return 1
            fi
            ;;
        *)
            warn "Skipping $_name download"
            [ "$_required" = "1" ] && return 1 || return 0
            ;;
    esac
}

echo ""
info "Checking for model files in $JENOVA_ROOT/models/ ..."

# 1. Agent (Main Inference)
download_model "$JENOVA_ROOT/models/agent/$AGENT_FILE" "Agent" "$AGENT_URL" "$AGENT_SIZE" 1 || {
    warn "Agent model not found/downloaded. Jenova will require a model to be fully functional."
}

# 2. Semantic (Embedding/RAG)
download_model "$JENOVA_ROOT/models/embed/$EMBED_FILE" "Semantic" "$EMBED_URL" "$EMBED_SIZE" 0 || true

# 3. Embedding (Drafting/Speculative)
download_model "$JENOVA_ROOT/models/draft/$DRAFT_FILE" "Embedding" "$DRAFT_URL" "$DRAFT_SIZE" 0 || true

# Symlink models/jenova.gguf -> agent model for health checks
if [ -f "$JENOVA_ROOT/models/agent/$AGENT_FILE" ]; then
    ln -sf "agent/$AGENT_FILE" "$JENOVA_ROOT/models/jenova.gguf"
fi

echo ""
ok "Model check complete."
