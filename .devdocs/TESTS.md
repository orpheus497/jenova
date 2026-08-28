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

`tests/Makefile` `check` target — **runs 3 of the 8 test scripts present**:

| Script | Spec | Status |
|---|---|---|
| `test-health.sh` | Smoke test: the server starts and responds | **Cannot run on a clean machine** — requires `python3`, which `make deps` does not install (B-24). Also cannot pass on a headless start: `--daemon` brings up no `:8080` (B-13) |
| `test-launcher.sh` | Config loading, module existence, `jenova-ca` verbs, health check, cleanup guard | Not executed this session |
| `proxy-concurrency/all.sh` | Every proxy regression check — **the S-1 acceptance gate (V-4)** | See §3 |

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

## 5. Verification gates — V-1 … V-6

Outstanding in full. **None has been executed on native FreeBSD** (blocker B-1).

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
