# TESTS

Test specifications, validation criteria and expected outcomes. Mandated by `AGENTS.md`
§ WORKSPACE ARCHITECTURE.

**Created:** 2026-08-28 (Session 004). Mandated from the outset; absent for Sessions 001–003.
See `DECISIONS_LOG.md` C-10.

> **Provenance.** Every file below was enumerated on disk this session and its purpose taken
> from its own header. Pass/fail *status* is carried from the Session 003 audit with its
> `file:line` citations, and is labelled as such — **no suite below has been executed on native
> FreeBSD**, which is the whole content of blocker B-1.

---

## 1. Standing rule

The editing environment is a Linux container on a FreeBSD host (the Linuxulator). **Nothing run
there is evidence for FreeBSD behaviour.** Static checks (`sh -n`, `luajit -bl`) and pure-logic
scripts are the exception: they test the text, not the kernel. Anything touching sysctls,
`/proc`, procstat, GPU or the network stack must be run natively before it counts.

## 2. The automated suite

`tests/Makefile` `check` target — **runs 6 entry points: 5 of the 9 scripts in `tests/`, plus
`proxy-concurrency/all.sh`.** *(Count corrected twice on 2026-08-31: it read "3 of 8" from before
`test_api_db.sh` landed at N-S3b, then "4 of 9" before `test_api_fs.sh` and `test_routes.sh` were
added. **The four orphans are unchanged throughout, so B-25 stands** — only the arithmetic was
ever stale.)*

| Script | Spec | Status |
|---|---|---|
| `test-health.sh` | Smoke test: the server starts and responds | **Cannot run on a clean machine** — requires `python3`, which `make deps` does not install (B-24). Also cannot pass on a headless start: `--daemon` brings up no `:8080` (B-13) |
| `test-launcher.sh` | Config loading, module existence, `jenova-ca` verbs, health check, cleanup guard | Not executed |
| `proxy-concurrency/all.sh` | Every proxy regression check — **the S-1 acceptance gate (V-4)** | See §3 |
| `test_api_db.sh` | The `/api/db/*` contract against the Nim core, 22 assertions on a scratch database | **PASS 22/22** (2026-08-28). **Incomplete in one dimension — N-27:** every assertion checks database state over HTTP and none checks the filesystem, so it cannot see that `api.nim` omits `proxy.lua`'s ten `fs_sync` mirroring calls. See §5b |

### Orphaned — present but never invoked (B-25)

| Script | Spec | Why it is not wired in |
|---|---|---|
| `test_bin_jenova.sh` | Validates `bin/jenova` against a running `jenova-ca` backend | Orphaned |
| `test_validate_arg.sh` | `detect-hardware.sh` argument validation | Orphaned **and destructive to the tree** — see §4 |
| `test_gpu.sh` | GPU path | Orphaned; also requires `external/ext_bin/bin/llama-cli`, which `build-llama.sh` never copies (it copies `llama-server` and `*.so*` only) — **fails unconditionally** |
| `test_gpu_single.sh` | Single-GPU path | Same |

`download-draft-model.sh` is a utility, not a test. It writes to the repository's `models/`
rather than `$JCA_HOME/models/draft/`, fetches Qwen2.5-Coder-0.5B where `model_dl.sh` fetches
Qwen3.5-0.8B, and claims speculative decoding will switch on automatically when `JENOVA_DRAFT`
is 0 in the deployed profile (B-26).

## 3. `proxy-concurrency/` — the acceptance gate

| File | Role |
|---|---|
| `all.sh` | Runs every check in the directory |
| `run.sh` | Acceptance suite for the concurrency / fd-leak defects |
| `test_reaper.sh` | Connection-reaper regression (remediation-plan WP-3) |
| `stub_backend.py`, `probe_streams.py` | Python harness support |
| `test_ffi_flags.lua` | FFI flag constants — **5/5 verified live on FreeBSD in Session 001** |

**The fd-leak assertion is vacuous on the target platform (B-23).** `run.sh:58,96` counts
descriptors with `find /proc/$PX/fd`. `/proc` is not mounted on stock FreeBSD, so both counts
are `0` and `[ 0 -le 2 ]` passes whether or not descriptors leaked. The check only ever
functioned under the Linuxulator, where it was written. **FreeBSD needs `procstat -f`.**

Consequence: **V-4 is a partial gate until B-23 is fixed.** Treating a green `all.sh` as proof
of no fd leak would be a Directive 6 violation.

## 4. A test that damages the repository

`test_validate_arg.sh:62` calls `assert_pass "Vulkan/dgpu-i5-1135g7"`, which genuinely invokes
`--apply-profile`; `detect-hardware.sh:339-342` then mirrors the profile into
`$JENOVA_ROOT/etc/jenova.conf` whenever that directory is writable. The test's `mktemp`
isolation covers `JCA_HOME` but **not the repository mirror** (B-22).

**This is the true origin of commit `eee557e` "Revert hand-edit of etc/jenova.conf" — no hand
edit ever occurred.** Do not run this script against a working tree until it is isolated.

## 5. Verification gates — V-1 … V-6 — **DEFERRED to post-refactor by D-Y**

> **Ruling D-Y, 2026-08-31.** *"you are not going to test the deployment - as that will overwrite
> my currently working version — you are focussing on the rewrite - the build testing happens
> AFTER all refactoring has been completed."*
>
> **`make install`, `make verify` and `jenova-ca --daemon` are prohibited for the duration of the
> rewrite.** The USER runs a working deployment from this tree; an install would overwrite it.
>
> **B-1 is not a blocker and never was one for this phase** — it was gating the wrong work.
> V-1 … V-6 form a post-refactor acceptance phase, and the three test-surface defects that block
> them — **B-08, B-23, B-24** — are prerequisites for a gate that is not yet due. They leave the
> near-term path with the gates.
>
> **Still permitted, because they touch nothing deployed:** `make core`; `bin/jenova-core` and all
> of its self-test subcommands against scratch databases; `sh -n`; read-only inspection. This is
> the entire N-S* acceptance surface in §5a, which is unaffected by D-Y.

The table below is retained as the specification of that future phase, not as current work.

| ID | Gate | Blocked by |
|---|---|---|
| V-1 | `make deps` — all packages resolve, incl. the appindicator FreeBSD provides | B-24 (`python3` missing from the list) |
| V-2 | `make` — full build. Watch `jenova-ui`: the `#error` guard and the indicator-library probe | — |
| V-3 | `make install` → `make verify` | **B-08 — `verify-install.sh` cannot pass.** Q-10 open |
| V-4 | `sh tests/proxy-concurrency/all.sh` — the S-1 acceptance gate | B-23 (vacuous fd check), B-24 |
| V-5 | `jenova-ca --daemon --lan`, then `sockstat -4l`: `:8080` on `0.0.0.0`, `:8081`/`:8082` on `127.0.0.1` | B-13 — `--daemon` starts no `:8080` |
| V-6 | Streaming completion end-to-end in the WebUI; `lsof` flat across a session | — |

**Three of six gates are blocked by defects in the test surface itself, not by the product.**
Fixing B-08, B-23 and B-24 is prerequisite work, not optional polish.

`TODOS.md` V-1…V-3 still spell the command `gmake`; the `make`→`gmake` change was reverted and
the Makefile builds with base `make(1)` (B-06).

## 5a. Plan B stage acceptance

### N-S0 — build proof

1. `make core` exits 0 and writes `bin/jenova-core`; `file` reports an **ELF 64-bit FreeBSD**
   executable.
2. `./bin/jenova-core` runs and exits 0.
3. **The FreeBSD guard must fire, not merely exist.** `nim c --os:linux src/jenova_core.nim`
   must fail with the `{.error.}` message. Run this on every change to the guard — C-9 records a
   guard that passed static checking while doing nothing.

### N-S1 — configuration precedence

The regression that matters is B-12. Compare the two resolution paths directly:

```sh
# Shell path — reproduces bin/jenova-ca:44-48 (local conf sourced BEFORE profile)
sh -c 'JENOVA_ROOT="$PWD"; export JENOVA_ROOT; \
  . ./lib/detect-env.sh; . ./lib/jenova-conf.sh; \
  . ./lib/jenova-model.sh; . ./etc/jenova.conf; \
  echo "THREADS=$THREADS DEVICES=$DEVICES FIT_TARGET=$FIT_TARGET"'

# Nim core — corrected order
./bin/jenova-core config | grep -E '^(THREADS|DEVICES|FIT_TARGET)='
```

**Expected while `etc/jenova.local.conf` declares 8 / three devices / 768:** the shell prints the
*profile* values (4, two devices, 512) and the Nim core prints the *local conf* values. They are
**supposed to differ** until N-S6 deletes `bin/jenova-ca`; identical output before then means the
Nim core has regressed to the inverted order.

Environment precedence: `JENOVA_THREADS=16 ./bin/jenova-core config` must report `THREADS=16`,
beating both files.

**Recorded result, 2026-08-28:** all three checks pass. Shell 4 / `Vulkan0,Vulkan1` / 512; Nim
8 / `Vulkan0,Vulkan1,Vulkan2` / 768; env override 16.

### N-S2 — database concurrency

`./bin/jenova-core db-selftest` — a writer thread and four reader threads against one database.

**What it asserts, and why each matters:**

| Check | Why it is the right check |
|---|---|
| `sqlite3_threadsafe()` != 0 | A single-threaded SQLite build would make the whole design unsound. `initDb` refuses to run against one |
| `journal_mode` = `wal` | Without WAL a writer blocks every reader, reintroducing serialization |
| Distinct connection handle per thread | Structural proof the layer is per-thread, not one shared handle behind a lock |
| **Reader/writer time-window overlap > 0** | **The load-bearing measurement.** Completion proves nothing — serialized work completes too. Only overlap shows the threads ran *at the same time* |

**Recorded result, 2026-08-28:** PASS. 2000 operations across 5 threads in 15.8 ms; each reader
100% concurrent with the writer; five distinct handles.

**A passing self-test does not mean the system is concurrent.** It covers this layer alone. The
system-level property is decided at N-S3, where the async loop must dispatch blocking work to
worker threads rather than calling it inline (C-13). A future regression test for that belongs
with N-S3, not here.

### N-S3 — the server must not serialize

`./bin/jenova-core serve-selftest`. **This is the regression test for the defect that motivated
the whole rewrite**, so it is worth being precise about why it is built the way it is.

It opens an SSE stream and records the gap between consecutive events — **twice**: once with the
server idle, then again while four other connections sit inside real 400,000-row recursive CTEs
in SQLite. The stream is opened *before* the load starts, so it owns its worker; the property
under test is that established streams are not stalled by blocking work elsewhere.

| Why each choice | |
|---|---|
| **Maximum** gap, not average | An average hides a single long freeze, and a single long freeze *is* the defect |
| **Two phases, compared** | One passing run says nothing about whether load matters. The comparison is the evidence |
| **Real SQL, not `sleep`** | A sleep would not exercise the database path that stalled the Lua proxy |
| Budget = 2.5× the send interval | A serialization defect shows as *multiples* of the interval, not milliseconds over it |

**Phase 3 — a saturated class must not take the server down.** Added 2026-08-28 under D-U. Over-
subscribe the debug class 3:1 with 800 ms holds, then time `/health` and `/`. This is the property
a single shared pool fails *even when nothing blocks*: completion streams are long-lived by
design, so enough of them occupy every worker and the server goes dark. **A server can pass phases
1 and 2 and still fail this one.**

**Recorded results, 2026-08-28:** PASS all three. Idle max gap 40.1 ms against a 40 ms interval;
under load 40.1 ms with 38 slow queries overlapping the stream; `/health` 0.2 ms and `/` 0.2 ms
while the debug class was saturated.

> **A test that silently stopped testing — worth remembering.** When the class table was resized
> under D-T, phase 2 kept passing but reported 4 slow queries where it had reported 41.
> `/debug/stream` and `/debug/slow-query` had both landed in the now-1-thread debug class, so the
> "load" queued *behind* the stream rather than overlapping it. The assertion still passed, and it
> was measuring nothing. The load endpoint moved to the api class. **A passing concurrency test
> whose overlap count collapses is not passing — check the work actually happened concurrently.**

**Also verified by raw socket** — deliberately not with `fetch`, which normalises `..` out of the
URL client-side and would have made the traversal check meaningless:

```
GET /../etc/jenova.conf   -> 403 Forbidden
GET /../../etc/jenova.conf-> 403 Forbidden
GET /nope.js              -> 404 Not Found
GET /                     -> 200 OK   (public/index.html)
POST /                    -> 405 Method Not Allowed
GET /debug/slow-query     -> 404 under `serve` (gated; enabled only for the self-test)
```

### N-S3b — the `/api/db/*` contract

`sh tests/test_api_db.sh` — 22 assertions, wired into `tests/Makefile check`. Starts its own
`jenova-core` on a scratch database and stops it on exit.

**Every assertion encodes something `lib/proxy.lua` does**, not something that merely seems
reasonable. `jca_web` is a shipped client that must keep working unchanged while it is deprecated
(D-L), so "sensible" is not the standard — "identical" is.

The three that exist because a first implementation got them wrong, all found by reading `db.lua`
rather than inferring from the route list:

| Assertion | The behaviour it pins |
|---|---|
| `child deleted without forks reparents grandchild` | Children are moved onto the deleted node's own parent, not orphaned (`db.lua:369`) |
| `deleteWithForks removes nested descendants` | The fork walk is recursive, not one level deep (`db.lua:341-360`) |
| `restoring a note revives its workspace` / `its project` | Restore cascades *upward*; without it a restored item sits inside a deleted container and never appears (`db.lua:905-917`) |

Also pinned: integer columns stay JSON numbers rather than strings, partial updates touch only
the fields supplied, soft deletes populate the trash listing, and import runs transactionally.

**Recorded result, 2026-08-28:** PASS, 22/22.

> **A wrong assertion, corrected rather than accommodated.** The workspace-cascade check first
> asserted `projects/all` was empty, but a *different* workspace's project was legitimately still
> alive — the cascade was right and the test was wrong. Rewritten to check the specific row. An
> assertion that only passes because unrelated state happens to be empty is not a test.

### N-S4 — in-process inference

**`./bin/jenova-core llama-selftest [prompt]`** loads the model from config and generates,
bypassing the server. Use it to separate a model/backend problem from a serving problem.

**Recorded result, 2026-08-28** at the full deployed configuration — `devices=Vulkan0,Vulkan1`,
`ctx=32768`, `slots=2`, `kv=q8_0`, `ngl=-1`, `threads=8`: loads (Vulkan0 152.85 MiB, Vulkan1
381.11 MiB) and generates 48 tokens.

**Serving, and the property that matters.** With `serve` running, issue a long generation and time
other classes *while it runs*:

```sh
# long generation in the background
printf 'POST /completion ... {"prompt":"...","max_tokens":180}' | nc 127.0.0.1 $PORT &
# then, concurrently:
GET /health            GET /api/db/workspaces            GET /
```

**Recorded result, 2026-08-28:** `/health` 3–4 ms, `/api/db/workspaces` 6 ms, `/` 3 ms, while the
generation ran to all 180 tokens. **This is precisely the scenario in which `proxy.lua` froze
every other client.** Warm the model with a one-token request first, or the timing measures model
loading rather than serving.

Streaming shape: `POST /v1/chat/completions` with `"stream":true` returns
`Content-Type: text/event-stream` and `chat.completion.chunk` records terminated by
`data: [DONE]`.

> **Not covered by any test yet:** sampling parameters are ignored (N-25) and client disconnect
> does not cancel a generation (N-26). Neither should be assumed working because these checks pass.

## 5e. `jenova-core rag-selftest` — retrieval (N-S5b, 2026-08-31)

**7 assertions, PASS.** Indexes a three-document scratch corpus, then asserts a keyword hit ranks
the right file, that a snippet survives storage (**the property `search.lua` lost on every
restart**), and that a path filter confines results.

**The vector half is asserted without an embedding server, deliberately.** Endianness, the BLOB
round-trip and the dot product are where a silent error would live, and waiting for a server to be
running to find out is how unverified logic ships. `rag.nim` exposes `vectorRoundTrip`,
`similarity` and `storeChunkVector` so the test can pin them directly: a float32 vector survives
byte-exact, identical vectors score 1.0, orthogonal score 0.0, and a stored vector reads back
through the same `queryBlob` path the query itself uses.

**`chunks with vectors: 0` in the output is not a failure** — it is the embedding server being
absent, and keyword-only retrieval is a supported degraded mode that `search.lua` had too.

**What this does NOT cover, recorded as N-31:** the HTTP request and response shape against a live
embedding server on :8082. That is the one part of the semantic path still unproven.

**`jenova-core db-capabilities`** reports what the linked libsqlite3 can actually do —
threadsafety, journal mode and FTS5 — because Q-24's index choice was contingent on a fact that had
been assumed rather than checked (D-AB). Result on this host: `fts5: available`.

## 5d. The route inventory — **now a test**, `tests/test_routes.sh` (2026-08-31)

**9 assertions, PASS.** Wired into `tests/Makefile check`. Runs in a scratch `JCA_HOME` (D-AE).

**Reading the statuses correctly matters here.** A **502** on `/v1/chat/completions`, `/completion`
and `/infill` is the **pass** condition under D-AF: it proves the request was classified and reached
`upstream.forward`, which then found no `llama-server` listening. **A 404 or 405 would mean the
route was never classified at all** — which is precisely what `/infill` returned before N-S4c. The
test asserts 502, not "not an error", for exactly that reason.

The prose below explains why the check exists and how to extend it when a new surface is claimed.

### Why it exists

**Any stage claiming to reproduce a surface must diff its routes against the running binary before
the claim is made.** N-29 exists because that was never done: the audit enumerated the route
families it noticed, `/api/storage/*` was not among them, and N-S5a was recorded complete with five
routes unserved.

The check is one loop and takes seconds:

```sh
probe() { printf '%s %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' "$1" "$2" \
          | nc 127.0.0.1 "$PORT" | head -1; }
```

Enumerate the source's routes first — for `lib/proxy.lua`,
`grep -oE '"\^(GET|POST|DELETE|PUT|\[A-Z\]\+) /[a-zA-Z0-9/_%.-]*'` plus the `find("…")` matches,
since it uses both forms — then probe every one. **A 404 or 405 on a route the original serves is
the finding.** Reading the handler list is not a substitute; that is what produced the false claim.

## 5c. `tests/test_api_fs.sh` — the filesystem contract (N-S5a, 2026-08-31)

**46 assertions, PASS** (31 at N-S5a, 15 more for `/api/storage/*`). Covers what §5b said was
missing: physical path layout, the git repo per
workspace, base64 `data:` decoding, rename-then-trash-the-old-path, the `<epoch>_<name>` trash
naming, the `.metadata.json` sidecar, all four `/api/fs/*` routes, per-entity delete ordering, and
that bulk import does *not* mirror.

**Both API suites now run inside a `mktemp` `JCA_HOME` and delete only a directory matching their
own prefix.** This is not hygiene — `test_api_db.sh` previously derived its database path as
`"${JCA_HOME:-$HOME/JCA}/.system/jenova.db"` and `rm -f`'d it, **so `make check` deleted the live
conversation database on any machine with a real deployment.**

> **A vacuous run, caught before it was believed.** The first execution reported `ok` on eight
> checks while the server was listening on a different port — every one an absence check, and an
> absence check passes when the entire system is unreachable. **A `/health` liveness gate now runs
> before any assertion.** Same lesson as the N-S3 phase-2 overlap collapse: an assertion that
> cannot fail is not evidence.

> **An over-strict assertion, corrected rather than accommodated.** It pinned the sidecar's byte
> spacing — `fs_sync.lua` writes `{"type": "notes", …}`, the Nim core emits compact JSON. Only
> those two components read the file and both parse it as JSON, so the formats are interchangeable
> in both directions. **The fields are the contract; the spacing is incidental.**

**The `/api/storage/*` assertions are about containment, because that is the risk.** These four
routes take a client-supplied path and read, write and delete with it. Asserted: three traversal
forms all refused with **403 and not 404** (a 404 would disclose whether a path outside the root
exists), an absent file inside the root answering 404, the trash preserving the original relative
path, and — after a defect of mine — **a stored file beginning with `[` being served as its own
content rather than mistaken for the JSON listing.** The first wiring picked the content type with
`not body.startsWith("[")`; `ApiResult` now carries `contentType` explicitly.

**And a fidelity finding that only appeared because the port broke an existing test.**
`test_api_db.sh`'s restore-cascade assertions began failing. Not a regression: **`fs_sync.lua:70`
refuses to mirror a row whose `id` is not a UUID, and `proxy.lua:899` deletes the row and answers
500.** The test used `"n2"`, and had passed only because `api.nim` had no mirroring to reject it —
**the test was encoding the gap rather than the contract.** Real UUIDs now, plus an assertion
pinning the rejection.

## 5b. N-27 — the dimension the contract test did not cover *(CLOSED 2026-08-31 by §5c)*

Recorded 2026-08-31. **`test_api_db.sh` passes 22/22 and is not wrong. It is incomplete.**

`lib/proxy.lua` calls `fs_sync` at **ten sites inside the `/api/db/*` routes** —
`sync_workspace`, `sync_note`, `sync_fileAsset`, `trash_workspace`, `trash_project`,
`trash_folder`, `trash_note`, `trash_fileAsset` — so creating a workspace makes a directory and
deleting a note moves the file into a trash tree. `src/jenova/api.nim` performs none of it.

**Why no assertion caught it:** all 22 issue HTTP requests and inspect the JSON that comes back.
The filesystem is never examined, so the suite has no assertion that *could* fail on this. It is
C-9's lesson in a new place — **a check that cannot fail in a dimension is not evidence about that
dimension**, and a green suite says nothing about what it does not look at.

**Required of the N-S5a acceptance test**, so this cannot recur:

| Assertion | Why |
|---|---|
| Creating a workspace/project/folder through `/api/db/*` **creates the directory on disk** | The mirroring contract, in the dimension the current suite omits |
| Deleting a note **moves the file into the trash tree**, and `GET /api/fs/trash` lists it | Pins delete-side mirroring and the `/api/fs/*` port together |
| `POST /api/fs/trash/restore` **returns the file to its original path** | Restore is the half most likely to be quietly wrong |
| `GET /api/fs/tree` matches the real directory contents | The route N-20 must reproduce |
| **Run against the existing `proxy.lua` first, then the Nim core, and compare** | "Identical, not sensible" — `jca_web` is frozen under D-Z and must keep working unchanged |

## 6. What has actually been verified, and how

**Live on FreeBSD 15.1 (Session 001):** `sh -n` across 53 shell scripts · `luajit -bl` on every
Lua file · `ffi_defs` loading with FreeBSD constants and a 16-byte `sockaddr_in` ·
`test_ffi_flags.lua` 5/5 · `jenova-model-switch` 6/6 including filenames containing spaces ·
environment detection · profile selection across the full ladder · CUDA opt-in exclusion ·
zero bash · zero `IS_LINUX`.

**By source reading (Session 003), not execution:** remediation-plan Phase 1 — non-variadic
`fcntl`/`open`/`ioctl` with a FreeBSD load guard, `set_cloexec` on accepted sockets,
`fd_set_new()`, the `stalled` flag, the drained accept loop, backlog 128.

**Session 004:** `sh -n scripts/cleanup.sh` clean, plus an end-to-end run of
`cleanup.sh --logs --cache --state` answering `n` at the prompt, confirming all three paths
resolve under `$JCA_HOME` (`var/log`, `var/cache`, `.system`) and that nothing outside it is
targeted. Nothing was deleted.

**Not verified by anyone yet:** a full build, an install, a live daemon start, and the complete
`proxy-concurrency` harness on native FreeBSD.
