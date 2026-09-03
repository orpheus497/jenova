## Script function and purpose: a VTE terminal hosting the user's own `nvim`.
## Hand-written `vte-2.91-gtk4` FFI because owlkettle has none; the binding lives
## here and the `renderable` wrapping it lives in the window, so this module
## knows nothing but VTE.

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

# Action purpose: bound through VTE's own header rather than by declaring the
# ABI, so a changed signature is a C compile error. Only the calls the embedded
# editor needs are declared; VTE's surface is far larger.
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

## Function purpose: the theme holds colours as `#rrggbb` and VTE wants floats.
## A malformed value yields transparent black rather than raising, because a
## wrong colour must not stop the terminal appearing.
proc parseHex(c: string, a = 1.0): GdkRGBA =
  let h = c.strip(chars = {'#'})
  if h.len != 6: return GdkRGBA(alpha: cfloat(a))
  GdkRGBA(red: cfloat(parseHexInt(h[0..1]).float / 255.0),
          green: cfloat(parseHexInt(h[2..3]).float / 255.0),
          blue: cfloat(parseHexInt(h[4..5]).float / 255.0),
          alpha: cfloat(a))

## The chat column is transparent so the canvas shows through and the terminal
## has to match, or it reads as a rectangle pasted on. Not fully transparent:
## terminal text needs some ground to stay legible over the particle field.
const BackgroundAlpha = 0.35

## Action purpose: the terminal's translucency cannot be set on this side of the
## boundary. A colourscheme sets `Normal` with a background, Neovim emits it as
## a per-cell attribute, and VTE renders what it is told — so no CSS rule and no
## VTE setting sees through a cell the application explicitly filled. It is
## cleared where it is set instead.
##
## `--cmd` runs before the user's configuration, which registers the autocommand
## early enough to catch the colourscheme loading afterwards, and `ColorScheme`
## catches every later change so switching schemes does not undo it.
##
## Only the embedded instance is affected: this lives in the argument vector,
## never in the user's own configuration.
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
  spawnEnv: seq[string] = @[]

## Function purpose: owlkettle's `beforeBuild` sees no field values, so the
## spawn arguments have to be in module state before the widget is built.
##
## `env` is the whole child environment and an empty one means inherit. It is
## passed in rather than read here so this module keeps knowing nothing but VTE.
proc configure*(socket, workdir: string, env: seq[string] = @[]) =
  sockPath = socket
  spawnCwd = workdir
  spawnEnv = env

## Function purpose: everything that must happen before the child is spawned,
## in one place — colours, scrollback and the argument vector are all read at
## spawn time and cannot be changed afterwards.
proc buildTerminal(socket, workdir, file: string): GtkWidget =
  result = vte_terminal_new()

  var
    fg = parseHex(theme.active().fg)
    bg = parseHex(theme.active().bg, BackgroundAlpha)

  # Action purpose: the sixteen ANSI slots must be supplied. A nil palette
  # leaves VTE on its built-in xterm sixteen, so every colour the editor draws
  # comes from stock terminal red/green/blue and the page reads as a different
  # application dropped into the window.
  var palette: array[16, GdkRGBA]
  for i, hex in theme.TerminalPalette:
    palette[i] = parseHex(hex)
  vte_terminal_set_colors(result, addr fg, addr bg, addr palette[0], 16)
  # Without this VTE paints an opaque background whatever the alpha above says;
  # the `.nvim-term` CSS supplies the ground instead.
  vte_terminal_set_clear_background(result, 0)
  vte_terminal_set_scrollback_lines(result, 10_000)
  vte_terminal_set_font_scale(result, 1.0)

  var args = @["nvim", "--listen", socket, "--cmd", TransparentBackground]
  # Action purpose: `--` first, because a document name is user data and a name
  # beginning with a dash would otherwise be read as an option. Appended only
  # when there is a file: with none, the editor opens on its own start screen.
  if file.len > 0:
    args.add "--"
    args.add file
  var argv = allocCStringArray(args)
  var cwd: cstring = nil
  # A missing directory makes the spawn fail outright, and the workspaces root
  # does not exist until the first workspace is created.
  if workdir.len > 0 and dirExists(workdir): cwd = workdir.cstring
  # Action purpose: a non-nil `envv` replaces the child's environment rather than
  # adding to it, so this is either complete or nil and never partial — a partial
  # one spawns an editor with no `PATH` and no display.
  var envv: cstringArray = nil
  if spawnEnv.len > 0: envv = allocCStringArray(spawnEnv)
  vte_terminal_spawn_async(
    result, PtyDefault, cwd,
    argv, envv, SpawnSearchPath,
    nil, nil, nil, -1, nil, nil, nil)
  if envv != nil: deallocCStringArray(envv)
  deallocCStringArray(argv)

## Function purpose: the widget the window instantiates. `--listen` on the
## configured socket is what makes this instance readable by `nvimctl`, so the
## chat can be about the buffer the user is looking at.
proc newNvimTerminal*(): GtkWidget =
  buildTerminal(sockPath, spawnCwd, "")

