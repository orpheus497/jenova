#!/bin/sh
SCRIPT_DIR=$(dirname "$(dirname "$(realpath "$0")")")
if [ -f "$SCRIPT_DIR/etc/jenova.conf" ]; then
    . "$SCRIPT_DIR/etc/jenova.conf"
fi

# Preflight: verify jenova-ca exists and is executable
if [ ! -x "$SCRIPT_DIR/bin/jenova-ca" ]; then
    echo "Error: $SCRIPT_DIR/bin/jenova-ca not found or not executable" >&2
    exit 1
fi

"$SCRIPT_DIR/bin/jenova-ca" > test_bin_jenova.log 2>&1 &
PID1=$!
sleep 10
echo "Checking bin/jenova-ca background boot:"

check_port() {
    luajit "$SCRIPT_DIR/lib/healthcheck.lua" 127.0.0.1 "$1" 3 2>/dev/null
}

EXIT_CODE=0

check_port 8080 && echo "HTTP 8080 Proxy OK" || { echo "HTTP 8080 Proxy Down"; EXIT_CODE=1; }
check_port 8081 && echo "HTTP 8081 LLAMA OK" || { echo "HTTP 8081 LLAMA Down"; EXIT_CODE=1; }
check_port 8082 && echo "HTTP 8082 Embed OK" || { echo "HTTP 8082 Embed Down"; EXIT_CODE=1; }

# Kill via jenova-ca stop to ensure all child processes are cleaned up
"$SCRIPT_DIR/bin/jenova-ca" stop 2>/dev/null
kill "$PID1" 2>/dev/null
wait "$PID1" 2>/dev/null

echo ""
echo "Log output:"
cat test_bin_jenova.log
rm -f test_bin_jenova.log

exit $EXIT_CODE
