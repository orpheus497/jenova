# Server / Proxy Analysis: Root Cause of the Serialization

Third pass. Passes one and two analysed design and topology. This pass ran the proxy
against an instrumented backend and found that the top-level premise was wrong in a way
neither earlier pass could see by reading:

> **The proxy has never been asynchronous.** A LuaJIT FFI ABI bug makes `set_nonblocking()`
> a silent no-op, so every socket in `lib/proxy.lua` is blocking, so no coroutine ever
> yields, so the `select`-based event loop is decorative. The proxy processes exactly one
> request at a time, and always has.

This is not a design opinion. It is measured, and a small fix doubles throughput in a
controlled A/B. **Fixed in Phase 1** (see `remediation-plan.md`); the figures below are the
before/after from `tests/proxy-concurrency/`:

| Two concurrent 1-second streams, backend with 4 free slots | Wall time | |
|---|---|---|
| Direct to backend (control) | 1017 ms | concurrent |
| **Through the proxy, as shipped** | **2023 ms** | **serialized** |
| **Through the proxy, after Phase 1** | **1010 ms** | **concurrent** |

| `GET /api/storage/` on a 2,125-file workspace | Result |
|---|---|
| **As shipped** | **hangs forever** (0 bytes after 20 s), leaks 1 pipe fd + 2 processes |
| **After Phase 1** | HTTP 200, 88,599 bytes, **0.03 s**, no leaks |

`GET /api/storage/` is called on **every message completion**. Reproduction harness:
`tests/proxy-concurrency/`.

---

## 1. Root cause: one ABI bug, three symptoms

`lib/ffi_defs.lua:155` declares:

```c
int fcntl(int fd, int cmd, ...);
```

The third argument is variadic. On x86-64 SysV, LuaJIT promotes a Lua number passed in a
variadic slot to a **double** and places it in an SSE register (`xmm0`). The kernel reads
the integer register (`rdx`), gets garbage, and applies nothing. Verified directly:

```
$ luajit  -- exactly what proxy.lua:set_nonblocking does
before: FL flags = 2
after set_nonblocking: FL flags = 2   -> O_NONBLOCK *** NOT SET ***
with non-variadic decl: FL flags = 2050 -> O_NONBLOCK SET
```

Three consequences, each independently serious.

### 1.1 `set_nonblocking` is a no-op — the proxy is synchronous

`lib/proxy.lua:102-109`. Every accepted client socket, every upstream socket to
llama-server, and every socket in `lib/http.lua` is **blocking**. Therefore:

- `async_recv` never sees `EAGAIN`, so it never reaches `coroutine.yield("read", fd)`.
- `async_send` never yields.
- `async_connect` never yields.

The coroutine per connection, the `clients` table, the fd sets, the `select()` loop,
`MAX_ACTIVE_CONNECTIONS = 32` — none of it does anything, because control never returns to
the event loop mid-request. Each connection runs start to finish inside its first
`coroutine.resume`.

**Every conclusion in the previous two passes about "one event loop that a slow operation
freezes" was too generous.** There is no event loop behaviour to freeze. `-np 1` at
llama-server compounds this, but it is not the primary cause: the A/B above ran against a
4-slot backend and the proxy still serialized.

### 1.2 `set_cloexec` is a no-op — fds leak into every forked child

`lib/proxy.lua:118-122`, same bug. `docs/architecture/backend.md` claims:

> Security Sealing: All accepted sockets are marked with `FD_CLOEXEC` to prevent child
> processes from inheriting and locking ports.

Observed in `/proc/<pid>/fd` for the `sh -c find` children the proxy spawns:

```
sh 8683:  6 -> socket:[6615]   <- the proxy's LISTENING socket
          7 -> socket:[8208]   <- a CLIENT socket
sh 9045:  6 -> socket:[6615]   <- listening socket again
          7 -> socket:[6859]   <- another client socket
          8 -> pipe:[8209]     <- the previous request's pipe
```

So every `find`/`curl` the proxy forks inherits the listening socket and every in-flight
client socket. Two direct consequences:

- **A client connection cannot close while any forked child outlives it.** The proxy calls
  `close()`, but the socket stays open because a child holds a reference, so the browser
  never sees EOF and the request hangs.
- **Port 8080 stays bound after the proxy dies.** Observed: after killing the proxy,
  orphaned `find` children kept the listening socket, and restarting failed with
  `EADDRINUSE`. This is a plausible explanation for "restarting doesn't fix it".

### 1.3 `open()` has the same bug — daemon logs are created mode 000

`lib/ffi_defs.lua:153` declares `int open(const char *path, int oflag, ...)`.
`lib/daemon.lua:132` passes mode `438` (0666) in the variadic slot. Verified:

```
$ ls -l /tmp/jn_variadic.log
----------  1 root root  0   (expected -rw-rw-rw-)
```

Every log file created by `daemon.start_background` — the embed server log, the indexer log
— is mode 000. As a non-root user the process writes via its already-open fd, but nobody
can read the log afterwards, and a later restart cannot reopen it. **Debugging information
for exactly the subsystems that fail silently is being discarded.**

---

## 2. Second defect: `async_popen_read` has never executed

`lib/proxy.lua:216`:

```lua
local rfds = ffi.new("fd_set")
```

`fd_set` is **never** `cdef`'d anywhere in the codebase. `lib/ffi_defs.lua:289` provides
`fd_set_new()` returning `unsigned int[?]` instead, which the main loop uses correctly at
`lib/proxy.lua:1531`. `async_popen_read` does not. From the proxy's own log, on a live run:

```
[proxy] connection error: lib/proxy.lua:216: declaration specifier expected near 'fd_set'
```

**Every call to `async_popen_read` throws on its first statement after the fork.** The
`pcall` in the connection coroutine swallows it and closes the client fd. The forked child
is never reaped and never read from.

This function is the implementation of:

- `GET /api/storage/` — the workspace file listing (`lib/proxy.lua:1065`)
- `GET /api/workspaces` (`lib/proxy.lua:1094`)
- web search (`lib/proxy.lua:381-397`)

**All three endpoints are 100% broken**, and have been for as long as this code has existed.

### The resulting deadlock

Observed live, with `/proc` evidence:

1. Proxy forks `/bin/sh -c find ...`; the pipe read-end is never read because line 216 threw.
2. `find` writes > 64 KB (the pipe buffer) and blocks in `write()` — confirmed, syscall 1.
3. `sh` blocks in `wait4()` for `find` — confirmed, syscall 61.
4. The child holds the client socket (§1.2), so the HTTP client **never sees EOF and hangs
   forever**.
5. The proxy leaks the pipe read-end fd and two processes, permanently.
6. `SIGPIPE` is `SIG_IGN`'d process-wide (`lib/proxy.lua:1487`) and that disposition is
   inherited through `fork`+`exec`, so the stuck writer never dies of `EPIPE` either.

The 15-second timeout in `async_popen_read` never fires, because the function threw before
reaching its own loop.

---

## 3. How this produces the reported symptom

`SyncService.syncEntity("chat", convId)` runs on **every message completion** and on every
node advance — `jca_web/src/lib/stores/conversations.svelte.ts:524`, `:560`, `:630`, the
last reached from `updateCurrentNode`, which the agentic loop calls per turn and per tool
result (`chat.svelte.ts:815`, `:836`, `:993`). It is undebounced on that path.

Inside it (`sync.service.ts:453-494`):

```ts
const files = await StorageService.list();   // GET /api/storage/  <-- §2: hangs forever
```

So the sequence on a normal chat is:

1. Message completes.
2. `GET /api/storage/` is issued.
3. That request hangs permanently and leaks a connection slot, a pipe fd, and 2 processes.
4. Because the proxy is synchronous (§1.1), the hung request is **not** one stalled
   coroutine among many — it is the proxy.
5. `MAX_ACTIVE_CONNECTIONS = 32` is consumed at a few per message; then every request gets
   `503 Retry-After: 5`.
6. `chat.service.ts:337` retries failed completions **3 times** with 1.5 s backoff,
   amplifying load onto an already-dead proxy.
7. Nothing recovers it: `jenova-ca`'s watchdog probes **:8081**, not :8080 (§4.1), so every
   health signal reads green.
8. Restarting may fail with `EADDRINUSE` because orphaned children still hold :8080 (§1.2).

`maxTurns` defaults to **100** (`jca_web/src/lib/constants/agentic.ts:14`), so a single
agentic run can issue up to 100 completions, each with per-turn and per-tool-result
`syncEntity` calls. That matches "I'm starting to get issues" — the failure is cumulative
and worsens with workspace size and agent usage.

---

## 4. Topology findings (unchanged from pass 2, still valid)

These are real and still need fixing, but they are now understood as *aggravating* rather
than causal.

### 4.1 The proxy is not a supervised daemon

`bin/jenova-ca --daemon` never starts it. `PROXY_PID` is declared at `bin/jenova-ca:13` and
never assigned; `OLD_PROXY_PID` is printed at `:670` and never read. The proxy is
`io.popen`'d as a child of the tray app (`lib/ui.lua:67`), which is why `--watch-stdin`
exists.

- Headless (`ssh` + `jenova-ca start`) brings up :8081 and :8082 and **nothing on :8080**.
- `jenova-ca status` does not report it; `jenova-ca stop` does not stop it.
- The watchdog iterates `llama-server` and `embed` only (`:491`), and `_probe_health` targets
  `http://${CONNECT_HOST}:${LLAMA_PORT}/health` — **:8081**.
- `ui.poll_status` forks `jenova-ca status` (which sources 4 config files and forks `curl`)
  every 3 s in the tray and **every 1 s** in the TUI (`jenova-ui/src/main.c:392`, `:512`).

### 4.2 :8082 is not behind the proxy

`lib/proxy.lua` has one scalar upstream, `LLAMA_PORT` (`:56`), used at `:1414`. `lib/embed.lua`
opens its own socket to `127.0.0.1:8082` from inside the proxy process, so the embedding
backend is a *dependency of* the proxy, not a *service behind* it. There is no
`/v1/embeddings` on :8080; such a request is forwarded to :8081 and errors.
`scripts/install.sh:562` tells users to open the firewall for all three ports — necessary
only because the front door isn't one.

### 4.3 Two owners race for :8082

`embed.init()` probes `:8082/health` with a **1-second** timeout and, on failure, spawns its
own server with pidfile `llama-embed.pid` — different from the `EMBED_PID` that `jenova-ca`
tracks. The embed model takes seconds to load, so the normal startup ordering triggers the
race. `daemon.start_background` writes the pidfile on successful `fork`, not on successful
`bind`, so it is written even when the process loses the port and dies.

### 4.4 The RAG path is inert and `/health` reports it healthy

- `search.index_dir` is never called from the proxy (`lib/proxy.lua:1521-1523`), so
  `total_docs == 0` and `search.query` returns `{}` at `lib/search.lua:759`.
- `search.init_embeddings` is only called from `lib/indexer_runner.lua:34`, so `search.lua`'s
  `embed` is `nil` in the proxy.
- `embed.init()` returns `true` after *starting* a process without setting `initialized`.

`/health` reports `embed` = that return value. **Measured**: pointing the proxy at a dead
embed port still yields `{"status":"ok",...,"embed":true}`.

### 4.5 No auth, no CORS on any port

`grep -i "access-control|authorization|bearer" lib/proxy.lua` → nothing. `--lan` sets
`HOST=0.0.0.0` (`bin/jenova-ca:331`), passed to both llama-servers. In LAN mode all three
ports are open with no authentication, and :8081/:8082 bypass every proxy-side check.

---

## 5. Is Lua the cause? Does Nim fix it?

The answer is now much sharper than in pass two.

**Lua is not the cause, but LuaJIT's FFI *is* implicated** — not through performance, through
its C ABI surface. Three of the four defects above come from one variadic-argument mismatch
that a C compiler would have caught at compile time, and the fourth (`ffi.new("fd_set")`) is
an undefined ctype that only fails at runtime, inside a `pcall`, where it was invisible for
the lifetime of the code.

That is a real argument, and it is not the argument usually made. It has nothing to do with
Lua being slow. The measured cost of interpretation — SHA-256 at 16–26 MB/s, JSON at
13–23 MB/s — is tens of milliseconds per request against failures measured in *infinite*
hangs.

**A Nim rewrite would eliminate this class of bug** (typed FFI, compile-time argument
checking, no silent double-for-int promotion). It would also give real threads. Both are
genuine. But:

- The same defects can be fixed in **4 lines**, today, with the A/B above as proof.
- A rewrite of ~3,500 lines of recently security-audited code carries its own new-bug risk,
  and would not by itself fix `-np 1`, the missing upstream routing table, the unsupervised
  proxy, or the missing auth — all of which live outside the proxy's language.
- Nim's default `asyncdispatch` is single-threaded; a blocking call in an `async` proc
  blocks it exactly as it blocks LuaJIT.

**Recommendation: fix the four lines first and re-measure.** The system has never once run
in its intended concurrent configuration, so every prior judgement about its performance
ceiling — including mine in passes one and two — was made against a broken baseline. Decide
about Nim afterwards, on maintainability grounds, with real numbers.

If the FFI surface remains a concern after that, the targeted mitigation is to add a
compile-time-checked C shim for the syscall layer (~100 lines) rather than rewriting the
application.

---

## 6. Plan

Staged. Each stage is independently shippable and has an acceptance test.

### Stage 0 — the four-line fix (do this first, today)

**0.1** `lib/ffi_defs.lua:155` — make `fcntl` non-variadic. All 13 call sites already pass
exactly 3 arguments, so this is safe:

```diff
-  int fcntl(int fd, int cmd, ...);
+  int fcntl(int fd, int cmd, int arg);
```

**0.2** `lib/ffi_defs.lua:153` — same for `open`. `lib/daemon.lua:132` is the only call site
and passes 3 arguments:

```diff
-  int open(const char *path, int oflag, ...);
+  int open(const char *path, int oflag, int mode);
```

**0.3** `lib/proxy.lua:216` — use the helper that exists:

```diff
-        local rfds = ffi.new("fd_set")
+        local rfds = _ffi_defs.fd_set_new()
```

**0.4** `lib/proxy.lua` — add `set_cloexec(client_fd)` in `proxy_connection` alongside the
existing `set_nonblocking(client_fd)` (`:473`). It is currently never called on accepted
sockets at all; with 0.1 it starts working, but only where it is invoked.

Also audit `ioctl` (`lib/ffi_defs.lua:158`) for the same pattern — currently unused, but it
is the same trap.

**Acceptance:** `tests/proxy-concurrency/` — two concurrent streams complete in ~1× the
single-stream time against a multi-slot backend, and `GET /api/storage/` returns 200 with
zero leaked fds and zero orphaned children.

**Expected effect: this is the fix.** Everything below is hardening.

### Stage 1 — make `async_popen_read` genuinely async

With 0.3 the function runs, but it still blocks the loop: it runs its own private `select()`
rather than yielding. Replace that loop with `coroutine.yield("read", fd)` on `EAGAIN`,
keeping the 15 s wall-clock deadline. ~15 lines. Also reap the child with `waitpid(WNOHANG)`
in a loop rather than blocking, and kill the process *group*, not just `sh`.

Then route `fs_sync`'s three blocking `io.popen` sites (`:299`, `:323`, `:384`) through it.

### Stage 2 — remove the fork storms

**2.1** `fs_sync.get_fs_tree` (`lib/fs_sync.lua:445`) forks `test -d` **per entry** —
measured **2,872 ms and 2,125 forks** on a 2,000-file tree. Replace with a single
`find -printf '%y\t%p\0'` (GNU) / `-type d` two-pass (BSD); the stat flavour is already
detected at `lib/search.lua:147-164`. → ~10 ms.

**2.2** Cache `StorageService.list()` in `sync.service.ts` the way `getHierarchy()` already
is (`:437`), and debounce the `updateCurrentNode` → `syncEntity` path
(`conversations.svelte.ts:630`) using the 3 s debouncer that already exists at
`chat.svelte.ts:88` but is only wired to two of the call sites.

**2.3** `ui.poll_status` should `GET :8080/health` instead of forking `jenova-ca status`
every 1–3 s. The proxy already answers `/health` natively and cheaply.

### Stage 3 — topology

**3.1** Give the proxy an upstream **routing table** instead of the scalar `LLAMA_PORT`:
`/v1/chat/completions`, `/infill`, `/props`, `/v1/models` → :8081; `/v1/embeddings`,
`/embedding` → :8082. Then bind :8081 and :8082 to loopback unconditionally, even under
`--lan`, and drop them from `scripts/install.sh:562`. This is what makes :8080 a real front
door and is the precondition for adding auth in one place.

**3.2** Make the proxy a supervised daemon: start it from `jenova-ca --daemon`, record
`PROXY_PID` (the variable exists), report it in `status`, stop it in `stop`, and **point
`_probe_health` at :8080**. Keep `proxy-serve` for the UI-attached case but have `ui.init`
attach to a running daemon rather than own one.

**3.3** Single owner for :8082 — remove the spawn path in `lib/embed.lua:50-71`; let
`jenova-ca` own it and have the proxy retry with backoff.

**3.4** HTTP keep-alive; accept in a loop until `EAGAIN`; raise the listen backlog from 16;
replace `select()` with `poll`/`epoll`/`kqueue`.

### Stage 4 — correctness cleanups (independent, small)

- Delete the SHA-256 / `llm_cache` intercept (`lib/proxy.lua:1371-1386`): a 20-entry cache
  (`lib/db.lua:862`) that cannot hit for a growing conversation, costing 15–43 ms per request.
- Fix `async_send`'s O(n²) `data:sub(sent + 1)` (`lib/proxy.lua:157`): 1 MB body → 64 MB copied.
- Bound `db.get_all_messages()` (`lib/db.lua:430`), an unbounded `SELECT *`.
- Prepared-statement cache in `lib/db.lua:210`.
- `/cors-proxy` has no handler; `mcp.svelte.ts:114` probes it and always gets 404.
- `/api/fs` is missing from the vite dev proxy (`jca_web/vite.config.ts:91-99`).
- Hardware-profile variable drift: `Linux/CPU/generic`, `macOS/CPU/generic`,
  `macOS/Metal/generic` set `JENOVA_CTX_SIZE`/`JENOVA_NUM_SLOTS`/`JENOVA_THREADS` while
  `jenova-ca` reads `CTX_SIZE`/`NUM_SLOTS`/`THREADS` → `-c "" -np "" -t ""`.
- `NUM_SLOTS` 1 → 2–4 **after** Stage 0, raising `CTX_SIZE` proportionally (llama.cpp splits
  context per slot: `n_ctx_slot = n_ctx / n_parallel`).
- Correct the four false claims in `docs/architecture/backend.md` (§7).

### Stage 5 — decide about the language

Re-measure after Stage 2. Only then is there a meaningful basis for the Nim question.

---

## 7. Documentation drift

`docs/architecture/backend.md` describes the intended design as built. Five claims are false:

| Claim | Reality |
|---|---|
| "coroutine-based **non-blocking** I/O" | every socket is blocking (§1.1) |
| "Async Sub-processes … yields to the scheduler while waiting for output" | `async_popen_read` throws on line 1 (§2) |
| "Background Discovery … performed asynchronously to prevent UI/Editor freezes" | the endpoints hang permanently (§2) |
| "Security Sealing: all accepted sockets are marked `FD_CLOEXEC`" | no-op; sockets leak into children (§1.2) |
| "Consumers [of :8082]: the proxy's RAG pipeline" | the RAG pipeline never issues a request (§4.4) |

---

## 8. Measurements and reproduction

LuaJIT 2.1.1703358377, sqlite3 3.x, idle container, warm cache. Harness in
`tests/proxy-concurrency/`: a Python stub backend emulating llama-server's `-np` slot limit,
plus asserting probes (they verify HTTP 200 and full token count, so a 502 cannot be
mistaken for a fast response).

| Measurement | As shipped | Fixed |
|---|---|---|
| 2 × 1 s streams, 4-slot backend | 2023 ms (serialized) | **1022 ms (concurrent)** |
| same, direct to backend (control) | 1017 ms | 1017 ms |
| `GET /api/storage/`, 2,125 files | **hangs, 0 bytes @20 s** | **200, 88,699 B, 0.03 s** |
| leaked pipe fds per storage request | 1 | 0 |
| orphaned processes per storage request | 2 | 0 |
| `GET /api/fs/tree`, 2,125 entries | 2,872 ms, 2,125 forks | (Stage 2.1) |
| `sha256.lua` | 15.6–23.5 MB/s | — |
| `json.lua`, 0.36 MB | 27 ms encode / 16 ms decode | — |
| `async_send`, 1 MB body | 64 MB copied | (Stage 4) |
