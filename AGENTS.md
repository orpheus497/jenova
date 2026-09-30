# Agents Operational Directives

## ROLE & CORE DIRECTIVES

Act as a strictly permission-gated AI development assistant, usable across sessions and across different AI providers/tools. You are bound by the following non-negotiable rules:

1. **Permission-Gated Action:** For any code change, dependency change, or file deletion: Ask → Explain → Justify → Wait for Approval → Execute. **Exempt from this gate** (may proceed without asking): reading files, running read-only analysis/search, fixing typos in `.devdocs/` prose, and routine `.devdocs/` timestamp/log updates that record already-approved work.
2. **FOSS Compliance:** Rely on Free and Open-Source Software. GPL and other copyleft licences are allowed — the project is AGPL-3.0-or-later. Zero proprietary dependencies.
3. **Total Feature Retention:** Never deprecate or remove existing features unless explicitly instructed.
4. **Separation of Concerns:** Product code lives under `src/`, and the Web UI under `jca_web/`. Build output stays in git-ignored directories, and the installed application lives outside the repository in `$JCA_HOME`. All AI process, planning, and tracking documentation lives exclusively under `.devdocs/`, except this file (`AGENTS.md`), which is a root-level governance file.

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

**Scope — new and touched code only.** These rules govern code you write, and code you are already editing for another reason. **Do not mass-edit existing files solely to add or reformat comments**, and do not add commenting retroactively unless the user explicitly asks for it. An existing file that does not meet this standard is not thereby a defect to fix.

**Format — the prefixes are required**, written in the language's native comment syntax (`//`, `#`, `##`). For shell scripts, place the file-level comment directly beneath the shebang.

* `Script function and purpose:` [what this file is for, and its place in the system] — at the top of a source file **you create**. **Budget: 1–4 lines, hard ceiling 6.**
* `Function purpose:` [why it exists and how it is used] — **required above every new public/exported function**, and above a private one whose purpose the body does not make obvious. An FFI declaration gets none; its enclosing `{.push .}` block gets one `Action purpose:` naming the library. **Budget: 1 line; 2 only where one genuinely cannot carry it.**
* `Action purpose:` [why this logic, and how it is meant to work] — above a block that is genuinely not self-explanatory: a workaround for external behaviour, an ordering constraint, a non-obvious invariant, a deliberate omission. **Budget: 1–3 lines.**

**The budgets are a ceiling to cut to, not a target to fill.** They bind in both directions: when you touch a comment that runs over its budget, cut it back in the same edit. Coverage and volume are one rule, not two — adding a missing comment while leaving an over-long one beside it untouched raises the total, which is the opposite of what this standard exists to do.

**Comment only what the code cannot say for itself.** Do not restate a name, a signature, or the statement below it. The test: if the sentence stays true when the function is renamed to `doThing`, it describes *what* and it goes. If the code below reads clearly, write nothing — a comment that adds nothing is deleted rather than shortened.

**Two prohibitions, both from defects this repository has already had:**

* **No cross-reference labels.** No `G-30`, `D-BQ`, `W-01`, `P-A5`. Where a label carried real information, state the information in words. These once reached 689 references across `src/`, pointing at documents that had been deleted. (`SHA-256`, `UTF-8`, `PDF-1` are not labels.)
* **No history.** No "used to", "was missing", "shipped", "the old", no dates, no session numbers. Present tense, describing the code as it stands. A comment that recounts what a past change fixed is a commit message in the wrong file, and it goes stale the moment anything moves.

## OPERATIONAL WORKFLOW

### Session Start

1. Read `.devdocs/BRIEFING.md` first, then `SESSION_HANDOFF.md`'s most recent entries, then any other `.devdocs/` file relevant to the task at hand. Full-file reads of every tracker on every session are not required once `BRIEFING.md` is current and accurate.
2. Output a Session Briefing: current phase/status, previous session's accomplishments, current blockers, recent decisions, next 3-5 concrete steps.
3. Clarify ambiguities and obtain approval before executing.

### Execution (per approved step)

1. Announce the action, its necessity, and the technical approach.
2. Execute.
3. Apply the doc-update matrix above.

### Session End

1. Ensure `BRIEFING.md` reflects current state.
2. Prepend a new entry to `SESSION_HANDOFF.md` (accomplishments, files touched, decisions, next steps) and a matching one-paragraph pointer to `SUMMARIES.md`.
3. Report to the user.

## COMMAND LAWS

- All Date/Time values in `.devdocs/` are **canonically UTC in ISO-8601 format carrying an explicit `Z`** (e.g. `YYYY-MM-DDTHH:MMZ`), and must be sourced from the active harness's own tooling or clock — never constructed manually, and never local time or offsets. A bare local stamp or arbitrary offset is ambiguous the moment a second machine, a second contributor or a second timezone touches the file, and the ledgers are ordered by it.
- Entries stay **reverse-chronological** — newest at the top of the file.
- ALWAYS USE THE NATIVE TOOLING OF THE ACTIVE HARNESS - IF YOU ARE IN AN IDE ALWAYS USE THE NATIVE IDE TOOLING 

- DO NOT - create python scripts or run bash scripts to speed up behaviours or hasten the workload completion - DO NOT - use terminal or bash commands or scripts where there is available tooling or a practical ordefined method to behave from within the harness.