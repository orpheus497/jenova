#!/bin/sh

# coder: Launch the agentic coding assistant
# Starts llama-server if not running, then connects the LuaJIT agent
#
# Usage:
#   ./bin/coder              # auto-start server + agent
#   CODER_PORT=8081 ./bin/coder  # use different port

SCRIPT_DIR=$(dirname "$(realpath "$0")")
. "$SCRIPT_DIR/../etc/coder.conf"

mkdir -p "$LOG_DIR"

SERVER_LOG="$LOG_DIR/server.log"

# Health check — uses luajit with the FFI HTTP module (zero dependencies)
check_health() {
    luajit -e "
        package.path=[[$SCRIPT_DIR/../lib/?.lua;]]..package.path
        local http=require('http')
        local c=http.get('http://${HOST}:${PORT}/health',3)
        os.exit(c==200 and 0 or 1)
    " 2>/dev/null
}

if check_health; then
    echo "Server already running at $API_URL"
else
    echo "Starting llama-server in background..."
    echo "Server log: $SERVER_LOG"
    "$SCRIPT_DIR/coder-server" > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    printf "Waiting for server"
    for i in $(seq 1 120); do
        if check_health; then
            echo " ready!"
            break
        fi
        printf "."
        sleep 1
        if [ $i -eq 120 ]; then
            echo " timeout!"
            echo "Check server log: $SERVER_LOG"
            kill "$SERVER_PID" 2>/dev/null
            exit 1
        fi
    done
fi

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "Stopping server (PID $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

export CODER_API_URL="$API_URL"
export CODER_ROOT
exec luajit "$SCRIPT_DIR/../lib/agent.lua"
