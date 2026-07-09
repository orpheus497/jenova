#!/bin/bash
export JENOVA_ROOT="${JENOVA_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
export PID_FILE="/tmp/test_jenova.pid"
export LLAMA_PORT=8080
export JENOVA_CONNECT_HOST="127.0.0.1"

# Case 1: Stopped
echo "Stopped state:"
rm -f "$PID_FILE"
time "$JENOVA_ROOT"/bin/jenova-ca status

# Case 2: Healthy (mock a quick response)
echo -e "\nHealthy state:"
echo "$$" > "$PID_FILE"
( echo -e "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" | { nc -l 8080 2>/dev/null || nc -l -p 8080 2>/dev/null; } ) &
NC_PID=$!
sleep 0.5
time "$JENOVA_ROOT"/bin/jenova-ca status
if kill -0 $NC_PID 2>/dev/null; then kill $NC_PID 2>/dev/null; pkill -P $NC_PID 2>/dev/null; fi

# Case 3: Hung (listen but don't respond, forcing curl to timeout)
echo -e "\nHung state:"
{ nc -l 8080 2>/dev/null || nc -l -p 8080 2>/dev/null; } &
NC_PID=$!
sleep 0.5
time "$JENOVA_ROOT"/bin/jenova-ca status
if kill -0 $NC_PID 2>/dev/null; then kill $NC_PID 2>/dev/null; pkill -P $NC_PID 2>/dev/null; fi
