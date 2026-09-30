# Report 07 — Build Verification, and What the owlkettle Pin Left Behind

**Status as of 2026-09-29T22:34Z (baseline `4acedfa0`; host Arch Linux).** Open tracker. §0–§5
were measured in an Ubuntu-24.04-class Linux container, as root, with gcc of unrecorded version —
not on FreeBSD and not on this host. Still holding: §1's three measurements and rows V-01–V-03 and
V-07–V-16 (citations now by symbol, or "as of <commit>" for quoted text). Superseded: the "passes
on stock packages" claim (on Arch `nimble gui` fails at `vte.nim`'s `GdkRGBA` under gcc 16.2.1
and clang 22.1.8) and the FreeBSD-only framing (FreeBSD and Linux are both supported). Reopened:
V-04, V-05, V-06. Per-host results and what was never verified: end of §0. Forward work: see
PLANS.md.
**Scope:** the path from `nimble gui` to a mapped window, and the claims `src/` makes about
what owlkettle can and cannot do — re-checked against **the revision now pinned**, not against
the tag the comments were written for.
**Method:** a build environment (§0's container) was constructed and **every finding was
reproduced by compiling or running.** Where a claim comes from a header or from owlkettle's own
source it is quoted verbatim with a file and line.
**Audited at commit:** `aabcc77`, then carried through session 9's consolidation
[2026-09-29T22:34Z: `aabcc77` is reflog-only — unreachable from any ref and prunable; cite
`989c2b5d` (#117) or `4acedfa0` (#118) instead]
**owlkettle audited at:** `ac61ecf0adea2fd611ce962e3915e704abc2fb7f` — the revision the
`requires` line of `jenova_core.nimble` pins.

---

## 0. The environment, and why this report is short

This report was opened to answer "is the owlkettle build fully functional, using everything on
owlkettle's main branch". A full environment was assembled to answer it by measurement:

| Component | Version | Source |
|---|---|---|
| Host | not recorded — by this package set, dash's error text (V-04) and `/root/.cache/nim` (V-06), an Ubuntu-24.04-class Linux container run as root | — |
| C compiler | gcc (V-04's reproduction is gcc output), version not recorded — presumably that base's gcc 13, where `vte.nim`'s `GdkRGBA` mismatch is only a warning | distribution package |
| Nim | 2.2.10 | bootstrapped from source, `github.com/nim-lang/Nim` tag `v2.2.10`. `nim-lang.org` is blocked by egress policy; GitHub is not, and `build_all.sh` fetches `csources_v2` from GitHub |
| GTK4 | 4.14.5 | distribution package |
| libadwaita | 1.5.0 | distribution package |
| GtkSourceView | 5.12.0 | distribution package |
| VTE (GTK4) | 0.76.0 | distribution package |
| D-Bus | 1.14.10 | distribution package |
| owlkettle | `v3.0.0` **and** `ac61ecf`, side by side as git worktrees, selected with `--path:` | GitHub |
| runtime for the harness | Xvfb, ImageMagick, `xwininfo`, `xdotool`, `xclip`, `nc` | distribution packages |

**`sh tests/gui_build.sh` passed end to end in this container**, including the steps that need a
mapped window — the only host on which the mapped-window tier has run:

```
gui_build: window is 900x680+0+0
gui_build: composer mean change — idle 0.00108441, after <Ctrl>n 0.0106788
gui_build: window-wide shortcuts fire
gui_build: the transcript renders the seeded conversation
gui_build: the composer is at the bottom of the window and takes typing
gui_build: PASS
```

Every self-test that existed at the time passed in the container, and `jenova --check` exits 0.
Twenty-two are registered now (`SelfTests` in `jenova_core.nimble`): sixteen plus `asset`,
`inspect`, `math`, `pipeline`, `rag` and `routes`, the last added on 2026-09-09 on the FreeBSD
host — so the container never ran all twenty-two. *(This read "All nineteen", then
"the seventeen that existed" plus six — 23, not 22. [2026-09-29T22:34Z: corrected; per-host runs
are in the matrix at the end of §0.])*

**The answer to the opening question is therefore "almost".** Sessions 7 and 8 pinned
`ac61ecf`, set `-d:adwminor=4`, and took the window from 18 owlkettle widgets to 39. What was
left was not capability — it was four places where the build or the source still described
owlkettle `v3.0.0` while linking `ac61ecf`, each of them the stated reason for code that no
longer needed to exist.

**Session 9 closed those four and found four more while doing it** (V-05…V-08), every one in the
build harness rather than the product: a gate nothing ran, a shared nimcache that makes a clean
tree fail to link, an unhandled exception printed on a passing run, and a port override that
never overrode anything. Six further findings are open and stated in §5. **The pattern across all
fourteen is one thing — the apparatus that checks this project had not itself been checked.**
[2026-09-29T22:34Z: open now — V-04, V-05 and V-06, reopened, and V-17; see §4 and §5.]

### What this environment still does not cover

* **Linux/glibc, not FreeBSD.** The two `when not defined(freebsd)` guards
  (`src/jenova_core.nim`, `src/jenova_gui.nim`) are neutralised in a scratch copy; the repository
  is not modified. `grep -rn freebsd src/jenova/*.nim` returns nothing, so the copy differs from
  the real tree in exactly two lines. [2026-09-29T22:34Z: superseded — both guards were removed
  (see the "no OS guard" header comments of both entry points); every host builds the tree as is.]
* **GTK 4.14.5, not the target's 4.20.4** (reported from the FreeBSD host); **libadwaita 1.5.0**,
  not the target's 1.8.5.1. Both floors are satisfied on both hosts — see §1, where the version
  question is settled rather than left open. [2026-09-29T22:34Z: the targets are now FreeBSD and
  Linux (Arch, Debian, Fedora). The floor is GTK ≥ 4.10 and libadwaita ≥ 1.4; Debian 12 is
  below it, Arch has 4.22.5 / 1.9.4.]
* Report 05's Phase 1 list stands unchanged: the `sysctl` probe, the `fork`/`setsid`/`execv`
  backend path, the D-Bus tray (no `StatusNotifierWatcher` runs under Xvfb), and the embedded
  Neovim page are FreeBSD-only and untested here. [2026-09-29T22:34Z: only the `sysctl` probe is
  FreeBSD-specific; the other three are shared code to verify on both OSes, and Linux has no
  hardware probe at all — see the matrix below.]
* **`--check` builds the startup tree, and that is less than it looks.** The overlay panels are
  inserted unconditionally — **seven** of them, the `insert(app.<x>Panel()) {.addOverlay.}` lines
  that end `method view` in `src/jenova/gui.nim`, not five — which makes it tempting to say they
  are constructed. **Only their shells are.** Six of the seven panel bodies sit behind
  `if app.<x>Open:` — settings, hardware, models, trash, files and inspector, `trashPanel`'s
  `if app.trashOpen:` being the pattern — and `previewPanel`'s behind
  `if app.previewAtt.payload.len > 0:`, so the
  `beforeBuild` hook of every widget *inside* them had never run, on any host, under any gate.
  Two agents found this independently in session 9. Recorded as **V-14**, and **now closed**:
  `tests/gui_build.sh` compiles a variant with those guards forced open and `--check`s it, at a
  cost of 21 s on a 90 s gate (container timings). It found a real defect on its first run — see
  V-16.

  *(The line numbers in this bullet were wrong when first written — "five overlay panels" at
  `:6163-6167` and a guard at `:4813` — and are corrected above. A report whose whole argument is
  that claims must be checked does not get to cite drifted line numbers; they are cheap to
  re-derive and were not re-derived. [2026-09-29T22:34Z: the corrected lines had drifted again, to
  `:7320-7326` and `:5525` at `4acedfa0`; the bullet now cites symbols.])*

### Verification by host (as of 2026-09-29T22:34Z)

| Check | Ubuntu-class audit container, Sep 2026 | FreeBSD 15.1, 2026-09-10 | Arch Linux, 2026-09-29 | Debian | Fedora |
|---|---|---|---|---|---|
| GTK / libadwaita / GtkSourceView / VTE | 4.14.5 / 1.5.0 / 5.12.0 / 0.76.0 | 4.20.4 / 1.8.5.1 / — / — | 4.22.5 / 1.9.4 / 5.20.0 / 0.84.1 | — | — |
| C compiler | gcc, version not recorded | base clang, version not recorded | gcc 16.2.1; clang 22.1.8 also tried | — | — |
| `nimble core` | builds | builds | builds | — | — |
| Self-tests | every one then registered PASS | 22/22 PASS | 22/22 PASS, `serve` included | — | — |
| Six shell suites | not recorded | 6/6 PASS | 6/6 PASS (`test_lifecycle.sh` prints 12 GNU grep "stray \\" warnings) | — | — |
| `nimble gui`, then `jenova --check` | builds; exit 0 | builds (`bin/jenova`, 2026-09-10T08:11Z); exit 0 | **fails** at `vte.nim`'s `GdkRGBA` (incompatible-pointer-types) under gcc 16.2.1 **and** clang 22.1.8. With that one error downgraded it builds and `--check` passes; libadwaita warns `gtk-application-prefer-dark-theme` is unsupported | — | — |
| `tests/gui_check.sh` | not recorded | PASS | PASS | — | — |
| `tests/gui_build.sh` | full PASS, mapped window under Xvfb | build-only tier; mapped tier not run | not run — Xvfb, xdotool, xclip, xwininfo absent; Wayland desktop | — | — |
| Web UI (`public/`) | not recorded | built 2026-09-10T01:03Z; `jca_web/node_modules` holds FreeBSD-native packages | not built | — | — |
| llama.cpp backend | not built | `external/ext_bin`, 2026-08-24T03:53Z, from the since-deleted `bin/build-llama-jenova` (older than `task llama`, added in `7b859f59`) | `a6ea155d3` (the recorded pointer is `e8f19cc0a`) built by hand, not by `nimble llama`: Vulkan, `CMAKE_INSTALL_RPATH='$ORIGIN'` with `CMAKE_BUILD_WITH_INSTALL_RPATH=ON`, target `llama-server`, 9m27s at `-j 6`; RUNPATH `[$ORIGIN]`; runs after `cp -a` into an unrelated directory; the default `LLAMA_USE_PREBUILT_UI=ON` downloaded the llama UI from huggingface.co | — | — |
| `llama-server --list-devices`, i5-1135G7 laptop | — | Vulkan0 NVIDIA, Vulkan1 Intel, as the i5 profiles and `hardware-selftest` encode (not re-measured) | **Vulkan0 Intel Iris Xe, Vulkan1 NVIDIA GTX 1650 Ti Max-Q** — the reverse | — | — |
| `jenova-core hardware detect` | — | not recorded | "OS: FreeBSD unknown", CPU "", 0 threads, 0 GiB RAM and swap, storage "UFS" on btrfs; matched CPU/generic | — | — |

Sources: the container — §0 above; FreeBSD — PROGRESS.md (2026-09-10T02:59Z), TODOS.md, and the
dates and ELF headers of `bin/jenova` and `external/ext_bin`; Arch — this session's runs at
`4acedfa0`. The Arch runs also exposed a test-isolation defect: the `jenova-core` self-tests write
their scratch databases, and the `attachtest`, `attachcost` and `hwtest-home` directories, under
`p.state` — the real `~/Jenova/.system` unless `JENOVA_STATE` or `JCA_HOME` is set — and
`pipeline-selftest` made live DuckDuckGo requests. `styles/` there is written by the desktop
application itself (`gui.run`'s `sourceview.installScheme`), which also runs under `jenova --check`;
`jenova-core` does not import `sourceview`. Forward work: see PLANS.md.

### Not verified (as of 2026-09-29T22:34Z)

* **`nimble llama` as written**, on any host. On Nim 2.2.12 its copy loop would write a full
  duplicate for every SONAME link and a mode-0644 `llama-server`: NimScript `listFiles` lists
  symlinks, and `cpFile` follows them without keeping the executable bit (measured). At
  `a6ea155d3`, `LLAMA_CURL` is deprecated and the default UI provisioning downloads from
  huggingface.co — a build-time network egress the task inherits. A hand-configured build works
  (matrix above).
* **`nimble web` on Linux**, and **`nimble suites` as one command** on any recorded host.
* **The mapped-window tier** anywhere but the container.
* **A clean GUI build on a current Linux toolchain** — Arch fails at `vte.nim` (matrix above);
  FreeBSD's older clang only warned, and its current clang is untested.
* **The installed layout** (`paths.detectLayout`'s `lyInstalled`): no task produces it and no
  test resolves it.
* **Hardware detection on Linux** — there is no Linux probe. On Arch `hardware apply --best` would
  deploy CPU/generic, and the i5 profiles' fixed `VulkanN` indices would address the two GPUs in
  reverse. On FreeBSD the `sysctl` probe is still recorded as unexercised.
* **The backend `fork`/`setsid`/`execve` path, the D-Bus tray against a real watcher, and the
  embedded Neovim page**, on either OS.
* **CUDA (opt-in)** anywhere, and the current tree's Vulkan backend on FreeBSD.
* **Debian and Fedora** — nothing has been built.

---

## 1. Three decisions confirmed by measurement, not by reading

Recorded because they were taken on a read of owlkettle's source and are now backed by a
reproduction. None needs work.

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
The `adw.brew` call in `gui.run` passes exactly that constant for a dark palette. `Default` and
`ForceLight` were right by coincidence; only the dark case was wrong, and it was wrong in the
direction that makes Adwaita's own menus disagree with the Jenova stylesheet — the precise thing
the comment above that line says the forced value exists to prevent. `ac61ecf` fixes the order
and, in the same commit (`fcf019d`), puts `{.size: sizeof(cint).}` on **every** C enum in both
binding files: a Nim enum without it is sized to its own range, so a two-case enum is one byte
where the C ABI expects four. [2026-09-29T22:34Z: on Arch, libadwaita 1.9.4 also logs during
`--check` that `gtk-application-prefer-dark-theme` is unsupported and `AdwStyleManager:color-scheme`
should be used instead — see PLANS.md.]

### Both version floors are already at their maximum useful value — and that is now provable

`-d:gtkminor=10 -d:adwminor=4` were each set as *floors*, deliberately below the toolkit present
(`jenova_core.nimble`: *"10 is a deliberate floor rather than a match"*). The open question was
whether they were leaving capability on the table, and whether the target satisfies them at all.
Both halves are now answered.

**The target's versions**, reported by the user from the FreeBSD host:

```
libadwaita-1.8.5.1             Building blocks for modern adaptive GNOME applications
```

with GTK 4.20.4 (reported from the same host). Both floors are cleared with room to spare, on the
target and on the audit host (1.5.0 / 4.14.5) — so nothing in the build requires a version either
machine lacks. [2026-09-29T22:34Z: Arch (4.22.5 / 1.9.4) clears them too; Debian 12 does not. The
hand-bound `AdwBreakpoint` in `gui.nim` needs libadwaita 1.4 as well.]

**And raising either buys nothing at `ac61ecf`.** Every version gate in the pinned revision,
enumerated exhaustively:

```
$ grep -rhoE 'AdwVersion >= \([0-9]+, [0-9]+\)' owlkettle/ | sort -u
AdwVersion >= (1, 2)
AdwVersion >= (1, 3)
AdwVersion >= (1, 4)

$ grep -rhoE 'GtkMinor >= [0-9]+' owlkettle/ | sort -u
GtkMinor >= 10
GtkMinor >= 12
GtkMinor >= 4
GtkMinor >= 8
```

* **`adwminor=4` is the ceiling, not merely a satisfied floor.** owlkettle gates nothing above
  libadwaita 1.4. Raising it would raise the runtime requirement for zero capability.
* **`gtkminor=12` would buy exactly one boolean.** The only thing gated above 10 is
  `CenterBox.shrinkCenterLast` (`owlkettle/widgets.nim:360`, GTK 4.12) and its binding
  (`bindings/gtk.nim:774-775`). **`CenterBox` is used nowhere in `src/`** — verified — so 10 is
  the ceiling too, until something uses that widget.

Both numbers are therefore correct *and* maximal for this dependency. **This is a fact about
`ac61ecf`, not a standing property**: raising the pin means re-running the two greps above, since
a newer owlkettle may gate on a version these floors exclude. That check belongs beside the pin.

---

## 2. Findings

### V-01 — `-d:gtk48` is a dead define, and the comment justifying it is false at the pinned revision · severity: low, but it is load-bearing · **done**

**Now:** `NimFlags` is `-d:release -d:gtkminor=10 -d:adwminor=4 --hints:off --path:src` and
`GuiFlags` adds only `--mm:arc`, so `-d:gtk48` is passed nowhere. What follows is the state as of
`c5111ce3`.

The `NimFlags` comment in `jenova_core.nimble` (text as of `c5111ce3`):

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

`defined(gtk48)` appears nowhere in `ac61ecf`. `-d:gtk48` in `NimFlags` (as of `c5111ce3`) is a
define nothing reads. Confirmed by building the window against `ac61ecf` **without** it, at
`-d:gtkminor=10 -d:adwminor=4`: it compiles, `--check` exits 0, and `tests/gui_build.sh` passes.

This is the same class of defect the `.nimble` file caught in itself when it pinned the
revision: a switch and a paragraph that describe a dependency the build no longer uses.

### V-02 — four "owlkettle cannot do this" claims are false at `ac61ecf`, and each is the stated reason for a hand-rolled widget · severity: medium

These are not cosmetic. Every one is written as the *justification* for a custom `renderable` or
a raw `importc`, so while they stand, the code they justify cannot be removed by a reader who
believes them — and this project's rule is that a comment is checked before it is written
("per rule 5", which several of these cite).

| Site (lines as of `aabcc77`) | The claim | The fact at `ac61ecf` |
|---|---|---|
| `src/jenova/gui.nim:2686` | *"Not in owlkettle's bindings — `hAlign` there is a `Box` packing property"* about `gtk_widget_set_halign` | **`owlkettle/bindings/gtk.nim:683`: `proc gtk_widget_set_halign*(widget: GtkWidget, align: GtkAlign)`.** It was also there in `v3.0.0`, at `:659`. **This claim has never been true at any revision this project has used.** The local declaration is a duplicate that takes `cint` instead of the typed `GtkAlign` |
| `src/jenova/gui.nim:2590`, `:2607` | *"owlkettle's `renderable` emits an unexported type"* — the stated reason `NeuralCanvas` and `SourceCode` live in `gui.nim` rather than beside their FFI in `canvas.nim` and `sourceview.nim` | True on `v3.0.0`. `6386729` (*"Automatically export widgets"*) exports the widget type, its state type, `buildState`, `updateState` and `destroyState`, with `{.private.}` to opt out. **Both renderables can move to the modules that own their bindings** |
| `src/jenova/gui.nim:2614`, `:2670`, `:2678`, `:2833` | *"owlkettle's `ScrolledWindow` exposes only `child` — no adjustment"*, justifying `ContentScroll`, `AutoScroll` and four raw `importc` | `68c1db0` adds `propagateNaturalWidth`/`propagateNaturalHeight` as fields **and as bindings** (`bindings/gtk.nim:828-829`); `0138a38` adds the `edgeOvershot(edge: Edge)` and `edgeReached(edge: Edge)` signals. Two of the four `importc` at `:2674-2683` are now duplicates of owlkettle's own |
| `src/jenova/gui.nim:3003` | *"owlkettle's `TextView` has no wrap property — checked in `widgets.nim`, per rule 5"* | `6323696` adds `wrapMode: WrapMode` and `textMargin: Margin` (`owlkettle/widgets.nim:2626-2627`) |

**Now (V-02 done):** `gui.nim` declares no `gtk_widget_set_halign` of its own; it imports owlkettle's
typed binding, with `GtkAlign`, `GTK_ALIGN_FILL` and `GTK_ALIGN_START`, from `owlkettle/bindings/gtk`.
`NeuralCanvas` lives in `canvas.nim` and `SourceCode` in `sourceview.nim`: at `ac61ecf` owlkettle
exports a renderable's widget type, state type, `buildState`, `updateState` and `destroyState` unless
it is marked `{.private.}`. The propagate-natural pair is imported from owlkettle's bindings too, and
the only raw scrolled-window `importc` left in `gui.nim` — `gtk_scrolled_window_set_policy` and
`gtk_scrolled_window_set_max_content_height` — are not in owlkettle's bindings, so none duplicates
one.

**Two neighbouring claims survive and must not be swept away with the rest.** Both were
re-checked at `ac61ecf`:

* *"`updateChild` lives in `owlkettle/widgetutils`, which `owlkettle.nim` imports but does not
  re-export"* — still true. `owlkettle.nim` re-exports `widgetdef` (except `build_bin` and
  `update_bin`), `widgets`, `guidsl` and `Align`, and four symbols from `mainloop`: the types
  `Stylesheet` and `ApplicationEvent` and the procs `newStylesheet` and `loadStylesheet`. It also
  defines exported procs of its own, such as `brew`, `writeClipboard` and `addGlobalTimeout`. The
  rest of `mainloop` is not re-exported either.
* *"owlkettle's `TextView` declares no events at all"* — still true. `DraftView` stays.

`AutoScroll` is the interesting case rather than a straight deletion: `edgeReached`/`edgeOvershot`
report the reader's position as *events*, which is what the module-level `scrollPinned` and
`scrollSticky` globals exist to track through a bare C signal handler with nowhere to put state.
Whether the two signals give the same behaviour as the `changed`/`value-changed` pair the current
code binds is a question for a measurement, not for a comment — the current implementation
documents a real defect it was written to fix (following that fell one token behind every frame).

### V-03 — `nimble suites` cannot pass on a clean checkout, and blames the wrong thing · severity: medium

`SelfTests` in `jenova_core.nimble` includes `"serve"`, and `serve-selftest` phase 3 asserts:

```nim
elif not health.contains("\"status\":\"ok\"") or not index.contains("<"):
  echo "  FAIL: health or static did not answer while the debug class was saturated"
```
— `serverselftest.run`, phase 3, as of `c5111ce3` [2026-09-29T22:34Z: now two separate
conditions, and `run` fails first with "no Web UI at …" when `index.html` is absent]

`index` is the body of `GET /`, which `serveStatic` answers out of `public/`. **Nothing in
`coreTask`, `guiTask` or `suites` built `public/`** as of `c5111ce3` — only the separate `web` task
did. (Now `suites` calls `webTask()` after `coreTask()` and `guiTask()` and before the self-tests;
the `web` task, which runs `npm install` and `npm run build` in `jca_web/`, is still the only code
that builds `public/`.) On a tree without it, `/` is `404 text/plain`, contains no `<`, and the run
failed:

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

### V-04 — the pkg-config calls have no failure path · severity: low · **reopened**

**Now:** `dbus.nim`, `sourceview.nim`, `vte.nim`, `mathfont.nim` (HarfBuzz) and `gui.nim` (FreeType)
all call the `pkgConfig` template in `src/jenova/pkgconfig.nim`, which runs pkg-config through
`gorgeEx` and stops the compile with `error()` on a non-zero exit, naming the missing module and its
FreeBSD port only. That `gorgeEx` is the only `gorge` or `staticExec` left in `src/`; owlkettle's own
`gorge` for `gtk4`, `libadwaita-1` and `cairo` still has no failure path. What follows is the state as
of `c5111ce3`.

The `passC`/`passL` pragmas of `src/jenova/dbus.nim` (`gorge`), `src/jenova/sourceview.nim` and
`src/jenova/vte.nim` (`staticExec`), as of `c5111ce3`, splice pkg-config's **stdout** straight
into `passC` and `passL`. When the package is absent, its prose becomes linker arguments.
Reproduced with `dbus-1` missing:

```
gcc: error: the: linker input file not found: No such file or directory
gcc: error: pkg-config: linker input file not found: No such file or directory
gcc: error: Package: linker input file not found: No such file or directory
gcc: error: dbus-1: linker input file not found: No such file or directory
/bin/sh: 4: Syntax error: EOF in backquote substitution
```

Sixty lines of that, naming no missing dependency. `gorgeEx` returns the exit code; a failure
should name the package and the port that provides it, which `docs/install.md` already lists.
[2026-09-29T22:34Z: reopened — see §4. `pkgconfig.pkgQuery` now fails cleanly, but its message
names FreeBSD ports only; `docs/install.md` lists FreeBSD packages only and omits HarfBuzz,
FreeType and cairo; and owlkettle's own bare `gorge` for `gtk4`, `libadwaita-1` and `cairo` still
has no failure path.]

---

## 3. Four more findings, produced by executing the first four

Each was reproduced before it was acted on.

### V-05 — the build gate did not gate the build

`tests/gui_build.sh` is 612 lines, is tracked, and its own header records two defects it caught
that `nim check` could not see. But `grep -n "gui_build\|gui_check" jenova_core.nimble` returned
nothing and the repository has no CI workflow, so `suites` ran the self-tests and six shell
suites and never the only harness that has ever compiled, linked, mapped and driven the window.
[2026-09-29T22:34Z: 978 lines at `4acedfa0`; there is still no CI workflow. Reopened — the tiers
added to fix this disagree; see §4.]

### V-06 — the harness shared one nimcache with every other build on the machine

A gate run produced ~20 `undefined reference` errors for generic instantiations in
`markdown.nim`, ending in `final link failed: bad value`. **There was no code defect**: the same
tree with an explicit fresh `--nimcache:` linked and exited 0. Nim's default cache is keyed on
project *name*, so `/root/.cache/nim/jenova_core_r/` is shared by every build of every copy of
this project from any directory. `gui_build.sh` compiles from the repository tree itself but writes
its outputs and its own nimcache (`$OUT/nimcache/{core,gui,panels}`) into a fresh `mktemp -d` each
run; the only copies it makes are `etc/` and `png/` into `$OUT/root`, and `src/` into `$OUT/panels`
for the panel-open variant. A developer reaches the same state by changing a generic across modules
and rebuilding. Two agents hit it independently; for one it read as a sibling's defect. Reopened on
2026-09-29: the per-task cache does not stop cross-OS reuse (§4).

### V-07 — the harness printed an unhandled Nim exception on a passing run

```
syncio.nim(161)          raiseEIO
Error: unhandled exception: errno: 32 `Broken pipe` [IOError]
```

from the Nim version guard of `tests/gui_build.sh`, `case $("$NIM" --version | head -1) in`
(as of `aabcc77`; it now reads `sed -n 1p`) — `head -1` closes the pipe, `nim` takes SIGPIPE,
and Nim's `syncio` raises rather than dying quietly. Non-deterministic: one run in three. A gate that prints `Error: unhandled exception` while passing trains its reader
to skim the one line that will eventually matter.

### V-08 — the gate never had a port of its own, and the script contradicted itself

The run step of `tests/gui_build.sh` (pre-fix text; no reachable commit holds it) launched the
window with a bare `PORT=18787`. `etc/jenova.conf:39` is `PORT="${JENOVA_PORT:-8080}"`, so the
conf overwrites a bare `PORT` whenever `JENOVA_PORT` is unset: the gate's window bound **8080**,
the real one, under a comment claiming it got "a port of its own, so the run cannot collide". The
same script did it correctly thirty lines earlier, in its seeding step. Measured both ways through
`jenova-core config`. It cost one agent a red gate that read as a code defect.

---

## 4. Tracker

| ID | Finding | Class | Size | State |
|---|---|---|---|---|
| V-01 | `-d:gtk48` dead at the pinned revision; its justifying comment describes `v3.0.0` | stale | XS | **done** |
| V-02 | Four owlkettle-capability claims false at `ac61ecf`; each justifies code that can now go | stale + dead code | S–M | **done**, with one deliberate exception below |
| V-03 | `nimble suites` fails on a clean checkout, reporting the wrong cause | false report | S | **done** — `suites` now depends on `web` |
| V-04 | pkg-config `gorge`/`staticExec` with no failure path | build robustness | XS | **reopened** 2026-09-29T22:34Z — `src/jenova/pkgconfig.nim` fails cleanly, but names FreeBSD ports only; owlkettle's own `gorge` (`gtk4`, `libadwaita-1`, `cairo`) has no failure path. Forward work: PLANS.md |
| V-05 | The build gate did not gate the build | process | S | **reopened** 2026-09-29T22:34Z — tiered and wired into `suites`, but the tiers disagree: `suites` counts `nc` as a mapped-window tool, while `gui_build.sh` requires it — and starts a seeding server — before its build-only branch, so that tier is neither "a compile and a link" nor socket-free. With an inherited `DISPLAY` it drives the live desktop, and on Wayland GTK picks a backend the X11 probes cannot see. Forward work: PLANS.md |
| V-06 | A shared nimcache makes a clean tree fail to link | build robustness | XS | **reopened** 2026-09-29T22:34Z — the per-task `nimcache/` stops cross-checkout sharing, not cross-OS reuse: Nim relinks an object whose regenerated C is byte-identical, `nimcache/core` holds FreeBSD objects beside the Arch build and `nimcache/gui` is FreeBSD-only; `test_nvimctl.sh` still compiles into the default cache. Forward work: PLANS.md |
| V-07 | Unhandled Nim exception printed on a passing gate run | noise | XS | **done** |
| V-08 | The gate bound the real port; the script contradicted itself | isolation | XS | **done** |
| V-09 | Report 03's E-05 verification cannot be reproduced | audit trail | S | **done** |
| V-10 | Every attached image leaves a zero-byte file in the workspace mirror | data | S | **done** |
| V-11 | The gate is not concurrency-safe | isolation | XS | **done** |
| V-12 | `tests/gui_check.sh:31` (as of `aabcc77`) still passes `-d:gtk48` | stale | XS | **done**, and the claim is now self-enforcing |
| V-13 | Four owlkettle gaps found by using it — upstream candidates, not defects here | upstream | — | recorded |
| V-14 | `--check` never builds anything behind an `if …Open` | coverage | S | **done** |
| V-15 | A renamed file asset can restore the wrong copy and report success | **data** | M | **done** — `restoreMirror` collects every matching sidecar and takes the newest by the trash name's own epoch prefix, with the sidecar's mtime as tie-break and the path last so two equal candidates resolve the same way on every run. This row read `open` for two sessions after the fix landed |
| V-16 | A settings help string containing markup blanks its own row | display | XS | **done** — the string, and then the general form: `pipeline-selftest`'s `helpTextIsSafeAsMarkup` block walks `settings.Defs` and fails the suite on a raw `<`, `>` or `&`. [2026-09-29T22:34Z: this read "fails the build"; it is a self-test assertion, so `nimble suites` fails, not `nimble core`/`gui`] |
| V-17 | The reports' line citations drift on every commit | audit trail | S | **open** — open findings re-derived; the class needs symbol-bearing citations |

### V-02's exception: `AutoScroll` stays, and not out of caution

The replacement is **not expressible** at `ac61ecf`. owlkettle's `ScrolledWindow`
(`widgets.nim:1140-1181`) exposes `child`, the two natural-size flags and
`edgeReached`/`edgeOvershot` — and `bindings/gtk.nim:815-821` binds `gtk_adjustment_set_*` with
**no getters at all**, so nothing owlkettle offers can read the view's position. The edge events
fire on *arriving* at an edge and never on *leaving* one, which is exactly the transition
`scrollSticky` exists to observe. The comment was corrected to state what owlkettle does expose
and why it is still not enough. This is the work order's intended outcome: a claim re-checked at
the pinned revision, and the mechanism kept because the *new* reading also says keep it.

---

## 5. The open findings, stated

| ID | Finding |
|---|---|
| **V-04** | **Reopened 2026-09-29T22:34Z.** A missing package now fails with its name, but the hint names FreeBSD ports only and owlkettle's own `gtk4`/`libadwaita-1`/`cairo` queries still splice pkg-config's prose into the link line. Tracker row above; forward work in PLANS.md. |
| **V-05** | **Reopened 2026-09-29T22:34Z.** The gate's tiers disagree about `nc` and sockets, and its mapped-window tier assumes a private X11 display. Tracker row above; forward work in PLANS.md. |
| **V-06** | **Reopened 2026-09-29T22:34Z.** A build tree can link objects compiled on another OS. Tracker row above; forward work in PLANS.md. |
| **V-17** | **The reports' line citations drift on every commit and nothing notices** — 209 of them point into files changed since the last pass. The open findings are re-derived; the class needs symbol-bearing citations. See below. **Re-measured 2026-09-09 and it is worse than this row states**: of seventeen high-value citations resolved by hand, three landed on what they name. `gui.nim` has grown 5,472 → 7,246 lines since the last correction pass. [2026-09-29T22:34Z: 7,547 at `4acedfa0`.] |

**V-15 has been closed** and is recorded in the tracker above. It was fixed in
`fssync.restoreMirror` — every matching sidecar is collected and the newest wins, read
from the trash name's own epoch prefix — which is the resolution this row proposed and
declined to take. The row went on saying `open` for two sessions afterwards, which is the
V-17 class arriving in a state field rather than in a line number.

**This section used to list seven findings under the heading "four", five of them already
recorded as done in the tracker above.** It is now the tracker's open rows and nothing else.
Each of the five, and V-14, was re-checked against the tree rather than taken on the tracker's
word:

* **V-09** — closed. `serverselftest.nim` imports `upstream`, and its phase 4 is the fake
  upstream that drives `upstream.forward` end to end. The finding's evidence — that
  `serverselftest.nim` "mentions neither `upstream` nor `forward`" — was true when written and
  is false now.
* **V-10** — closed. `fssync.syncFileAsset` (`fssync.nim:504-521`) returns `true` before
  touching the disk when the decoded payload is empty, so an image row writes no file and
  `git add`s nothing. `restoreMirror`'s tail reads the same rule back: no bytes means no
  physical form, not a lost file.
* **V-11** — closed. `tests/gui_build.sh` derives `SEED_PORT` from `$$`, and its Xvfb loop
  derives the display number the same way.
* **V-12** — closed. No `-d:gtk48` is passed anywhere. The eight remaining mentions (in
  `jenova_core.nimble`, `gui_check.sh` and `gui_build.sh`) are prose recording that it is gone,
  and the `NimFlags` comment in `jenova_core.nimble` states the property both scripts check.
* **V-16** — closed **in its general form**, not only as one string: `pipeline-selftest`'s
  `helpTextIsSafeAsMarkup` block walks `settings.Defs` and fails the suite on a raw `<`, `>` or
  `&` in any `label` or `help`. That is the assertion this row asked for. [2026-09-29T22:34Z:
  this read "fails the build" at `jenova_core.nim:5174-5182`; corrected.]
* **V-14** — closed. `run_panel_variant` in `tests/gui_build.sh` compiles the panel-open variant
  and `--check`s it, and refuses to pass if any guard it patches has been renamed.

**V-13**, for completeness, is not a defect in this tree: at `ac61ecf` owlkettle binds no
`gtk_file_chooser_set_current_name` (so a Save dialog cannot be pre-filled), no `GtkSorter` on
`ColumnView` (so header-click sorting does not exist to wire), and no `ScrolledWindow` adjustment
getters; and `TextView` still declares no events, which is why `DraftView` remains custom. Four
upstream contribution candidates, found by using the library rather than reading it.

### V-17 — the reports' line citations drift on every commit, and nothing notices · severity: low

**Measured, session 11:** 209 `file.nim:N` citations across the eight reports point into files
changed since the last correction pass, and most no longer land on what they name. This is the
third time it has happened: commit `70ef1003` was *"docs: correct drifted line numbers"*, the
session-10 cleanup corrected them again, and ~2,000 lines of source changed after that.
[2026-09-29T22:34Z: `70ef1003` is reflog-only and prunable; its work is in `989c2b5d` (#117).]

**The open findings were re-derived and fixed** — V-15's five, report 03's deferred table, report
06 §3 and report 05's Phase 2/4/5 states, report 02's P-A6 and P-A8, and V-16's assertion — because
those are the citations a reader actually follows. The rest sit in closed findings and historical
narrative, where a wrong line costs a reader a `grep` rather than a wrong conclusion.

**The class cannot be fixed by correcting it again.** A bare `file:N` carries nothing a checker can
verify: the number is only wrong relative to an intent the citation does not state. Two options,
neither taken here because both are the user's call:

* **Cite the symbol beside the line** — `fssync.nim:836 (restoreMirror)` at `4acedfa0` — which
  makes the citation self-describing and lets a script assert that the named symbol is at or near
  that line.
  A gate for it is about twenty lines of shell, and it would fail the same way `gui_check.sh`
  does: loudly, at the moment the claim stops being true.
* **Drop line numbers from prose entirely** and cite symbols alone, keeping lines only where a
  report quotes source verbatim.

Recorded rather than done because it touches all eight reports and the choice between the two
shapes is a preference about how these documents read. [2026-09-29T22:34Z: the 2026-09-09 V-17
ruling banned citations in code comments only. This report's corrections cite symbols first,
giving a line only as "at `4acedfa0`" and quoted text as "as of <commit>" — close to the first
option, as a working convention; the user's call on report prose is still open.]

### Cross-references

* **Report 05, Phase 0** — closed by session 7's pin and `-d:adwminor=4`. V-01 is the residue:
  the third switch in the same string was not re-examined when the first two were.
* **Report 05, Phase 1** — the Linux half is now stronger than the addendum records:
  `tests/gui_build.sh` passes complete, mapped window and all, on stock packages. The
  FreeBSD-only list in that addendum is unchanged and is what still keeps the phase open.
  [2026-09-29T22:34Z: "stock packages" meant the Ubuntu-class container's, under its unrecorded
  gcc; on Arch `nimble gui` fails at `vte.nim`'s `GdkRGBA` under gcc 16.2.1 and clang 22.1.8.
  With Linux first-class, that list is a both-OS verification list — see the matrix at the end
  of §0.]
* **Report 06 §4** — the widget census. V-02 is the same argument applied to the *bindings*
  rather than the widgets: three hand-rolled `importc` and two custom renderables are held in
  place by comments describing the untagged revision.
