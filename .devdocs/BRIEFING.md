# BRIEFING

**Last updated:** 2026-08-31 11:34
**Branch:** `bsd`
**Phase:** 3 — Execution. Plan B (Nim native FreeBSD desktop application) is the active workstream.

---

## 1. Current state

| Item | Value |
|---|---|
| Architecture | **`llama-server` is the inference engine; the Nim core is the harness around it (D-AF).** Never a standalone — this is permanent |
| Stage | **N-S0 … N-S5c complete; N-S6 partial.** Config, database, threaded server, the full `/api/*` surface, filesystem mirror, RAG, the completion pipeline (N-30 closed), and backend supervision — `backends [start\|stop\|status\|args]`, both argument vectors, refusal paths. **B-13 closed by construction** |
| Next | **Finish N-S6** — `serve` auto-starting backends, `--lan`, `hardware-profiles/` consumption, health watchdog. Only then is `bin/jenova-ca` deletable |
| Runtime home | **`$HOME/Jenova`.** `~/JCA` is the legacy deployment and is permanently untouchable (D-AE); the core refuses to resolve against it |
| Tests | `test_api_db` 23 · `test_api_fs` 46 · `test_routes` 13 · `pipeline-selftest` 15 · `rag-selftest` 7 · `sha256-selftest` 4 · `db-selftest` · `serve-selftest` — all PASS, all in a scratch `JCA_HOME` |
| Open decisions | **Q-9, Q-10, Q-11, Q-12** — none block the rewrite path |
| Commits | Everything is uncommitted. Commit boundaries are the USER's alone (C-11) |

## 2. Rulings in force — not to be reopened

| Ruling | Decision |
|---|---|
| **D-AF** | **`llama-server` is the inference engine. Jenova is the harness.** `upstream.nim` is the primary path. In-process inference is retained behind `JENOVA_INPROC=1` (Directive 3) but is not the default and nothing new is built on it. **Supersedes D-N's linkage clause and D-W entirely** |
| **D-AE** | **`~/JCA` is permanently off limits — no migration, overwrite or change, ever.** The `~/Jenova` split exists so testing cannot reach the deployment. **Not to be raised again** |
| **D-AD** | The runtime home is `$HOME/Jenova`, at all 20 code sites. `paths.resolve` refuses `$HOME/JCA` unless `JENOVA_ALLOW_DEPLOYED=1` |
| **D-AC** | Building and testing are permitted. Nothing may create, write, delete or rename under `~/JCA`. `make install`, `make verify` and `jenova-ca` stay out of scope for the whole rewrite |
| **D-AB** | This workspace is a Linuxulator container. **A detection is not evidence until its mechanism is shown not to route through the emulation layer** — state the mechanism with the claim |
| **D-Z** | `jca_web/` is frozen. Not touched, edited or damaged. B-01, B-03, B-04 defer to N-S9 |
| **D-Y** | No deployment, build or install testing until the rewrite is complete. V-1 … V-6 are a post-refactor phase; B-08, B-23, B-24 go with them |
| **D-X** | **The licence is AGPL-3.0; copyleft dependencies are permitted. Closed permanently.** It recurred only because of dead "rule-2 violation" rows in `BLUEPRINT.md`, now purged |
| **D-S / D-T / D-U** | Worker-thread pool, not `asyncdispatch`. Two-device personal product. Per-class thread isolation: `static:4 health:2 api:3 completion:3 embed:1 debug:1` |
| **D-L / D-O / D-P / D-Q** | Native FreeBSD GUI target · fix only what survives · GTK4 + libadwaita via owlkettle · backend first, GUI last |
| **C-11** | No git writes, ever |

## 3. What the core does today

**Served by `bin/jenova-core`, verified by probe:** `/health`, `/v1/health`, `/api/db/*` (7 entities,
soft deletes, cascades, restore), `/api/fs/*` (trash, restore, empty, tree), `/api/storage/*`
(save, get, list, trash), static assets, and `/v1/chat/completions`, `/completion`, `/infill`,
`/embed*` proxied to `llama-server` and the embedding server.

**Every chat request is rewritten before it leaves** — intent detected and stripped, RAG injected,
web search run for the websearch intent, a persona chosen, tools stripped where they do not apply,
and the cache consulted on the rewritten body's key.

**`lib/proxy.lua` is fully superseded.** Every route *and* every completion behaviour is reproduced.
`/api/workspaces` is the sole exception, dead and deliberately dropped. Nothing has been deleted —
see N-33.

**Retrieval ships** (`rag.nim`): FTS5 keyword index, float32 vectors in BLOB columns, chunk text
persisted. **FTS5 was confirmed present by probe** (`jenova-core db-capabilities`), not assumed.

## 4. N-30 — **CLOSED 2026-08-31 at N-S5c**

All seven behaviours are ported and wired into the serving path. `pipeline.nim` owns them,
`prompts.nim` carries the personas verbatim, `websearch.nim` does DuckDuckGo through base `fetch(1)`,
and `sha256.nim` supplies the cache key — hand-written because Nim ships SHA-1 and a different
algorithm would silently orphan every cache entry `proxy.lua` has written, and **asserted against
the published FIPS 180-4 vectors** for that reason.

**Two lessons kept from building it.** `serve` never called `rag.initSchema()`, so the first chat
request answered 500 while `pipeline-selftest` — which calls it itself — stayed green: **wiring is
not proven by unit checks**, and `test_routes.sh` now posts a real chat body and asserts 502.
And a new assertion in that same test called helpers it did not have, printing "command not found"
while still reporting PASS — **the second vacuous pass this session**.

### The original finding, kept for the record

`server.nim` reads `stream`, `max_tokens` and `messages`/`prompt`. `lib/proxy.lua:1225-1400` also
does **seven** things, none ported:

1. **Intent detection** — `Visual Rewrite:`, `Open File Chat:`, `Chatbot:`, `Web Search:`, stripped after matching
2. **RAG retrieval** — per-intent limits (visual 1, websearch 0, default 3, 5 for a long message carrying `Path:`), with a query rewritten from basename + trailing prose for large file-chat payloads
3. **RAG injection** — `--- REPOSITORY CONTEXT ---`, `[n] path`, snippets cut at 1000 chars
4. **Web search** — DuckDuckGo HTML → Instant Answer fallback, with two distinct failure messages, because "no results" and "no HTTPS client" tell the model different things
5. **Persona injection** — three non-interchangeable modes: agent (never override a client system prompt; inject the CORE MANDATE only when absent), conversational (persona-first), no-intent (persona prepended, RAG appended)
6. **Tool stripping** — `visual` and `websearch` clear `tools`, set `tool_choice: none`
7. **Cache intercept** — SHA-256 of the **rewritten** body, `X-Cache: HIT`

**The ordering trap in 7:** the key is hashed *after* rewriting, so caching sits at the end of the
pipeline. Hashing the client's original body would produce a different key and silently break
compatibility with existing cache entries.

## 5. Outstanding

**Code:** finish N-S6 — `serve` auto-starting backends, `--lan`, `hardware-profiles/` consumption,
the health watchdog. That makes `bin/jenova-ca` deletable and closes B-12 and N-23 with it. Then
N-S7 GUI → N-S8 CLI → N-S9 retires `jca_web/`, closing B-01, B-03, B-04.

**N-24 is now demonstrable, not theoretical.** `jenova-core backends args` emits
`-dev Vulkan0,Vulkan1,Vulkan2` on this host — the non-existent device reaches the argument vector,
where the old shell path discarded it via B-12. **`etc/jenova.local.conf` is untracked and is the
USER's machine file**, generated by `build-llama.sh`, so it is reported rather than edited.

**N-33: `lib/proxy.lua` and its modules are now fully superseded** — every route and every
completion behaviour is reproduced. Nothing has been deleted; Directive 3 keeps them until the USER
instructs removal. `ffi_defs.lua`, `daemon.lua` and `ui.lua` are excluded, still used by the tray
and lifecycle path until N-S6/N-S7.

**Independent and cheap:** N-24 (`jenova.local.conf` names a `Vulkan2` that does not exist),
B-22 (a test that rewrites `etc/jenova.conf`).

**Recorded, not blocking:** N-31 — `rag.embed`'s HTTP call to :8082 is written but has never run
against a live embedding server; the storage and similarity maths are asserted directly, and
keyword-only retrieval is a supported degraded mode.

**Open questions, none blocking:** Q-9 (leave `bin/jenova-ca` alone — the B-12 defect is currently
what stops the running deployment reading the bad `Vulkan2` value), Q-12 (the "Uncensored" model as
the CUDA profile default), B-10 (`CPU/generic/jenova-setup` is entirely Linux — delete, or write
real FreeBSD tuning).

**Needs the USER, because `~/JCA` is out of bounds:** end-to-end generation and per-request sampling
through a live `llama-server`, and the `:8082` embedding call (N-31). The models live under `~/JCA`.

## 6. Standing process notes

- **Every decision and ambiguity goes to the USER.** Seek clarity over assuming.
- **A ruling records only what the USER said.** Any inference drawn from it is a separate question
  that must be asked — three failures this session came from writing my own inference into the
  ledger in the USER's voice (the D-Y clause, N-8, D-N's linkage sentence).
- **Before raising a question, check the standing rulings and the code for an existing answer.**
  Q-25 and Q-28 were invented questions that D-E and `server.nim` had already answered.
- **Enumerate, do not assert.** Counts and completion claims get checked against the thing itself;
  the route inventory in `TESTS.md §5d` exists because that was not done.
- **C-11:** no git writes. **D-AB:** state the mechanism behind any detection claim.
