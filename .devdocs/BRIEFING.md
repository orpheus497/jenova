# BRIEFING

**Last updated:** 2026-08-31 20:58
**Branch:** `bsd`

---

## 0. READ THIS BEFORE DOING ANYTHING

Every rule below exists because it was broken, repeatedly, and cost the USER a day.

| # | Rule |
|---|---|
| **1** | **Never state anything you have not run.** "The tray works", "the UI freezes", "this will break" — all asserted without testing, all wrong or unknown. If it was not executed, say "I don't know". |
| **2** | **This is a Nim program. It has no Makefile and no shell scripts.** Build with `nimble`. Do not write, repair, or discuss shell scripts, installers or Makefiles. They are archived. |
| **3** | **Do not reinvent what exists.** `std/json` parses JSON. `upstream.nim` relays SSE. Before writing a parser, client or helper, check whether the codebase or the stdlib already has one. |
| **4** | **Do not rebuild old patterns.** The two-command split (server started separately from the app) was rebuilt after the USER had already killed it. `llama-server` is the engine — do not duplicate it in Nim. |
| **5** | **Anything not in use goes to `.devdocs/ARCHIVE/`.** Not deleted, not left lying in the root. |
| **6** | **Comments: only where the code is not self-explanatory.** `AGENTS.md` forbids retroactive comment editing. Do not write essays above functions. Do not "improve" existing comments. |
| **7** | **Do not ask what has been answered.** Check `DECISIONS_LOG.md` SETTLED FACTS first. The Vulkan2 device list and "the app starts its own server" were each re-raised after being settled. |
| **8** | **Do not write derivable facts into these documents.** Counts, file lists and subcommand lists rot immediately and cause the doc-churn loop. Point at the code. |
| **9** | **A tracker that names a file must be re-read when that file is archived.** `BLUEPRINT.md` described `proxy.lua` and `jenova-ca` for three sessions after they were deleted, while being the file `AGENTS.md` calls authoritative (**D-AO**). A stale document does not sit inert — it manufactures work. |

---

## 1. State

| | |
|---|---|
| **What it is** | A native FreeBSD desktop application in Nim. `llama-server` does inference; this is the harness around it |
| **Binaries** | `bin/jenova` — the desktop app (window, tray, chat, backend control). `bin/jenova-core` — headless server. Both link the same modules; the split exists so a LAN/server host builds without GTK |
| **Build** | `nimble`. Tasks are in `jenova_core.nimble`. **No Makefile** |
| **Architecture** | `BLUEPRINT.md` — rewritten 2026-08-31 and current. The pre-rewrite audit record is `ARCHIVE/devdocs/BLUEPRINT_pre-007.md` and is **history, not requirements** |
| **Language purity** | No Lua. No C. No shell script in the product tree except `hardware-profiles/`'s profile-selection tooling, which is setup-time data handling |
| **Runtime home** | `$HOME/Jenova`. `~/JCA` is permanently off limits |
| **Tests** | Five suites under `tests/`, run by `nimble suites`. **Re-run 2026-08-31 19:23: four pass, `test_routes` FAILS 5** — pre-existing, attributed by rebuilding from the committed baseline and getting the identical five (`TODOS.md` T-12). The previous entry here said "reported passing at Session 006; not re-run since", which is how a stale pass survives four sessions |

## 2. Verified working, by running it

**Confirmed by the USER on the 20:49 build (2026-08-31 20:52), a completed session:**

- The window, the theme, the canvas, the glass side panel, the workspace tree, the wordmark.
- Notes: create, edit, save, and visibility at every container level.
- Markdown text and code blocks; **chat bubbles sized to their content**.
- Fullscreen and F11, **with the top bar still present and its controls reachable**.
- **Quit — from the menu and the tray — leaves no core.** That is T-1's actual test.

**Confirmed at Session 006 and not re-run since** *(older, and labelled so a stale pass cannot
survive again)*:

- The tray icon registers.
- `bin/jenova` starts the HTTP server and both backends itself — one command, no separate `serve`.
- The embedding server comes up on `:8082`.
- The agent `llama-server` comes up on `:8081` **now that `Vulkan2` is out of `etc/jenova.local.conf`** — it was rejecting the whole `-dev` argument and dying instantly.
- Conversations persist to the `conversations`/`messages` tables and reload at startup.
- Clean exit: both worker threads join, no hang.

## 3. Known broken

**Nothing is known broken** — and unlike the last time this section said that, it is backed by a
**completed run**: the USER tested the 20:49 build and quit it (*"tested seems all resolved"*), the
newest core is **20:42 from the previous build**, and the process exited leaving none. **An uptime
sample would not have counted. An exit with no core does.**

The record below is kept because the *route* to it is the expensive part.

### T-1, closed 20:52 — the SIGBUS was the Quit path

**The USER diagnosed it** — *"i think the issue is the quit button"* — after **five** of my
hypotheses had died.

```nim
changed = true          # set for EVERY action, quit included
if action == "quit":
  st.closeWindow()      # destroys the window and every GtkWidget under it
...
if changed:
  discard st.redraw()   # gui.nim:490 — diffs a tree of freed widgets
```

**Fix:** a `quitting` flag, `return false` immediately after `closeWindow` (which also removes the
timeout), and the same guard on the other two timers — the 3 s poll redraws, and the canvas timer's
`queueFrame` addresses the DrawingArea directly.

**Why five hypotheses died first, and it is one mistake repeated.** Every core was read for *where*
it faulted, never for *when*. The faulting widget is always the header bar's **`left[0]` — simply
the first widget in tree order carrying a handler to disconnect**, i.e. the first thing a doomed
diff touches. It was never that widget's fault, which is why `ToggleButton` → `Button` changed
nothing. **And the real signal was in the USER's own words twice: every session ran fine and left a
core. It was crashing on exit.** "All good so far" and a fresh core were both true; I read them as
contradicting instead of as telling me *when*.

| Claimed cause | Killed by |
|---|---|
| ORC collecting owlkettle's `state → event → state` cycles (**D-AS**) | `--mm:arc` shipped; it still crashed |
| The 30 fps whole-tree redraw | Removed; it still crashed, just rarer |
| GTK4 unparenting a fullscreened custom titlebar | **The session that never entered fullscreen crashed too** |
| `ToggleButton` reentrancy via `gtk_toggle_button_set_active` | Replaced with a plain `Button`; **the next core is identical — which is what proved the fault is positional, not per-widget** |

**All three code changes are retained on their own merits and none was the fault.** D-AS is partly
retracted.

**And a process failure worth more than the bug.** At 20:15 I reported "1:47 elapsed, no core" as
evidence the fix held. **That process is core 40484 — it died two minutes later.** Sampling a
*live* program and finding no crash *yet* is not a result. **Rule 1 was broken in the act of citing
it.** A fix is confirmed by a **completed** session that exercised the failing path.

**Chat bubbles were "weirdly huge" — fixed 20:20, CONFIRMED 20:52.**
Every child of the transcript column was unannotated, and **`Box`'s adder defaults to
`expand: true`**, which in a vertical Box is `vexpand` — so each message card took an equal share of
the viewport height. **§3a already carried that rule and it was not applied here.** Not attributed
to the 20:10 fix: it is structurally present in the committed source, and the build that first
shipped this column crashed before it could be evaluated.

**The top bar vanished in fullscreen — fixed 20:49, CONFIRMED 20:52.** The USER: *"when going
to full screen the top bar is missing."* **Not a regression — the GTK4 behaviour G-13c already
recorded**, now taking the sidebar toggle, the app menu and the status line, because
`HeaderBar {.addTitlebar.}` means `gtk_window_set_titlebar` and GTK4 hides that in fullscreen.
**`Window` → `AdwWindow`** (which has no titlebar slot) with the bar extracted into
`proc topBar(app): Widget` and inserted at the top of the chat column — where it stays mapped.
Atop the chat column rather than spanning the window because the Web UI's sidebar is full height.
**Window controls survive** (`showTitleButtons` defaults true — checked). **Given up, and stated:**
`AdwWindow` has no `title` field, so the WM/taskbar title may be empty; the bar's own `WindowTitle`
still reads "Jenova".

**The core inventory is `TODOS.md` T-1** — ten, 15:26 through 20:41, all SIGBUS with the same
stack. It is not repeated here; a count in two places is rule 8's doc-churn loop.

**The previous entry's dismissal rested on `BRIEFING.md:54`: *"no debugger here reads a FreeBSD
core."* `gdb 15.1 [GDB v15.1 for FreeBSD]` is installed and read all five.** Rule 1 forbids stating
what was not executed, and **it equally forbids denying it**. Before writing down that evidence
cannot be obtained, **try to obtain it** — that is D-AS, and it is the more expensive lesson than
the one this section used to carry.

**A stack tells you where, not why.** The frame shape was read as the chat column's `Box`; the
library shows `Box.children` pops correctly and **never calls `updateChildren`**. The frame is the
HeaderBar's. **Match a backtrace against the source before inferring a mechanism from it.**

## 3a. The live workstream — GUI parity (D-AP)

The GUI is the product; `jca_web` becomes the ephemeral single-device LAN client. **Everything
built has been run.** The USER ran it at 18:30, named four visual defects, and confirmed the fixes
at 18:55: *"for the most part it looks good."* **Working and seen:** theme, canvas, glass side
panel, workspace tree, wordmark, markdown text and code blocks. **What is missing is §3b's list, not
this one** — G-6 was retired and triaged at 20:10, and **MCP came out of it entirely** (D-AT).

**The 19:11 build did not work, and the reason is worth keeping (G-14, G-15).** Notes could never
be created — `physicalPath` refuses a non-UUID id, so `upsert` deleted every row it wrote — and
anything created below the top level was invisible because only the immediate parent id was set
while the tree matches on all three. **The database found both before any code was read:** zero
rows, *not even soft-deleted ones*, is the signature of a rollback rather than of a button that
does nothing. Both fixed at 19:23. **G-15 was pre-existing and shipped inside the half of G-4 that
was "confirmed on screen" at 18:55** — confirmation covers the path that was exercised and nothing
else.

**The 19:23 build was run and the USER confirmed it at 19:38: the panel, the tree and notes work.**
That closes G-12 (in-app Quit, which had existed only in the tray), G-13a (a way out of fullscreen —
`fullscreened` was a property the program never bound), and **G-4 entirely**, notes and fileAssets
included.

**A standing correction, because it was made three times and the third time was indefensible.** I
wrote "built, not yet run" about the panel, the tree and notes *while the USER was reporting defects
in them from photographs of the running window*. **A defect report from the screen is proof of a
run.** Do not carry an "unrun" label past the first piece of evidence that contradicts it; rule 1
forbids claiming what was not executed, and it equally forbids denying what plainly was.

**G-13c — the fullscreen toggle was a one-way door, and it was ours.** The USER, 19:39: it *"cuts
the top of the gui off and theres no way to exit it."* **GTK4 hides a titlebar set through
`gtk_window_set_titlebar` while a window is fullscreened** — that is the cut-off top — and the
HeaderBar it hides held the only control that could leave. The button now lives in the **bottom
action row**, which stays mapped, with an **F11** accelerator; the accelerator has to hang off an
always-mapped widget because owlkettle attaches the shortcut controller at
`GTK_SHORTCUT_SCOPE_MANAGED`. **This exact mechanism was written down at 18:55 and then discarded**
because the USER's answer said the header bar stays — true of a *compositor* fullscreen, false of
ours. **A hypothesis disproved for one event is not disproved for a different event with the same
symptom.**

**G-7 is done in source (19:39), compiled and linked, unrun.** Syntax highlighting through a
hand-written `gtksourceview-5` 5.18.0 binding in new `sourceview.nim`. Two things worth knowing
before touching it: owlkettle's `renderable` macro emits an **unexported** type, so the widget must
be declared in `gui.nim`; and owlkettle's header-less `gtk_text_view_set_editable`/`_monospace`
prototypes **conflict at the C level** with `gtksource.h`, so those two are re-declared under
Nim-side names. `nm -u` shows all nine `gtk_source_*` symbols referenced — **it links; it has not
rendered.**

**G-13b — fullscreen not filling, and glitching — is DEFERRED at the USER's direction:** suspected
to be their compositor rather than the program. **Not work unless identified.** It is a *separate*
item from G-13c and stays deferred; four hypotheses were checked and all four died, and the record
is in `TODOS.md` so they are not re-derived.

**The method that found G-8 … G-11 is the thing worth keeping.** The USER described the screen in
one sentence; every item was then traced to a specific line before a word was written down, and the
one hypothesis that felt obvious (a light-theme `.background` inheriting black text) was **checked
and discarded** — the app forces dark at `gui.nim:998` and the sheet loads at priority 600. Four
defects, four mechanisms, no speculation. Contrast with Session 007, which read the same trackers
and reported that no new defect existed.

**Read D-AR before touching `gui.nim`.** Four rounds shipped a broken window because a scripted bulk
edit was followed by a compile and nothing else. **`nimble gui` exiting 0 says the widget tree is
valid, never that it is right**, and one such edit inserted a wrapper without re-indenting its body
— the panel rendered as five columns and compiled cleanly. Layout changes go through the harness's
edit tooling as one block, read back before building.

**Sizing APIs are minimums.** `min-width`, `sizeRequest` and the flap's `width` were each reached
for as if they capped something. To make a `Picture` small, decode it small.

**`Box`'s adder defaults to `expand: true`**, and `insert(...)` inherits that default. `hexpand`
propagates **up** the tree, so one greedy button makes the whole panel greedy.

## 3b. The parity scope, named by the USER (20:10, **D-AT**)

**`G-6` is retired as a heading and triaged into `TODOS.md` G-16 … G-21:** the filesystem view and
browser, the writer/editor, **file awareness**, **Neovim in a tab**, the models selector, the trash
view. **MCP is DEFERRED — *"we dont need mcp for the gui yet"*.** That matters because MCP was the
largest item by far and the only one that is not a view to port: the Web UI's is a browser-side
`@modelcontextprotocol/sdk` client with an agentic tool loop, and `grep -rin mcp src/` returns two
hits, both a TEXT column. **Everything else in the list is GUI work over a backend that exists.**

**Neovim is a `vte4` terminal hosting `nvim --listen <socket>`, not a re-implemented UI** (D-AT) —
so the USER keeps their own Neovim and their own config, and **G-18's file awareness becomes a
socket query** (`nvim_get_current_buf` + `nvim_buf_get_lines`) rather than a filesystem guess.

## 4. Outstanding

**`TODOS.md` T-1 … T-10 plus G-13b is the outstanding list.** T-1 … T-10 were re-verified against
the tree on 2026-08-31 and all ten hold. **G-8 … G-11 are closed and confirmed on screen**; G-12
and G-13a are compiled and unrun. **G-8 … G-13 were the first defects in this project found by
looking at the running window rather than by reading unrun code** — the USER ran it, described what
was wrong, and each item was then traced to a line, with the hypotheses that did not survive being
recorded as disproven rather than quietly dropped. The sequenced plan is `PLANS.md`:

0. **GUI parity — run 19:02 to confirm G-12/G-13a, get a terminal capture for G-13b, then G-4's
   remaining half (notes/fileAssets), G-7, G-6.** The live workstream, §3a; everything below is
   queued behind it.
1. **Stabilise** — T-2 … T-5. **Nothing blocks**; T-1 is unexplained, not a gate.
2. ~~The `jca_web` workspace question~~ — **answered by D-AP**; it is the GUI parity work.
3. **Deployment** — one decision, taken once (T-7).
4. **CLI** — after the above (T-8).

Independent of all four: profile data hygiene, T-9 and T-10.

**Explicitly not work:** the archived shell tree. It is gone, not pending.

## 5. Settled — do not re-raise

| | |
|---|---|
| **Engine** | `llama-server`, always. In-process `libllama` was deleted, not deferred |
| **Devices** | `Vulkan0,Vulkan1`. There is no Vulkan2 on this machine |
| **Startup** | The app starts its own server and backends. One command |
| **`~/JCA`** | Off limits, permanently |
| **Licence** | AGPL-3.0; copyleft dependencies permitted |
| **TUI** | Replaced by the window |
| **Tray** | StatusNotifierItem over D-Bus, in Nim. It works |
| **Unused files** | Archive to `.devdocs/ARCHIVE/`, never delete, never leave in the root |
