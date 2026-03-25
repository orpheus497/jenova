#!/bin/sh
SCRIPT_DIR=$(dirname "$(realpath "$0")")
if [ -f "$SCRIPT_DIR/etc/jenova.conf" ]; then
    . "$SCRIPT_DIR/etc/jenova.conf"
fi

"$SCRIPT_DIR/bin/jenova-ca" > test_bin_jenova.log 2>&1 &
PID1=$!
sleep 10
echo "Checking bin/jenova-ca background boot:"

check_port() {
    luajit "$SCRIPT_DIR/lib/healthcheck.lua" 127.0.0.1 "$1" 3 2>/dev/null
}

check_port 8080 && echo "HTTP 8080 Proxy OK" || echo "HTTP 8080 Proxy Down"
check_port 8081 && echo "HTTP 8081 LLAMA OK" || echo "HTTP 8081 LLAMA Down"
check_port 8082 && echo "HTTP 8082 Embed OK" || echo "HTTP 8082 Embed Down"

# Kill via jenova-ca stop to ensure all child processes are cleaned up
"$SCRIPT_DIR/bin/jenova-ca" stop 2>/dev/null
kill "$PID1" 2>/dev/null
wait "$PID1" 2>/dev/null

echo ""
echo "Log output:"
cat test_bin_jenova.log
rm -f test_bin_jenova.log
