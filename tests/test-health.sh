#!/bin/sh
# Quick smoke test: verify server starts and responds
SCRIPT_DIR=$(dirname "$(realpath "$0")")
. "$SCRIPT_DIR/../etc/coder.conf"

echo "Testing server health..."
python3 -c "
import http.client, sys
try:
    c = http.client.HTTPConnection('${HOST}', ${PORT}, timeout=5)
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
