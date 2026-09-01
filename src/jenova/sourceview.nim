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

import std/[os, strutils, tables]
import owlkettle/bindings/gtk
import ./theme

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
proc gtk_source_style_scheme_manager_append_search_path(
  m: GtkSourceStyleSchemeManager, path: cstring)
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
const SchemePreference = @["jenova-dark", "Adwaita-dark", "classic-dark",
                           "solarized-dark", "oblivion", "cobalt"]

## The same ladder for a light palette (G-31's Theme setting). A dark code block
## on a white transcript is the mismatch that makes a ported theme look
## half-finished, and the fallbacks matter for the same reason as above: which
## schemes a build ships is not guaranteed.
const LightSchemePreference = @["Adwaita", "classic", "solarized-light",
                                "tango", "kate"]

## Action purpose: the Jenova scheme, embedded in the binary rather than shipped
## as a data file. GtkSourceView loads schemes only from a directory on its
## search path, so the XML is written out once at startup and that directory
## appended — which keeps the application a single file with no data dependency
## to install, deploy or lose.
##
## **Why a scheme at all.** Without one, `SchemePreference` fell through to
## `Adwaita-dark`, which a probe against the installed GtkSourceView 5.18
## confirms resolves — so every code block in the transcript was painted in
## GNOME's palette: blue keywords, red strings, nothing from the brand. The
## twelve ids that library offers contain no dark scheme built on purple and
## gold, so one has to be supplied.
##
## The mapping is the same reasoning as `theme.TerminalPalette`: keyword to the
## heading purple, string to gold, comment to the muted grey, number and constant
## to the brand blue, error to crimson. `def:` styles are GtkSourceView's own
## cross-language abstractions, so colouring those covers every language the
## library ships rather than one per fence label.
const SchemeXml = """<?xml version="1.0" encoding="UTF-8"?>
<style-scheme id="jenova-dark" name="Jenova Dark" version="1.0">
  <author>Jenova Cognitive Architecture</author>
  <description>Jenova brand palette — purple, gold, crimson on near-black.</description>

  <color name="bg"           value="#1c1b1b"/>
  <color name="fg"           value="#f0edf2"/>
  <color name="muted"        value="#9fa0a6"/>
  <color name="border"       value="#5e5966"/>
  <color name="purple_head"  value="#7b52ab"/>
  <color name="purple_light" value="#8e7cc3"/>
  <color name="purple_deep"  value="#4b2c70"/>
  <color name="gold"         value="#e4b382"/>
  <color name="crimson"      value="#c96464"/>
  <color name="blue"         value="#aba0d9"/>

  <style name="text"                        foreground="fg" background="bg"/>
  <style name="selection"                   foreground="fg" background="purple_deep"/>
  <style name="cursor"                      foreground="gold"/>
  <style name="current-line"                background="#232122"/>
  <style name="draw-spaces"                 foreground="border"/>
  <style name="background-pattern"          background="bg"/>

  <style name="bracket-match"               foreground="gold" bold="true"/>
  <style name="bracket-mismatch"            foreground="crimson" bold="true"/>
  <style name="search-match"                foreground="bg" background="gold"/>

  <style name="def:comment"                 foreground="muted" italic="true"/>
  <style name="def:shebang"                 foreground="muted" italic="true"/>
  <style name="def:doc-comment-element"     foreground="muted" italic="true"/>

  <style name="def:constant"                foreground="blue"/>
  <style name="def:string"                  foreground="gold"/>
  <style name="def:special-char"            foreground="crimson"/>
  <style name="def:number"                  foreground="blue"/>
  <style name="def:floating-point"          foreground="blue"/>
  <style name="def:boolean"                 foreground="blue" bold="true"/>
  <style name="def:character"               foreground="gold"/>

  <style name="def:identifier"              foreground="fg"/>
  <style name="def:function"                foreground="gold" bold="true"/>
  <style name="def:builtin"                 foreground="purple_light"/>

  <style name="def:statement"               foreground="purple_head" bold="true"/>
  <style name="def:keyword"                 foreground="purple_head" bold="true"/>
  <style name="def:operator"                foreground="purple_light"/>
  <style name="def:type"                    foreground="purple_light" bold="true"/>
  <style name="def:preprocessor"            foreground="crimson"/>

  <style name="def:error"                   foreground="crimson" bold="true" underline="single"/>
  <style name="def:warning"                 foreground="gold" underline="single"/>
  <style name="def:note"                    foreground="blue" bold="true"/>
  <style name="def:deletion"                foreground="crimson" strikethrough="true"/>
  <style name="def:heading"                 foreground="purple_head" bold="true"/>
  <style name="def:link-destination"        foreground="blue" underline="single"/>
  <style name="def:emphasis"                italic="true"/>
  <style name="def:strong-emphasis"         foreground="gold" bold="true"/>
  <style name="def:inline-code"             foreground="gold"/>
</style-scheme>
"""

## Function purpose: make the Jenova scheme available, given a directory this
## process may write to. Called once from the application entry point before any
## buffer is built, because `applyScheme` asks for `jenova-dark` first and a
## search path appended afterwards would be too late for the blocks already on
## screen. Failure is survivable and silent by design: an unwritable directory
## means the scheme is absent, `SchemePreference` falls through to `Adwaita-dark`
## as it did before, and code blocks are off-brand rather than missing.
proc installScheme*(dir: string) =
  try:
    createDir(dir)
    let path = dir / "jenova-dark.xml"
    if not fileExists(path) or readFile(path) != SchemeXml:
      writeFile(path, SchemeXml)
    gtk_source_style_scheme_manager_append_search_path(
      gtk_source_style_scheme_manager_get_default(), dir.cstring)
  except OSError, IOError:
    discard

proc applyScheme(buffer: GtkSourceBuffer) =
  let mgr = gtk_source_style_scheme_manager_get_default()
  # The palette in force decides which ladder is walked. `theme.active()` rather
  # than a parameter, because every SourceCode widget resolves its own scheme as
  # it is built and threading the choice through the widget tree would put a
  # theme concern into every code block.
  let prefer = (if theme.active().preferDark: SchemePreference
                else: LightSchemePreference)
  for id in prefer:
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
