## Script function and purpose: a VTE terminal widget hosting the USER's own
## `nvim` (G-19, ruling D-AT). Hand-written `vte-2.91-gtk4` FFI because owlkettle
## has none; same split as `sourceview.nim` — the FFI lives here, the
## `renderable` in `gui.nim`.

import std/[os, strutils]
import owlkettle/bindings/gtk
import ./theme

{.passC: staticExec("pkg-config --cflags vte-2.91-gtk4").}
{.passL: staticExec("pkg-config --libs vte-2.91-gtk4").}

type
  GdkRGBA = object
    red, green, blue, alpha: cfloat

  SpawnCallback = proc(term: GtkWidget, pid: cint, err: pointer,
                       data: pointer) {.cdecl.}

{.push importc, cdecl, header: "vte/vte.h".}

proc vte_terminal_new(): GtkWidget
proc vte_terminal_set_colors(term: GtkWidget, fg, bg, palette: ptr GdkRGBA,
                             paletteSize: csize_t)
proc vte_terminal_set_scrollback_lines(term: GtkWidget, lines: clong)
proc vte_terminal_set_clear_background(term: GtkWidget, setting: cint)
proc vte_terminal_set_font_scale(term: GtkWidget, scale: cdouble)
proc vte_terminal_spawn_async(term: GtkWidget, ptyFlags: cint,
                              workingDirectory: cstring,
                              argv, envv: cstringArray,
                              spawnFlags: cint,
                              childSetup: pointer, childSetupData: pointer,
                              childSetupDataDestroy: pointer,
                              timeout: cint, cancellable: pointer,
                              callback: SpawnCallback, userData: pointer)

{.pop.}

const
  PtyDefault = 0.cint
  SpawnSearchPath = (1 shl 2).cint

proc parseHex(c: string, a = 1.0): GdkRGBA =
  ## `theme.nim` holds the palette as `#rrggbb`; VTE wants floats.
  let h = c.strip(chars = {'#'})
  if h.len != 6: return GdkRGBA(alpha: cfloat(a))
  GdkRGBA(red: cfloat(parseHexInt(h[0..1]).float / 255.0),
          green: cfloat(parseHexInt(h[2..3]).float / 255.0),
          blue: cfloat(parseHexInt(h[4..5]).float / 255.0),
          alpha: cfloat(a))

## The chat column is fully transparent so the canvas shows through; the terminal
## has to match or it reads as a pasted-on rectangle. Not fully transparent —
## terminal text needs some ground to stay legible over the particle field.
const BackgroundAlpha = 0.35

var
  sockPath = ""
  spawnCwd = ""

## owlkettle's `beforeBuild` sees no field values, so the spawn arguments are
## set here first — same arrangement as `canvas.newArea`.
proc configure*(socket, workdir: string) =
  sockPath = socket
  spawnCwd = workdir

## Function purpose: build the terminal and start `nvim` in it. `--listen` makes
## the same instance readable by `nvimctl`, which is what ties G-19 to G-18.
proc newNvimTerminal*(): GtkWidget =
  let socket = sockPath
  let workdir = spawnCwd
  result = vte_terminal_new()

  var
    fg = parseHex(theme.ColForeground)
    bg = parseHex(theme.ColBackground, BackgroundAlpha)
  vte_terminal_set_colors(result, addr fg, addr bg, nil, 0)
  # Without this VTE paints an opaque background regardless of the alpha above,
  # which is what made the tab a solid slab. The `.nvim-term` CSS supplies the
  # ground instead.
  vte_terminal_set_clear_background(result, 0)
  vte_terminal_set_scrollback_lines(result, 10_000)
  vte_terminal_set_font_scale(result, 1.0)

  var argv = allocCStringArray(["nvim", "--listen", socket])
  var cwd: cstring = nil
  # A missing cwd makes the spawn fail outright, and the workspaces root does not
  # exist until the first workspace is created.
  if workdir.len > 0 and dirExists(workdir): cwd = workdir.cstring
  vte_terminal_spawn_async(
    result, PtyDefault, cwd,
    argv, nil, SpawnSearchPath,
    nil, nil, nil, -1, nil, nil, nil)
  deallocCStringArray(argv)
