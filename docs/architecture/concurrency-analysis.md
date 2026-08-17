# Server / Proxy Topology and Concurrency Analysis

Second pass. The first version of this document analysed the proxy's *internals* and
missed the topology — which is where the actual problem lives. This version maps every
moving part in the server/proxy system, compares the implemented topology against the
intended one, and traces the observed stalls to a specific causal chain.

**Headline: the intended design is a single front door on :8080 with :8081 and :8082
behind it. That is not what is built.** :8082 is not proxied at all, and the proxy is not
a supervised service — it is a child process of the desktop tray app. Almost every
symptom follows from those two facts.

---

## 1. Intended vs. actual topology

### Intended

```
                    ┌──────────────────────────────┐
  clients ─────────►│  :8080  Intelligence Proxy   │
  (WebUI, API,      │  single front door           │
   Leo, LAN)        └───────┬──────────────┬───────┘
                            │              │
                   ┌────────▼──────┐  ┌────▼─────────────┐
                   │ :8081 llama   │  │ :8082 embed/RAG  │
                   │ (chat/infill) │  │ (vectors)        │
                   └───────────────┘  └──────────────────┘
                     bound to loopback only, never reachable directly
```

### Actual

```
  browser ──────────► :8080  proxy.lua ──────────► :8081  llama-server
                        ▲         │
                        │         └──(in-process client, lib/embed.lua)──┐
                        │                                                │
  spawned by io.popen   │                                                ▼
  from lib/ui.lua ──────┘                                        :8082  embed server
                                                                        ▲
  jenova-ca --daemon ───────────────────────────────────────────────────┘
     (also starts one; two owners, one port)

  LAN mode: :8080, :8081 AND :8082 all bind 0.0.0.0, no auth on any of them.
```

The gap between these two diagrams is the report.

---

## 2. The moving parts, in full

| Component | What it is | Who starts it | Who supervises it |
|---|---|---|---|
| `:8081` llama-server | C++ chat/infill backend | `jenova-ca --daemon` | watchdog (PID + `/health`) |
| `:8082` llama-server `--embedding` | C++ embedding backend | `jenova-ca --daemon` **and/or** `lib/embed.lua` | watchdog, *only* if jenova-ca started it |
| `:8080` `lib/proxy.lua` | LuaJIT front door | `lib/ui.lua` via `io.popen(... proxy-serve, "w")` | **nobody** |
| `jenova-ui` / `jenova-tui` | GTK tray / ncurses TUI (C + Lua) | user | — |
| `lib/indexer_runner.lua` | background embedder | `search.index_dir` (never called in proxy) | pidfile only |
| `jca_web` | SvelteKit UI | browser | — |

### 2.1 The proxy is not a daemon

`bin/jenova-ca --daemon` starts llama-server (`_launch_llama_server_bg`, `:216`) and the
embed server (`:694-710`), polls `/health`, then writes the pidfile:

```sh
printf '%s' "$LLAMA_PID${EMBED_PID:+ $EMBED_PID}" > "$PID_FILE"
```

`PROXY_PID` is declared at `bin/jenova-ca:13` and never assigned. `OLD_PROXY_PID` is
printed at `:670` and never read. **`jenova-ca --daemon` never starts the proxy.**

The proxy is started only by `lib/ui.lua:67`:

```lua
ui._proxy_handle = io.popen(shell_quote(root .. "/bin/jenova-ca") .. " proxy-serve " .. lan_arg, "w")
```

`proxy-serve` (`bin/jenova-ca:419-427`) `exec`s `luajit proxy.lua --watch-stdin`. The
`--watch-stdin` flag exists precisely because the proxy's lifetime is bound to that pipe:
`lib/proxy.lua:1586-1593` shuts down on stdin EOF ("parent process died").

Consequences, all of them load-bearing:

1. **Headless = no proxy.** Running `jenova-ca start` over SSH brings up :8081 and :8082
   and nothing on :8080.
2. **`jenova-ca status` does not report the proxy.** It reports llama-server and embed
   (`:385-404`). The "ACTIVE" light in the tray/TUI means llama-server is up.
3. **`jenova-ca stop` does not stop the proxy.** It kills the pidfile PIDs and `pkill`s
   llama-server by port. :8080 stays bound, now 502-ing.
4. **The watchdog does not watch the proxy.** `bin/jenova-ca:491` iterates
   `"llama-server:$_W_LLAMA" "embed:$_W_EMBED"` only, and its health probe is:

   ```sh
   _url="http://${CONNECT_HOST}:${LLAMA_PORT}/health"   # :8081, not :8080
   ```

   **If the proxy wedges — which is the reported symptom — every health signal in the
   system still reads green, and nothing restarts it.** This is why a stall feels like it
   has no cause: nothing is looking at the component that stalled.
5. **The UI polls by forking.** `jenova-ui/src/main.c:392` — `g_timeout_add_seconds(3, ...)`
   → `ui.poll_status()` → `io.popen("jenova-ca status")`, a shell script that sources four
   config files and forks `curl`. In the TUI the same call sits inside the render loop with
   `timeout(1000)` (`main.c:512`), so it runs **once per second**. Plus `ip route` /
   `ifconfig` forks when LAN mode is on (`lib/ui.lua:170-190`).

### 2.2 :8082 is not behind the proxy

`lib/proxy.lua` has exactly one upstream. `LLAMA_PORT` (`:56`) is a scalar, used at `:1414`
for the only outbound connect. There is no route, no upstream table, and no
`/v1/embeddings` endpoint.

The proxy reaches :8082 as an ordinary HTTP *client*, from inside its own process:

```lua
-- lib/embed.lua:26
local EMBED_URL = os.getenv("JENOVA_LLAMA_EMBED_URL") or "http://127.0.0.1:8082"
-- lib/embed.lua:107
local status, body = http.post(EMBED_URL .. "/embedding", payload, 30)
```

So the embedding backend is a *dependency* of the proxy, not a *service behind* it. Nothing
outside the proxy process can reach embeddings through :8080. `POST /v1/embeddings` to
:8080 is forwarded to :8081 — the chat model, loaded without `--embedding` — and errors.

`scripts/install.sh:562` makes the drift explicit:

> the firewall allows ports 8080, 8081, and 8082 from this host.

That instruction is only necessary *because* the front door isn't one.

### 2.3 Two owners for :8082

`lib/proxy.lua:63` calls `embed.init()` at startup. `lib/embed.lua:43` probes
`:8082/health` with a **1-second** timeout; on failure it spawns its own embedding server
via `daemon.start_background` with pidfile `$JENOVA_STATE/llama-embed.pid`
(`lib/embed.lua:66`) — a different pidfile from the `EMBED_PID` that `jenova-ca` tracks.

The embed model takes several seconds to load. If the proxy starts during that window —
which is the normal case, since the tray app starts the proxy immediately — the 1 s probe
fails and a **second** `llama-server --embedding` is spawned against an already-claimed
port. The loser fails to bind and dies, but `daemon.start_background` writes its pidfile on
successful `fork`, not on successful bind, so the pidfile is written either way.

`jenova-ca stop` deletes `llama-embed.pid` (`:372`) without killing that PID; the trailing
`pkill -f "llama-server.*--port.*${LLAMA_EMBED_PORT}"` (`:378`) is what actually cleans up —
a blunt instrument that would kill any llama-server on that port.

### 2.4 The embedding path is inert, and `/health` lies about it

Three independent breaks, any one of which is sufficient:

- `embed.init()` returns `true` after *starting* a server but never sets
  `initialized = true` (`lib/embed.lua:66-69`), so `embed.encode` returns
  `"not initialized"` forever on that path.
- `search.init_embeddings` is only called from `lib/indexer_runner.lua:34`, so the
  module-local `embed` in `search.lua` is `nil` inside the proxy.
- `search.index_dir` is never called from the proxy (deliberately deferred,
  `lib/proxy.lua:1521-1523`), so `total_docs == 0` and `search.query` returns `{}` at
  `lib/search.lua:759` before doing anything.

And `/health` reports `embed = embed_ok`, where `embed_ok` is the return of `embed.init()` —
i.e. "I started a process", not "embeddings work". **The health endpoint reports the RAG
subsystem as healthy while it is completely non-functional.**

### 2.5 No auth, no CORS, on any of the three ports

`grep -i "access-control\|authorization\|bearer" lib/proxy.lua` → nothing. `--lan` sets
`HOST=0.0.0.0` (`bin/jenova-ca:331`) and `--host "$HOST"` is passed to **both** llama-server
and the embed server. In LAN mode all three ports are open to the network with no
authentication and no rate limiting, and :8081/:8082 bypass the proxy's persona, RAG, and
path-traversal checks entirely.

The missing CORS headers also mean the Jenova-native endpoints (`/api/db`, `/api/fs`,
`/api/storage`) only work same-origin — so the "external integrations such as the Leo
browser" described in `docs/architecture/overview.md` can reach the OpenAI surface but not
the workspace surface.

---

## 3. The causal chain behind the stalls

This is the specific sequence, and it explains why it feels like "everything goes through
one endpoint and blocks."

**`SyncService.syncEntity("chat", convId)` runs on every message completion**
(`jca_web/src/lib/stores/conversations.svelte.ts:524`, `:560`, `:630`). Inside it
(`sync.service.ts:453-494`):

```ts
const conv     = await DatabaseService.getConversation(id);        // GET  /api/db/conversations
const messages = await DatabaseService.getConversationMessages(id);// GET  /api/db/messages
const files    = await StorageService.list();                      // GET  /api/storage/   ◄── blocks
await StorageService.save(path, md);                               // POST /api/storage/...
```

`GET /api/storage/` lands on `lib/proxy.lua:1053-1080`, which calls `async_popen_read` — a
function that, despite its name, **forks and then runs its own private `select()` loop and
never calls `coroutine.yield`** (`lib/proxy.lua:182-240`). For the whole duration of that
`find`, the single event loop is frozen: no accepts, no other coroutines, and no token
relaying for any in-flight stream.

Measured on a 2,000-file workspace tree, warm cache, idle container:

| Endpoint | Entries | Wall time, loop frozen |
|---|---|---|
| `GET /api/storage/` | 2,125 | **14–17 ms** |
| `GET /api/fs/tree` | 2,125 | **2,872 ms** (2,125 `fork`+`exec`) |

Then stack the rest on top:

- **Every request is a new TCP connection.** The proxy forces `Connection: close` on its
  own responses and rewrites the upstream request the same way (`lib/proxy.lua:1191-1192`,
  `1355-1358`). One `syncEntity` = ~5 connect/parse/teardown cycles.
- **The accept path takes one connection per event-loop pass** (`lib/proxy.lua:1595`), and
  the listen backlog is 16 (`:1515`), against `MAX_ACTIVE_CONNECTIONS = 32` (`:98`). A
  burst plus a frozen loop overflows the accept queue; the browser sees resets, and past
  32 it sees `503 Retry-After: 5` (`:1601`).
- **`-np 1`.** `etc/jenova.conf:88` → `NUM_SLOTS=1` → `bin/jenova-ca:231` passes `-np 1`.
  llama-server processes one request at a time. Even after the loop unfreezes, a second
  chat, a title generation, or an embedding call queues behind the first.
- **Nothing notices.** Per §2.1, the watchdog is probing :8081 and sees green throughout.

So: message completes → sync fires → `find` freezes the front door → queued connections
pile up behind a 16-deep backlog → the loop resumes → requests hit a backend with one slot
→ health checks report everything fine.

`GET /api/fs/tree` (the file explorer) is the same story with a 2.9-second freeze instead
of a 15 ms one, because `fs_sync.get_fs_tree` forks `test -d` **per entry**
(`lib/fs_sync.lua:445`) on top of a blocking `io.popen`. `fs_sync.get_trash` (`:299`,
`:323`) and `empty_trash` (`:384`) use blocking `io.popen` too.

### Secondary costs on the same thread

Real, but an order of magnitude smaller than the above:

- **SHA-256 on every chat request** (`lib/proxy.lua:1371`), measured at **16–26 MB/s**
  (15 ms @ 256 KB, 43 ms @ 1 MB) — feeding a cache that holds 20 entries
  (`lib/db.lua:862`) and can never hit for a growing conversation.
- **Synchronous SQLite** with no prepared-statement cache, re-preparing on every call and
  calling `sqlite3_column_name` + `ffi.string` per row per column (`lib/db.lua:210-275`).
  `db.get_all_messages()` (`:430`) is an unbounded `SELECT *`, reached from
  `DatabaseService.exportData()` → `SyncService.push()`.
- **Pure-Lua JSON**: 0.36 MB payload = **27 ms encode / 16 ms decode**.
- **`async_send` is O(n²)** — `data:sub(sent + 1)` copies the remainder on every partial
  send (`lib/proxy.lua:157`). A 1 MB body copies 64 MB; a 4 MB body copies 1 GB.

---

## 4. Is Lua the cause? Does Nim fix it?

### Is Lua the cause — no, and the reason is sharper than "Lua is fast enough"

The system has **one process, one thread, one event loop, one upstream, and no
supervision** — and that process is owned by a GUI application. Every stall traces to that
topology:

- A blocking `find` freezes the front door because there is only one loop *and nowhere
  else to put the work*.
- Inference serializes because there is one slot.
- Nothing recovers because the only supervisor is watching a different port.
- The embedding backend can't be reached through the front door because the proxy has one
  hardcoded upstream.

None of these are properties of LuaJIT. `async_popen_read` is four lines from being
correct — the fd is already non-blocking and CLOEXEC, it simply needs `coroutine.yield`
instead of its own `select`. That is a bug, not a language limit.

### Does Nim fix it — not by itself, and the honest case for it is different

Nim's real advantage here is threads: you could put SQLite and filesystem walks on a
worker pool instead of the reactor. That is genuinely relevant. But:

- `-np 1` is untouched. Inference stays serialized.
- `os.execute` per file is still per file unless you also fix the algorithm.
- A blocking call inside an `async` proc blocks Nim's dispatcher exactly as it blocks
  LuaJIT's loop. Default `asyncdispatch` is single-threaded.
- The topology problems — proxy owned by the tray app, watchdog probing the wrong port,
  no upstream routing table, no auth — are all *outside* the proxy's language.
- You would rewrite ~3,500 lines of working, recently security-audited code (two command
  injection fixes in the last five commits) to buy ~40 ms per request.

**The multi-threading you actually want can be had without a rewrite**, because the fix is
process topology, not concurrency primitives: put slow work in worker processes and talk to
them over `socketpair(2)`, whose fds drop straight into the existing `select` sets. The
scaffolding for this already exists and is unused — `background_tasks` (`lib/proxy.lua:1528`)
is declared, added to the select sets, iterated, and never populated.

If after §5 the remaining hot spots are genuinely JSON and hashing, replace *those
functions* with a C or Nim shared library through LuaJIT's FFI — a couple of hundred lines.
`lib/db.lua` already demonstrates the pattern with SQLite.

A full Nim rewrite is a legitimate conversation, justified by maintainability rather than
throughput, and it should happen after the topology is right — otherwise you port the bugs.

---

## 5. Plan

Ordered by ratio of symptom relief to risk. Nothing here is implemented; this document is
the deliverable for review.

### Tier 0 — stop the bleeding (config + a few lines)

1. **`NUM_SLOTS` 1 → 2–4**, raising `CTX_SIZE` proportionally where VRAM allows. Note
   llama.cpp divides context among slots (`n_ctx_slot = n_ctx / n_parallel`), so `-np 2 -c 8192`
   halves per-conversation context; `-c 16384` keeps 8k per slot at roughly +128 MiB KV on
   the 3B/`q8_0` profile, which has 512 MiB of reserve.
2. **Give the embed server `-np 2`** so RAG lookups stop head-of-line-blocking each other.
3. **Cache `StorageService.list()`** in `sync.service.ts` the way `getHierarchy()` is
   already cached (10 s TTL, `sync.service.ts:437`). It is called only to find a stale path
   for a rename. This removes the per-message `find` immediately, from the client side,
   without touching the proxy.
4. **Fix the hardware-profile variable-name drift.** `Linux/CPU/generic`,
   `macOS/CPU/generic` and `macOS/Metal/generic` set `JENOVA_CTX_SIZE` / `JENOVA_NUM_SLOTS` /
   `JENOVA_THREADS` / `JENOVA_NGL`, while `jenova-ca` reads `CTX_SIZE` / `NUM_SLOTS` /
   `THREADS` / `NGL_AGENT`. `detect-hardware.sh:345` copies the profile over
   `etc/jenova.conf`, so on those three platforms llama-server is launched with
   `-c "" -np "" -t ""`. Only `BATCH_SIZE`/`UBATCH_SIZE` have fallbacks (`jenova-ca:175`).

### Tier 1 — make the event loop non-blocking (~200 LOC)

5. **Make `async_popen_read` actually yield.** Delete its private `select()` loop; on
   `EAGAIN`, `coroutine.yield("read", fd)`. Keep the 15 s wall-clock deadline. ~15 lines,
   and it fixes `/api/storage/`, `/api/workspaces`, and the 13-second web-search freeze at
   once.
6. **`get_fs_tree`: one fork instead of N.** Replace the per-entry `os.execute('test -d')`
   with a single `find -printf '%y\t%p\0'` (GNU) or `-type d` two-pass (BSD). The stat
   flavour is already detected at `lib/search.lua:147-164`. 2.87 s → ~10 ms.
7. **Route `fs_sync`'s blocking `io.popen` calls through the fixed async helper.**
8. **Delete the SHA-256 / `llm_cache` intercept** (`lib/proxy.lua:1371-1386`, `1434-1482`).
9. **Fix `async_send`** to advance a `const char*` offset instead of `data:sub`.
10. **Bound `get_all_messages`**, or drop it in favour of `messages?convId=`.
11. **Accept in a loop until `EAGAIN`**, and raise the listen backlog from 16.

### Tier 2 — fix the topology (this is the real answer to the question)

12. **Give the proxy a real upstream routing table.** Replace the scalar `LLAMA_PORT` with
    a map, so `/v1/chat/completions`, `/infill`, `/props`, `/v1/models` → :8081 and
    `/v1/embeddings`, `/embedding` → :8082. Then bind :8081 and :8082 to loopback
    unconditionally, even under `--lan`, and drop them from the firewall instructions in
    `scripts/install.sh:562`. This is what makes :8080 an actual front door, and it is a
    precondition for adding auth in one place.
13. **Make the proxy a supervised daemon.** Start it from `jenova-ca --daemon`, record
    `PROXY_PID` in the pidfile (the variable already exists), report it in `status`, stop it
    in `stop`, and — critically — **point `_probe_health` at :8080 instead of :8081**, so
    the watchdog is probing the front door. Keep `proxy-serve` for the UI-attached case, but
    have `ui.init` attach to a running daemon rather than owning one. Fixes headless
    operation, "nothing noticed the stall", and the tray's misleading ACTIVE light.
14. **Single owner for the embed server.** Remove the spawn path in `lib/embed.lua:50-71`;
    let `jenova-ca` own :8082, and have the proxy retry the health probe with backoff instead
    of racing to start its own.
15. **Split the control plane from the data plane.** `/api/db` + `/api/fs` and inference
    proxying share nothing but a port number and have opposite latency profiles. Either give
    the DB/FS API its own listener, or — better — hand SQLite and filesystem work to worker
    processes over `socketpair(2)` and populate the existing `background_tasks` queue. The
    main loop then stays pure I/O, which is the multi-threading benefit without the rewrite.
16. **HTTP keep-alive**, and replace `select()` with `poll()`/`epoll`/`kqueue`.
17. **Cut the UI's fork-per-poll.** `ui.poll_status` shelling out to `jenova-ca status`
    every 1–3 seconds should become a single `GET :8080/health`, which the proxy already
    answers natively and cheaply (`lib/proxy.lua:527-585`) — and which, unlike the current
    probe, actually tests the front door.

### Tier 3 — decide about RAG

18. §2.4 means the embedding server is loaded, held in RAM, reported healthy, and never
    queried. Decide: wire `search.index_dir` in as a background task (possible once Tier 2
    lands), or remove the path and stop launching :8082. Either is defensible; the current
    state is the worst of both. If re-enabled, fix `embed.init` to set `initialized`, make
    `/health` report actual embedding availability rather than "a process was started", and
    note that `embed.cosine` (`lib/embed.lua:159`) recomputes both norms on every call
    despite the vectors being pre-normalised.

### Tier 4 — targeted native code, only if measurement demands it

19. Swap specific hot functions (JSON, hashing, vector math) for a small C/Nim FFI library.
    Not a rewrite.

### Smaller independent fixes

20. **`/cors-proxy` has no handler.** `jca_web/vite.config.ts:98` proxies it and
    `mcp.svelte.ts:114` probes it with `HEAD`; the proxy has no route and no HEAD handling,
    so it falls through to :8081 and 404s. MCP-over-CORS-proxy is permanently unavailable.
21. **`/api/fs` is missing from the vite dev proxy** (`vite.config.ts:91-99`), so trash and
    file-tree calls don't reach the backend under `vite dev`.
22. **Model switching is disconnected.** `bin/jenova-model-switch` swaps a symlink and
    requires a full llama-server restart, while the WebUI calls llama.cpp ROUTER-mode
    `/models/load` and `/models/unload` (`models.service.ts:57-88`) against a server launched
    in single-model mode. Neither half knows about the other.

---

## 6. Measurements

LuaJIT 2.1.1703358377, repo modules, idle container, warm page cache. A laptop running
llama-server should be assumed 3–5× slower.

| Measurement | Result |
|---|---|
| `GET /api/fs/tree`, 2,125 entries | **2,872 ms** wall, 2,125 forks, loop frozen |
| `GET /api/storage/`, 2,125 entries | **14–17 ms** wall, loop frozen |
| `sha256.lua` | 15.6 MB/s @16 KB · 16.7 MB/s @256 KB · 23.5 MB/s @1 MB |
| `json.lua`, 0.36 MB | encode 27.1 ms · decode 15.7 ms |
| `async_send` amplification | 1 MB body → 64 MB copied; 4 MB → 1 GB |

Before implementing Tier 1, it is worth adding elapsed-time logging around each route
handler in `proxy_connection` — the dispatch logging at `lib/proxy.lua:1364-1368` is the
natural place — to confirm this ranking against a real session rather than synthetic trees.

---

## 7. Documentation drift

`docs/architecture/backend.md` describes the intended design as though it were built. Four
claims are false against the current code, and they are worth correcting so the docs stop
masking the gaps:

| Claim | Reality |
|---|---|
| "Async Sub-processes … yields to the scheduler while waiting for output" | `async_popen_read` never yields (`lib/proxy.lua:182`) |
| "Background Discovery: directory crawling and workspace listing are performed asynchronously" | both block the loop (§3) |
| "Inbound storage updates trigger asynchronous background re-indexing" | no reindex trigger exists in the proxy |
| "Consumers [of :8082]: the proxy's RAG pipeline and the codebase indexer" | the proxy's RAG pipeline never issues a request (§2.4) |
