# Report 05 — Execution Plan

> **Status as of 2026-09-29T22:30Z (baseline `4acedfa0`; host Arch Linux):** superseded as the
> forward plan by `PLANS.md`; this report now records the verified state of its phases.
> **Done:** Phases 0, 3, 6 and 8; Phase 2 except 2.2 (2.4 and 2.5 landed differently from the step
> table — see Phase 2's state); 4.1; 5.1–5.3; P-B4; maths M-1–M-3; P-E8.
> **Re-checked 2026-09-30T01:16Z:** every claim a code verification flagged was read against the code
> and corrected in place.
> **Open:** Phase 1 on every OS (`nimble gui` fails on this host under gcc 16.2 and clang 22.1);
> 2.2; 4.2 (partial); 4.3; 5.4 and P-B7; P-A3; P-A7; P-B1 (partial); M-4; D-15.

**Supersedes the parity-port plan.** Report 06 established that owlkettle is not a constraint:
the window uses 18 of 85 available widgets, has 7 more compiled out of the build by omission, and
expresses structure through nested `Box`es because it was written to reproduce a browser DOM.
[2026-09-29T22:43Z: those were report 06's first-audit figures; at `4acedfa0` the window uses 41 of
the 85 and none is compiled out — see report 06.]

**The goal is restated:** not "reproduce the Web UI in GTK", but **build a native application on
the shared core**, which reaches parity on most items as a side effect and exceeds it on the rest.
Both surfaces are clients of the same `api.nim`, the same pipeline, the same retrieval. The
window's advantage is that it is a process on the machine.

**Rulings in force:** Push/Pull out of scope for the GUI · MCP and TTS deferred. The session-2
freeze on `jca_web` is superseded by the 2026-09-29T23:30Z ruling 4: the Web UI and the GUI are the
two points of access and behave the same. Beside these, the rulings of 2026-09-29 (`DECISIONS_LOG.md`
22:29Z and 23:30Z): FreeBSD and Linux (Arch, Debian, Fedora) both first-class, GPL code allowed, the
OS detected at build time, the installed program separate from the repository, and a clear
structural separation of concerns.

---

## The reframe, concretely

| Was planned as | Is actually |
|---|---|
| P-B12 keyboard shortcuts — *blocked on replacing a mechanism* | One custom `renderable` holding a window-level `GtkShortcutController`. The existing mechanism is already window-scoped; its `assert` is an upstream `# TODO` with a narrow constraint (report 06 §6) |
| P-B6 dedicated Files/Trash pages — *M, port two routes* | `ColumnView` — a virtualised, sortable, native list. Smaller than the port |
| The settings screen — *drawn with Label + Button + Switch* | `PreferencesPage` / `ActionRow` / `ComboRow` / `SwitchRow` / `EntryRow`. Deletes code |
| M-01 render caches — *capped in session 2* | Symptom. `ListView` virtualises the transcript and the cache becomes viewport-sized [2026-09-29T22:30Z: it did not — the rows recycle and the memos do not; see 2.2] |
| P-B1 error dialog, P-B2 processing state | `ToastOverlay` + `Banner` + `StatusPage`, all native, all currently unused [2026-09-29T22:30Z: all three are now used; see Phase 3] |

---

## Phase 0 — Unlock the toolkit (½ session, do first)

Two changes, both small, both gating everything after.

| Step | Detail |
|---|---|
| 0.1 | Confirm the libadwaita version on the FreeBSD host (`pkg info libadwaita`), then set `-d:adwminor=<n>` in `jenova_core.nimble` beside the existing `-d:gtkminor=10 -d:gtk48`. This alone restores `OverlaySplitView`, `ToolbarView`, `SwitchRow`, `EntryRow`, `PasswordEntryRow`, `Banner`, `AboutWindow` and 13 properties (report 06 §2) |
| 0.2 | Record the standard from report 04 §3 in `CLAUDE.md`, so every phase below is written to it rather than retrofitted in Phase 6 |

**Exit:** the build sees the whole toolkit; the comment rule is where a future session reads it.

> **State: 0.1 and 0.2 done.** `jenova_core.nimble`'s `NimFlags` sets `-d:gtkminor=10
> -d:adwminor=4` — no `-d:gtk48`, which owlkettle at the pinned revision never reads (the comment
> above `NimFlags` says why) — so all seven `{.since: AdwVersion >= (1, x).}` widgets are in the
> binary (report 06 §2), and its `requires` line pins owlkettle to `ac61ecf` rather than trusting
> `>= 3.0.0`, which the `v3.0.0` tag and `main` both satisfied while differing. Those flags and the
> hand-bound `AdwBreakpoint` set the toolkit floor at GTK 4.10 and libadwaita 1.4: Debian 12 is
> below it; Debian 13, Fedora, Arch and FreeBSD qualify. Step 0.2 is done in `AGENTS.md`'s code
> documentation standard (PROGRESS 2026-09-09T05:31Z; on `main` since `4acedfa0`).
> [2026-09-29T22:30Z: superseded — this block said 0.2 was not done because the repository had no
> `CLAUDE.md`; the standard went into `AGENTS.md`, which every session reads first.]

---

## Phase 1 — Build and first run on each supported OS (1 session per OS)

[2026-09-29T22:30Z: was "FreeBSD build and first run"; reframed under the user's ruling that
FreeBSD and Linux (Arch, Debian, Fedora) are both first-class. The state per OS closes this section.]

Unchanged in necessity, and now also validates Phase 0. `gui.nim` has never been type-checked
anywhere available: 30 of 35 modules check against a shimmed scratch tree, `jenova-core` builds
and runs 17 self-tests, and `gui.nim` gets only a differential parse against owlkettle stubs.
Superseded since: both binaries were built on FreeBSD 15.1 (session 9, PROGRESS 2026-09-10) and
`jenova-core` on Linux (2026-09-29), and there are twenty-two self-tests. The tree cannot show the
FreeBSD `jenova-core` any more: `bin/jenova` is still that FreeBSD 15.1 build, while `bin/jenova-core`
is now the Linux one.

`nimble core` · `nimble gui` · `nimble suites` · fix what the real compiler rejects in this
branch's window edits · run it · **A-2** capture a GUI screenshot · **A-3** reorder the README to
lead with the window · record in report 03 what the first real build changed, so the harness's
blind spots are known rather than assumed.

**Exit, on each supported OS:** green suite, the window runs, `png/` has a desktop screenshot.

> **Partly answered, session 7 — but on Linux, not FreeBSD.** The premise that this could only
> happen on the target host was wrong: GTK 4.14.5, libadwaita 1.5.0, GtkSourceView 5.12.0, VTE
> 0.76 and D-Bus 1.14 are stock packages, so both binaries now compile, link and run off FreeBSD,
> and the window maps under `Xvfb`. `tests/gui_build.sh` does it, and found two defects in this
> branch on its first run — one that stopped `bin/jenova` building at all, one that collapsed the
> window's whole layout (report 03, "The GUI became buildable and runnable").
>
> **What remains genuinely FreeBSD-only** and keeps this phase open: the `sysctl` hardware probe,
> the `fork`/`setsid`/`execv` backend path against FreeBSD's process semantics, the D-Bus tray
> (no `StatusNotifierWatcher` runs under Xvfb), the embedded Neovim page, GTK 4.20.4 against the
> 4.14 tested here, and the A-2 screenshot, which should be of the real desktop.
>
> [2026-09-29T22:30Z: superseded — that Linux was the audit environment, not a target. Under the
> ruling both OSes are targets; the state per OS follows.]

> **State per OS [2026-09-29T22:30Z].**
>
> - **FreeBSD 15.1**, the working host until 2026-09-10: both binaries built, and the twenty-two
>   self-tests, the six shell suites and `gui_check.sh` passed (PROGRESS 2026-09-10T02:59Z);
>   `bin/jenova` and `external/ext_bin/` are FreeBSD builds from that host. Not re-verified since,
>   and not verifiable without a FreeBSD host. Still outstanding there, per the trackers: the
>   `sysctl` probe on real hardware, `fork`/`setsid`/`execv` under FreeBSD, the tray against a real
>   `StatusNotifierWatcher`, the Neovim page, the mapped-window tier and the A-2 screenshot.
> - **Arch Linux**, this host: `nimble core` builds; the twenty-two self-tests and the six shell
>   suites pass. **`nimble gui` fails** under gcc 16.2 and clang 22.1: `vte.nim` declares `GdkRGBA`
>   as a Nim object and passes it to the header-declared `vte_terminal_set_colors`, an
>   incompatible-pointer error that FreeBSD's older clang only warned about. With that one error
>   downgraded the window builds, and `--check` and `gui_check.sh` pass. `hardware detect` reports
>   "FreeBSD", no CPU, 0 threads, 0 GiB and "UFS" on btrfs — `hardware.nim` has no Linux path for
>   the OS name (hard-coded) or the CPU, memory, storage and swap probes (`sysctl`, `zpool`,
>   `swapinfo`, `nvmecontrol`), and every profile sets `MATCH_OS="FreeBSD"`. GPU detection is the
>   exception: it runs `llama-server --list-devices`, which works on Linux, and that numbers the two
>   GPUs in the reverse of the order the i5-1135G7 profiles hard-code. Not run: the mapped-window
>   tier (`Xvfb`, `xdotool`, `xclip`, `xwininfo` absent; Wayland session), `nimble web`, and
>   `nimble suites` end to end.
> - **Debian, Fedora:** never built; the Phase 0 floor excludes Debian 12.
>
> The compile fix, Linux hardware detection with the OS chosen at build time, and verification on
> each OS are in `PLANS.md`.

---

## Phase 2 — The transcript becomes a ListView (1 session)

The single largest structural change, and the one everything else sits on.

| Step | Detail |
|---|---|
| 2.1 | Replace the `for m in app.messages` loop in `view` with `ListView`, `size = app.messages.len`, `viewItem(index)` building one message |
| 2.2 | Reduce `BlockMemo` / `ParseMemo` / `thumbCache` to viewport scale; keep the caps and the clearing — a smaller working set does not make an unbounded cache safe |
| 2.3 | Re-verify streaming: the last row updates every token. Confirm `ListView`'s `update` hook (`widgets.nim:4487`) re-runs `viewItem` for bound rows, and that autoscroll still pins |
| 2.4 | `Clamp` around the transcript for a reading-width column |
| 2.5 | `Avatar` + `ActionRow` idiom for message headers, replacing the "YOU"/"JENOVA" text labels |

**Risk: this is the highest-risk phase in the plan.** Streaming into a virtualised list is the
one place where `ListView`'s recycling and the token stream can fight. If 2.3 does not hold,
fall back to virtualising only conversations above a length threshold and record why.

**Exit:** a long conversation costs viewport memory, not conversation memory.

> **State: 2.1 and 2.3–2.5 done; 2.2 open. The risk did not materialise.** The transcript is a
> `ListView` built in `mainArea`, which `view` inserts, with one `messageCard` per row, and streaming
> into it holds, so the fallback
> above was never needed — open decision 3 is closed by that. On a 400-turn conversation the
> resident set after load falls 297 → 267 MiB. The note above the transcript's `AutoScroll` in
> `view`, and `messageCard`'s own, record the constraint that made it real: a `GtkListView`
> virtualises only as the scrolled window's direct child, so the reading-width `Clamp` moved into
> each card rather than wrapping the list. 2.5 landed as an `Avatar` beside the role name, which
> `messageCard` keeps on purpose, rather than as an `ActionRow`.
>
> **2.2 is the open half and the phase's exit condition is not met without it.** Four render
> memos are module-level `var`s at conversation scale: `mdMemo` (`markdown.BlockMemo`,
> `BlockMemoCap` 512), `attachMemo` (`pipeline.ParseMemo`, `ParseMemoCap` 128, no byte bound),
> `thumbCache` (keyed by size and attachment identity, `ThumbCacheCap` 64) and, since M-3,
> `mathLayoutCache` (keyed by formula source, `MathLayoutCacheCap` 64). `clearRenderMemos` empties
> all four on a conversation switch; within one conversation only the caps bound them — scrolling
> that same conversation to turn 130 reaches 320 MiB. The rows recycle; the caches do not. See
> report 06 §3. [2026-09-29T22:30Z: corrected — this named three memos keyed by message id;
> `thumbCache` is keyed by attachment, and `mathLayoutCache` came with M-3.]

---

## Phase 3 — Native chrome (1 session)

Mostly deletion. Every item replaces hand-built structure with a widget that already exists.

`OverlaySplitView` replacing `Flap` · `ToolbarView` for the header/content/footer · `ToastOverlay`
for transient notices (**P-B1** in part) · `Banner` for backend-down and LAN-on states ·
`StatusPage` for the empty transcript, empty trash, no-models states · `PopoverMenu` + `ContextMenu`
for right-click on messages and tree rows · `SplitButton` for send-with-options.

**Exit:** the window reads as a GNOME application. Two Class B gaps close as a side effect.

> **Session 7 — three of these are done, and one is larger than the line assumes.**
>
> | Item | State |
> |---|---|
> | `StatusPage` | **done.** Empty transcript (session 6), plus the models panel's not-installed state, its new no-matches state, and the trash's |
> | `Banner` | **done.** Backend-down with a Start button, and the LAN flag/socket disagreement — which the header subtitle had been reporting backwards, and now does not |
> | `ToastOverlay` | **done**, using owlkettle's own (`adw.nim:1374`, ungated). Confirmations enqueue on a `ToastQueue` the widget drains; errors keep the inline row with Retry. **P-B1 stays open**: a message you have to act on must not time out, and it needs the server's own detail — not because a toast cannot carry a button, which it can. [2026-09-29T22:30Z: only a stream error (`umError`) keeps the inline row; every other failure passes through `setNotice` and expires as a toast, and `ChatError.detail` is dropped, so P-B1 is partial] |
> | `ToolbarView` | available at `adw.nim:1010`, `{.since: AdwVersion >= (1, 4).}` — invisible only without `-d:adwminor=4`, which Phase 0 sets. Untouched |
> | `OverlaySplitView` | **done**, and it was **larger than it looked**: `Flap` folds itself through `FlapFoldAuto`, while `OverlaySplitView.collapsed` is a plain `bool` something must drive. libadwaita's answer is `AdwBreakpoint`, which owlkettle does *not* have, so `gui.nim` binds it by hand — and needs no split-view `GtkWidget` to do it, because the breakpoint belongs to the window: `BreakpointHost` takes the root window on `realize` and calls `adw_window_add_breakpoint`, the apply and unapply callbacks set `windowNarrow`, the 40 ms drain copies it into `app.narrow`, and that drives `collapsed` unless `alwaysShowSidebarOnDesktop` is set |
> | `PopoverMenu` + `ContextMenu` | **done** for the sidebar's chat, note and file rows: three inline icon buttons became one `⋯` plus right-click, so a row's name gets the width the controls were taking. Message rows are untouched |
> | `SplitButton` | available and untouched. Nothing in the composer has a secondary action to put on one yet, so it would be a widget in search of a use |
>
> **A dependency correction came out of this.** `requires "owlkettle >= 3.0.0"` was satisfied by
> both the `v3.0.0` tag and by `main`, which still calls itself 3.0.0 — and they differ:
> `ToastOverlay` and `ToolbarView` exist only after the tag. Which one a machine happened to have
> decided whether this window compiled. `jenova_core.nimble` now pins `ac61ecf`, the revision
> report 06 audited.

> **Session 8 closes Phase 3.** Everything above that was still open is done —
> `ToolbarView` carries the chat column, `OverlaySplitView` replaced `Flap` with
> `AdwBreakpoint` hand-bound to drive `collapsed`, `SplitButton` carries Send
> and its intent-prefix menu — and two things the phase did not list came out of
> finishing it:
>
> - **The app menu was still a `Popover` of flat `Button`s.** Every sidebar row
>   had already moved to `PopoverMenu` + `MenuItem`, for the reason `MenuItem`
>   exists: a plain button in a popover runs its handler and leaves the popover
>   standing over the window it just changed. The one menu the plan never named
>   was the one that still did it. Now `PopoverMenu` + `MenuItem` throughout.
> - **`AboutWindow` was compiled in and unused.** It was the last of the seven
>   `{.since: AdwVersion >= (1, x).}` widgets Phase 0 put back in the binary
>   with nothing using it, and the program's version was reachable only from
>   `--version` on a terminal. Its Troubleshooting page names the four paths a
>   bug report needs, which cannot be guessed from outside a relocatable tree.
>
> The version those three files each declared separately is now
> `src/jenova/version.nim`. The `.nimble` field stays a literal because nimble
> reads it before anything in `src/` compiles; nothing else declares one.

---

## Phase 4 — Keyboard and the command palette (1 session)

| Step | Detail |
|---|---|
| 4.1 | One custom `renderable` owning a window-level `GtkShortcutController` (report 06 §6), so bindings are declared in one place and the `Button.shortcut` constraint stops mattering |
| 4.2 | New chat, focus composer, toggle sidebar, search, settings, stop generation — **P-B12** |
| 4.3 | **P-E1** command palette over conversations, notes, files, settings and backend actions. Cheap once 4.1 exists; the first beyond-parity feature |

**Exit:** the window is keyboard-driveable. P-B12 closes, P-E1 ships.

> **State: 4.1 done; 4.2 partial; 4.3 open.** `src/jenova/shortcuts.nim` owns one window-level
> `GtkShortcutController` at managed scope and bindings are a `seq[Binding]` (`keyBindings` in
> `gui.nim`); no button carries a `shortcut` any more, which removes the container hazard at its
> source. Five bindings ship: F11, `<Ctrl>n`, `<Ctrl>b`, `<Ctrl>comma`, `<Ctrl>Escape`. Step 4.2
> also names focus composer and search, and neither is bound, so P-B12 is partial.
> [2026-09-29T22:30Z: corrected — this said 4.2 was done.] **P-E1, the command palette, does not
> exist** — `grep -in palette src/` finds only colour palettes — so P-B12 has not closed and P-E1
> has not shipped.

---

## Phase 5 — Settings, files and trash as native lists (1 session)

| Step | Detail |
|---|---|
| 5.1 | Rebuild the settings screen on `PreferencesPage` / `PreferencesGroup` / `ActionRow` / `ComboRow` / `SwitchRow` / `EntryRow`. **P-B7** (model information detail) becomes an `ExpanderRow` |
| 5.2 | **P-B6** Files and Trash on `ColumnView` — virtualised, sortable, native. Not a port of two Svelte routes |
| 5.3 | **P-A8** open, preview and export a file asset. As planned: the window wrote a `fileAssets` row for each attachment of a chat that belongs to a workspace, project or folder, and offered no way back to them — the most visible incoherence left. Done since: `openAsset` is reachable from the sidebar's file rows and from the Files panel |
| 5.4 | **P-B5** attachment "view all" · **P-B8** favourite models · **P-B11** selective export |

**Exit:** the three list surfaces are native. Four Class B gaps and one Class A gap close.

> **State: 5.1, 5.2 and 5.3 done; 5.4 open.** P-B6 — Files and Trash — landed as `ColumnView`s.
> The trash is one list over both of its kinds, and its Kind column tells a row-addressed item
> from a path-addressed one, because the two are restored by different calls (`trashPanel`).
> [2026-09-29T22:30Z: superseded — this said the trash stayed a plain list on purpose.] P-A8
> landed as `src/jenova/assetview.nim` plus `openAsset`. Header-click sorting is not wire-able:
> owlkettle binds no `GtkSorter` at `ac61ecf` (report 07, V-13).
>
> **5.1 was recorded open for longer than it was open, and report 06 §4 had it right the whole
> time.** The settings screen is built on `PreferencesGroup`, `ActionRow`, `ComboRow` and
> `SwitchRow` — `settingsField` and `settingsPanel` in `gui.nim`. `EntryRow` is deliberately not
> used and `settingsField` states the reason: it derives from `AdwPreferencesRow`, so it carries
> no `subtitle`, and in this panel the help text is the point. **What actually remains of 5.1 is
> P-B7 alone** — model information detail as an `ExpanderRow`.
> [2026-09-29T22:30Z: re-checked — P-B7, P-B5, P-B8 and P-B11 are all still absent: no
> `ExpanderRow` is used, and `exportConversations` still writes the whole of `api.exportAll()`.]

---

## Phase 6 — Inspectors (1 session)

Highest value-to-risk in the plan, and no browser can do it: the data is in-process.
`pipeline.Prepared` already carries intent, RAG hits, web hits, editor-document and trimmed-turn
count; `rag.query` already returns paths and scores. Both were discarded until this branch put
them on response headers.

**P-E5** pipeline inspector — what the model was actually sent, and how many turns were trimmed
to fit · **P-E4** retrieval inspector — which chunks the last turn retrieved, with scores ·
**P-B2** real processing state from the same channel · **P-B9** show the system message ·
**P-B10** `useThinking` toggle.

> **State: done.** `src/jenova/inspect.nim` parses the diagnostic headers into
> `inspect.Diagnostics`; the window holds one (`AppState.diag`), fills it from the stream (the
> `umDiag` branch of the channel drain) and clears it per request (`postConversation`). All five
> items in this phase are marked done in report 02's tracker.

---

## Phase 7 — Rendering and media (1–2 sessions)

**P-B4** per-code-block copy and preview · **P-A5** math · **P-A7** PDF viewing, which also
unblocks `pdfAsImage`, the one setting still honestly marked pending · **P-A3** audio capture
(`pipeline.contentFor` already emits `input_audio` parts, so only the recorder is missing; it
also unblocks `autoMicOnEmpty`, the last pending setting).

**P-A5 needs a decision before starting** — see Open decisions.

> **State: P-B4 done; P-A5's M-1, M-2 and M-3 shipped and M-4 open; P-A7 and P-A3 open.** The
> P-A5 decision was taken (open decision 1). M-1 is in the product: `markdown.nim`'s inline pass
> renders Greek, operator names and `^`/`_` inside the existing text block, on the path every
> reply takes.
>
> **Before M-3, M-2 and M-3's font half were written and not in the product, which this row and
> report 02 both described as "laid out and not painted".** That was too generous by a link step:
> `gui.nim` then imported neither `mathtex` nor `mathfont`, and `markdown.BlockKind` was `bkText,
> bkCode, bkTable` with no `bkMath`, so the parser, box layout, font probe and MATH-table reader were
> reachable only from `jenova_core.nim`'s self-tests. M-3 landed on 2026-09-10 (PROGRESS 00:18Z and
> 03:18Z): `gui.nim` imports both modules, `BlockKind` has `bkMath`, and the window reaches
> `mathtex.nim` (1,316 lines) and `mathfont.nim` (702) through `mdBlock` → `mathLayoutFor` →
> `mathtex.renderMath` and `initMathFont` → `mathfont.chooseFont`. It draws with Cairo — size
> variants by glyph index through a FreeType face, other glyphs as text — and with no usable maths
> font, or a formula that will not parse, it shows the literal LaTeX. M-4 is open and was dropped
> from `TODOS.md` without being done: `mathtex` still refuses `\begin{align}` and `cases`,
> `layoutRow` applies no inter-atom spacing, and `docs/usage.md` does not state the supported
> subset.
>
> P-A7 still has no rasteriser, so `pdfAsImage` is still pending, and P-A3 still has no recorder,
> so `autoMicOnEmpty` is too; both settings now name those blockers rather than the shipped one.
> [2026-09-29T22:30Z: still true. GPL code is now allowed, which widens the library choice for
> both; that choice is in `PLANS.md`.]

---

## Phase 8 — The comment standard (2–4 sessions)

Report 04's plan unchanged, last because it touches all 37 files and would collide with every
phase above. **Batches 1 and 2 are already done** (18 files, on `main` in `989c2b5d` (#117) —
originally `8033bdd` and `63a7440`, reflog-only — +629/−948 lines between them) — which is report
04's own recommended stopping point, so **batch 3 waits on your review of the shape those
produced.** 18 files is cheap to redo; 37 is not. [2026-09-29T22:30Z: corrected — the figures
given here, "−793 comment lines against +511", were batch 2's total-line diffstat alone; and
superseded — batches 3 to 8 ran the same day.]

`gui.nim` is batch 8, alone, last — and by then it will have been substantially rewritten by
phases 2–7, so schedule it against the new file, not the current one.

> **State: done, as executed history.** All eight batches and a residue sweep ran on 2026-09-03
> (`8033bdd`, `63a7440`, `a5b98522`, `8adf6666`, `6d40a72a`, `c2d0bede`, `54103ad9`, `28b1e52e`,
> `f3ebb8be`, all reflog-only) and reached `main` squashed into `989c2b5d` (#117), whose message
> quotes each batch; `gui.nim` went last, as batch 8, against the file of that day. The standard
> itself now lives in `AGENTS.md`. The two questions this left were answered by the USER on
> 2026-09-29T23:30Z (DECISIONS_LOG, ruling 7): the cross-references still in comments (91 comment
> lines in nine files: 71 labels or report references and 20 file:line citations, per report 04's
> census) are fixed where code is touched, never by a one-off strip. The comment share is 32.0%
> (`src/` and `tests/`, 44 files).

---

## Phase 9 — Parked, pending your ruling

**P-A1** MCP (if revisited, P-C2 argues for a *server-side* client: the Web UI probes `/cors-proxy`,
which this server does not serve, so its "Use jenova-server proxy" switch is disabled with a hint
naming a `--webui-mcp-proxy` flag that does not exist, and a remote MCP server that needs the proxy
cannot be used) · **P-A2** agentic loop, downstream of MCP, and
`toolCalls` (W-04), which no Nim code reads · **P-A4** TTS · **P-C3 / W-05** Push/Pull · **P-E3,
P-E6, P-E7** beyond-parity proposals; P-E1 is absorbed into Phase 4.
P-E8 is removed from this list — it shipped as the intent-prefix menu on the Send `SplitButton`
(`intentMenuItems`), as Phase 3's session 8 note records — and P-E2 turned out to be a parity gap,
the Web UI already moving items by drag (report 02). None of the items still parked here exists in
the Nim code; the Web UI has its own MCP client (`stores/mcp.svelte.ts`), agentic loop
(`stores/agentic.svelte.ts`) and speech synthesis (`services/audio.service.ts`), and reads and writes
`toolCalls` itself. The session-2 freeze on `jca_web` is superseded by the 2026-09-29T23:30Z ruling 4.

---

## Open decisions

1. ~~**Math rendering (P-A5)**~~ — **decided, session 9: in scope, and the framing above was
   wrong.** A fourth option existed and was not offered: a native Cairo layout over the font's
   own OpenType MATH table, which HarfBuzz exposes whole (`hb_ot_math_*`). TeX-quality metrics
   need **no package outside the GTK/Pango/Cairo stack and no process spawn** — though the build
   links HarfBuzz (`mathfont.nim`) and FreeType (`gui.nim`) explicitly through pkg-config rather
   than reaching them through Pango. The plan is
   `.devdocs/08-math-rendering.md`: two tiers, four phases, one open question (which font Tier 2
   prefers, and whether it may be a dependency). **Three of the four phases have since shipped**
   — M-1, M-2 and M-3 — leaving M-4. [2026-09-29T22:30Z: updated — this read "M-3's font half…
   leaving M-3's Cairo draw and M-4"; the draw landed on 2026-09-10.]
2. **D-15** — `etc/jenova.conf` sets `JENOVA_DRAFT=0` while its source profile and the README say
   the drafter is on; drift from `7b859f5` updating the profile without re-applying it. Untouched
   on purpose: it changes inference behaviour, and the fix is `hardware apply`, not a hand-edit —
   which is what `eee557e` reverted once already. [2026-09-29T22:30Z: the drift is still present
   (drafter default 0 against the profile's 1, which `README.md`'s profile table repeats), and the
   remedy is corrected — `hardware apply` writes `$JCA_HOME/etc/jenova.conf`, never the repo's
   `etc/jenova.conf`. Once that file exists `config.nim` reads the whole `$JCA_HOME/etc/`
   directory, so the repo's `etc/jenova.local.conf` stops applying. Under the ruling that the
   deployed build be separated from the repository, the open question is whether the repo should
   track a machine-specific `etc/jenova.conf` at all; see `PLANS.md`.]
3. ~~**Phase 2's fallback**~~ — **closed**: streaming into the virtualised `ListView` held (Phase
   2's State), so neither fallback was needed. The question was: if streaming into a virtualised
   `ListView` proves unstable, is virtualising only long conversations acceptable, or should the
   phase be reverted whole?

---

## Sequencing

| Phase | Why here |
|---|---|
| 0 | One line unlocks a seventh of the toolkit every later phase uses |
| 1 | Everything after is written blind otherwise |
| 2 | The structural change the rest sits on, and the riskiest — do it while the build is fresh |
| 3 | Mostly deletion once 0 and 2 land |
| 4 | Needs 3's stable container structure |
| 5 | Needs 0 for the row widgets |
| 6 | Independent; movable |
| 7 | Independent; movable |
| 8 | Touches every file; must not collide |

0 → 1 → 2 → 3 are strictly ordered. 4, 5, 6, 7 can be reordered. 8 is last.

[2026-09-29T22:30Z: in practice phases 2–7 largely completed while Phase 1 stayed open, and
Phase 8 ran early, on 2026-09-03. Forward sequencing now lives in `PLANS.md`.]
