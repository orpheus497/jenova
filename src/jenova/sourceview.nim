## Script function and purpose: syntax highlighting for the transcript's fenced
## code blocks, as a hand-written binding to GtkSourceView 5 because owlkettle
## has none. Deliberately a small surface — a read-only view, a buffer, a
## language and a style scheme — since anything beyond colouring a code block
## would be dead code here.
##
## The library's language specs and schemes are compiled into its shared object
## as a GResource, so nothing has to be installed beside the binary.

import std/[os, strutils, tables]
import owlkettle
import owlkettle/bindings/gtk
import ./theme
import ./pkgconfig

pkgConfig("gtksourceview-5", "x11-toolkits/gtksourceview5")

# Action purpose: bound through GtkSourceView's own header, so a changed
# signature is a C compile error rather than a wrong call. The handle types are
# `distinct pointer` because nothing here ever dereferences one.
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

# Action purpose: the GtkTextView setters are redeclared under Nim-side names
# rather than taken from owlkettle. owlkettle declares them with no header, so
# Nim emits its own `(void*, int)` prototypes, and including `gtksource.h` in
# the same file drags in the real GTK ones — which the C compiler then rejects
# as conflicting. Naming them here keeps one declaration of each: the header's.
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

# Action purpose: the handle types are `distinct`, so `isNil` does not carry
# over from `pointer` and has to be restated for each.
proc isNil(x: GtkSourceLanguage): bool = pointer(x).isNil
proc isNil(x: GtkSourceStyleScheme): bool = pointer(x).isNil

var sourceReady = false

## Function purpose: `gtk_source_init` registers the library's GResource, and
## must run before the first buffer exists or no language and no scheme resolve.
## Calling it twice is harmless; calling it late is not.
proc ensureSourceInit() =
  if not sourceReady:
    gtk_source_init()
    sourceReady = true

## Asked for in order, first hit wins, because which schemes a given
## GtkSourceView build ships is not guaranteed. An unavailable id answers nil
## rather than failing, so the ladder costs nothing and the worst outcome is an
## off-brand block rather than an unreadable light one.
const SchemePreference = @["jenova-dark", "Adwaita-dark", "classic-dark",
                           "solarized-dark", "oblivion", "cobalt"]

## The same ladder for a light palette. A dark code block on a white transcript
## is the mismatch that makes a theme look half-applied.
const LightSchemePreference = @["Adwaita", "classic", "solarized-light",
                                "tango", "kate"]

## Action purpose: embedded in the binary rather than shipped as a data file.
## GtkSourceView loads schemes only from a directory on its search path, so this
## is written out at startup and that directory appended — which keeps the
## application a single file with nothing to install or lose.
##
## A scheme has to be supplied because none of the ids the library ships is a
## dark scheme built on this palette, and without one the ladder falls through
## to GNOME's colours. The `def:` styles are GtkSourceView's own cross-language
## abstractions, so colouring those covers every language it ships rather than
## needing one rule per fence label.
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

## Function purpose: must run from the entry point before any buffer is built —
## a search path appended afterwards is too late for the blocks already on
## screen. Failure is silent by design: an unwritable directory means the ladder
## falls through and code blocks are off-brand rather than missing.
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

## Function purpose: resolves each buffer's scheme as it is built, reading the
## palette in force rather than taking it as a parameter — threading the choice
## through the widget tree would put a theme concern in every code block.
proc applyScheme(buffer: GtkSourceBuffer) =
  let mgr = gtk_source_style_scheme_manager_get_default()
  let prefer = (if theme.active().preferDark: SchemePreference
                else: LightSchemePreference)
  for id in prefer:
    let scheme = gtk_source_style_scheme_manager_get_scheme(mgr, id.cstring)
    if not scheme.isNil:
      gtk_source_buffer_set_style_scheme(buffer, scheme)
      return

## Fence labels are what a model writes, not what GtkSourceView calls a
## language. Only the ones that differ are listed; anything else passes through
## unchanged and simply fails to resolve if it is not a real id.
const LangAliases = {
  "sh": "sh", "shell": "sh", "bash": "sh", "zsh": "sh", "console": "sh",
  "js": "js", "javascript": "js", "ts": "typescript",
  "py": "python3", "python": "python3",
  "yml": "yaml", "md": "markdown", "rs": "rust",
  "c++": "cpp", "h": "c", "hpp": "cpp",
  "text": "", "txt": "", "plain": "", "": ""
}.toTable

## Function purpose: an empty mapping is deliberate and means "no highlighting",
## which is how a `text` or unlabelled fence stays plain.
proc resolveLanguage(label: string): GtkSourceLanguage =
  let key = label.strip.toLowerAscii
  let id = LangAliases.getOrDefault(key, key)
  if id.len == 0: return GtkSourceLanguage(nil)
  gtk_source_language_manager_get_language(
    gtk_source_language_manager_get_default(), id.cstring)

# ---------------------------------------------------------------------------
# The Nim surface: three calls, and no C type crosses them but the buffer handle
# the widget has to keep. The widget itself is at the foot of this file.
# ---------------------------------------------------------------------------

## Function purpose: hands back both halves because every later call addresses
## the buffer, not the view, and the widget cannot be asked for it afterwards.
proc newSourceWidget(): tuple[view: GtkWidget, buffer: GtkSourceBuffer] =
  ensureSourceInit()
  let buffer = gtk_source_buffer_new(nil)
  applyScheme(buffer)
  let view = gtk_source_view_new_with_buffer(buffer)
  # Action purpose: `gtk_source_buffer_new` hands back a full reference — a
  # GtkTextBuffer is a plain GObject and not floating — and the view adds one of
  # its own, so without this the constructor's reference is never dropped and a
  # buffer is leaked per fenced code block, for the life of the process. The
  # unref is AFTER the view exists, which is what leaves it holding the only
  # remaining reference: `state.buffer` keeps the handle for `setSourceText` and
  # `setSourceLanguage`, and it stays valid exactly as long as the view does.
  g_object_unref(pointer(buffer))
  viewSetEditable(view, cbool(0))
  viewSetMonospace(view, cbool(1))
  viewSetCursorVisible(view, cbool(0))
  viewSetWrapMode(view, GtkWrapWordChar)
  viewSetLeftMargin(view, 8)
  viewSetTopMargin(view, 4)
  (view, buffer)

## Function purpose: the length is passed explicitly so a code block containing
## a NUL byte is set whole rather than truncated at it.
proc setSourceText(buffer: GtkSourceBuffer, text: string) =
  bufferSetText(buffer, text.cstring, text.len.cint)

## Function purpose: an unrecognised fence label leaves the block uncoloured
## rather than failing — the lookup answers nil for an unknown id, and a nil
## language is how GtkSourceView is told there is no highlighting.
proc setSourceLanguage(buffer: GtkSourceBuffer, label: string) =
  gtk_source_buffer_set_language(buffer, resolveLanguage(label))

## A read-only, syntax-highlighted code block, beside the binding it wraps.
##
## No ScrolledWindow wraps this and none should — owlkettle's never calls
## `set_propagate_natural_height`, which is what collapsed the plain-Label code
## blocks to their header. The view word-wraps instead.
renderable SourceCode of BaseWidget:
  code: string
  language: string
  ## Action purpose: **the palette's scheme id, carried as a property so a theme
  ## change reaches blocks that already exist.** `applyScheme` runs in
  ## `beforeBuild` and reads the palette in force, which is right for a block
  ## being built and does nothing for one already on screen — owlkettle keeps
  ## widget state across a redraw, so switching the theme at runtime left every
  ## code block coloured for the palette it was born under, on a transcript that
  ## had otherwise changed colour around it.
  ##
  ## The value is the trigger and not the mechanism: `applyScheme` still walks
  ## the preference ladder itself, because which schemes a GtkSourceView build
  ## ships is not guaranteed and the first id is only the preferred one. What
  ## this property does is *change* when the palette changes, which is what makes
  ## owlkettle re-run the hook below.
  scheme: string
  buffer {.private, onlyState.}: GtkSourceBuffer

  hooks:
    beforeBuild:
      let (view, buffer) = newSourceWidget()
      state.buffer = buffer
      state.internalWidget = view

  hooks code:
    property:
      setSourceText(state.buffer, state.code)

  hooks language:
    property:
      setSourceLanguage(state.buffer, state.language)

  hooks scheme:
    property:
      applyScheme(state.buffer)
