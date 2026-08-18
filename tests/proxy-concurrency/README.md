# Proxy concurrency / fd-leak reproduction

Reproduces the findings in `docs/architecture/concurrency-analysis.md` without needing a
GPU, a model, or llama.cpp. Requires `luajit`, `python3`, and `libsqlite3`.

## What it shows

1. **The proxy serializes requests** even when the backend has free slots, because
   `set_nonblocking()` is a no-op (variadic `fcntl` ABI mismatch) and no coroutine ever
   yields.
2. **`GET /api/storage/` hangs forever** and leaks a pipe fd plus two processes per
   request, because `async_popen_read` throws on `ffi.new("fd_set")` before reading the
   pipe, and the forked child inherits the client socket (`set_cloexec` is also a no-op).

## Run

```sh
sh tests/proxy-concurrency/run.sh
```

`stub_backend.py` emulates llama-server: `SLOTS=N` reproduces `-np N` by admitting at most
N concurrent generations, each streaming 20 chunks over ~1 s.

`probe_streams.py` asserts HTTP 200 and a full token count before reporting timings, so an
error response cannot be misread as a fast one.
