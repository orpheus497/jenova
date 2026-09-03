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
| `owlkettle/adw.nim` renderables | **21** | — |
| **Total** | **83** | **18 distinct types** |

> **Corrected, session 7.** The adw figure was 23. `grep -c "renderable [A-Z]"
> owlkettle/adw.nim` at `v3.0.0` returns **21**, guarded declarations included. The
> conclusion is unchanged; the number is not.

Of ~160 widget instances in `gui.nim`, **130 are `Button` (72) or `Label` (58)**.

That ratio is the finding. A native toolkit offering 83 widgets is being used as though it
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
| `SwitchRow` | 1.4 | A labelled switch row — the native settings primitive |
| `EntryRow` | 1.2 | A labelled text-entry row |
| `PasswordEntryRow` | 1.2 | Ditto, masked |
| `Banner` | 1.3 | Inline message strip with an optional button |
| `AboutWindow` | 1.2 | The standard About dialog |

> **Corrected, session 7. `ToolbarView` was listed here and does not exist.** It is
> not gated by `AdwVersion` — it is absent from owlkettle 3.0.0 altogether:
> `grep -rn ToolbarView owlkettle/` returns nothing, in `adw.nim` and in
> `bindings/adw.nim` alike. The six above are real, and every one of them is now in
> the binary: `-d:adwminor=4` is set in `jenova_core.nimble` and `Banner` is in use
> in `gui.nim`'s chat column. The guards are `when AdwVersion >= (1, x) or
> defined(owlkettleDocs)` at `adw.nim:488`, `:714`, `:1061`, `:1251`, `:1281`.

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
| Transient notification | `ToastOverlay` (`adw.nim:1374`, ungated) | ~~A one-line notice label~~ — confirmations toast; errors keep the row, which is now only errors |
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

What owlkettle genuinely does not expose (`adw.nim` declares 23 renderables at `v3.0.0`;
these are not among them): `NavigationView`, `TabView`, `AdwDialog`/`AlertDialog`,
`BottomSheet`, and `BreakpointBin`/`AdwBreakpoint`. All are reachable by the same hatch if
wanted.

### Correction, session 8: two of those were never absent

An earlier pass in this session listed `ToolbarView`, `ToastOverlay` and `Toast` as missing and
bound `AdwToastOverlay` by hand in `src/jenova/toast.nim`. Checked against the source, all three
are in `owlkettle/adw.nim` at `v3.0.0` and `bindings/adw.nim` carries 23 `adw_toast_*` symbols.
The hand-written module is removed; the window uses upstream's widget.

* `ToolbarView` — `adw.nim:1010`, `{.since: AdwVersion >= (1, 4).}`. Invisible without
  `-d:adwminor=4`, which is §2's finding, not an absence.
* `ToastOverlay` — `adw.nim:1374`, ungated. Its answer to *a toast is an event and a
  `renderable` property is a state* is better than the `serial` counter written against it:
  `ToastQueue` is a `ref` the widget **drains** on each update, so a message raises exactly one
  toast and the same text twice raises two, by construction rather than by comparison.
* A toast **can** carry a button. `newToast` takes `buttonLabel` and `clickedHandler`, and
  `connectSignal` (`adw.nim:1314`) puts the closure in its own shared cell and disconnects on
  fire — it is not the per-update `EventObj` that ARC frees underneath a live toast, so the
  `DraftView.submit` hazard does not apply here. **P-B1 stays open on different grounds**:
  a message you have to act on must not time out, and it needs the server's own detail. Errors
  keep the inline row.
* `AdwBreakpoint` — not needed until `OverlaySplitView` replaces `Flap`, and then it is. `Flap`
  folds itself on a narrow window through `FlapFoldAuto`, which is what
  `alwaysShowSidebarOnDesktop` switches off; `OverlaySplitView.collapsed` is a plain `bool` that
  something must drive, and the something libadwaita intends is a breakpoint on the window.
  **Swapping the two without binding it trades a deprecated widget for a sidebar that no longer
  adapts** — so that item is larger than "replacing `Flap`" suggests, and should be planned as
  the pair.

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
