# TODOS

Two sections, in the order `AGENTS.md` sets: **Backlog** (raw, unscoped) then **Active** (scoped in
`PLANS.md`). A completed item is deleted from here and recorded in `PROGRESS.md`.

Rewritten 2026-09-30T02:07Z to match `PLANS.md` as revised after the USER's answers of
2026-09-29T23:30Z. Git work is out of scope (ruling 1) and is not listed.

## Backlog

- **Parked by ruling, not scoped:** MCP client (P-A1); agentic loop (P-A2); text-to-speech (P-A4);
  beyond-parity proposals P-E3, P-E6, P-E7.
- **Push/Pull (P-C3 / W-05):** out of scope for the GUI by the session-2 ruling; whether to remove it
  from the Web UI or re-specify it as backup/restore is the USER's decision (report 02 §4).
- **jvim's first start may download treesitter parsers** (`ensure_installed` for sixteen languages,
  none vendored), against the "zero internet" in its README. Unverified.
- **Cleanup, after the work and only on the USER's confirmation** — the candidates in `PLANS.md`.

## Active

Every Active item has its plan in `PLANS.md`, and each needs the USER's approval before it starts
(`AGENTS.md`, rule 1). Items are deleted here as they complete; Stages 1 and 2 completed on
2026-09-30T03:07Z (`PROGRESS.md`).

- **Stage 3 — the installed program, separate from the repository** (3.1–3.4): an install step in the
  Nim build, profile at install, launchers and desktop entry, uninstall and update.
- **Stage 4 — the GUI and the Web UI behave the same** (4.1–4.11): the Web UI sends `X-Jenova-Scope`,
  the same workspace-context bound, timestamp units, moving items in the GUI, the Web UI's Pull
  leaving its buttons disabled; and from the Linux deployment test, the Web UI's runaway FOCUS notes
  (high), mirror files deleted on save, trash restore, the dead page after a delete, the service
  worker, Continue and retries.
- **Stage 5 — defects** (5.1–5.16): short request bodies, index rows left by deletes, the embedding
  port on worker threads, `/api/db/cache` reporting success, "Open Web UI" stalling the control
  worker, the dual-GPU profile on an iGPU-only i5-1135G7, unread settings, the dual-GPU split, and
  the deployment test's findings (5.9–5.16).
- **Stage 6 — documentation**: the install and update steps once Stage 3 exists. (Every product doc,
  including `jca_web/README.md` and `jvim/README.md`, was checked against the code on 2026-09-30.)
- **Stage 7 — GUI feature backlog**, and the comments listed there, corrected when their code is next
  touched.
- **Stage 8 — last: tests** — isolation from `~/Jenova/.system`, no network in `pipeline-selftest`, the
  Web UI's missing Storybook setup; CI only if the USER wants it.
