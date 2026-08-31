#!/bin/sh
# Regression test for the connection reaper (WP-3).
#
# proxy.lua's event loop has a "stall-breaker": any connection idle for more than
# STALL_POKE_INTERVAL (15s) is force-resumed even though its watched fd is not
# ready. That resume used to refresh info.last_active, which is the same field the
# COROUTINE_TIMEOUT sweep uses to decide whether a connection is dead. The sweep
# could therefore never fire, and an abandoned connection held its
# active_connection_count slot and two fds forever -- until the 32-connection
# ceiling wedged the proxy for good.
#
# Two preconditions are needed to observe it, and both are the normal case:
#
#   1. The proxy must be BUSY. The stall-breaker lives inside `if n > 0`, so on an
#      idle proxy select() times out, the stall-breaker never runs, and the reaper
#      works fine. It only misbehaves when other traffic keeps select() returning.
#   2. JENOVA_CONN_TIMEOUT must exceed the 15s stall-breaker interval (the shipped
#      default is 600s). With a shorter timeout the sweep fires before the
#      stall-breaker ever gets a chance to refresh the timestamp.
#
# Getting either wrong makes this test pass against broken code.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${TMPDIR:-/tmp}/jenova-reaper-test.$$
mkdir -p "$WORK/ws" "$WORK/jca/var" "$WORK/jca/.system"
PORT=18401

JENOVA_ROOT="$ROOT" JCA_HOME="$WORK/jca" JENOVA_STATE="$WORK/jca/.system" \
JENOVA_WORKSPACES="$WORK/ws" JENOVA_PORT="$PORT" JENOVA_PROXY_PORT="$PORT" \
JENOVA_LLAMA_EMBED_URL="http://127.0.0.1:9999" \
JENOVA_CONN_TIMEOUT=20 \
  luajit "$ROOT/lib/proxy.lua" > "$WORK/proxy.log" 2>&1 &
PX=$!
i=0; while [ $i -lt 25 ]; do
  curl -s -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  i=$((i+1)); sleep 0.3
done

python3 - "$PORT" <<'PY'
import socket, sys, threading, time
port = int(sys.argv[1]); stop = False

# The connection under test: half-open, headers never completed, then silence.
victim = socket.create_connection(("127.0.0.1", port))
victim.sendall(b"GET /health HTTP")

# Background traffic, so select() keeps returning >0 and the stall-breaker runs.
def hammer():
    while not stop:
        try:
            c = socket.create_connection(("127.0.0.1", port), 2); c.settimeout(2)
            c.sendall(b"GET /health HTTP/1.1\r\nHost: h\r\n\r\n")
            while c.recv(4096): pass
            c.close()
        except Exception:
            pass
        time.sleep(0.05)

for _ in range(3):
    threading.Thread(target=hammer, daemon=True).start()
time.sleep(45)                 # > CONN_TIMEOUT(20) and > stall-breaker(15)
stop = True; time.sleep(1); victim.close()
PY

# SIGTERM, not SIGKILL: the proxy's log writes are buffered and would be lost.
kill -TERM $PX 2>/dev/null
sleep 2
kill -9 $PX 2>/dev/null

REAPED=$(grep -c "timeout: closing" "$WORK/proxy.log" 2>/dev/null | head -1)
[ -n "$REAPED" ] || REAPED=0
rm -rf "$WORK"

if [ "$REAPED" -ge 1 ]; then
  echo "  ok   abandoned connection reaped under load ($REAPED event(s))"
  exit 0
else
  echo "  FAIL abandoned connection never reaped -- stall-breaker is refreshing last_active"
  exit 1
fi
