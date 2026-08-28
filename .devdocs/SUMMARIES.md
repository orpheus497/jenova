# SUMMARIES

One compressed paragraph per session, pointing back to the matching `SESSION_HANDOFF.md` entry.
Reverse-chronological. A pointer, not a re-narration.

---

## Session 004 — 2026-08-28 18:56 → 19:49

Read `AGENTS.md` in full, returned to IDE-native tooling per COMMAND LAWS, and stopped at the
Directive 1 gate before touching code. **B-07 fixed and verified** — `scripts/cleanup.sh` now
sources `lib/jenova-conf.sh` instead of deriving `LOG_DIR`/`CACHE_DIR` from an unset `JCA_HOME`,
proven by running the script to its confirmation prompt and answering `n`, with all three paths
resolving under `$JCA_HOME`. Tracing the paths to their real owner before editing exposed a
defect no audit had caught: `PID_FILE` was built from a directory that never holds state, so the
daemons-running guard could never fire and `--state` would have deleted PID and lock files out
from under live daemons. Two workspace-governance failures were then found and closed:
`ARCHITECTURE_MAPPING.md` and `TESTS.md` were mandated by `AGENTS.md` from the outset and had
never existed — the doc-update matrix went unmet across Session 001's 31 relocated files — and
**Directive 6 has never been executable**, because the `PLANS.md` "Codebase Integrity Standard"
it mandates a pass against did not exist in that file or anywhere else. The standard was
authored (**D-J**, my wording, flagged as such) and its first pass run over `scripts/`, yielding
**B-35 … B-38** and a half-retraction of **B-31**, whose tray-icon claim proved false. Q-9 … Q-12
were deliberately left open: a blanket "proceed" is not a ruling on a product-identity question.
**The session then pivoted.** The USER redirected the project to the Nim rewrite with a native
FreeBSD GUI desktop application as the target, `jca_web/` retained but deprecated (**D-L**), and
seven rulings followed. The load-bearing correction was the USER's: I built a toolkit question on
`AGENTS.md` Directive 2's copyleft ban and recommended Dear ImGui, and was told the project is
AGPL-3.0 — verified in `LICENSE` and `NOTICE:14` — so GTK, Qt and FLTK were available all along.
**Q-4 was never a licence violation, and three sessions treated it as one.** The recommendation
reversed to GTK4 + libadwaita via owlkettle (**D-P**). `AGENTS.md` Directive 7 was also found to
govern `.dbc` cartridges and `test_roms/` that do not exist here, so the governance file looks
partly written for another project (**N-8**, the USER's to amend). A second standing rule fell:
"nothing run in this environment is evidence" is false — FreeBSD binaries execute here and the
narrower rule is that only `uname -s`/`/proc`/emulated syscalls are untrustworthy (**C-12**).
Plan B was approved backend-first, and **N-S0 shipped and was verified** — `make core` builds
`bin/jenova-core`, it runs, and its FreeBSD-only compile guard was proven to fire rather than
assumed, precisely because C-9 records a guard that passed static checking while doing nothing.
See `SESSION_HANDOFF.md` Session 004.

---

## Session 003 — 2026-08-28, continuing from 17:14

Read every file in the product tree and every tracker, cross-referencing the trackers against the
source rather than trusting them, and recorded 28 new defects as `TODOS.md` B-07…B-34 with a
severity index. Five matter: `cleanup.sh` can `rm -rf /var/cache` and delete `/var/log/*.log`
because it is the only script missing the `JCA_HOME` default; `make verify` can never pass because
`verify-install.sh` still verifies a bundled Neovim distribution that this repository does not
contain; `sudo scripts/jenova-setup` is broken for three of six profiles, including the only
CPU-only profile (entirely Linux) and the GPU fallback (a config-symlinker with a root five
`dirname` calls too high); the configuration hierarchy is inverted, so `etc/jenova.local.conf` is
ineffective and `build-llama.sh` generates one using exactly the names that get discarded; and
`tests/test_validate_arg.sh` rewrites the repository's `etc/jenova.conf`, which is the real origin
of commit `eee557e`. **Three completion claims in `PROGRESS.md` were retracted** — all three
concern files S-6 relocated rather than edited, where `sh -n` passes and no diff exists to review
(constraint C-9). Four questions opened for the USER as Q-9…Q-12. Phase 1 of the remediation plan
was confirmed genuinely complete in source; everything after it is untouched, and WP-11 and WP-12
are worse than the plan records. No product code was changed. `jca_web/src/` was sampled, not read
exhaustively — that remains outstanding. See `SESSION_HANDOFF.md` Session 003.

---

## Session 002 — 2026-08-28 16:45 → 17:14

Consolidated the user-facing documentation from 18 files (~2,755 lines) to 8, verifying every
substantive claim against the source rather than trusting the prose. Fourteen false claims were
corrected; the worst were three documents asserting that the Web UI stores conversations in
browser IndexedDB via Dexie — Dexie is not a dependency and storage is server-side SQLite behind
`/api/db/*` — and a models guide that stated the exact inverse of the real discovery fallback.
Six genuine source defects surfaced during verification and were logged as `TODOS.md` B-01…B-06,
including a Google Fonts import in `jca_web/src/app.css:3` that contacts Google on every Web UI
page load, contradicting the project's local-first claim. The two engineering documents moved to
`.devdocs/` per Directive 4 and the drift-ledger index was deleted. **Left undone:** the 8
superseded source documents are still on disk — they carry uncommitted S-0…S-7 edits so `git rm`
needs `-f`, and terminal commands were withdrawn mid-session. See `SESSION_HANDOFF.md` Session 002.

---

## Session 001 — 2026-08-28 13:50 → 14:58

FreeBSD-only migration implemented across stages S-0 … S-7, 60 files changed, driven by nine USER
rulings (D-A … D-I). The finding that reframed the work: Jenova was misdetecting its own
developer's FreeBSD host as Fedora, because detection keyed off `uname -s`, which answers `Linux`
under the Linuxulator. Detection now reads `kern.ostype`. Code complete; a full build and install
on native FreeBSD remains the outstanding gate. See `SESSION_HANDOFF.md` Session 001.
