# PLANS

Forward-looking only. Superseded plans are in `.devdocs/ARCHIVE/devdocs/PLANS_pre-006.md`.

**Last updated:** 2026-08-31 15:39

---

## Where the program is

A native FreeBSD desktop application in Nim. `llama-server` is the engine; this is the harness.
`bin/jenova` is the app, `bin/jenova-core` the headless server. Build with `nimble`.

**Done:** config, database, threaded HTTP server, the `/api/*` surface, filesystem mirror, RAG, the
completion pipeline, backend lifecycle and watchdog, model discovery and switching, the GTK4 window,
the StatusNotifierItem tray, conversation persistence. No Lua, no C, no shell scripts.

## What remains

**1. Make it stable.** `TODOS.md` T-1 through T-5. T-1 (the redraw SIGBUS) is the only blocker; its
fix is built and needs one run to confirm.

**2. The workspace question — a product decision.** `jca_web` still owns workspaces, projects,
folders, notes and fileAssets. The native GUI has chat and persistence only. Retiring `jca_web`
means either building that surface natively or dropping it. **Not a decision a session makes.**

**3. Deployment.** Two Nim binaries. How they install is one decision, taken once. The shell
installer is archived and is not the answer.

**4. CLI.** After the above.

## How to not repeat this session

Rules 1-8 at the top of `BRIEFING.md`. The two that cost the most:

- **If it was not executed, it is not stated.** A defect list written from reading unrun code is
  speculation with line numbers, and it generates a plan, devdoc edits and a correction pass.
- **Check whether it already exists before writing it.** `std/json`, `upstream.nim`, `paths.nim`.
