"""Drive N concurrent streaming chat completions and classify the result.

Every worker's outcome is recorded explicitly. A worker that raises must not be
able to leave the run looking healthy: with two workers and one crashing, an
earlier version of this script printed the single survivor and reported
CONCURRENT, because the exception killed only that thread and appended nothing
to either list. The run is only classified when every worker reported success.
"""

import json
import socket
import sys
import threading
import time

PORT = int(sys.argv[2])
WORKERS = 2
T0 = time.time()


def elapsed_ms():
    return (time.time() - T0) * 1000


results = []
failures = []
lock = threading.Lock()


def stream(name):
    try:
        body = json.dumps(
            {"model": "x", "stream": True,
             "messages": [{"role": "user", "content": "hi"}]}
        )
        request = (
            "POST /v1/chat/completions HTTP/1.1\r\n"
            "Host: h\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: %d\r\n\r\n%s" % (len(body), body)
        )
        sock = socket.create_connection(("127.0.0.1", PORT))
        sock.settimeout(30)
        try:
            sock.sendall(request.encode())
            first = None
            buf = b""
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                if first is None:
                    first = elapsed_ms()
                buf += chunk
        finally:
            sock.close()

        status = buf.split(b"\r\n", 1)[0] if buf else b"(no response)"
        tokens = buf.count(b"tok")
        if b"200" not in status or tokens < 20:
            with lock:
                failures.append(
                    "%s INVALID: %s (%d bytes, %d tokens)"
                    % (name, status.decode(errors="replace"), len(buf), tokens)
                )
            return
        with lock:
            results.append((name, first, elapsed_ms()))
    except Exception as exc:                      # noqa: BLE001 - any failure invalidates the run
        with lock:
            failures.append("%s FAILED: %s: %s" % (name, type(exc).__name__, exc))


threads = [threading.Thread(target=stream, args=("stream-%d" % i,))
           for i in range(WORKERS)]
for t in threads:
    t.start()
for t in threads:
    t.join()

if failures or len(results) != WORKERS:
    print("    *** HARNESS INVALID ***")
    for line in failures:
        print("    " + line)
    if len(results) != WORKERS and not failures:
        print("    only %d/%d workers reported a result"
              % (len(results), WORKERS))
    sys.exit(2)

for name, first, done in sorted(results):
    print("    %s  first-byte@%6.0fms  done@%6.0fms" % (name, first, done))

span = max(done for _, _, done in results)
print("    >>> wall for %d x 1s streams: %.0fms  (%s)"
      % (WORKERS, span, "CONCURRENT" if span < 1500 else "SERIALIZED"))
