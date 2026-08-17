# Concurrency Analysis: Proxy, Server, and the Single-Endpoint Bottleneck

Investigation of the request path through `lib/proxy.lua`, `bin/jenova-ca`, and the
supporting libraries, prompted by stalls attributed to "the single-threaded nature of
everything being passed through one endpoint."

**Verdict: the design is the problem, not Lua.** A Nim (or C, or Rust) rewrite of the
proxy would fix roughly 2% of the observed stall time. The stalls are seconds long; the
language-attributable cost is tens of milliseconds. Details and measurements below.

---

## 1. How the wiring actually works

```
browser ──► :8080  lib/proxy.lua  (LuaJIT, single process, single OS thread)
                     │
                     ├─ /health                 answered locally
                     ├─ /api/fs/*               fs_sync.lua   → find(1), test(1), rename
                     ├─ /api/db/*               db.lua        → SQLite via FFI
                     ├─ /api/storage/*          io.open / find(1)
                     ├─ /api/workspaces         find(1)
                     ├─ GET /<static>           public/ off disk
                     └─ everything else ───────► :8081  llama-server (C++)
                                                  └─ RAG hook → :8082 llama-server --embedding
```

`lib/proxy.lua:1551` is one `select(2)` loop. Each accepted connection becomes a Lua
coroutine (`lib/proxy.lua:1608`). The coroutine yields `("read"|"write", fd)` and the loop
re-arms it when that fd is ready. This is a correct, ordinary single-threaded reactor —
and for pure socket relaying it is genuinely fine.

The problem is what runs *between* the yields.

**Every request is a fresh TCP connection.** The proxy sets `Connection: close` on its own
responses and rewrites the upstream request to `Connection: close`
(`lib/proxy.lua:1191-1192`, `1355-1358`). No keep-alive anywhere. The frontend
(`jca_web/src/lib/services/database.service.ts`) makes many small sequential calls —
`updateConversation` does a `GET` then a `POST`, `deleteMessageCascading` issues one
request per message — so a single UI action can mean dozens of connect/parse/teardown
cycles.

**`MAX_ACTIVE_CONNECTIONS = 32`** (`lib/proxy.lua:98`). Past that the proxy returns
`503 Service Unavailable` with `Retry-After: 5` (`lib/proxy.lua:1601`). When the loop is
blocked (see §2) connections queue and this ceiling is reached quickly. If you are seeing
sporadic 503s, this is where they come from.

---

## 2. The real serialization points, ranked

### 2.1 `NUM_SLOTS=1` — the single inference slot

`etc/jenova.conf:88` and `hardware-profiles/Linux/Vulkan/dgpu/gtx-1650ti/jenova.conf:88`:

```sh
NUM_SLOTS="${JENOVA_SLOTS:-1}"
```

Passed to llama-server as `-np 1` (`bin/jenova-ca:231`, `:796`). **llama-server processes
exactly one request at a time.** Concurrency in the proxy is irrelevant to inference
latency: two chats, or a chat plus a title generation, or a chat plus an embedding call,
serialize at the backend regardless of what language the proxy is written in.

This is the single largest contributor to "it feels single-threaded," and it is a
one-character config change.

Caveat: llama.cpp divides the context window among slots (`n_ctx_slot = n_ctx /
n_parallel`). Going from `-np 1 -c 8192` to `-np 2 -c 8192` halves per-conversation
context to 4096. To keep 8k per slot you need `-c 16384`, which costs VRAM for KV cache.
With `q8_0` KV on a 3B model that is roughly +128 MiB — affordable on the 4 GiB profile,
which currently reserves 512 MiB of headroom.

The embedding server on :8082 is started with no `-np` at all
(`bin/jenova-ca:700-710`, `:817-826`), so it is also one slot, CPU-only, and shares
`-t $THREADS` with the main model.

### 2.2 `get_fs_tree` forks a process **per file**

`lib/fs_sync.lua:435-448`:

```lua
local p = io.popen('find ' .. sq(search_root) .. ' -mindepth 1 ... -print0')
local output = p:read("*a")          -- blocking read, no yield
...
for line in output:gmatch(...) do
    local is_dir = os.execute('test -d ' .. sq(line)) == 0   -- fork+exec PER ENTRY
```

Measured on this (fast, idle) container: **320 entries → 470 ms wall**. On a laptop with
llama-server holding 4–8 threads on the CPU, expect 1.5–3 s for a few hundred files.

This is a hard freeze of the entire event loop. Nothing else is serviced — not the health
check, not `/api/db`, and not an in-flight token stream. `GET /api/fs/tree` is a routine
UI call.

The `io.popen` is also the blocking Lua one, not the async variant, and `fs_sync.get_trash`
(`lib/fs_sync.lua:299`, `:323`) and `fs_sync.empty_trash` (`:384`) have the same problem.

### 2.3 `async_popen_read` is not async

`lib/proxy.lua:182-240`. Despite the name, it forks and then runs its **own** `select()`
loop with a 100 ms tick and a 15 s deadline. It never calls `coroutine.yield`. The fd is
set non-blocking and CLOEXEC — everything is in place to yield — but it doesn't.

Reachable from:

- `GET /api/storage` directory listing (`lib/proxy.lua:1065`)
- `GET /api/workspaces` (`lib/proxy.lua:1094`)
- web search, via `ddg_html_search` (8 s timeout) then `ddg_instant_answer`
  (5 s timeout) — `lib/proxy.lua:381-397`

The comment at `lib/proxy.lua:379-380` acknowledges this ("Blocks the calling coroutine
for up to ~13 seconds worst case. Acceptable: single-user system"). It does not block the
calling coroutine — it blocks *every* coroutine, including live token streams. **A web
search freezes the whole proxy for up to 13 seconds.**

### 2.4 Synchronous SQLite on the loop thread

`lib/db.lua` is a direct FFI binding, all calls synchronous. Every `/api/db/*` request
blocks the loop for the duration of the query plus JSON marshalling.

`execute_query` (`lib/db.lua:210`) prepares and finalizes a statement on every call — no
prepared-statement cache — and calls `sqlite3_column_name` + `ffi.string` **per row, per
column**. `db.get_all_messages()` (`lib/db.lua:430`) does `SELECT * FROM messages` with no
limit: for 5,000 messages that is 70,000 needless string allocations before any JSON is
produced.

Measured `lib/json.lua` throughput: a 0.36 MB conversation payload takes **27 ms to
encode, 16 ms to decode** here; 3–5× that on a loaded laptop.

### 2.5 The SHA-256 cache intercept buys nothing and costs on every request

`lib/proxy.lua:1371-1386` hashes the entire rewritten chat body with the pure-Lua SHA-256
in `lib/sha256.lua`, then does a SQLite lookup, on **every** `/v1/chat/completions`.

Measured throughput of `lib/sha256.lua`: **16–26 MB/s** (1.0 ms @ 16 KB, 15 ms @ 256 KB,
43 ms @ 1 MB). `str2blk` (`lib/sha256.lua:25-44`) builds a Lua table one byte at a time
with a `math.floor` per byte, which is most of the cost.

And the cache can essentially never hit: `db.set_cache` (`lib/db.lua:862`) keeps **20
entries**, and every turn of a growing conversation produces a different body. Meanwhile
`set_cache` runs a `COUNT(*)` and a `DELETE` on every write, and stores up to 50 MB of
response blob in SQLite (`lib/proxy.lua:1436`).

This is pure overhead on the hot path. It should be deleted, not optimized.

### 2.6 `async_send` is O(n²)

`lib/proxy.lua:157`:

```lua
local n = ffi.C.send(fd, data:sub(sent + 1), #data - sent, 0)
```

`data:sub(sent + 1)` copies the entire remainder of the string on every partial send.
Simulated with 8 KB partial sends: a 1 MB body copies **64 MB**; a 4 MB body copies
**1 GB**. It only triggers when the socket buffer fills, so streaming (8 KB chunks) is
safe, but large static assets, `/api/storage` file reads, and `messages/all` responses hit
it. Fix is a `const char*` pointer plus offset — no copy.

### 2.7 Blocking `getaddrinfo` on the non-loopback health path

`lib/proxy.lua:550-566`. The `127.0.0.1` fast path is fine; any other
`LLAMA_CONNECT_HOST` calls `getaddrinfo` synchronously on the loop thread. Minor, but it
is a DNS timeout waiting to happen on LAN-bound setups.

---

## 3. Functional defects found along the way

These are not performance issues but they materially change what the system does.

### 3.1 RAG is dead in the proxy

`lib/proxy.lua:1253` calls `search.query(...)`. But `search.query` returns `{}`
immediately when `total_docs == 0` (`lib/search.lua:759`), and `total_docs` is only ever
incremented by `bm25_index_file`, which is only reached via `search.index_dir` or
`search.reindex_file`. **Neither is called anywhere in `lib/proxy.lua`** — indexing was
deliberately deferred (`lib/proxy.lua:1521-1523`) and never re-enabled.

`search.init_embeddings` is likewise only called from `lib/indexer_runner.lua:34`, so the
module-level `embed` in `search.lua` is `nil` in the proxy process and the semantic half
never runs either.

Net effect: the proxy starts the embedding server on :8082, holds it in memory, and never
sends it a request. Every "REPOSITORY CONTEXT" injection documented in
`docs/architecture/overview.md` §3 is a no-op. This is worth knowing *before* optimizing
the RAG path — there is currently no RAG path to optimize.

### 3.2 Three hardware profiles pass empty arguments to llama-server

`bin/jenova-ca` reads `CTX_SIZE`, `NUM_SLOTS`, `THREADS`, `THREADS_BATCH`, `NGL_AGENT`,
`DEVICES`. These profiles set `JENOVA_`-prefixed names instead and never assign the
unprefixed ones:

| Profile | Sets | jenova-ca reads |
|---|---|---|
| `Linux/CPU/generic` | `JENOVA_CTX_SIZE`, `JENOVA_NUM_SLOTS`, `JENOVA_THREADS`, `JENOVA_NGL`, `JENOVA_DEVICES` | `CTX_SIZE`, `NUM_SLOTS`, `THREADS`, `NGL_AGENT`, `DEVICES` |
| `macOS/CPU/generic` | same | same |
| `macOS/Metal/generic` | same | same |

`detect-hardware.sh:345` copies the matched profile over `etc/jenova.conf`, so on those
three platforms llama-server is launched as `-c "" -np "" -t "" -tb ""`. Only
`BATCH_SIZE`/`UBATCH_SIZE` have fallbacks in `jenova-ca` (`:175-176`).

### 3.3 `/cors-proxy` has no handler

`jca_web/vite.config.ts:98` proxies `/cors-proxy` to :8080 and
`jca_web/src/lib/stores/mcp.svelte.ts:114` calls it, but `lib/proxy.lua` has no route for
it. The request falls through to the generic llama-server forward and 404s.

### 3.4 `/api/fs` is missing from the dev proxy

`jca_web/vite.config.ts:91-99` lists `/v1`, `/api/storage`, `/api/workspaces`, `/api/db`,
`/props`, `/models`, `/cors-proxy` — but not `/api/fs`. Trash and file-tree calls do not
reach the backend under `vite dev`.

### 3.5 Dead scaffolding

`background_tasks` (`lib/proxy.lua:1528`) is declared, added to the select sets, and
iterated — but nothing ever inserts into it. The mechanism for off-loop work exists and is
unused; §5 proposes using it.

---

## 4. Answering the question directly

### Is Lua the cause?

No. Break the stall budget down:

| Cost | Source | Language-attributable? |
|---|---|---|
| ∞ (serialized) | `-np 1` at llama-server | **No** — C++ backend config |
| 0.5–3 s | fork-per-file in `get_fs_tree` | **No** — algorithm |
| up to 13 s | `async_popen_read` not yielding | **No** — it is 4 lines from being correct |
| 10–200 ms | SQLite + JSON on the loop thread | Partly — but the fix is off-loop, not faster |
| 15–40 ms | SHA-256 per chat request | Yes — and the code should be *deleted* |
| 1–60 ms | `async_send` O(n²) | **No** — algorithm |

LuaJIT's actual weaknesses show up in exactly two places: `sha256.lua` (16–26 MB/s vs
~500 MB/s in C, ~2 GB/s with hardware SHA) and `json.lua` (13–23 MB/s vs 1–3 GB/s for a
tuned C parser). Both are 20–100× penalties in the abstract. In practice they are worth
tens of milliseconds per request against stalls measured in seconds.

Everything else in the hot path is FFI syscalls and `memcpy` on 8 KB buffers. That code
runs at the same speed in any language, because it *is* the same code — LuaJIT is calling
`recv`/`send` directly.

### Does replacing Lua with Nim solve it?

Not on its own, and a rewrite would probably reproduce the same bugs. Nim gives you real
threads and `async`/`await`, which is genuinely nicer than hand-rolled coroutine yields —
but:

- `-np 1` is untouched. Inference stays serialized.
- `os.execute` per file is still `os.execute` per file unless you also fix the algorithm.
- A blocking call inside an `async` proc blocks Nim's dispatcher exactly as it blocks
  LuaJIT's `select` loop. Nim's default `asyncdispatch` is single-threaded too.
- You would be rewriting ~3,500 lines of working, security-audited code (two CVE fixes
  landed in the last five commits) to buy ~40 ms per request.

The honest case *for* Nim is different from the one implied by the question: it is not
"Lua is slow," it is "hand-rolled coroutine plumbing is error-prone and a language with
real threads plus a mature async library is easier to keep correct." That is a legitimate
argument, but it is a 2–4 week project and it should be made after the design is fixed,
not instead of fixing it — otherwise you port the bugs.

### Is there a smaller, simpler fix?

Yes. See below. Tiers 0 and 1 are a few hours and address the seconds-scale stalls.

---

## 5. Proposed plan

Staged so each tier is independently shippable and measurable. **Nothing here has been
implemented — this document is the deliverable for review.**

### Tier 0 — config only (minutes, no code)

1. Raise `NUM_SLOTS` to 2–4 across profiles, raising `CTX_SIZE` proportionally where VRAM
   allows. This alone unblocks concurrent chat + title-gen + embedding.
2. Give the embedding server its own `-np 2` so RAG lookups stop head-of-line-blocking
   each other.
3. Fix the `JENOVA_*` variable-name mismatch in the three broken profiles (§3.2), or add
   `CTX_SIZE="${CTX_SIZE:-${JENOVA_CTX_SIZE:-8192}}"`-style fallbacks in `jenova-ca` so
   the naming drift cannot silently produce empty flags again.

**Expected effect: the largest single win, for the least work.**

### Tier 1 — unblock the event loop (~200 LOC, low risk)

4. **`get_fs_tree`: one fork instead of N.** Replace the `os.execute('test -d')` loop with
   a single `find ... -printf '%y\t%p\0'` (GNU) / `find ... -type d` two-pass or
   `-exec stat` (BSD) — the codebase already detects stat flavour in
   `lib/search.lua:147-164` and can reuse that. 470 ms → ~5 ms.
5. **Make `async_popen_read` actually yield.** Delete its private `select()` loop; the fd
   is already non-blocking, so `coroutine.yield("read", fd)` on `EAGAIN` hands control back
   to the main loop. Keep the 15 s deadline as a wall-clock check. This turns the 13-second
   web-search freeze into a background wait. ~15 lines.
6. **Route `fs_sync`'s three `io.popen` sites through the now-async helper** so trash
   listing and emptying stop blocking.
7. **Delete the SHA-256 / `llm_cache` intercept** on the chat path (`lib/proxy.lua:1371-1386`,
   `1434-1482`). It cannot hit for a growing conversation, and it costs 15–40 ms plus two
   SQLite round-trips per request. If response caching is wanted later, key it on something
   that can actually repeat and put it behind a config flag.
8. **Fix `async_send`** to advance a `const char*` pointer instead of `data:sub(sent+1)`.
   ~5 lines.
9. **Bound `get_all_messages`** — add `LIMIT`/pagination, or drop the endpoint if the UI
   can use `messages?convId=`.

**Expected effect: no single request can freeze the loop for more than ~50 ms.**

### Tier 2 — structural, addresses "one endpoint" directly (~1 day)

10. **Split the control plane from the data plane.** The DB/FS API and inference proxying
    have completely different latency profiles and share nothing but a port number. Two
    options:
    - *Simplest:* run a second `proxy.lua` instance on :8083 handling only `/api/db` and
      `/api/fs`, and point the frontend at it. UI metadata traffic then physically cannot
      stall a token stream. ~30 lines of routing plus a vite proxy entry.
    - *Better:* keep one port, but hand slow work (SQLite, filesystem walks) to a small
      pool of worker processes over `socketpair(2)`. The main loop stays pure I/O and the
      worker fds slot straight into the existing `select` sets. **This is what the unused
      `background_tasks` table (§3.5) was scaffolded for.**
11. **Add HTTP keep-alive.** Removing the forced `Connection: close` eliminates a
    connect/teardown per UI call and takes pressure off the 32-connection ceiling.
12. **Raise `MAX_ACTIVE_CONNECTIONS`** once the loop no longer stalls, and replace
    `select()` with `poll()` (or `epoll`/`kqueue`) — `select` is capped at `FD_SETSIZE`
    and rebuilds its fd sets on every iteration.

### Tier 3 — decide about RAG (scope call needed)

13. §3.1 means RAG currently does nothing. Before any optimization, decide: wire
    `search.index_dir` into the proxy as a background task (now possible after Tier 2),
    or remove the dead path and stop launching the embedding server. **Either is fine;
    the current state — starting a model server and never querying it — is the worst
    option.** If it is re-enabled, note that `embed.cosine` (`lib/embed.lua:159`)
    recomputes both norms on every call despite vectors being pre-normalized, which is 3×
    the necessary work over up to 600 files' worth of 1024-dim chunks.

### Tier 4 — targeted native code, only if measurement demands it (~200 LOC)

14. If, after Tiers 0–2, profiling still shows JSON or hashing dominating, replace **those
    specific functions** with a small C or Nim shared library loaded through LuaJIT's FFI —
    which is what the FFI is for. `lib/db.lua` already demonstrates the pattern with
    SQLite. That is a couple of hundred lines against a full rewrite, and it keeps the
    audited request-handling logic intact.

A full Nim rewrite belongs in a separate conversation, justified by maintainability rather
than throughput, and only after the above establishes what the real numbers are.

### Also worth fixing (small, independent)

15. `/cors-proxy` handler (§3.3) and the missing `/api/fs` vite proxy entry (§3.4).
16. `getaddrinfo` on the health path (§2.7) — move it behind the same async helper.

---

## 6. Measurement notes

All figures produced with LuaJIT 2.1.1703358377 against the repo's own modules, on an
idle container. A loaded laptop running llama-server should be assumed 3–5× slower.

| Measurement | Result |
|---|---|
| `sha256.lua` throughput | 15.6 MB/s @16 KB, 16.7 MB/s @256 KB, 23.5 MB/s @1 MB |
| `json.lua`, 0.36 MB payload | encode 27.1 ms, decode 15.7 ms |
| `get_fs_tree` pattern, 320 entries | 470 ms wall, 320 forks |
| `async_send` copy amplification | 1 MB body → 64 MB copied; 4 MB body → 1 GB copied |

Before implementing, it is worth capturing a baseline from a real session — the proxy
already logs dispatch lines (`lib/proxy.lua:1364-1368`), and adding elapsed-time logging
around each route handler would confirm the ranking above against your actual workload
rather than these synthetic numbers.
