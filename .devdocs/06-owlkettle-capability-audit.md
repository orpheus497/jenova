# Report 06 — Owlkettle Capability Audit

**Method:** `owlkettle` 3.0.0 was cloned at `ac61ecf` (2026-07-20) and read. Every claim below
cites the line that produces it. Nothing is asserted from memory or from the comments in
`gui.nim`, several of which turned out to describe the framework wrongly.
**Question asked:** is owlkettle a constraint on building a proper native window, or has this
project simply not used it?
**Answer:** it is not a constraint. The window uses roughly a fifth of the toolkit, has compiled
a further seventh of it out of the build by omission, and reaches for `Button` and `Label` where
native widgets exist.

---

## 1. The census

| | Available | Used by `gui.nim` |
|---|---|---|
| `owlkettle/widgets.nim` renderables | **62** | — |
| `owlkettle/adw.nim` renderables | **23** | — |
| **Total** | **85** | **18 distinct types** |

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

That ratio is the finding. A native toolkit offering 85 widgets is being used as though it
offered two, with structure expressed through nested `Box`es and CSS classes. It is a web
document tree rendered by GTK.

---

## 2. What is compiled out of the build entirely · **severity: high**

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
| `OverlaySplitView` | 1.4 | The modern adaptive sidebar. **The window uses `Flap` instead** |
| `ToolbarView` | 1.4 | Header/content/footer layout with correct adaptive styling |
| `SwitchRow` | 1.4 | A labelled switch row — the native settings primitive |
| `EntryRow` | 1.2 | A labelled text-entry row |
| `PasswordEntryRow` | 1.2 | Ditto, masked |
| `Banner` | 1.3 | Inline message strip with an optional button |
| `AboutWindow` | 1.2 | The standard About dialog |

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

Plus **13 individual properties** on widgets that do compile, among them `StatusPage.description`
(1.4), `ActionRow.titleLines`/`subtitleLines` (1.3), `ButtonContent.canShrink` (1.4).

**This is a one-line fix in `jenova_core.nimble`** and it is the highest-leverage change in the
whole plan. The installed GTK is 4.20.4; libadwaita's version on the target host must be
confirmed and `-d:adwminor` set to match.

---

## 3. The transcript is not virtualised · **severity: high**

`gui.nim:3674`:

```nim
for i, m in (if app.openNote.len > 0: @[] else: app.messages):
  Frame {.expand: false.}:
```

Every message in the open conversation is a live widget subtree, inside a `Box`, inside
`AutoScroll`. A thousand-turn conversation is a thousand `Frame`s with their children, built and
retained.

**`ListView` (`widgets.nim:4432`) is GTK4's virtualised list and owlkettle exposes it fully.**
It wraps `gtk_list_view_new` over a `GListModel` with a `GtkSignalListItemFactory`, and its
`bind`/`unbind` callbacks build and destroy item widgets as they scroll into and out of view
(`widgets.nim:4463-4486`). The interface is `proc viewItem(index: int): Widget` plus a `size`.

**This reframes report 03's M-01 as a symptom.** `BlockMemo`, `ParseMemo` and `thumbCache` were
unbounded because the design requires holding every rendered message at once. Session 2 capped
and cleared them, which was correct and remains correct — but a `ListView` transcript needs a
cache proportional to the *viewport*, not the conversation. The cure for the memory pressure is
the right widget, not a bigger lid.

`ColumnView` (`widgets.nim`) is the same mechanism with columns, for the file and trash lists.

---

## 4. The native idioms the window does not use

| Idiom | Widgets | What `gui.nim` does instead |
|---|---|---|
| Settings screens | `PreferencesPage`, `PreferencesGroup`, `ActionRow`, `ComboRow`, `ExpanderRow`, `SwitchRow`, `EntryRow` | Boxes of `Label` + `Button` + `Switch` |
| Transient notification | `ToastOverlay` (`adw.nim:1374` on the pinned revision, ungated) | ~~A one-line notice label~~ — upstream's widget: confirmations toast, and the row is now errors only |
| Empty states | `StatusPage` | ~~A dim `Label`~~ — done for the empty transcript, the two model-list states and the trash, session 7 |
| Inline messages | `Banner` | ~~—~~ — done for backend-down and the LAN flag/socket disagreement, session 7 |
| Adaptive sidebar | `OverlaySplitView` | `Flap` |
| Menus | `PopoverMenu`, `ModelButton`, `ContextMenu` | 1 `Popover`, 1 `MenuButton` |
| Split primary action | `SplitButton` | Two buttons |
| Reading-width column | `Clamp` | Margins |
| Identity | `Avatar` | Text labels ("YOU" / "JENOVA") |

None of these is exotic. They are the widgets a GNOME application is *made of*.

---

## 5. The escape hatch, already used four times in this repository

Where owlkettle lacks a widget, you declare one. `owlkettle.nim:25` exports `widgetdef`, so
`renderable` is available to consumers, and this project already relies on that:

| File | Binds |
|---|---|
| `src/jenova/vte.nim` | VTE terminal (`vte/vte.h`) |
| `src/jenova/sourceview.nim` | GtkSourceView (`gtksourceview/gtksource.h`) |
| `src/jenova/canvas.nim` | cairo directly |
| `src/jenova/gui.nim:2561` | `AutoScroll`, a custom `renderable of BaseWidget` |

**"owlkettle does not have widget X" is therefore never a wall.** It is roughly forty lines of
`renderable` plus `importc`, and the author has written it four times already.

What owlkettle genuinely does not expose, verified absent from `owlkettle/` at the revision
`jenova_core.nimble` pins: `NavigationView`, `TabView`, `AdwDialog`/`AlertDialog`, `BottomSheet`,
and `BreakpointBin`/`AdwBreakpoint`. All are reachable by the same hatch if wanted.

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
letting it surface as `undeclared identifier` inside a `gui:` block.

**Upstream's `ToastOverlay` also answers the design question better than the hand-binding did.**
*A toast is an event and a `renderable` property is state*: the hand-binding reconciled them with
a serial the window bumped per message and the widget compared against the last one raised.
`ToastQueue` is a `ref` the widget **drains** on each update, so a message raises exactly one
toast and the same text twice raises two — by construction, with no counter to keep anywhere.

**And a toast can carry a button.** `newToast` takes `buttonLabel` and `clickedHandler`, and
`connectSignal` (`adw.nim:1314`) puts the closure in its own shared cell and disconnects it on
fire, so it is not the per-update `EventObj` that ARC frees under a live toast — the
`DraftView.submit` hazard does not apply, and the hand-binding's note claiming it did was wrong.
**P-B1 stays open on different grounds:** a message you have to act on must not time out, and it
needs the server's own detail rather than one line. Errors keep the inline row.

**One item genuinely is missing, and it gates a planned one:**

* `AdwBreakpoint` — not needed until `OverlaySplitView` replaces `Flap`, and then it is. `Flap`
  folds itself on a narrow window through `FlapFoldAuto`, which is what
  `alwaysShowSidebarOnDesktop` switches off; `OverlaySplitView.collapsed` is a plain `bool` that
  something must drive, and the something libadwaita intends is a breakpoint on the window.
  **Swapping the two without binding it trades a deprecated widget for a sidebar that no longer
  adapts** — so that item is larger than "replacing `Flap`" suggests, and should be planned as
  the pair. Binding it also needs the split view's own `GtkWidget`, which owlkettle does not
  expose from a `gui:` block, so the pair is really a triple.

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

---

## 7. Conclusion

The parity report was written as a list of Web UI features to reproduce. That framing is what
produced a window built from buttons and labels: reproducing a `<div>` tree gives you a `Box`
tree.

The correct framing is that both surfaces are **clients of the same `api.nim` and the same
pipeline**, and the window's advantage is that it is a native application. Nothing in owlkettle
prevents it from being one. Three of the largest open parity items — the settings screen, the
files list, keyboard control — are not ports at all once the native widget is used; they are
smaller than the ports would have been.
