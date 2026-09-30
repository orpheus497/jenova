# Report 06 — Owlkettle Capability Audit

> **Status as of 2026-09-29T22:31Z** (baseline `4acedfa0` / `154e0cf9` mode-only; host Arch Linux, GTK 4.22.5, libadwaita 1.9.4).
> **Current:** owlkettle is installed at the pinned `ac61ecf` (its `nimblemeta.json` `vcsRevision`), and every owlkettle line cited below re-checks. The window uses 41 of the 85 renderables and nothing is compiled out; §2a records the toolkit floor.
> **Superseded:** the "fifth of the toolkit" answer, the per-session counts, and every `gui.nim` line number written before this pass. Once-true narrative is annotated, not deleted.
> **Re-checked 2026-09-30T01:16Z:** every claim a code verification flagged was read against the code and the pinned owlkettle, and corrected in place.
> Forward work: see PLANS.md.

**Method:** `owlkettle` 3.0.0 was cloned at `ac61ecf` (2026-07-20) and read. Every claim below
cites the line that produces it. Nothing is asserted from memory or from the comments in
`gui.nim`, several of which turned out to describe the framework wrongly.
**Question asked:** is owlkettle a constraint on building a proper native window, or has this
project simply not used it?
**Answer:** it is not a constraint. The window uses roughly a fifth of the toolkit, has compiled
a further seventh of it out of the build by omission, and reaches for `Button` and `Label` where
native widgets exist. [2026-09-29T22:31Z: true at first audit; at `4acedfa0` the window uses 41
of the 85 and nothing is compiled out — §1, §2.]

---

## 1. The census

| | Available | Used by `gui.nim` |
|---|---|---|
| `owlkettle/widgets.nim` renderables | **62** | — |
| `owlkettle/adw.nim` renderables | **23** | — |
| **Total** | **85** | ~~**18 distinct types**~~ → **38 after session 7**, **39 after session 8** (`AboutWindow`), **41 at `4acedfa0`** (`DrawingArea` came with M-3) |

[2026-09-29T22:31Z: corrected — "46 counted 2026-09-09" stood here and does not reproduce: 40
distinct renderables at `989c2b5d` and 41 at `4acedfa0`, counting DSL lines that open one of the
85. The per-session figures are as first recorded and cannot be re-derived from git.]

> **Session 7 first "corrected" these to 21 and 83, and that was wrong.** The
> recount was taken against the **`v3.0.0` tag**; this report states its revision in
> its own header and audited **`ac61ecf`, which is `main`** — where `grep -c
> "renderable [A-Z]" owlkettle/adw.nim` returns 23. The figures above are restored
> and the revision distinction is now stated wherever it changes an answer, because
> it changes several. **The two are not interchangeable and `jenova_core.nimble`
> could not tell them apart** until session 7 pinned it: owlkettle's `main` still
> declares `version = "3.0.0"` in its own nimble file, so `requires "owlkettle >=
> 3.0.0"` was satisfied by both.

Of ~160 widget instances in `gui.nim`, **130 are `Button` (72) or `Label` (58)**.
[2026-09-29T22:31Z: at `4acedfa0`, 319 widget lines across 41 renderables — `Button` 67, `Box`
67, `Label` 60.]

That ratio is the finding. A native toolkit offering 85 widgets is being used as though it
offered two, with structure expressed through nested `Box`es and CSS classes. It is a web
document tree rendered by GTK.

> **Sessions 7 and 8 closed §4 and §3's widget half.** [2026-09-29T22:31Z: first written as
> "Session 7 closed §4 and §3". §3's cache half is still open, and report 05's Phase 3 record
> puts `ToolbarView`, `OverlaySplitView`, `SplitButton` and `BreakpointHost` in session 8.]
> The window then used **38** distinct owlkettle renderables,
> having added `ActionRow`, `Avatar`, `Banner`, `Clamp`, `ColumnView`, `ComboRow`, `ContextMenu`,
> `ListView`, `MenuButton`, `OverlaySplitView`, `PopoverMenu`, `PreferencesGroup`, `SplitButton`,
> `StatusPage`, `SwitchRow`, `ToastOverlay` and `ToolbarView` — plus two hand-bound widgets for
> things owlkettle does not have at all: `MenuItem` (a `GtkModelButton` that closes the menu it
> is in) and `BreakpointHost` (`AdwBreakpoint`, which nothing in owlkettle binds).
>
> `Button` and `Label` counts barely moved (72→67, and `Label` 58 then, 60 at `4acedfa0` — this line once said 55), and that is expected: the
> substitutions replaced *structure* — a Box of a Label and a Switch became a `SwitchRow`, a Box
> of message cards became a `ListView` — while buttons and labels remain what a button and a
> label are. The ratio was a symptom of the structure, not of the leaf widgets.

---

## 2. What was compiled out of the build entirely · **resolved** (was severity: high)

[2026-09-29T22:31Z: resolved — `jenova_core.nimble`'s `NimFlags` sets `-d:gtkminor=10
-d:adwminor=4` and no `-d:gtk48`, which is dead at the pin (report 07, V-01), so nothing below is
compiled out. As first found:]

`owlkettle/bindings/adw.nim:29`:

```nim
const AdwMinor {.intdefine: "adwminor".}: int = 0 ## ... Defaults to 0.
const AdwVersion* = (AdwMajor, AdwMinor)
```

**`-d:adwminor` is never set anywhere in this repository.** `jenova_core.nimble` sets
`-d:gtkminor=10 -d:gtk48` and stops. So `AdwVersion` is `(1, 0)` at compile time, and every
widget guarded `{.since: AdwVersion >= (1, x).}` does not exist in the binary:

| Widget | Since | What it is |
|---|---|---|
| `OverlaySplitView` | 1.4 | The modern adaptive sidebar. ~~The window uses `Flap` instead~~ — in use; `Flap` is gone |
| `ToolbarView` | 1.4 | Header/content/footer layout with correct adaptive styling. In use |
| `SwitchRow` | 1.4 | A labelled switch row — the native settings primitive. In use |
| `EntryRow` | 1.2 | A labelled text-entry row. Compiled in, unused by design (§4) |
| `PasswordEntryRow` | 1.2 | Ditto, masked. Compiled in, unused |
| `Banner` | 1.3 | Inline message strip with an optional button. In use |
| `AboutWindow` | 1.2 | The standard About dialog. **In use since session 8** — app menu → About Jenova. Deprecated in libadwaita 1.6 (§2a) |

> **This table is correct and session 7 briefly claimed otherwise.** `ToolbarView`
> was struck from it on the finding that `grep -rn ToolbarView owlkettle/` returns
> nothing — which is true of the **`v3.0.0` tag** and false of `ac61ecf`, the
> revision this report audits and the one `jenova_core.nimble` now pins. It is
> declared `renderable ToolbarView {.since: AdwVersion >= (1, 4).}` at
> `adw.nim:1010`, so it is exactly what this section says it is: present, and
> compiled out at `adwminor=0`.
>
> **All seven are now in the binary.** `-d:adwminor=4` is set, and `Banner` is in
> use in `gui.nim`'s chat column — for backend-down, and for the LAN flag/socket
> disagreement (session 7).
>
> **Five of the seven are in use** — `OverlaySplitView`, `ToolbarView`, `SwitchRow`,
> `Banner` and `AboutWindow`, the last from session 8. [2026-09-29T22:31Z: corrected — this
> said "six"; `EntryRow` is deliberately unused, for the reason §4 gives.] `PasswordEntryRow` has
> nothing to mask: `settings.OmittedFields` records `apiKey` as
> `"excluded by the USER — this server does not authenticate"`, and the search
> backend it does reach takes no key either: `websearch.search` queries DuckDuckGo's HTML
> endpoint (`html.duckduckgo.com/html`) and falls back to the instant-answer API
> (`api.duckduckgo.com`) only when that returns nothing, with no key on either request. A masked entry row with no secret behind it would be
> decoration.

Plus **six** gated properties on widgets that do compile — `ButtonContent.canShrink` (1.4),
`PreferencesPage.description` (1.4), `ExpanderRow.titleLines`/`subtitleLines` (1.3) and
`AdwHeaderBar.showBackButton`/`showTitle` (1.4) — and four `when AdwVersion` branches in
`adw.nim`: one inside a hook (`ExpanderRow`'s `actions` hook, choosing the suffix or action adder,
line 386), one in `AdwHeaderBar`'s `addTitle` adder (900), and two in the plain `toGtk(toast)` proc
— the custom title and clicked handler at 1.2 (1338) and markup at 1.4 (1355). [2026-09-29T22:31Z: corrected — this said "13 individual
properties", which also counted the seven widgets' own `since` pragmas, and named
`StatusPage.description` (ungated) and `ActionRow.titleLines` (`ActionRow` has none).]

**This is a one-line fix in `jenova_core.nimble`** and it is the highest-leverage change in the
whole plan. The installed GTK is 4.20.4; libadwaita's version on the target host must be
confirmed and `-d:adwminor` set to match. [2026-09-29T22:31Z: done — `-d:adwminor=4`. 4.20.4 was
the FreeBSD host; this Arch host has GTK 4.22.5 and libadwaita 1.9.4. 4 is also the highest
libadwaita gate owlkettle `ac61ecf` has, so matching a newer libadwaita gains nothing — §2a.]

## 2a. Toolkit floor and deprecations

*Added 2026-09-29T22:31Z. Distro versions are approximate.*

* **Floor.** GTK ≥ 4.10 (`-d:gtkminor=10`: `SearchEntry.placeholderText`, `Picture.contentFit`)
  and libadwaita ≥ 1.4 (`-d:adwminor=4`, plus the hand-bound `adw_breakpoint_*` and
  `adw_window_add_breakpoint`, both `ADW_AVAILABLE_IN_1_4`). Arch (4.22 / 1.9, this host), Fedora
  42–43 (≈4.18–4.20 / 1.7–1.8), Debian 13 (≈4.18 / 1.7) and FreeBSD (≈4.20 / 1.8) clear it;
  Debian 12 (≈4.8 / 1.2) does not.
* **Headroom.** `ac61ecf` gates nothing above libadwaita 1.4, so `AdwDialog`, `AlertDialog`,
  `AboutDialog`, `NavigationView`, `TabView`, `BottomSheet` and `ShortcutsDialog` are reachable
  only through the §5 hatch.
* **Deprecated on every target, removed only in GTK 5 / libadwaita 2:** `AboutWindow`
  (`AdwAboutWindow`, deprecated in 1.6 for `AdwAboutDialog`); `FileChooserDialog` and
  `MessageDialog` (the GtkDialog family, 4.10); owlkettle's `style =` path through `GtkStyleContext`
  classes (`gtk_style_context_add_class` in `widgetutils.nim`, 4.10); `Picture` through
  `gtk_picture_set_pixbuf` (4.12); `gtk_css_provider_load_from_data` (4.12, in owlkettle's
  `mainloop.nim` and in `theme.nim`). owlkettle also declares `gtk_widget_show`/`hide` (4.10) in
  `bindings/gtk.nim`, but neither it nor `src/` calls them. owlkettle declares header-less
  prototypes, so none of these warns at build time.
* **Private type.** `MenuItem`, like owlkettle's own `ModelButton`, creates `GtkModelButton` by
  name through `g_type_from_name`. GTK 4.22.5 exports no constructor for it; it works today with no
  API guarantee, and every menu in the window depends on it.
* **This host.** `nimble gui` fails under gcc 16.2 and clang 22.1: `vte.nim` passes a Nim-declared
  `GdkRGBA` to the header-declared `vte_terminal_set_colors`. With that one error downgraded the
  window builds and `--check` passes, and libadwaita warns that `gtk-application-prefer-dark-theme`
  is unsupported in favour of `AdwStyleManager:color-scheme`.

Forward work: see PLANS.md.

---

## 3. The transcript · **widget half done; cache half open**

**As first written this section read "the transcript is not virtualised · severity: high", and
quoted the `for i, m in … Frame` loop at `gui.nim:3674` (at `c5111ce`) that built one live widget
subtree per message.** That loop is gone. The transcript is a `ListView` (in `gui.mainArea`), so
the heading and the excerpt are kept only as the statement of what was fixed.

**`ListView` (`widgets.nim:4432`) is GTK4's virtualised list and owlkettle exposes it fully.**
It creates a `GtkSignalListItemFactory` and a `GListStore`, then calls `gtk_list_view_new` with a
nil selection model and that factory. Its bind callback builds a row through `viewItem(index)` and
sets it as the list item's child; its unbind callback only drops the row's entry from `itemStates`
and does not destroy the widget (`widgets.nim:4463-4486`). The interface is
`proc viewItem(index: int): Widget` plus a `size`.

> **Done, session 7 — and it measures.** On a 400-turn conversation the resident set after load
> falls from 297 MiB to 267 MiB, reproducibly across runs. The widget subtrees are viewport-scaled.
> The comment over the transcript's scroller in `gui.mainArea` records the constraint that makes it
> real: a `GtkListView` virtualises only when it is the scrolled window's direct child, so the
> reading-width `Clamp` moved into each row (`messageCard`).

**The cache half is still open, and it reframes report 03's M-01 as a symptom.** `BlockMemo`,
`ParseMemo` and `thumbCache` were unbounded because the old design required holding every rendered
message at once. Session 2 capped and cleared them, which was correct and remains correct — but a
`ListView` transcript wants a cache proportional to the *viewport*, not the conversation. Scrolling
that same 400-turn conversation to turn 130 takes the resident set to 320 MiB: the rows recycle,
but the caches are still module-level `var`s — **four** of them since M-3: `mdMemo`
(`markdown.BlockMemo`, cap 512) and `attachMemo` (`pipeline.ParseMemo`, cap 128) keyed by message
id, `thumbCache` (cap 64) keyed by attachment, and `mathLayoutCache` (cap 64) keyed by formula
source. They grow with what was *ever* rendered, bounded only by their caps and emptied only by
`clearRenderMemos` on a conversation switch. **Verified still open, 2026-09-29T22:31Z.** Reducing
them to viewport scale (report 05's Phase 2.2) has not been done; see PLANS.md.

`ColumnView` (`widgets.nim:4609`) is the same mechanism with columns.

> **Done for the models list, session 7 — and *not* for the trash, deliberately.** The models
> panel was the right fit and was drawn as prose: a name on one line and "instruct · 4387 MB" in
> grey underneath, so comparing two models by size meant reading down a ragged column that did
> not line up. Model, folder and size are columns now.
>
> The trash is a poor fit and forcing it there would be worse than leaving it. It holds **two
> lists of different kinds** — rows addressed by id, which can be restored, and files addressed
> by path, which cannot — and the comment in `trashPanel` already records that presenting them
> as one thing would be a false claim about what restoring one does. A `ColumnView` must be the
> `ScrolledWindow`'s own child to be a list, so accommodating both would mean either merging
> them or giving a 720x560 panel two scrollers. Neither is an improvement on a short list that
> fits on screen.
>
> [2026-09-29T22:31Z: superseded — the trash is a `ColumnView` too (`gui.trashPanel`): one table
> over both lists, indexed rather than merged, with a Kind column, and Restore dispatches on which
> list the row falls in, which answers the objection above. Files are a `ColumnView` as well
> (`gui.filesPanel`).]

---

## 4. The native idioms the window does not use

| Idiom | Widgets | What `gui.nim` does instead |
|---|---|---|
| Settings screens | `PreferencesGroup`, `ActionRow`, `ComboRow`, `SwitchRow` | ~~Boxes of `Label` + `Button` + `Switch`~~ — preference rows in a group per section. `EntryRow` is **not** used and the reason is in `settingsField`: it derives from `AdwPreferencesRow`, so it has no `subtitle`, and in this panel the help text is the point |
| Transient notification | `ToastOverlay` (`adw.nim:1374` on the pinned revision, ungated) | ~~A one-line notice label~~ — upstream's widget: confirmations toast, and the row is now errors only — but only chat-stream errors reach it; other failures go through `setNotice` and expire as toasts (report 02, P-B1) |
| Empty states | `StatusPage` | ~~A dim `Label`~~ — done for the empty transcript, the two model-list states and the trash, session 7 |
| Inline messages | `Banner` | ~~—~~ — done for backend-down and the LAN flag/socket disagreement, session 7; since also the inspector's trim warning |
| Header/content/footer | `ToolbarView` | ~~A `Box` of three sections~~ — the chat column is a `ToolbarView` |
| Adaptive sidebar | `OverlaySplitView` | ~~`Flap`~~ — swapped, with `AdwBreakpoint` hand-bound to drive `collapsed`, since owlkettle has no breakpoint at all |
| Menus | `PopoverMenu`, `ContextMenu`, `MenuItem` | ~~1 `Popover`, 1 `MenuButton`~~ — every conversation, note and file row in the sidebar (`convRow`, `leafRow`) has a `⋯` menu and a right-click menu; workspace, project and folder nodes keep an inline strip of icon buttons (`nodeTools`) with neither. `ModelButton` is wrapped as `MenuItem` so choosing an item closes the menu, which owlkettle's does not. **The app menu itself was the last holdout** and was still a `Popover` of flat `Button`s in session 7: its items ran and left the menu standing over the window they had just changed. Session 8 moved it to `PopoverMenu` + `MenuItem` |
| Split primary action | `SplitButton` | ~~Two buttons~~ — Send carries the intent-prefix menu (P-E8). It reverts to a plain `Button` while streaming, because Stop has no secondary action |
| Reading-width column | `Clamp` | ~~Margins~~ — each transcript row is clamped to 760 (`messageCard`), close to the Web UI's own `max-w-[48rem]` (768 px, `ChatMessages.svelte`); a `Clamp` around the list would defeat its virtualisation |
| Identity | `Avatar` | ~~Text labels~~ — an icon avatar beside the name on every message card |

None of these is exotic. They are the widgets a GNOME application is *made of*.

---

## 5. The escape hatch, used ten times in this repository

Where owlkettle lacks a widget, you declare one. `owlkettle.nim:25` exports `widgetdef`, so
`renderable` is available to consumers, and this project already relies on that:

| File | Binds |
|---|---|
| `src/jenova/vte.nim` | `NvimTerminal` — VTE terminal (`vte/vte.h`) |
| `src/jenova/sourceview.nim` | `SourceCode` — GtkSourceView (`gtksourceview/gtksource.h`) |
| `src/jenova/canvas.nim` | `NeuralCanvas` — a `GtkDrawingArea` painted with cairo |
| `src/jenova/shortcuts.nim` | `ShortcutHost` — one window-level `GtkShortcutController` (§6) |
| `src/jenova/gui.nim` | `AutoScroll`, `ContentScroll`, `DropZone`, `DraftView`, `MenuItem` (`GtkModelButton`) and `BreakpointHost` (`AdwBreakpoint`) |

**"owlkettle does not have widget X" is therefore never a wall.** It is roughly forty lines of
`renderable` plus `importc`, and the author has written it ten times now [2026-09-29T22:31Z: four
at first audit].

What owlkettle genuinely does not expose, verified absent from `owlkettle/` at the revision
`jenova_core.nimble` pins (re-checked 2026-09-29T22:31Z): `NavigationView`, `TabView`,
`AdwDialog`/`AlertDialog`, `BottomSheet`, `BreakpointBin`/`AdwBreakpoint`, and any `GtkSorter`
(report 07, V-13). All are reachable by the same hatch if wanted.

### Correction: `ToolbarView` and `ToastOverlay` were never absent — and "v3.0.0" is why both passes got it wrong

This section listed them as missing, and `AdwToastOverlay` was bound by hand in
`src/jenova/toast.nim` on that basis. The module is deleted and the window uses upstream's
widget. It was not merely redundant: it **collided** with upstream's, so the tree would not
compile at all against the revision this report audits —
`Error: ambiguous identifier: 'ToastOverlay'`.

**The trap is that two different trees both answer to "owlkettle 3.0.0."** `main` has never
bumped its own nimble file, so it still declares `version = "3.0.0"` thirty-four commits past the
tag of that name — and `requires "owlkettle >= 3.0.0"` was satisfied by either. The two are not
the same toolkit:

| | `v3.0.0` tag (`861092d`) | `ac61ecf` (`main`, +34) |
|---|---|---|
| `renderable` count in `adw.nim` | **21** | **23** |
| `ToastOverlay`, `Toast`, `ToastQueue` | absent | present, `adw.nim:1374` |
| `ToolbarView` | absent | present, `adw.nim:1010`, `{.since: AdwVersion >= (1, 4).}` |
| `adw_toast_*` in `bindings/adw.nim` | **0 symbols** | **23 symbols** |

This report's header names `ac61ecf`, and that is the column its census and §2 come from. A later
pass recounted against the tag, found 21 and no toasts, and "corrected" a correct report; a pass
after that restored it and attributed the widgets to `v3.0.0`, which is the same conflation
running the other way. **`jenova_core.nimble` now pins the commit**, so the question cannot be
answered two ways again, and `tests/gui_build.sh` refuses a tag checkout by name rather than
letting it surface as `undeclared identifier` inside a `gui:` block — but only when the `OWLKETTLE`
path variable is set: it greps that checkout's `adw.nim` for `renderable ToastOverlay`, and a tag
checkout on the default nimble path is not checked.

**Upstream's `ToastOverlay` also answers the design question better than the hand-binding did.**
*A toast is an event and a `renderable` property is state*: the hand-binding reconciled them with
a serial the window bumped per message and the widget compared against the last one raised.
`ToastQueue` is a `ref` the widget **drains** on each update, so a message raises exactly one
toast and the same text twice raises two — by construction, with no counter to keep anywhere.

**And a toast can carry a button.** `newToast` takes `buttonLabel` and `clickedHandler`, and
`connectSignal` (`adw.nim:1315`; the button handler is wired only under `AdwVersion >= (1, 2)`)
puts the closure in its own shared cell and disconnects it on
fire, so it is not the per-update `EventObj` that ARC frees under a live toast — the
`DraftView.submit` hazard does not apply, and the hand-binding's note claiming it did was wrong.
**P-B1 stays open on different grounds:** a message you have to act on must not time out, and it
needs the server's own detail rather than one line. Chat-stream errors keep the inline row.
[2026-09-29T22:31Z: corrected — this said "Errors keep the inline row". Failures outside the chat
stream (model switch, hardware detection, fork, export, import, restore) go through `setNotice`
and expire as toasts, and `ChatError.detail` never reaches the row — report 02, P-B1.]

**One item genuinely is missing, and it gates a planned one:**

* `AdwBreakpoint` — **bound by hand** (in session 8, per report 05's Phase 3 record; this line
  first said session 7), because `OverlaySplitView` did replace `Flap`
  and this is what makes that lossless rather than a downgrade. `Flap`
  folds itself on a narrow window through `FlapFoldAuto`, which is what
  `alwaysShowSidebarOnDesktop` switches off; `OverlaySplitView.collapsed` is a plain `bool` that
  something must drive, and the something libadwaita intends is a breakpoint on the window.
  **Swapping the two without binding it trades a deprecated widget for a sidebar that no longer
  adapts** — so that item is larger than "replacing `Flap`" suggests, and should be planned as
  the pair. Binding it also needs the split view's own `GtkWidget`, which owlkettle does not
  expose from a `gui:` block, so the pair is really a triple.
  [2026-09-29T22:31Z: as built it did not — `onBreakpointApply`/`onBreakpointUnapply` set a flag,
  the 40 ms drain copies it into `AppState.narrow` and redraws, and `OverlaySplitView.collapsed`
  reads that. No widget handle was needed.]

---

## 6. `Button.shortcut` — the hazard restated correctly

Report 02 called this a mechanism that "must be fixed first". Reading the source, that is half
right and the reasoning was wrong.

`widgets.nim:923-939`:

```nim
hooks shortcut:
  build:
    ...
    gtk_shortcut_controller_set_scope(controller, GTK_SHORTCUT_SCOPE_MANAGED)
    gtk_shortcut_controller_add_shortcut(controller, shortcut)
    gtk_widget_add_controller(state.internalWidget, controller)
  update:
    if widget.hasShortcut:
      assert state.shortcut == widget.valShortcut # TODO
```

Two corrections:

1. **The scope is already `GTK_SHORTCUT_SCOPE_MANAGED`**, so the shortcut fires window-wide
   rather than only when the button has focus. The mechanism is not local; it is fine.
2. **The `assert` is an unimplemented update path, marked `# TODO` upstream** — not a design
   decision. The constraint it imposes is narrow: *a given button's shortcut string may not
   change after build*. The crashes came from changing the child count of the container holding
   the shortcut-carrying button, which makes owlkettle diff that button's state against a
   different widget spec.

**So window-wide shortcuts do not need a new mechanism at all.** They need shortcut-carrying
buttons to live in a container whose child count is constant — or, better, a single custom
`renderable` holding one window-level `GtkShortcutController` for every binding, which is ~40
lines by the hatch in §5 and removes the constraint permanently rather than working around it.

`CustomWidget` (`widgets.nim:1633`) already provides `keyPressed`, `keyReleased`, `mousePressed`,
`mouseReleased`, `mouseMoved`, `scroll` and `focusable` over a legacy event controller, which is
the other route to the same place.

[2026-09-29T22:31Z: built as recommended — `shortcuts.ShortcutHost` holds one controller at
`GTK_SHORTCUT_SCOPE_MANAGED` for every binding, `gui.keyBindings` is the table (five bindings),
and no `Button` carries a `shortcut`. The bindings still missing are report 02's P-B12.]

---

## 7. Conclusion

The parity report was written as a list of Web UI features to reproduce. That framing is what
produced a window built from buttons and labels: reproducing a `<div>` tree gives you a `Box`
tree.

The correct framing is that both surfaces are **clients of the same `api.nim` and the same
pipeline**, and the window's advantage is that it is a native application. Nothing in owlkettle
prevents it from being one. Three of the largest open parity items — the settings screen, the
files list, keyboard control — are not ports at all once the native widget is used; they are
smaller than the ports would have been. [2026-09-29T22:31Z: all three have since been built that
way — `settingsPanel` on preference rows, `filesPanel` on a `ColumnView`, and `ShortcutHost`.]
