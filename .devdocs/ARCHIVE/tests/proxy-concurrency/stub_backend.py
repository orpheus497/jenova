import socket, threading, time, sys, os
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
SLOTS = int(os.environ.get("SLOTS", "1"))
sem = threading.Semaphore(SLOTS)          # emulate llama-server -np N
def handle(c):
    try:
        c.settimeout(30)
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = c.recv(65536)
            if not d: return
            buf += d
        head, _, rest = buf.partition(b"\r\n\r\n")
        cl = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                cl = int(line.split(b":")[1])
        while len(rest) < cl:
            d = c.recv(65536)
            if not d: break
            rest += d
        with sem:                          # <-- the single slot
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                      b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            for i in range(20):            # 20 tokens @ 50ms = 1.0s generation
                payload = b'data: {"choices":[{"delta":{"content":"tok%d "}}]}\n\n' % i
                c.sendall(b"%x\r\n" % len(payload) + payload + b"\r\n")
                time.sleep(0.05)
            c.sendall(b"0\r\n\r\n")
    except Exception:
        pass
    finally:
        try: c.close()
        except: pass
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT)); s.listen(64)
print(f"fake llama-server on :{PORT} with {SLOTS} slot(s)", flush=True)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
