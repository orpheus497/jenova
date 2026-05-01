#!/bin/sh
# Quick smoke test: verify Jenova server starts and responds
SCRIPT_DIR=$(dirname "$(realpath "$0")")
# Load jenova.conf
if [ -f "$SCRIPT_DIR/../etc/jenova.conf" ]; then
    . "$SCRIPT_DIR/../etc/jenova.conf"
else
    echo "Error: etc/jenova.conf not found."
    exit 1
fi

echo "Testing Jenova server health..."
python3 -c "
import http.client, sys
try:
    c = http.client.HTTPConnection('${HOST}', ${PORT}, timeout=10)
    c.request('GET', '/health')
    r = c.getresponse()
    body = r.read().decode()
    print(f'Status: {r.status}')
    print(f'Body: {body[:200]}')
    sys.exit(0 if r.status == 200 else 1)
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
