#!/bin/sh
# Reproduce the proxy serialization and fd-leak findings.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${TMPDIR:-/tmp}/jenova-proxy-test.$$
mkdir -p "$WORK/ws" "$WORK/jca/var" "$WORK/jca/.system"

# 2000-file workspace: enough for find(1) output to exceed the 64 KB pipe buffer
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
PPID_=$!
i=0; while [ $i -lt 25 ]; do
  curl -s -m 1 "http://127.0.0.1:$PPORT/health" >/dev/null 2>&1 && break
  i=$((i+1)); sleep 0.3
done

echo
echo "--- control: 2 concurrent streams DIRECT to the 4-slot backend ---"
python3 "$HERE/probe_streams.py" two "$BPORT"
echo
echo "--- 2 concurrent streams THROUGH the proxy ---"
python3 "$HERE/probe_streams.py" two "$PPORT"
echo
echo "--- GET /api/storage/ through the proxy (20s cap) ---"
python3 - "$PPORT" <<'PY'
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
    print("    %s  %d bytes in %.2fs" % (hdr.decode(errors="replace"), n, time.time()-t0))
except Exception:
    print("    *** HUNG *** (%d bytes after %.1fs)" % (n, time.time()-t0))
PY
echo "    leaked pipe fds in proxy: $(ls -l /proc/$PPID_/fd 2>/dev/null | grep -c pipe)"
echo "    orphaned children:        $(pgrep -P $PPID_ 2>/dev/null | wc -l)"

kill -9 $PPID_ $BPID 2>/dev/null
for c in $(pgrep -f "sh -c find --" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
rm -rf "$WORK"
