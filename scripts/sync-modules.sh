#!/bin/sh
# scripts/sync-modules.sh
# Copies shared Lua modules from cli-agent/lua/ into jvim/runtime/lua/jenova/agent/shared/
# Called by `make sync-modules` and `make jvim`.
# Safe to run multiple times (idempotent).

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

SRC="$ROOT/cli-agent/lua"
DST="$ROOT/jvim/runtime/lua/jenova/agent/shared"

MODULES="
engine/query_engine.lua
tools/registry.lua
providers/base.lua
providers/init.lua
providers/jenova_backend.lua
providers/llamacpp.lua
config/loader.lua
history/manager.lua
context/manager.lua
context/file_tracker.lua
permissions/manager.lua
services/tool_verifier.lua
utils/array.lua
utils/http.lua
utils/json_fallback.lua
utils/paths.lua
utils/string.lua
utils/trio.lua
constants/prompts.lua
state/app_state.lua
"

count=0
missing=0
for mod in $MODULES; do
    [ -z "$mod" ] && continue
    src_file="$SRC/$mod"
    dst_file="$DST/$mod"
    dst_dir=$(dirname "$dst_file")
    if [ ! -f "$src_file" ]; then
        echo "  SKIP (not found): $mod" >&2
        missing=$((missing + 1))
        continue
    fi
    mkdir -p "$dst_dir"
    cp "$src_file" "$dst_file"
    count=$((count + 1))
done

echo "   Synced $count modules → jvim/runtime/lua/jenova/agent/shared/"
if [ "$missing" -gt 0 ]; then
    echo "   WARNING: $missing module(s) not found in cli-agent/lua/ (skipped)" >&2
fi
