# Report 05 — Execution Plan

**Supersedes the parity-port plan.** Report 06 established that owlkettle is not a constraint:
the window uses 18 of 85 available widgets, has 7 more compiled out of the build by omission, and
expresses structure through nested `Box`es because it was written to reproduce a browser DOM.

**The goal is restated:** not "reproduce the Web UI in GTK", but **build a native application on
the shared core**, which reaches parity on most items as a side effect and exceeds it on the rest.
Both surfaces are clients of the same `api.nim`, the same pipeline, the same retrieval. The
window's advantage is that it is a process on the machine.

**Rulings in force:** `jca_web` frozen · Push/Pull out of scope · MCP and TTS deferred.

---

## The reframe, concretely

| Was planned as | Is actually |
|---|---|
| P-B12 keyboard shortcuts — *blocked on replacing a mechanism* | One custom `renderable` holding a window-level `GtkShortcutController`. The existing mechanism is already window-scoped; its `assert` is an upstream `# TODO` with a narrow constraint (report 06 §6) |
| P-B6 dedicated Files/Trash pages — *M, port two routes* | `ColumnView` — a virtualised, sortable, native list. Smaller than the port |
| The settings screen — *drawn with Label + Button + Switch* | `PreferencesPage` / `ActionRow` / `ComboRow` / `SwitchRow` / `EntryRow`. Deletes code |
| M-01 render caches — *capped in session 2* | Symptom. `ListView` virtualises the transcript and the cache becomes viewport-sized |
| P-B1 error dialog, P-B2 processing state | `ToastOverlay` + `Banner` + `StatusPage`, all native, all currently unused |

---

## Phase 0 — Unlock the toolkit (½ session, do first)

Two changes, both small, both gating everything after.

| Step | Detail |
|---|---|
| 0.1 | Confirm the libadwaita version on the FreeBSD host (`pkg info libadwaita`), then set `-d:adwminor=<n>` in `jenova_core.nimble` beside the existing `-d:gtkminor=10 -d:gtk48`. This alone restores `OverlaySplitView`, `ToolbarView`, `SwitchRow`, `EntryRow`, `PasswordEntryRow`, `Banner`, `AboutWindow` and 13 properties (report 06 §2) |
| 0.2 | Record the standard from report 04 §3 in `CLAUDE.md`, so every phase below is written to it rather than retrofitted in Phase 6 |

**Exit:** the build sees the whole toolkit; the comment rule is where a future session reads it.

---

## Phase 1 — FreeBSD build and first run (1 session)

Unchanged in necessity, and now also validates Phase 0. `gui.nim` has never been type-checked
anywhere available: 30 of 35 modules check against a shimmed scratch tree, `jenova-core` builds
and runs 17 self-tests, and `gui.nim` gets only a differential parse against owlkettle stubs.

`nimble core` · `nimble gui` · `nimble suites` · fix what the real compiler rejects in this
branch's window edits · run it · **A-2** capture a GUI screenshot · **A-3** reorder the README to
lead with the window · record in report 03 what the first real build changed, so the harness's
blind spots are known rather than assumed.

**Exit:** green suite on FreeBSD, the window runs, `png/` has a desktop screenshot.

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

---

## Phase 2 — The transcript becomes a ListView (1 session)

The single largest structural change, and the one everything else sits on.

| Step | Detail |
|---|---|
| 2.1 | Replace the `for m in app.messages` loop (`gui.nim:3674`) with `ListView`, `size = app.messages.len`, `viewItem(index)` building one message |
| 2.2 | Reduce `BlockMemo` / `ParseMemo` / `thumbCache` to viewport scale; keep the caps and the clearing — a smaller working set does not make an unbounded cache safe |
| 2.3 | Re-verify streaming: the last row updates every token. Confirm `ListView`'s `update` hook (`widgets.nim:4487`) re-runs `viewItem` for bound rows, and that autoscroll still pins |
| 2.4 | `Clamp` around the transcript for a reading-width column |
| 2.5 | `Avatar` + `ActionRow` idiom for message headers, replacing the "YOU"/"JENOVA" text labels |

**Risk: this is the highest-risk phase in the plan.** Streaming into a virtualised list is the
one place where `ListView`'s recycling and the token stream can fight. If 2.3 does not hold,
fall back to virtualising only conversations above a length threshold and record why.

**Exit:** a long conversation costs viewport memory, not conversation memory.

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
> | `ToastOverlay` | **done**, using owlkettle's own (`adw.nim:1374`, ungated). Confirmations enqueue on a `ToastQueue` the widget drains; errors keep the inline row with Retry. **P-B1 stays open**: a message you have to act on must not time out, and it needs the server's own detail — not because a toast cannot carry a button, which it can |
> | `ToolbarView` | available at `adw.nim:1010`, `{.since: AdwVersion >= (1, 4).}` — invisible only without `-d:adwminor=4`, which Phase 0 sets. Untouched |
> | `OverlaySplitView` | available, but **larger than it looks**: `Flap` folds itself through `FlapFoldAuto` and `OverlaySplitView.collapsed` is a plain `bool` something must drive. libadwaita's answer is `AdwBreakpoint`, which owlkettle does *not* have — and binding it also needs the split view's own `GtkWidget`, which owlkettle does not expose from a `gui:` block. Plan the three together, or the swap trades a deprecated widget for a sidebar that stops adapting |
> | `PopoverMenu` + `ContextMenu` | **done** for the sidebar's chat, note and file rows: three inline icon buttons became one `⋯` plus right-click, so a row's name gets the width the controls were taking. Message rows are untouched |
> | `SplitButton` | available and untouched. Nothing in the composer has a secondary action to put on one yet, so it would be a widget in search of a use |
>
> **A dependency correction came out of this.** `requires "owlkettle >= 3.0.0"` was satisfied by
> both the `v3.0.0` tag and by `main`, which still calls itself 3.0.0 — and they differ:
> `ToastOverlay` and `ToolbarView` exist only after the tag. Which one a machine happened to have
> decided whether this window compiled. `jenova_core.nimble` now pins `ac61ecf`, the revision
> report 06 audited.

---

## Phase 4 — Keyboard and the command palette (1 session)

| Step | Detail |
|---|---|
| 4.1 | One custom `renderable` owning a window-level `GtkShortcutController` (report 06 §6), so bindings are declared in one place and the `Button.shortcut` constraint stops mattering |
| 4.2 | New chat, focus composer, toggle sidebar, search, settings, stop generation — **P-B12** |
| 4.3 | **P-E1** command palette over conversations, notes, files, settings and backend actions. Cheap once 4.1 exists; the first beyond-parity feature |

**Exit:** the window is keyboard-driveable. P-B12 closes, P-E1 ships.

---

## Phase 5 — Settings, files and trash as native lists (1 session)

| Step | Detail |
|---|---|
| 5.1 | Rebuild the settings screen on `PreferencesPage` / `PreferencesGroup` / `ActionRow` / `ComboRow` / `SwitchRow` / `EntryRow`. **P-B7** (model information detail) becomes an `ExpanderRow` |
| 5.2 | **P-B6** Files and Trash on `ColumnView` — virtualised, sortable, native. Not a port of two Svelte routes |
| 5.3 | **P-A8** open, preview and export a file asset. The window writes `fileAssets` rows on every attachment and offers no way back to them — the most visible incoherence left |
| 5.4 | **P-B5** attachment "view all" · **P-B8** favourite models · **P-B11** selective export |

**Exit:** the three list surfaces are native. Four Class B gaps and one Class A gap close.

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

---

## Phase 7 — Rendering and media (1–2 sessions)

**P-B4** per-code-block copy and preview · **P-A5** math · **P-A7** PDF viewing, which also
unblocks `pdfAsImage`, the one setting still honestly marked pending · **P-A3** audio capture
(`pipeline.contentFor` already emits `input_audio` parts, so only the recorder is missing; it
also unblocks `autoMicOnEmpty`, the last pending setting).

**P-A5 needs a decision before starting** — see Open decisions.

---

## Phase 8 — The comment standard (2–4 sessions)

Report 04's plan unchanged, last because it touches all 37 files and would collide with every
phase above. **Batches 1 and 2 are already done** (18 files, `8033bdd` and `63a7440`, −793 comment
lines against +511) — which is report 04's own recommended stopping point, so **batch 3 waits on
your review of the shape those produced.** 18 files is cheap to redo; 37 is not.

`gui.nim` is batch 8, alone, last — and by then it will have been substantially rewritten by
phases 2–7, so schedule it against the new file, not the current one.

---

## Phase 9 — Parked, pending your ruling

**P-A1** MCP (if revisited, P-C2 argues for a *server-side* client: `/cors-proxy` is called by the
frozen Web UI and not served, silently disabling remote MCP servers there) · **P-A2** agentic loop,
downstream of MCP, and `toolCalls` (W-04) stays unread until it exists · **P-A4** TTS ·
**P-C3 / W-05** Push/Pull · **P-E2, P-E3, P-E6, P-E7, P-E8** beyond-parity proposals; P-E1 is
absorbed into Phase 4.

---

## Open decisions

1. **Math rendering (P-A5)** — KaTeX is a browser library with no GTK equivalent. Pango-drawn
   subset (native, limited), external TeX renderer (correct, heavy), or out of scope. Blocks 7.
2. **D-15** — `etc/jenova.conf` sets `JENOVA_DRAFT=0` while its source profile and the README say
   the drafter is on; drift from `7b859f5` updating the profile without re-applying it. Untouched
   on purpose: it changes inference behaviour, and the fix is `hardware apply`, not a hand-edit —
   which is what `eee557e` reverted once already.
3. **Phase 2's fallback** — if streaming into a virtualised `ListView` proves unstable, is
   virtualising only long conversations acceptable, or should the phase be reverted whole?

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
