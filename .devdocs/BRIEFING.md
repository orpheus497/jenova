# BRIEFING

**Last updated:** 2026-08-31 10:19
**Branch:** `bsd`
**Phase:** 3 — Execution. **Plan B (Nim native FreeBSD desktop application) is the active workstream.**

---

## 1. Current state

| Item | Value |
|---|---|
| Active plan | **Plan B — Nim native FreeBSD GUI application** (D-L). Approved backend-first, N-S0 … N-S9 |
| Architecture | **D-AF, 2026-08-31: `llama-server` runs inference; Jenova is the harness.** 2,813 of 3,452 Nim lines (81%) are unaffected. `llama.nim` + `inference.nim` (639) become an optional path |
| Stage | **N-S4c done 2026-08-31** — inference proxied by default, `/infill` and `/v1/health` correct, route inventory now a test. **Next: N-S5a-2 (`/api/storage/*`).** |
| Stage (prior) | **N-S0 … N-S4 complete; N-S5a PARTIAL.** The `fs_sync` mirroring (N-27) and `/api/fs/*` (N-20) are done and tested. **`lib/proxy.lua` is NOT retired — five routes are unported (N-29).** An earlier entry today claimed it was; that claim is retracted |
| Plan A (FreeBSD migration) | Code complete, S-0 … S-7. The foundation Plan B builds on |
| Open defects | **38 recorded, B-01 … B-38 less B-07, plus N-27 new this session.** Under D-O only a subset is to be fixed — see §6 |
| Open decisions | **Q-9, Q-11, Q-12 and Q-10.** All four reframed 2026-08-31; none answered |
| Destructive defects | **None outstanding** |
| Commits | N-S4 work is **uncommitted**. Commit boundaries are the USER's alone (C-11) |

## 2. Four disputes closed permanently on 2026-08-31

**These are not to be reopened, and no session may raise them as open items again.**

| Ruling | Decision |
|---|---|
| **D-X** | **The licence is AGPL-3.0. Copyleft dependencies are permitted. Q-4 is closed permanently.** It kept recurring because of dead "rule-2 violation" rows in `BLUEPRINT.md`, now purged — not because anything was ever in doubt. `AGENTS.md` Directive 2's copyleft clause is **dead letter**; its operative clause is "zero proprietary dependencies" |
| **D-Y** | **No deployment, build or install testing until the rewrite is complete.** The USER runs a working deployment from this tree and an install would overwrite it. `make install`, `make verify` and `jenova-ca --daemon` are **prohibited**. `V-1 … V-6` move to a post-refactor phase and are no longer Active |
| **D-Z** | **`jca_web/` is frozen — not to be touched, edited or damaged.** It is the working interim LAN client until N-S7 reaches parity and N-S9 retires it. The `jca_web/src/` full read is **cancelled**. B-01, B-03 and B-04 are deferred to N-S9 because fixing them means editing a frozen tree |
| **D-AB** | **This workspace is a Linuxulator container; detection results are suspect until their mechanism is shown not to route through the emulation layer.** State the mechanism alongside any detection claim, or it is unverified |
| **D-AC** | **Building and testing are permitted; `~/JCA` is untouchable.** Not minimised — nothing may create, write, delete or rename there. `make install`, `make verify` and `jenova-ca` stay out of scope for the whole rewrite |
| **D-AF** | **`llama-server` is the inference engine; the Nim core is the harness around it.** `upstream.nim` becomes the primary path; in-process inference is retained as `JENOVA_INPROC=1`, not deleted. **Supersedes D-N's linkage clause, which I wrote myself** — Q-22 asked about GUI architecture, not about replacing `llama-server`. Closes N-25, N-26 and D-W; reduces FIM to route classification; **reopens Q-25 as Q-28** |
| **D-AE** | **`~/JCA` is permanently off limits — no migration, no overwrite, no change, ever.** Stated by the USER four times. The `~/Jenova` split exists so testing cannot reach the deployment; **offering to migrate defeats its purpose and is not to be raised again** |
| **D-AD** | **The runtime home is `$HOME/Jenova`**, changed at all eleven code sites. The five Lua modules already said `Jenova`, so this also resolved a shell/Lua inconsistency that `jenova-conf.sh`'s export had been hiding. `paths.resolve` **refuses `$HOME/JCA`** unless `JENOVA_ALLOW_DEPLOYED=1` |

**N-8 is CLOSED, and it was substantially wrong — my error.** `AGENTS.md` has **four** directives.
There is no Directive 7, no `.dbc`, no `test_roms/`; they were removed before this session. I
relayed the claim from `TODOS.md` without checking the governance file I had just read in full.

**The larger defect that check surfaced:** the devdocs cite a superseded directive numbering.
**`Directive 6` is referenced 14 times and does not exist** — it is what the entire Codebase
Integrity Standard apparatus (D-J, C-10) was built on. `Directive 7` is referenced 6 times and does
not exist. The standard is **retained on its merits as workspace practice**, no longer claimed as
governance. All stale citations corrected this session.

## 3. The rewrite, settled

| Ruling | Decision |
|---|---|
| **D-L** | Native FreeBSD GUI desktop application. Not a web wrapper |
| **D-N** | **Single binary** — GUI links the core in-process; `llama.cpp` linked directly |
| **D-O** | Fix only what survives the rewrite |
| **D-P** | **GTK4 + libadwaita via owlkettle**; `gintro` as escape hatch |
| **D-Q** | Backend first, GUI last. Source in `src/` at the root |
| **D-S** | Worker-thread pool, **not `asyncdispatch`** — an async loop is the same defect class as `proxy.lua`'s |
| **D-T** | **Personal single-user product.** Host plus at most one LAN device. Every capacity number derives from two devices |
| **D-U** | Every service surface owns its own routine and threads. `static:4 health:2 api:3 completion:3 embed:1 debug:1` + 2 acceptors |
| **D-W** | Inference is **serial** — one context, one generation at a time |
| **C-11** | I run no git writes. Read-only inspection permitted |

**Stage order:** N-S0 ✅ → N-S1 ✅ → N-S2 ✅ → N-S3a ✅ → N-S3b ✅ → N-S4 ✅ →
**N-S5 RAG** → N-S6 lifecycle parity → N-S7 GUI + tray → N-S8 CLI → N-S9 WebUI retirement.

**D-R proven at the level that matters.** While a 180-token generation ran: `/health` 3–4 ms,
`/api/db/*` 6 ms, static 3 ms. **That is the exact scenario in which `proxy.lua` froze every
client.** `JENOVA_INPROC=0` still reverts to proxying `llama-server`.

## 4. N-27 — the finding that reordered the plan *(CLOSED 2026-08-31 at N-S5a)*

**Resolved.** `src/jenova/fssync.nim` and the ten mirroring call sites are in; `tests/test_api_fs.sh`
holds the contract at 31 assertions. **A destructive defect was found while closing it:**
`tests/test_api_db.sh` derived its database path from `${JCA_HOME:-$HOME/JCA}` and deleted it, so
`make check` destroyed the live conversation database on any machine with a real deployment. Both
suites are now isolated to a scratch `JCA_HOME`. The original finding is kept below.

### The original finding

**`src/jenova/api.nim` is missing the filesystem half of the `/api/db/*` contract.**

`lib/proxy.lua` calls `fs_sync` at **ten sites inside the `/api/db/*` routes** — `sync_workspace`,
`sync_note`, `sync_fileAsset`, `trash_workspace`, `trash_project`, `trash_folder`, `trash_note`,
`trash_fileAsset` — mirroring every create and delete into real directories and a trash tree.
`api.nim` has **none of it**.

**The 22-assertion contract test cannot detect this**, because every assertion checks database
state over HTTP and none checks the filesystem. It passed, and it is not wrong — it is
incomplete in a dimension it never looked at.

**Why this reorders N-S5.** RAG indexes *files*. The files are the ones `fs_sync` creates. Porting
the RAG layer onto a core that does not write those files would index an empty tree, which is a
more elaborate version of the B-15 defect it exists to fix. **`fs_sync` must be ported before or
with N-S5, not after** — and it is the same module `/api/fs/*` (N-20) needs, so the two collapse
into one stage.

## 5. Blockers

| # | Blocker | Type |
|---|---|---|
| **N-11** | **Dependency change awaiting approval** — add `nim` to `install-dependencies.sh` DEPS so `make core` can depend on `deps` | decision |
| **Q-9, Q-10, Q-11, Q-12** | Four open rulings, all reframed 2026-08-31. See `DECISIONS_LOG.md` | decision |
| **N-S5 design** | Two architecture questions the USER must settle before RAG is written — vector/BM25 storage, and in-process vs subprocess embeddings. See `PLANS.md` | decision |

**No longer blockers.** `B-1` was gating the wrong phase and is superseded by **D-Y**. `N-8` is
closed. The `jca_web/src/` read is cancelled by **D-Z**.

## 6. Defects still to fix under D-O

Under **D-Z**, B-01 leaves this list — it cannot be fixed without editing a frozen tree.

| ID | What | Status |
|---|---|---|
| **B-22** | A test that rewrites `etc/jenova.conf` — the real origin of commit `eee557e`. Cheap; protects the tree | to fix |
| **B-09, B-10** | `jenova-setup` broken for 3 of 6 profiles, incl. the GPU fallback and the only CPU-only profile | gated on Q-11 |
| **B-05, B-20, B-21** | Hardware-profile data contradicting itself; `CUDA/dgpu-generic` ships a third-party "Uncensored" model as its default | B-21 gated on Q-12 |
| **N-24** | `etc/jenova.local.conf` names a `Vulkan2` that does not exist on this machine | to fix |
| **N-27** | `api.nim` has no filesystem mirroring | folded into N-S5 |
| ~~B-01~~ | Google Fonts leak in `jca_web/` | **deferred to N-S9 by D-Z** |

`hardware-profiles/` is data and survives the rewrite, which is why its defects are worth fixing
and the Lua/shell ones are not.

## 6a. N-29 — the route inventory that had never been run

**Five routes the Web UI can call are unported**, found by probing a running core rather than by
reading the trackers:

| Route | Core | `proxy.lua` serves |
|---|---|---|
| `GET /api/storage` | **404** | recursive file listing, depth 4 |
| `GET /api/storage/<path>` | **404** | file download, `application/octet-stream` |
| `POST /api/storage/<path>` | **absent** | file upload (`:1009`) |
| `DELETE /api/storage/<path>` | **absent** | trash a file — needs `fs_sync.trash_path`, the 1 of 13 functions not ported |
| `GET /api/workspaces` | **404** | filesystem workspace list (`:1096`) |
| `POST /infill` | **405** | FIM completion — `routes.nim` never classifies it, so it lands in the static class |
| `GET /v1/health` | **400** | classified to completion, which then fails to parse a body |

**Why it was missed.** `TODOS.md` N-20 recorded that `/api/fs/*` was unported and nothing ever
recorded `/api/storage/*`. The full-tree audit enumerated the route families it happened to notice
and **never diffed them against the implementation.** The inventory above is one loop against a
running binary. It should be a standing check at every stage that claims a surface is reproduced.

## 6b. N-30 — the largest gap, found by the directed inventory

**The Nim core's completion path is a raw llama-server equivalent, not Jenova.**
`server.nim:181-185` reads `stream`, `max_tokens` and `messages`/`prompt`. `lib/proxy.lua:1225-1400`
additionally does **seven** things, none of them ported:

intent detection (four stripped prefixes) · RAG retrieval with per-intent limits · RAG injection as
`--- REPOSITORY CONTEXT ---` · web search with two distinct failure messages · persona injection in
three non-interchangeable modes · per-intent tool stripping · an LLM cache intercept keyed on the
SHA-256 of the **rewritten** body.

**This is the product's distinguishing behaviour.** It reframes N-S5b — RAG is one input to this
pipeline, not the stage itself — and it is now N-S5c in `PLANS.md`.

## 7. Next steps

1. ~~**N-S4c**~~ — **done 2026-08-31.** Default inverted, `/infill` classified, `/v1/health` fixed,
   `tests/test_routes.sh` added. The one check that needs a real `llama-server` — per-request
   sampling actually taking effect — is the USER's, since the models live under `~/JCA` (D-AE).
2. **Answer Q-28** — embeddings via the :8082 server (recommended, consistent with D-AF) or
   in-process CPU-only as Q-25 chose. Q-25 assumed in-process inference; that assumption is gone.
   **Gates the embedding half of N-S5b only** — it does not block N-S5a-2.
3. **N-S5a-2 — finish the surface (N-29).** `/api/storage/*` (4 routes, **verified live** in
   `storage.service.ts`), `fs_sync.trash_path`, `/infill` classified (**the USER's Neovim FIM
   depends on it**), `/v1/health` routed to health. **Do not port `/api/workspaces` — it is dead
   and never worked.** This is what actually retires `lib/proxy.lua`.
4. **N-S5b — RAG.** **Q-24 = SQLite for both indexes** (FTS5 + BLOB) stands. First task is the FTS5
   probe in the native build — if absent, fall back to Q-24 option B and report it (D-AB: check, do
   not assume). The embedding half waits on Q-28.
2. **`llama.LoadSpec` needs a per-context device override** so the embedding context can request
   CPU while the agent context keeps `DEVICES=Vulkan0,Vulkan1`. C-14 is the standing warning here.
3. **N-S5c — the completion pipeline (N-30).** The stage that makes the core Jenova rather than a
   llama-server clone. Depends on N-S5b for its RAG input. **N-25 folds in here** — per-request
   sampling belongs in the rebuilt request path.
4. **N-24 and B-22** — the two cheap fixes that touch nothing frozen or deployed.
5. **N-S6** — lifecycle parity, which is what finally deletes `bin/jenova-ca` and closes B-12,
   B-13 and N-23 in the shell path.
6. **Q-12 and B-10** remain the only open questions outside the rewrite path.

## 8. Standing process notes

- **Directive 1 is per-item.** A general "proceed" is not a ruling on an open question.
- **All ambiguity and every decision goes to the USER.** Seek clarity over assuming — USER
  instruction, 2026-08-31.
- **C-11:** no git writes, ever.
- **D-AB:** state the mechanism behind any detection claim, or it does not count as evidence.
- **D-X:** the licence is settled. Do not raise it again.
