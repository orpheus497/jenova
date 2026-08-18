# Remediation Plan

Execution plan for the defects in `concurrency-analysis.md`. Work packages are ordered by
dependency; each has an explicit acceptance test. Nothing here is speculative — every
defect referenced has been reproduced.

**Critical sequencing note:** WP-1 makes code live that has *never executed* in the history
of this codebase. Two latent bugs in that code are proven (WP-2, WP-3) and **must ship in
the same change**, or WP-1 converts an immediate failure into a slow resource leak. Do not
ship WP-1 alone.

---

## Phase 1 — Restore correctness (must ship together)

Total diff: roughly 30 lines across 3 files. This is the whole fix for the reported symptom.

### WP-1 — Fix the FFI variadic ABI bug

**Defect.** `lib/ffi_defs.lua` declares `fcntl` and `open` with variadic third arguments.
LuaJIT promotes a Lua number in a variadic slot to a `double` in an SSE register; the kernel
reads the integer register. `set_nonblocking()` and `set_cloexec()` are silent no-ops, so
every socket is blocking and every fd leaks into forked children.

**Change.** All 13 `fcntl` call sites and the single `open` call site already pass exactly
three arguments, so making the declarations non-variadic is safe and mechanical:

```diff
--- a/lib/ffi_defs.lua
-  int open(const char *path, int oflag, ...);
+  int open(const char *path, int oflag, int mode);
-  int fcntl(int fd, int cmd, ...);
+  int fcntl(int fd, int cmd, int arg);
```

Also add `set_cloexec(client_fd)` in `proxy_connection` (`lib/proxy.lua:473`) — accepted
sockets are currently never passed to it at all, so fixing the no-op is necessary but not
sufficient.

```diff
--- a/lib/proxy.lua
     set_nonblocking(client_fd)
+    set_cloexec(client_fd)
     set_socket_opts(client_fd)
```

Audit `ioctl` (`lib/ffi_defs.lua:158`) for the same pattern. It is currently unused; either
fix or delete it so the trap is not re-armed later.

**Risk: medium.** Low diff, but it switches the entire I/O model from synchronous to
asynchronous for the first time. WP-2 and WP-3 exist because of this.

**Acceptance.** `tests/proxy-concurrency/run.sh`: two concurrent streams complete in ~1×
single-stream time against a multi-slot backend (currently 2×).

---

### WP-2 — Fix `async_popen_read`'s undefined ctype

**Defect.** `lib/proxy.lua:216` calls `ffi.new("fd_set")`, but `fd_set` is never `cdef`'d.
The function throws on its first statement after forking, on **every** call, and the `pcall`
in the connection coroutine swallows it. `GET /api/storage/`, `GET /api/workspaces`, and web
search have never worked. The orphaned `find` blocks writing to a full 64 KB pipe, and
(because of WP-1) holds the client socket, so the request hangs forever.

**Change.** Use the helper that already exists and that the main loop already uses:

```diff
--- a/lib/proxy.lua
-        local rfds = ffi.new("fd_set")
+        local rfds = _ffi_defs.fd_set_new()
```

**Risk: low.**

**Acceptance.** `GET /api/storage/` on a 2,000-file workspace returns HTTP 200 in under
100 ms with zero leaked pipe fds and zero orphaned child processes. Currently: hangs at 0
bytes, leaks 1 fd and 2 processes per request.

---

### WP-3 — Fix the connection reaper (the one that makes WP-1 safe)

**Defect — proven, and the reason WP-1 cannot ship alone.** The 15-second stall-breaker
force-resumes idle coroutines and then refreshes their liveness timestamp:

```lua
elseif not ready and info.last_active and (os.time() - info.last_active > 15) then
    ready = true                      -- proxy.lua:1633  force-resume
end
if ready then
    info.last_active = os.time()      -- proxy.lua:1638  refreshes liveness
```

The reaper then tests `now - info.last_active > COROUTINE_TIMEOUT` (`:1676`), which can never
be true while the stall-breaker keeps refreshing it. **Verified**: with
`JENOVA_CONN_TIMEOUT=5`, a half-open connection held for 25 s was never reaped —
`"timeout: closing"` appeared 0 times.

Today this is masked, because the synchronous proxy never leaves connections in `clients`
across loop iterations. After WP-1 it becomes live: every abandoned connection (closed
laptop, killed tab, dropped Wi-Fi) permanently holds an `active_connection_count` slot and
two fds until the 32-connection ceiling wedges the proxy for good.

**Change.** Separate *liveness* from *scheduling*. Refresh a timestamp only when a resume
was driven by real fd readiness, not by the stall-breaker:

```diff
-            elseif not ready and info.last_active and (os.time() - info.last_active > 15) then
-                ready = true
+            elseif info.last_active and (os.time() - info.last_active > 15) then
+                ready = true          -- stall-breaker: resume, but do NOT count as progress
+                stalled = true
             end
             if ready then
-                info.last_active = os.time()
+                if not stalled then info.last_active = os.time() end
```

Two related holes in the same area, worth closing in the same pass:

- **Unreachable header timeout.** The `os.time() - start_time > 10` check
  (`lib/proxy.lua:520`) sits *after* a successful `recv`, so a client that connects and
  sends nothing never reaches it. With WP-1 such a connection yields on `"read"` forever.
- **`accept()` once per loop pass** (`lib/proxy.lua:1595`) against a listen backlog of 16
  (`:1515`). Accept in a loop until `EAGAIN`, and raise the backlog.

**Risk: low.** Small, local, and directly testable.

**Acceptance.** With `JENOVA_CONN_TIMEOUT=5`, a half-open connection is reaped within ~10 s
and `active_connection_count` returns to its prior value. 40 abandoned connections do not
leave the proxy permanently 503-ing.

---

### Phase 1 rollout

Ship WP-1 + WP-2 + WP-3 as one commit with the harness green. Then, on real hardware, before
touching anything else:

1. Confirm streaming still works end-to-end in the WebUI (the relay loop's yield paths have
   never run).
2. Confirm an agentic run with tool calls completes (`maxTurns` defaults to 100).
3. Watch `lsof -p <proxy>` across a session — fd count should be flat, not monotonic.

Only after that is green does the rest of the plan make sense, because **every performance
judgement about this system — including the earlier passes of my own analysis — was made
against a baseline that never once ran concurrently.** Re-measure before optimising.

---

## Phase 2 — Remove the self-inflicted load

Now that requests no longer hang, the remaining cost is real work done needlessly.

### WP-4 — Stop the per-message full-tree scan

`SyncService.syncEntity` calls `StorageService.list()` → `GET /api/storage/` on every
message completion and every node advance (`conversations.svelte.ts:630`, reached from
`updateCurrentNode`, which the agentic loop hits per turn **and** per tool result). It is
called only to find a stale path for a rename.

- Cache `StorageService.list()` with a short TTL, exactly as `getHierarchy()` already is
  (`sync.service.ts:437`).
- Route the `updateCurrentNode` → `syncEntity` path through the 3-second debouncer that
  already exists at `chat.svelte.ts:88` but is wired to only two of its call sites.

**Acceptance.** A 10-turn agentic run issues single-digit `/api/storage/` requests, not one
per turn per tool call.

### WP-5 — Make `async_popen_read` actually asynchronous

After WP-2 it runs, but it still blocks the event loop in its own private `select()`.
Replace that with `coroutine.yield("read", fd)` on `EAGAIN`, keeping the 15 s wall-clock
deadline. Reap with `waitpid(WNOHANG)` rather than blocking, and kill the process *group* —
the current code kills `sh` and orphans `find`. Then route `fs_sync`'s three blocking
`io.popen` sites (`:299`, `:323`, `:384`) through it.

### WP-6 — Kill the fork storms

- `fs_sync.get_fs_tree` (`lib/fs_sync.lua:445`) forks `test -d` **per entry** — measured
  **2,872 ms and 2,125 forks** on a 2,000-file tree. Replace with a single
  `find -printf '%y\t%p\0'` (GNU) or `-type d` two-pass (BSD); the stat flavour is already
  detected at `lib/search.lua:147-164`.
- `ui.poll_status` forks `jenova-ca status` — which sources four config files and forks
  `curl` — every 3 s in the tray and **every 1 s** in the TUI. Replace with
  `GET :8080/health`, which the proxy answers natively and cheaply.

### WP-7 — Cheap correctness wins on the hot path

- Delete the SHA-256 / `llm_cache` intercept (`lib/proxy.lua:1371-1386`): a 20-entry cache
  (`lib/db.lua:862`) that cannot hit for a growing conversation, costing 15–43 ms per request.
- Fix `async_send`'s O(n²) `data:sub(sent + 1)` (`lib/proxy.lua:157`) — a 1 MB body copies
  64 MB. Use a `const char*` plus offset.
- Bound `db.get_all_messages()` (`lib/db.lua:430`), an unbounded `SELECT *`.
- Add a prepared-statement cache in `lib/db.lua:210`.
- Reconsider the 3× retry on failed completions (`chat.service.ts:337`), which amplifies
  load onto a saturated proxy. It is defensible once the proxy stops wedging; it was not
  before.

---

## Phase 3 — Fix the topology

Nothing here is required to stop the stalls. It is required for the system to be the thing
it is documented to be.

### WP-8 — Give the proxy an upstream routing table

Replace the scalar `LLAMA_PORT` (`lib/proxy.lua:56`, used at `:1414`) with a route map:
`/v1/chat/completions`, `/infill`, `/props`, `/v1/models` → :8081; `/v1/embeddings`,
`/embedding` → :8082. Then bind :8081 and :8082 to loopback **unconditionally**, including
under `--lan`, and remove them from the firewall instructions at `scripts/install.sh:562`.

This is what makes :8080 an actual front door, and it is the precondition for adding
authentication in one place rather than three.

### WP-9 — Make the proxy a supervised service

`jenova-ca --daemon` never starts the proxy; it is `io.popen`'d as a child of the tray app
(`lib/ui.lua:67`). Consequences: headless runs have no :8080 at all; `status` doesn't report
it; `stop` doesn't stop it; and the watchdog's `_probe_health` targets **:8081**, so a wedged
proxy reads green everywhere and nothing restarts it.

- Start it from `jenova-ca --daemon`, record `PROXY_PID` (the variable exists at `:13` and is
  never assigned), report it in `status`, stop it in `stop`.
- **Point `_probe_health` at :8080.** This single change is what would have surfaced the
  entire class of failure in this report.
- Keep `proxy-serve` for the UI-attached case, but have `ui.init` attach to a running daemon
  rather than own one.

### WP-10 — Single owner for the embedding server

`embed.init()` probes `:8082/health` with a 1-second timeout and, on failure, spawns its own
server under a *different* pidfile than the one `jenova-ca` tracks. The embed model takes
seconds to load, so normal startup ordering triggers the race. Remove the spawn path
(`lib/embed.lua:50-71`); let `jenova-ca` own :8082 and have the proxy retry with backoff.

### WP-11 — Make `/health` tell the truth

`/health` reports `embed` = the return value of `embed.init()`, which is `true` when a
process was *started*, not when embeddings work. **Verified**: pointing the proxy at a dead
embed port still returns `{"status":"ok",...,"embed":true}`. Report actual reachability, and
fix `embed.init` to set `initialized` on the path where it starts a server.

### WP-12 — Decide about RAG

The proxy starts the embedding server, holds it in RAM, reports it healthy, and never queries
it: `search.index_dir` is never called from the proxy, so `total_docs == 0` and `search.query`
returns `{}` at `lib/search.lua:759` before doing anything. Either wire indexing in as a
background task (feasible once Phase 1 lands — `background_tasks` at `lib/proxy.lua:1528` is
declared, iterated, and never populated), or remove the path and stop launching :8082.

**Either is defensible. The current state — loading a model to never use it — is not.**

---

## Phase 4 — Cleanups and the language question

### WP-13 — Configuration and small breakages

- **Hardware-profile variable drift.** `Linux/CPU/generic`, `macOS/CPU/generic` and
  `macOS/Metal/generic` set `JENOVA_CTX_SIZE` / `JENOVA_NUM_SLOTS` / `JENOVA_THREADS`, while
  `jenova-ca` reads `CTX_SIZE` / `NUM_SLOTS` / `THREADS`. `detect-hardware.sh:345` copies the
  profile over `etc/jenova.conf`, so on those three platforms llama-server launches with
  `-c "" -np "" -t ""`. Add fallbacks in `jenova-ca` so the naming can't silently drift again.
- **`NUM_SLOTS` 1 → 2–4**, but only *after* Phase 1 and only with `CTX_SIZE` raised
  proportionally — llama.cpp splits context per slot (`n_ctx_slot = n_ctx / n_parallel`), so
  `-np 2 -c 8192` halves per-conversation context.
- `/cors-proxy` has no handler; `mcp.svelte.ts:114` probes it and always gets 404.
- `/api/fs` is missing from the vite dev proxy (`jca_web/vite.config.ts:91-99`).
- Model switching is disconnected: the WebUI calls llama.cpp ROUTER-mode `/models/load`
  (`models.service.ts:57`) against a server launched in single-model mode, while
  `bin/jenova-model-switch` swaps a symlink and needs a restart.

### WP-14 — Correct the documentation

`docs/architecture/backend.md` describes the intended design as built. Five claims are false
and should be corrected or removed, since they actively hid these defects:

| Claim | Reality |
|---|---|
| "coroutine-based **non-blocking** I/O" | every socket is blocking (WP-1) |
| "Async Sub-processes … yields to the scheduler" | `async_popen_read` throws on line 1 (WP-2) |
| "Background Discovery … performed asynchronously" | the endpoints hang permanently (WP-2) |
| "All accepted sockets are marked `FD_CLOEXEC`" | no-op, and never called on them (WP-1) |
| "Consumers [of :8082]: the proxy's RAG pipeline" | never issues a request (WP-12) |

### WP-15 — Revisit Lua vs Nim, with real numbers

Only meaningful after Phase 2. The honest framing:

Performance was never the issue. But **LuaJIT's C ABI surface is genuinely implicated** —
three of the four Phase 1 defects come from one variadic-argument mismatch a compiler would
have caught, and the fourth is an undefined ctype that failed only at runtime, inside a
`pcall`, invisibly, for the lifetime of the code. That is a real argument for a typed FFI,
and it is not the argument usually made for a rewrite.

Against a rewrite: the same defects cost ~30 lines to fix; ~3,500 lines of recently
security-audited code would be re-risked; Nim's default `asyncdispatch` is single-threaded
too; and it fixes none of WP-8 through WP-13, which live outside the proxy's language.

**Recommended middle path if the FFI surface remains a concern:** a compile-time-checked C
shim for the syscall layer (~100 lines) behind the existing `ffi_defs` interface. That
removes the entire bug class without touching application logic.

---

## Test strategy

The repo has no test that exercises the proxy at all — `tests/` covers config parsing, the
launcher, and GPU regexes. That is why these defects survived.

`tests/proxy-concurrency/` (added) is the start: a GPU-free harness with a stub backend that
emulates `-np` slots, and probes that **assert HTTP 200 and full token count** before
reporting timings. That assertion matters: during this investigation, 502 responses were
twice mistaken for fast successes.

Add alongside Phase 1:

| Test | Guards |
|---|---|
| two concurrent streams overlap | WP-1 |
| `GET /api/storage/` returns 200, no fd/process leak | WP-2 |
| half-open connection reaped within `JENOVA_CONN_TIMEOUT` | WP-3 |
| fd count flat across 100 sequential requests | WP-1, WP-2, WP-3 |
| `set_nonblocking`/`set_cloexec` unit assertions on a real fd | WP-1 regression |

The last one is worth its own file: a five-line test asserting `O_NONBLOCK` and `FD_CLOEXEC`
are actually set would have caught the root cause of this entire report.

---

## Summary

| Phase | Packages | Effect | Risk |
|---|---|---|---|
| **1** | WP-1..3 | Fixes the reported symptom. ~30 lines. **Ship together.** | Medium — switches the I/O model on for the first time |
| **2** | WP-4..7 | Removes needless load; makes the system fast rather than merely working | Low |
| **3** | WP-8..12 | Makes the topology match the documented design | Medium — touches process lifecycle |
| **4** | WP-13..15 | Config correctness, docs, language decision | Low |
