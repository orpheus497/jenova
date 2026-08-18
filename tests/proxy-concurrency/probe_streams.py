import socket, threading, time, sys, json
PORT=int(sys.argv[2]); T0=time.time()
def el(): return (time.time()-T0)*1000
out=[]; errs=[]
def stream(name):
    body=json.dumps({"model":"x","stream":True,"messages":[{"role":"user","content":"hi"}]})
    s=socket.create_connection(("127.0.0.1",PORT)); s.settimeout(30)
    s.sendall(("POST /v1/chat/completions HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"%(len(body),body)).encode())
    first=None; buf=b""
    while True:
        d=s.recv(65536)
        if not d: break
        if first is None: first=el()
        buf+=d
    s.close()
    status=buf.split(b"\r\n",1)[0] if buf else b"(no response)"
    if b"200" not in status or buf.count(b"tok")<20:
        errs.append("%s INVALID: %s (%d bytes, %d tokens)"%(name,status.decode(errors='replace'),len(buf),buf.count(b"tok")))
        return
    out.append((name, first, el()))
ts=[threading.Thread(target=stream,args=("stream-%d"%i,)) for i in range(2)]
for t in ts: t.start()
for t in ts: t.join()
if errs:
    print("    *** HARNESS INVALID ***"); [print("    "+e) for e in errs]; sys.exit(2)
for n,f,d in sorted(out): print("    %s  first-byte@%6.0fms  done@%6.0fms" % (n,f,d))
span=max(d for _,_,d in out)
print("    >>> wall for 2 x 1s streams: %.0fms  (%s)" % (span, "CONCURRENT" if span<1500 else "SERIALIZED"))
