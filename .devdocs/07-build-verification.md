# Report 07 — Build Verification, and What the owlkettle Pin Left Behind

**Status:** open tracker
**Scope:** the path from `nimble gui` to a mapped window, and the claims `src/` makes about
what owlkettle can and cannot do — re-checked against **the revision now pinned**, not against
the tag the comments were written for.
**Method:** a build environment was constructed and **every finding was reproduced by compiling
or running.** Where a claim comes from a header or from owlkettle's own source it is quoted
verbatim with a file and line.
**Audited at commit:** `aabcc77`
**owlkettle audited at:** `ac61ecf0adea2fd611ce962e3915e704abc2fb7f` — the revision
`jenova_core.nimble:24` pins.

---

## 0. The environment, and why this report is short

This report was opened to answer "is the owlkettle build fully functional, using everything on
owlkettle's main branch". A full environment was assembled to answer it by measurement:

| Component | Version | Source |
|---|---|---|
| Nim | 2.2.10 | bootstrapped from source, `github.com/nim-lang/Nim` tag `v2.2.10`. `nim-lang.org` is blocked by egress policy; GitHub is not, and `build_all.sh` fetches `csources_v2` from GitHub |
| GTK4 | 4.14.5 | distribution package |
| libadwaita | 1.5.0 | distribution package |
| GtkSourceView | 5.12.0 | distribution package |
| VTE (GTK4) | 0.76.0 | distribution package |
| D-Bus | 1.14.10 | distribution package |
| owlkettle | `v3.0.0` **and** `ac61ecf`, side by side as git worktrees, selected with `--path:` | GitHub |
| runtime for the harness | Xvfb, ImageMagick, `xwininfo`, `xdotool`, `xclip`, `nc` | distribution packages |

**`sh tests/gui_build.sh` passes end to end on this host**, including the steps that need a
mapped window:

```
gui_build: window is 900x680+0+0
gui_build: composer mean change — idle 0.00108441, after <Ctrl>n 0.0106788
gui_build: window-wide shortcuts fire
gui_build: the transcript renders the seeded conversation
gui_build: the composer is at the bottom of the window and takes typing
gui_build: PASS
```

All seventeen self-tests pass. `jenova --check` exits 0.

**The answer to the opening question is therefore "almost".** Sessions 7 and 8 pinned
`ac61ecf`, set `-d:adwminor=4`, and took the window from 18 owlkettle widgets to 39. What is
left is not capability — it is four places where the build or the source still describes
owlkettle `v3.0.0` while linking `ac61ecf`, and each of them is currently the stated reason for
code that no longer needs to exist.

### What this environment still does not cover

* **Linux/glibc, not FreeBSD.** The two `when not defined(freebsd)` guards
  (`src/jenova_core.nim`, `src/jenova_gui.nim`) are neutralised in a scratch copy; the repository
  is not modified. `grep -rn freebsd src/jenova/*.nim` returns nothing, so the copy differs from
  the real tree in exactly two lines.
* **GTK 4.14.5, not the target's 4.20.4** (D-AK); **libadwaita 1.5.0**, against a
  `-d:adwminor=4` floor whose satisfaction on the target is still unverified.
* Report 05's Phase 1 list stands unchanged: the `sysctl` probe, the `fork`/`setsid`/`execv`
  backend path, the D-Bus tray (no `StatusNotifierWatcher` runs under Xvfb), and the embedded
  Neovim page are FreeBSD-only and untested here.

---

## 1. Two decisions confirmed by measurement, not by reading

Recorded because they were taken on a read of owlkettle's source and are now backed by a
reproduction. Neither needs work.

### The `ac61ecf` pin prevented a startup SIGSEGV

owlkettle `v3.0.0`, `owlkettle/widgets.nim:870-872`, verbatim:

```nim
  hooks pixbuf:
    property:
      gtk_picture_set_pixbuf(state.internalWidget, state.pixbuf.gdk)
```

`Pixbuf` is a `ref`. `.gdk` on a nil one is a nil dereference inside `buildState`, and
`src/jenova/gui.nim` says the opposite where it decodes the sidebar logo — *"A nil pixbuf is
survivable — `Picture` renders empty — so a missing icon file costs the logo, not the window."*
Reproduced, `jenova --check` with `png/` absent:

```
SIGSEGV: Illegal storage access. (Attempt to read from nil?)
…/owlkettle/widgets.nim(864) build
…/owlkettle/widgetdef.nim(872) buildState
```

`ac61ecf` guards it (`8254267`). Measured, four runs:

| owlkettle | `png/jenova.png` present | absent |
|---|---|---|
| `v3.0.0` | tree builds, exit 0 | **SIGSEGV** |
| `ac61ecf` | tree builds, exit 0 | tree builds, exit 0 |

The comment is now true. It was not true of the dependency the `.nimble` file used to accept.

### The pin also fixed the dark theme, which was sending libadwaita *prefer-light*

`/usr/include/libadwaita-1/adw-style-manager.h:22-28`, verbatim:

```c
typedef enum {
  ADW_COLOR_SCHEME_DEFAULT,
  ADW_COLOR_SCHEME_FORCE_LIGHT,
  ADW_COLOR_SCHEME_PREFER_LIGHT,
  ADW_COLOR_SCHEME_PREFER_DARK,
  ADW_COLOR_SCHEME_FORCE_DARK,
} AdwColorScheme;
```

owlkettle `v3.0.0` ordered its `ColorScheme` `Default, ForceLight, ForceDark, PreferDark,
PreferLight`, so `ColorSchemeForceDark` was ordinal **2** — `ADW_COLOR_SCHEME_PREFER_LIGHT`.
`src/jenova/gui.nim:6349` passes exactly that constant for a dark palette. `Default` and
`ForceLight` were right by coincidence; only the dark case was wrong, and it was wrong in the
direction that makes Adwaita's own menus disagree with the Jenova stylesheet — the precise thing
the comment above that line says the forced value exists to prevent. `ac61ecf` fixes the order
and, in the same commit (`fcf019d`), puts `{.size: sizeof(cint).}` on **every** C enum in both
binding files: a Nim enum without it is sized to its own range, so a two-case enum is one byte
where the C ABI expects four.

---

## 2. Findings

### V-01 — `-d:gtk48` is a dead define, and the comment justifying it is false at the pinned revision · severity: low, but it is load-bearing

`jenova_core.nimble:31-35`:

> **`-d:gtk48` is required alongside it and is not redundant.** owlkettle 3.0.0 gates the *widget*
> on `GtkMinor >= 8` but its *binding* on `defined(gtk48)` (`bindings/gtk.nim:836`), so raising
> only `gtkminor` fails to compile with an undeclared `gtk_picture_set_content_fit`. Both
> switches, or neither.

**That is exactly right for the `v3.0.0` tag** — `owlkettle/bindings/gtk.nim:836` there is
`when defined(gtk48):`. At `ac61ecf` the same gate reads (`owlkettle/bindings/gtk.nim:864-867`):

```nim
when GtkMinor >= 8:
  proc gtk_picture_set_content_fit*(picture: GtkWidget, fit: GtkContentFit)
else:
  proc gtk_picture_set_keep_aspect_ratio*(picture: GtkWidget, keep: cbool)
```

`defined(gtk48)` appears nowhere in `ac61ecf`. `-d:gtk48` in `NimFlags`
(`jenova_core.nimble:42`) is a define nothing reads. Confirmed by building the window against
`ac61ecf` **without** it, at `-d:gtkminor=10 -d:adwminor=4`: it compiles, `--check` exits 0, and
`tests/gui_build.sh` passes.

This is the same class of defect the `.nimble` file caught in itself when it pinned the
revision: a switch and a paragraph that describe a dependency the build no longer uses.

### V-02 — four "owlkettle cannot do this" claims are false at `ac61ecf`, and each is the stated reason for a hand-rolled widget · severity: medium

These are not cosmetic. Every one is written as the *justification* for a custom `renderable` or
a raw `importc`, so while they stand, the code they justify cannot be removed by a reader who
believes them — and this project's rule is that a comment is checked before it is written
("per rule 5", which several of these cite).

| Site | The claim | The fact at `ac61ecf` |
|---|---|---|
| `src/jenova/gui.nim:2686` | *"Not in owlkettle's bindings — `hAlign` there is a `Box` packing property"* about `gtk_widget_set_halign` | **`owlkettle/bindings/gtk.nim:683`: `proc gtk_widget_set_halign*(widget: GtkWidget, align: GtkAlign)`.** It was also there in `v3.0.0`, at `:659`. **This claim has never been true at any revision this project has used.** The local declaration is a duplicate that takes `cint` instead of the typed `GtkAlign` |
| `src/jenova/gui.nim:2590`, `:2607` | *"owlkettle's `renderable` emits an unexported type"* — the stated reason `NeuralCanvas` and `SourceCode` live in `gui.nim` rather than beside their FFI in `canvas.nim` and `sourceview.nim` | True on `v3.0.0`. `6386729` (*"Automatically export widgets"*) exports the widget type, its state type, `buildState`, `updateState` and `destroyState`, with `{.private.}` to opt out. **Both renderables can move to the modules that own their bindings** |
| `src/jenova/gui.nim:2614`, `:2670`, `:2678`, `:2833` | *"owlkettle's `ScrolledWindow` exposes only `child` — no adjustment"*, justifying `ContentScroll`, `AutoScroll` and four raw `importc` | `68c1db0` adds `propagateNaturalWidth`/`propagateNaturalHeight` as fields **and as bindings** (`bindings/gtk.nim:828-829`); `0138a38` adds the `edgeOvershot(edge: Edge)` and `edgeReached(edge: Edge)` signals. Two of the four `importc` at `:2674-2683` are now duplicates of owlkettle's own |
| `src/jenova/gui.nim:3003` | *"owlkettle's `TextView` has no wrap property — checked in `widgets.nim`, per rule 5"* | `6323696` adds `wrapMode: WrapMode` and `textMargin: Margin` (`owlkettle/widgets.nim:2626-2627`) |

**Two neighbouring claims survive and must not be swept away with the rest.** Both were
re-checked at `ac61ecf`:

* *"`updateChild` lives in `owlkettle/widgetutils`, which `owlkettle.nim` imports but does not
  re-export"* — still true. `owlkettle.nim`'s export list is `widgetdef`, `widgets`, `guidsl`,
  `Align`, `Stylesheet` and four stylesheet procs. The same holds for `mainloop`.
* *"owlkettle's `TextView` declares no events at all"* — still true. `DraftView` stays.

`AutoScroll` is the interesting case rather than a straight deletion: `edgeReached`/`edgeOvershot`
report the reader's position as *events*, which is what the module-level `scrollPinned` and
`scrollSticky` globals exist to track through a bare C signal handler with nowhere to put state.
Whether the two signals give the same behaviour as the `changed`/`value-changed` pair the current
code binds is a question for a measurement, not for a comment — the current implementation
documents a real defect it was written to fix (following that fell one token behind every frame).

### V-03 — `nimble suites` cannot pass on a clean checkout, and blames the wrong thing · severity: medium

`SelfTests` (`jenova_core.nimble:81`) includes `"serve"`, and `serve-selftest` phase 3 asserts:

```nim
elif not health.contains("\"status\":\"ok\"") or not index.contains("<"):
  echo "  FAIL: health or static did not answer while the debug class was saturated"
```
— `src/jenova/serverselftest.nim:208-209`

`index` is the body of `GET /`, which `serveStatic` answers out of `public/`. **Nothing in
`coreTask`, `guiTask` or `suites` builds `public/`** — only the separate `web` task does. On a
tree without it, `/` is `404 text/plain`, contains no `<`, and the run fails:

```
  phase 3  debug class saturated: 3 holds of 800 ms against 1 debug threads
           /health answered in    0.9 ms
           /        answered in    0.5 ms

  FAIL: health or static did not answer while the debug class was saturated
```

Both requests answered, and fast. The message names a saturation failure that did not happen.
This is the class report 01 spent a session removing from the user-facing documentation, in the
one place a developer meets it first. Either `suites` depends on `web`, or the assertion states
the precondition it actually has and skips honestly — under A-2's rule, "skip" needs the same
justification `test_nvimctl.sh` was given.

### V-04 — the pkg-config calls have no failure path · severity: low

`src/jenova/dbus.nim:13-14` (`gorge`), `src/jenova/sourceview.nim:14-15` and
`src/jenova/vte.nim:10-11` (`staticExec`) splice pkg-config's **stdout** straight into `passC`
and `passL`. When the package is absent, its prose becomes linker arguments. Reproduced with
`dbus-1` missing:

```
gcc: error: the: linker input file not found: No such file or directory
gcc: error: pkg-config: linker input file not found: No such file or directory
gcc: error: Package: linker input file not found: No such file or directory
gcc: error: dbus-1: linker input file not found: No such file or directory
/bin/sh: 4: Syntax error: EOF in backquote substitution
```

Sixty lines of that, naming no missing dependency. `gorgeEx` returns the exit code; a failure
should name the package and the port that provides it, which `docs/install.md` already lists.

---

## 3. Tracker

| ID | Finding | Class | Size | State |
|---|---|---|---|---|
| V-01 | `-d:gtk48` dead at the pinned revision; its justifying comment describes `v3.0.0` | stale | XS | open |
| V-02 | Four owlkettle-capability claims false at `ac61ecf`; each justifies code that can now go | stale + dead code | S–M | open |
| V-03 | `nimble suites` fails on a clean checkout, reporting the wrong cause | false report | S | open |
| V-04 | pkg-config `gorge`/`staticExec` with no failure path | build robustness | XS | open |

### Cross-references

* **Report 05, Phase 0** — closed by session 7's pin and `-d:adwminor=4`. V-01 is the residue:
  the third switch in the same string was not re-examined when the first two were.
* **Report 05, Phase 1** — the Linux half is now stronger than the addendum records:
  `tests/gui_build.sh` passes complete, mapped window and all, on stock packages. The
  FreeBSD-only list in that addendum is unchanged and is what still keeps the phase open.
* **Report 06 §4** — the widget census. V-02 is the same argument applied to the *bindings*
  rather than the widgets: three hand-rolled `importc` and two custom renderables are held in
  place by comments describing the untagged revision.
