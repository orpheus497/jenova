## Script function and purpose: syntax highlighting for the transcript's fenced
## code blocks (G-7), as a hand-written binding to GtkSourceView 5.
##
## owlkettle 3.0.0 has no GtkSourceView widget and no bindings for it, so this is
## the one place in the program that declares foreign functions itself. It is a
## deliberately small surface — a read-only view, a buffer, a language and a
## style scheme — rather than a general binding: everything GtkSourceView can do
## beyond colouring a code block is out of scope and would be dead code.
##
## The library's language specs and style schemes are compiled into
## `libgtksourceview-5.so` as a GResource, so nothing has to be installed beside
## the binary and no data path has to be configured.

import std/[strutils, tables]
import owlkettle/bindings/gtk

{.passC: staticExec("pkg-config --cflags gtksourceview-5").}
{.passL: staticExec("pkg-config --libs gtksourceview-5").}

{.push importc, cdecl, header: "gtksourceview/gtksource.h".}

type
  GtkSourceBuffer* = distinct pointer
  GtkSourceLanguage* = distinct pointer
  GtkSourceLanguageManager* = distinct pointer
  GtkSourceStyleScheme* = distinct pointer
  GtkSourceStyleSchemeManager* = distinct pointer

proc gtk_source_init()
proc gtk_source_buffer_new(table: pointer): GtkSourceBuffer
proc gtk_source_view_new_with_buffer(buffer: GtkSourceBuffer): GtkWidget
proc gtk_source_buffer_set_language(buffer: GtkSourceBuffer, lang: GtkSourceLanguage)
proc gtk_source_buffer_set_style_scheme(buffer: GtkSourceBuffer,
                                        scheme: GtkSourceStyleScheme)
proc gtk_source_language_manager_get_default(): GtkSourceLanguageManager
proc gtk_source_language_manager_get_language(m: GtkSourceLanguageManager,
                                              id: cstring): GtkSourceLanguage
proc gtk_source_style_scheme_manager_get_default(): GtkSourceStyleSchemeManager
proc gtk_source_style_scheme_manager_get_scheme(m: GtkSourceStyleSchemeManager,
                                                id: cstring): GtkSourceStyleScheme
{.pop.}

# The GtkTextView setters are declared with Nim-side names and an explicit
# `importc`, not under the push above and not taken from owlkettle. owlkettle's
# bindings declare `set_editable` and `set_monospace` **without** a header, so
# Nim emits its own prototypes — `(void*, int)` — and including
# `gtksource.h` in the same file drags in the real GTK declarations, which the C
# compiler then rejects as conflicting. Naming them here keeps one declaration of
# each, the header's.
{.push cdecl, header: "gtksourceview/gtksource.h".}

proc bufferSetText(buffer: GtkSourceBuffer, text: cstring, len: cint)
  {.importc: "gtk_text_buffer_set_text".}
proc viewSetWrapMode(view: GtkWidget, mode: cint)
  {.importc: "gtk_text_view_set_wrap_mode".}
proc viewSetCursorVisible(view: GtkWidget, visible: cbool)
  {.importc: "gtk_text_view_set_cursor_visible".}
proc viewSetEditable(view: GtkWidget, editable: cbool)
  {.importc: "gtk_text_view_set_editable".}
proc viewSetMonospace(view: GtkWidget, monospace: cbool)
  {.importc: "gtk_text_view_set_monospace".}
proc viewSetLeftMargin(view: GtkWidget, margin: cint)
  {.importc: "gtk_text_view_set_left_margin".}
proc viewSetTopMargin(view: GtkWidget, margin: cint)
  {.importc: "gtk_text_view_set_top_margin".}

{.pop.}

const GtkWrapWordChar = 3.cint

proc isNil(x: GtkSourceLanguage): bool = pointer(x).isNil
proc isNil(x: GtkSourceStyleScheme): bool = pointer(x).isNil

var sourceReady = false

## `gtk_source_init` registers the library's GResource. Calling it twice is
## harmless, but it must happen before the first buffer exists or no language
## and no scheme can be looked up.
proc ensureSourceInit() =
  if not sourceReady:
    gtk_source_init()
    sourceReady = true

## The Web UI's code blocks are dark. Schemes are asked for in order and the
## first that resolves is used, because which ones a given GtkSourceView build
## ships is not guaranteed — an unavailable id returns nil rather than failing,
## so the fallback costs nothing and a missing scheme degrades to the default
## rather than to an unreadable light block.
const SchemePreference = ["Adwaita-dark", "classic-dark", "solarized-dark",
                          "oblivion", "cobalt"]

proc applyScheme(buffer: GtkSourceBuffer) =
  let mgr = gtk_source_style_scheme_manager_get_default()
  for id in SchemePreference:
    let scheme = gtk_source_style_scheme_manager_get_scheme(mgr, id.cstring)
    if not scheme.isNil:
      gtk_source_buffer_set_style_scheme(buffer, scheme)
      return

## Fence labels are what a model writes, not what GtkSourceView calls a language.
## Only the ones that actually differ are listed; anything else is passed through
## unchanged and simply fails to resolve if it is not a real id.
const LangAliases = {
  "sh": "sh", "shell": "sh", "bash": "sh", "zsh": "sh", "console": "sh",
  "js": "js", "javascript": "js", "ts": "typescript",
  "py": "python3", "python": "python3",
  "yml": "yaml", "md": "markdown", "rs": "rust",
  "c++": "cpp", "h": "c", "hpp": "cpp",
  "text": "", "txt": "", "plain": "", "": ""
}.toTable

proc resolveLanguage(label: string): GtkSourceLanguage =
  let key = label.strip.toLowerAscii
  let id = LangAliases.getOrDefault(key, key)
  if id.len == 0: return GtkSourceLanguage(nil)
  gtk_source_language_manager_get_language(
    gtk_source_language_manager_get_default(), id.cstring)

# ---------------------------------------------------------------------------
# The Nim surface. Three calls, and no C type crosses them except the buffer
# handle the widget has to hold on to.
#
# The `renderable` itself lives in `gui.nim` rather than here: owlkettle's macro
# emits its type without an export marker (`widgetdef.nim:730`), so a widget
# declared in this module would be invisible to the module that uses it. Keeping
# the FFI here and the widget beside the rest of the widget tree is the split
# that actually compiles, and it is the better one anyway.
# ---------------------------------------------------------------------------

## Function purpose: build a read-only, monospaced, word-wrapping source view and
## hand back both halves — the widget for owlkettle's `internalWidget`, and the
## buffer, because every later call addresses the buffer rather than the view.
proc newSourceWidget*(): tuple[view: GtkWidget, buffer: GtkSourceBuffer] =
  ensureSourceInit()
  let buffer = gtk_source_buffer_new(nil)
  applyScheme(buffer)
  let view = gtk_source_view_new_with_buffer(buffer)
  viewSetEditable(view, cbool(0))
  viewSetMonospace(view, cbool(1))
  viewSetCursorVisible(view, cbool(0))
  viewSetWrapMode(view, GtkWrapWordChar)
  viewSetLeftMargin(view, 8)
  viewSetTopMargin(view, 4)
  (view, buffer)

proc setSourceText*(buffer: GtkSourceBuffer, text: string) =
  bufferSetText(buffer, text.cstring, text.len.cint)

## An unrecognised fence label leaves the block uncoloured rather than failing:
## `gtk_source_language_manager_get_language` returns nil for an unknown id and
## `set_language(nil)` is how GtkSourceView is told "no highlighting".
proc setSourceLanguage*(buffer: GtkSourceBuffer, label: string) =
  gtk_source_buffer_set_language(buffer, resolveLanguage(label))
