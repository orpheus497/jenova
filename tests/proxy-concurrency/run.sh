#!/bin/sh
# Acceptance suite for the proxy concurrency / fd-leak defects.
# Needs luajit, python3, libsqlite3. No GPU, model, or llama.cpp required.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${TMPDIR:-/tmp}/jenova-proxy-test.$$
mkdir -p "$WORK/ws" "$WORK/jca/var" "$WORK/jca/.system"
FAILED=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILED=$((FAILED+1)); }

# A workspace large enough that find(1)'s output exceeds the 64 KB pipe buffer,
# which is what turned the async_popen_read defect into a permanent hang.
i=0
while [ $i -lt 5 ]; do j=0
  while [ $j -lt 4 ]; do k=0
    while [ $k -lt 5 ]; do
      d="$WORK/ws/workspace$i/project$j/folder$k"; mkdir -p "$d"; n=0
      while [ $n -lt 20 ]; do echo x > "$d/note${n}_id.md"; n=$((n+1)); done
      k=$((k+1)); done
    j=$((j+1)); done
  i=$((i+1)); done
echo "workspace: $(find "$WORK/ws" -type f | wc -l) files"

BPORT=18100; PPORT=18101
SLOTS=4 python3 "$HERE/stub_backend.py" "$BPORT" > "$WORK/backend.log" 2>&1 &
BPID=$!
sleep 2

JENOVA_ROOT="$ROOT" JCA_HOME="$WORK/jca" JENOVA_STATE="$WORK/jca/.system" \
JENOVA_WORKSPACES="$WORK/ws" JENOVA_PORT="$PPORT" JENOVA_PROXY_PORT="$PPORT" \
JENOVA_LLAMA_PORT="$BPORT" JENOVA_LLAMA_URL="http://127.0.0.1:$BPORT" \
JENOVA_LLAMA_EMBED_URL="http://127.0.0.1:9999" \
  luajit "$ROOT/lib/proxy.lua" > "$WORK/proxy.log" 2>&1 &
PX=$!
i=0; while [ $i -lt 25 ]; do
  curl -s -m 1 "http://127.0.0.1:$PPORT/health" >/dev/null 2>&1 && break
  i=$((i+1)); sleep 0.3
done
curl -s -m 2 "http://127.0.0.1:$PPORT/health" >/dev/null 2>&1 || {
  echo "proxy failed to start"; tail -5 "$WORK/proxy.log"; exit 1; }

echo
echo "[1] control: 2 concurrent streams direct to the 4-slot backend"
python3 "$HERE/probe_streams.py" two "$BPORT" | sed 's/^/  /'

echo
echo "[2] WP-1: 2 concurrent streams through the proxy must not serialize"
OUT=$(python3 "$HERE/probe_streams.py" two "$PPORT")
echo "$OUT" | sed 's/^/  /'
echo "$OUT" | grep -q CONCURRENT && pass "proxy overlaps concurrent streams" \
                                 || fail "proxy serializes concurrent streams"

echo
echo "[3] WP-2: GET /api/storage/ must return, and must not leak"
CH0=$(pgrep -P $PX 2>/dev/null | wc -l)
FD0=$(ls /proc/$PX/fd 2>/dev/null | wc -l)
RES=$(python3 - "$PPORT" <<'PY'
import socket, sys, time
p = int(sys.argv[1]); t0 = time.time()
s = socket.create_connection(("127.0.0.1", p)); s.settimeout(20)
s.sendall(b"GET /api/storage/ HTTP/1.1\r\nHost: h\r\n\r\n")
n = 0; hdr = b""
try:
    while True:
        d = s.recv(65536)
        if not d: break
        if not hdr: hdr = d.split(b"\r\n", 1)[0]
        n += len(d)
    print("%s|%d|%.2f" % (hdr.decode(errors="replace"), n, time.time()-t0))
except Exception:
    print("HUNG|%d|%.1f" % (n, time.time()-t0))
PY
)
echo "  $RES" | tr '|' ' '
case "$RES" in
  "HTTP/1.1 200 OK"*) pass "GET /api/storage/ returns 200" ;;
  *)                  fail "GET /api/storage/ did not return 200" ;;
esac

echo
echo "[4] WP-1/2/3: fd and child counts must be flat across 100 requests"
i=0; while [ $i -lt 100 ]; do
  curl -s -m 5 "http://127.0.0.1:$PPORT/health" >/dev/null 2>&1
  i=$((i+1))
done
sleep 1
FD1=$(ls /proc/$PX/fd 2>/dev/null | wc -l)
CH1=$(pgrep -P $PX 2>/dev/null | wc -l)
echo "  fds: $FD0 -> $FD1     children: $CH0 -> $CH1"
[ "$FD1" -le "$((FD0 + 2))" ] && pass "fd count stable across 100 requests" \
                              || fail "fd leak: $FD0 -> $FD1"
[ "$CH1" -le "$((CH0 + 1))" ] && pass "child process count stable" \
                              || fail "process leak: $CH0 -> $CH1"

kill -9 $PX $BPID 2>/dev/null
for c in $(pgrep -f "sh -c find --" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
rm -rf "$WORK"
echo
[ "$FAILED" -eq 0 ] && { echo "ALL CHECKS PASSED"; exit 0; } \
                    || { echo "$FAILED CHECK(S) FAILED"; exit 1; }
