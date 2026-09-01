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

## Action purpose: **this is G-23, and it was never a GTK problem.**
##
## Three attempts to make the Neovim page translucent all worked on this side of
## the boundary — an alpha in `vte_terminal_set_colors`, then
## `set_clear_background(false)`, then a `.nvim-term` glass rule — and all three
## failed, because the opacity is not painted here. **Neovim paints it.** A
## colourscheme sets `Normal` with a background (`jvim` uses `#14131A`), Neovim
## emits that as a per-cell background attribute, and VTE renders exactly what it
## is told. No CSS rule and no VTE setting can see through a cell the application
## explicitly filled.
##
## So the background is cleared where it is actually set. `--cmd` runs before the
## user's configuration, which registers the autocommand early enough to catch
## the colourscheme that loads afterwards; `ColorScheme` catches every later
## change too, so switching schemes inside the editor does not undo it.
##
## **This affects only the instance embedded in this window.** The USER's own
## `nvim`, started from a terminal, is untouched — the override lives in this
## argument vector, not in their configuration.
const TransparentBackground =
  "autocmd VimEnter,ColorScheme * " &
  "hi Normal guibg=NONE ctermbg=NONE | " &
  "hi NormalNC guibg=NONE ctermbg=NONE | " &
  "hi NormalFloat guibg=NONE ctermbg=NONE | " &
  "hi SignColumn guibg=NONE ctermbg=NONE | " &
  "hi LineNr guibg=NONE ctermbg=NONE | " &
  "hi EndOfBuffer guibg=NONE ctermbg=NONE"

var
  sockPath = ""
  spawnCwd = ""
  docSockPath = ""
  docCwd = ""
  docFile = ""

## owlkettle's `beforeBuild` sees no field values, so the spawn arguments are
## set here first — same arrangement as `canvas.newArea`.
proc configure*(socket, workdir: string) =
  sockPath = socket
  spawnCwd = workdir

## Function purpose: aim the document panel's editor before the widget is built
## (G-25). Set from the click that opens a document, which is the redraw before
## `beforeBuild` runs — the same ordering `configure` relies on.
##
## Switching documents therefore means destroying the panel widget and building
## it again, because a VTE spawns its child once. That is not a workaround: it is
## the same lifecycle the page editor already has, and it keeps one `nvim` per
## visible terminal rather than a multiplexing scheme nothing asked for.
proc configureDoc*(socket, workdir, file: string) =
  docSockPath = socket
  docCwd = workdir
  docFile = file

proc buildTerminal(socket, workdir, file: string): GtkWidget =
  result = vte_terminal_new()

  var
    fg = parseHex(theme.active().fg)
    bg = parseHex(theme.active().bg, BackgroundAlpha)

  # Action purpose: hand VTE the brand's sixteen ANSI slots. This call passed a
  # nil palette of size 0, which leaves VTE on its built-in xterm 16 — so every
  # colour `nvim` drew came from stock terminal red/green/blue and the page read
  # as a different application dropped into the window. `theme.TerminalPalette`
  # is the one definition; see its comment for the two limits (green is invented,
  # and `termguicolors` bypasses this entirely).
  var palette: array[16, GdkRGBA]
  for i, hex in theme.TerminalPalette:
    palette[i] = parseHex(hex)
  vte_terminal_set_colors(result, addr fg, addr bg, addr palette[0], 16)
  # Without this VTE paints an opaque background regardless of the alpha above,
  # which is what made the tab a solid slab. The `.nvim-term` CSS supplies the
  # ground instead.
  vte_terminal_set_clear_background(result, 0)
  vte_terminal_set_scrollback_lines(result, 10_000)
  vte_terminal_set_font_scale(result, 1.0)

  var args = @["nvim", "--listen", socket, "--cmd", TransparentBackground]
  # `--` first: a document name is user data and could otherwise be read as an
  # option. Only appended when there is one — the page editor opens no file and
  # starts on nvim's own start screen, which is the whole point of it being the
  # user's editor rather than ours.
  if file.len > 0:
    args.add "--"
    args.add file
  var argv = allocCStringArray(args)
  var cwd: cstring = nil
  # A missing cwd makes the spawn fail outright, and the workspaces root does not
  # exist until the first workspace is created.
  if workdir.len > 0 and dirExists(workdir): cwd = workdir.cstring
  vte_terminal_spawn_async(
    result, PtyDefault, cwd,
    argv, nil, SpawnSearchPath,
    nil, nil, nil, -1, nil, nil, nil)
  deallocCStringArray(argv)

## Function purpose: build the terminal and start `nvim` in it. `--listen` makes
## the same instance readable by `nvimctl`, which is what ties G-19 to G-18.
proc newNvimTerminal*(): GtkWidget =
  buildTerminal(sockPath, spawnCwd, "")

## Function purpose: the document panel's editor — a second `nvim`, on its own
## socket, opened on one file in that chat's project directory (G-25).
proc newDocTerminal*(): GtkWidget =
  buildTerminal(docSockPath, docCwd, docFile)
