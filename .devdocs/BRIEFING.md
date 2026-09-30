# BRIEFING

**Current as of 2026-09-30T04:36Z.** Overwritten each session.

## Where the project is

- **Code:** `main` = `4acedfa0` (PR #118). The branch `idk` is rebuilt as `main` plus this session's
  commits: the llama.cpp update to `a6ea155d3`, Stages 1 and 2 with the thinking setting, the
  `.gitignore` and `jvim/` cleanup, and the documentation. Its previous tip, `154e0cf9` (a commit that
  only made every file executable), is dropped from the branch and kept on `idk-before-cleanup`.
  Nothing is pushed.
- **Host:** bare-metal Arch Linux (HP ENVY, i5-1135G7, Iris Xe + GTX 1650 Ti). `bin/` and
  `external/ext_bin/` hold Linux builds; `nimble suites` passes end to end.
- **Deployed** to `~/Jenova` from the checkout (no install step yet — Stage 3): profile
  `Vulkan/dgpu-igpu-i5-1135g7`; `models/instruct/` holds the Nemotron3-Nano 4B Q8_K_P (active),
  `models/thinking/` the Qwen3.5 9B Q4_K_M, `models/embed/` nomic-embed-text 1.5. Instruct runs with
  thinking off and a `5,1` split (`~/Jenova/etc/jenova.local.conf`), about 8 tok/s; thinking about 3.
  Start it with `./bin/jenova` (window) or `./bin/jenova-core serve`.
- **Rulings:** `DECISIONS_LOG.md` 2026-09-29T23:30Z, 2026-09-30T03:07Z and 04:36Z — including git back
  in scope for this branch, and `jvim/` being Jenova's own Neovim config under Jenova's licence.

## What this session accomplished

1. Stages 1 and 2 (build and OS detection on FreeBSD and Linux).
2. The Linux build and a tested deployment with the USER's models.
3. `JENOVA_REASONING`, with instruct models defaulting to no thinking; llama.cpp's `-lm`.
4. `.gitignore` fixed; `jvim/` repository leftovers removed; every doc checked against the code.

## Blockers — needs the USER

- Approval of Stage 3 and each later stage. `PLANS.md` 4.6 (the Web UI creates new FOCUS notes on
  every page load) is the most urgent defect found.
- The Push/Pull decision (remove it from the Web UI, or re-specify it as backup/restore).
- Whether to push `idk`.

## Next steps (after approval)

1. Stage 3 — the install step in the Nim build.
2. Stages 4 and 5 — 4.6 first.
3. Stage 7, then Stage 8 (tests) last. Cleanup only on confirmation.
