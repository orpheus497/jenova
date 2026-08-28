# Proxy regression checks

Reproduces and guards the defects in `.devdocs/CONCURRENCY_ANALYSIS.md`.
No GPU, model, or llama.cpp build required. Needs `luajit`, `python3`, `libsqlite3`, `curl`.

```sh
sh tests/proxy-concurrency/all.sh      # everything (~60s)
```

| File | Guards |
|---|---|
| `test_ffi_flags.lua` | `set_nonblocking`/`set_cloexec` actually take effect; `open()` honours its mode; `fd_set` is allocated via `fd_set_new()` |
| `run.sh` | concurrent streams overlap; `GET /api/storage/` returns; fd and child counts flat over 100 requests |
| `test_reaper.sh` | an abandoned connection is reaped under load (~50s) |

`stub_backend.py` stands in for llama-server: `SLOTS=N` emulates `-np N` by admitting at
most N concurrent generations, each streaming 20 chunks over ~1s. Takes a port argument.

`probe_streams.py` asserts HTTP 200 **and** a full token count before reporting timings.
That assertion is not decoration: during the original investigation, 502 responses were
twice mistaken for unusually fast successes.

## What these caught

`fcntl` and `open` were declared with variadic third arguments. LuaJIT promotes a Lua number
in a variadic slot to a double (SSE register); the kernel reads the integer register and
silently discards it. `set_nonblocking()` and `set_cloexec()` therefore did nothing, so every
socket in the proxy was blocking, no coroutine ever yielded, and the `select` event loop was
decorative — the proxy served exactly one request at a time. The same bug leaked the
listening socket and live client sockets into every forked child.

Separately, `async_popen_read` called `ffi.new("fd_set")`, a ctype never `cdef`'d anywhere, so
it threw on its first statement after forking, on every call. `GET /api/storage/`,
`GET /api/workspaces` and web search had never worked; the orphaned `find` blocked writing to
a full 64 KB pipe while holding the client socket, hanging the request permanently.

## Caveats worth knowing before editing these

- **The reaper test needs load and a timeout above 15s.** The stall-breaker only runs inside
  `if n > 0`, so on an idle proxy it never fires and the reaper works. And a
  `JENOVA_CONN_TIMEOUT` below the 15s stall-breaker interval fires before the bug can occur.
  Get either wrong and the test passes against broken code.
- **Shut the proxy down with SIGTERM, not SIGKILL.** Its log writes are buffered; `kill -9`
  discards them and makes a working reaper look broken.
