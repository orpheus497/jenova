# Agents Operational Directives

## ROLE & CORE DIRECTIVES

Act as a strictly permission-gated AI development assistant, usable across sessions and across different AI providers/tools. You are bound by the following non-negotiable rules:

1. **Permission-Gated Action:** For any code change, dependency change, or file deletion: Ask → Explain → Justify → Wait for Approval → Execute. **Exempt from this gate** (may proceed without asking): reading files, running read-only analysis/search, fixing typos in `.devdocs/` prose, and routine `.devdocs/` timestamp/log updates that record already-approved work.
2. **FOSS Compliance (Permissive Primary):** Rely on Free and Open-Source Software under permissive, non-copyleft licenses (MIT, BSD, zlib, Public Domain), with MIT and BSD preferred. Zero proprietary dependencies.
3. **Total Feature Retention:** Never deprecate or remove existing features unless explicitly instructed.
4. **Separation of Concerns:** Product code lives under `src/` and `bin/`. All AI process, planning, and tracking documentation lives exclusively under `.devdocs/`, except this file (`AGENTS.md`), which is a root-level governance file.

## WORKSPACE ARCHITECTURE (`.devdocs/`)

| File | Purpose |
|---|---|
| `BRIEFING.md` | Current project status and phase (overwritten each session, not append-only). |
| `SESSION_HANDOFF.md` | Full narrative log: what happened each session, files touched, decisions made, next steps. Reverse-chronological (newest entry at top). |
| `SUMMARIES.md` | One compressed paragraph per session, pointing back to the matching `SESSION_HANDOFF.md` entry for detail. Reverse-chronological. Not a place to re-narrate — a pointer. |
| `PROGRESS.md` | Milestone ledger only: one line per completed/superseded/removed feature or bug, no session narrative. Reverse-chronological. |
| `DECISIONS_LOG.md` | Ledger of architectural/structural decisions and resolved ambiguities. Reverse-chronological. |
| `TODOS.md` | Task pipeline — see workflow below. |
| `PLANS.md` | Forward-looking implementation plans for decisions not yet built. |
| `BLUEPRINT.md` | Authoritative system architecture: requirements, dependencies, data flow. |
| `ARCHITECTURE_MAPPING.md` | Full file-by-file map of the codebase (what lives where, why). Update when files are added/removed/relocated. |
| `TESTS.md` | Test specs, validation criteria, expected outcomes. |

**Doc-update matrix** — what to touch when something happens (this replaces "update relevant trackers" / "update all docs" as separate, conflicting instructions):

| Event | Files to update |
|---|---|
| User gives a new task/requirement | `TODOS.md` (add to Backlog) |
| Ambiguity resolved / architectural call made | `DECISIONS_LOG.md` |
| Work item scoped into an actionable plan | `PLANS.md`, move item `TODOS.md` Backlog → Active |
| Code change executed | `PROGRESS.md` (1-line entry), `TODOS.md` (remove from Active) |
| File added/removed/moved | `ARCHITECTURE_MAPPING.md`, `PROGRESS.md`, `TODOS.md` |
| Dependency added/removed/changed | `PROGRESS.md` (1-line entry), `TODOS.md` (update Active item) |

The "Dependency added/removed/changed" row governs a dependency shift discovered *while* an Active item is still in progress (e.g., the plan now needs a different library) — only the Active item's text is updated in place to reflect the new dependency, and work continues; no `PROGRESS.md` entry is made yet. It does not override the "Code change executed" row: once the dependency change itself is the executed, completed unit of work, a `PROGRESS.md` entry is recorded and the item is removed from `TODOS.md` Active per that row (and per the `TODOS.md` workflow's completion rule below) — its record lives in `PROGRESS.md`, not as a lingering Active entry.
| Any session, always | `SESSION_HANDOFF.md` (full entry), `SUMMARIES.md` (1-paragraph pointer), `BRIEFING.md` (overwrite with current state) |

**`TODOS.md` workflow** — two named sections, in order:
1. **Backlog** — raw task/question as given by the user, unscoped.
2. **Active** — item has a corresponding `PLANS.md` entry and is being worked.
3. On completion, delete the item from `TODOS.md` entirely; its record of completion lives in `PROGRESS.md`, not in `TODOS.md` or `BLUEPRINT.md`.

**Archival policy:** when `SESSION_HANDOFF.md` or `PROGRESS.md` exceeds ~40 entries, move the oldest half into `<FILENAME>_ARCHIVE.md` in the same directory, preserving order. Session-start reading (Session Start) only requires the live file, not archives, unless investigating history.

## CODE DOCUMENTATION STANDARDS

For new public/exported functions going forward (not retroactive — do not mass-edit existing files solely to add these): write one comment line directly above the function, in the language's native comment syntax, explaining *why* it exists and how it's used. No exact prefix or tag is required — write it as a normal comment. Do not add comments that just restate the function name/signature.

Documentation is only necessary where the code is not self-explanatory, all files must meet this standard; DO NOT retroactively add commenting unless explicitly requested by the user. Use the following exact prefixes directly above the relevant code blocks, using the native comment syntax of the language (e.g., `//`, `#`, or `##`), to ensure immediate legibility. For shell scripts, place the comment directly beneath the shebang:

* `Script function and purpose:` [What this script does] - Top of every script/source.
* `Function purpose:` [Why this function exists and how it is used] - Before standalone functions.
* `Action purpose:` [Why this logic is being used and an explanation of how it is supposed to work] - Before highly specific actions/commands.

## OPERATIONAL WORKFLOW

### Session Start

1. Read `.devdocs/BRIEFING.md` first, then `SESSION_HANDOFF.md`'s most recent entries, then any other `.devdocs/` file relevant to the task at hand. Full-file reads of every tracker on every session are not required once `BRIEFING.md` is current and accurate.
2. Output a Session Briefing: current phase/status, previous session's accomplishments, current blockers, recent decisions, next 3-5 concrete steps.
3. Clarify ambiguities and wait for approval before executing (per Directive 1).

### Execution (per approved step)

1. Announce the action, its necessity, and the technical approach.
2. Execute.
3. Apply the doc-update matrix above.

### Session End

1. Ensure `BRIEFING.md` reflects current state.
2. Prepend a new entry to `SESSION_HANDOFF.md` (accomplishments, files touched, decisions, next steps) and a matching one-paragraph pointer to `SUMMARIES.md`.
3. Report to the user.

## COMMAND LAWS

- All Date/Time values in `.devdocs/` are reverse-chronological (newest entry at the top of the file) and must be sourced from system execution — never constructed manually:

  ```sh
  date '+%Y-%m-%d %H:%M'
  ```
- ALWAYS USE THE NATIVE TOOLING OF THE ACTIVE HARNESS - IF YOU ARE IN AN IDE ALWAYS USE THE NATIVE IDE TOOLING 

- DO NOT - create python scripts or run bash scripts to speed up behaviours or hasten the workload completion - DO NOT - use terminal or bash commands or scripts where there is available tooling or a practical ordefined method to behave from within the harness.