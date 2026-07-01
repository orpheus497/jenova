#!/bin/bash
export JENOVA_ROOT="${JENOVA_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
export PID_FILE="/tmp/test_jenova.pid"
export LLAMA_PORT=8080
export JENOVA_CONNECT_HOST="127.0.0.1"

# Case 1: Stopped
echo "Stopped state:"
rm -f "$PID_FILE"
time $JENOVA_ROOT/bin/jenova-ca status

# Case 2: Healthy (mock a quick response)
echo -e "\nHealthy state:"
echo "$$" > "$PID_FILE"
# Let's start a quick nc server to respond instantly, but nc doesn't respond HTTP.
# We'll just let curl fail instantly (connection refused) which is fast.
time $JENOVA_ROOT/bin/jenova-ca status

# Case 3: Hung (listen but don't respond, forcing curl to timeout)
echo -e "\nHung state:"
nc -l 8080 &
NC_PID=$!
time $JENOVA_ROOT/bin/jenova-ca status
if kill -0 $NC_PID 2>/dev/null; then kill $NC_PID; fi
