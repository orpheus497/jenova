## Script function and purpose: the visual identity as a GTK4 stylesheet, with
## the palette as Nim constants the sheet is generated from.
##
## The palette lives here rather than in the window because the canvas and the
## terminal paint outside the stylesheet and need the same colours. One
## definition means a colour cannot drift between the widgets and the thing
## painted behind them.
##
## Two properties have no GTK4 equivalent and are approximated rather than
## dropped silently: a backdrop blur becomes a translucent fill plus the same
## highlight, which carries the depth cue without the blur, and screen blending
## on the canvas is left as plain alpha compositing.
##
## Typography is deliberately not set. This sheet names no font and no absolute
## size, so the window uses the desktop's own — overriding the system font is
## what makes a native application look foreign.

import owlkettle
import owlkettle/bindings/gtk
import owlkettle/bindings/adw

const
  ## The dark surfaces, as hex.
  ColBackground* = "#131313"
  ColForeground* = "#f0edf2"
  ColCard* = "#1c1b1b"
  ColPopover* = "#201f1f"
  ColPrimary* = "#2b1e3a"       ## Dark royal purple
  ColSecondary* = "#c96464"     ## Crimson
  ColMuted* = "#353534"
  ColMutedForeground* = "#9fa0a6"
  ColAccent* = "#e4b382"        ## Gold
  ColBorder* = "#5e5966"
  ColSidebar* = "#131313"
  ColSidebarAccent* = "#1c1b1b"
  ColCodeBackground* = "#1c1b1b"
  ColCodeForeground* = "#e4b382"

  ## The brand hues. The heading purple is lighter than the primary and is a
  ## separate value rather than a mistake — the wordmark uses it.
  ColBrandPurple* = "#4b2c70"
  ColBrandPurpleLight* = "#8e7cc3"
  ColBrandPurpleHead* = "#7b52ab"
  ColBrandBlue* = "#aba0d9"

  ## The canvas's own colours, named here so the painter and any later tuning
  ## share one definition rather than two literals.
  CanvasParticle* = (0.867, 0.718, 1.0)   ## rgb(221,183,255)
  CanvasLink* = (0.725, 0.780, 0.894)     ## rgb(185,199,228)

  ## The same particle colour as hex, because the glow rule below needs it too.
  ## One definition and two consumers: the canvas paints it and the stylesheet
  ## glows in it.
  ColGlow* = "#ddb7ff"

type
  Palette* = object
    ## Every colour the window draws with, in one record, so a second theme is a
    ## second value rather than a second stylesheet. The constants above stay the
    ## dark palette's source and it is assembled from them, because the terminal
    ## reads them directly and duplicating them would be two places to change.
    bg*, fg*, card*, popover*: string
    primary*, secondary*, muted*, mutedFg*, accent*, border*: string
    sidebar*, sidebarAccent*, codeBg*, codeFg*: string
    purpleHead*, purpleDeep*, purpleLight*, blue*, glow*: string
    ## The highlight and shadow. On dark these are a white top edge and a black
    ## drop; on light a white highlight is invisible and a heavy black shadow is
    ## wrong, so both have to be palette values rather than constants.
    edge*, shadow*: string
    ## The canvas paints these. Light particles read on a near-black ground and
    ## vanish on white, so the light palette darkens them — the canvas is the one
    ## thing that cannot inherit a stylesheet colour.
    canvasParticle*, canvasLink*: tuple[r, g, b: float]
    ## Which source-view scheme fenced code blocks use. A dark scheme on a light
    ## surface is the mismatch that makes a theme look half-applied.
    sourceScheme*: string
    ## Asked of GTK itself, so the desktop's own widgets — menus, tooltips, the
    ## file chooser — match rather than staying dark under a light palette.
    preferDark*: bool

const
  DarkPalette* = Palette(
    bg: ColBackground, fg: ColForeground, card: ColCard, popover: ColPopover,
    primary: ColPrimary, secondary: ColSecondary, muted: ColMuted,
    mutedFg: ColMutedForeground, accent: ColAccent, border: ColBorder,
    sidebar: ColSidebar, sidebarAccent: ColSidebarAccent,
    codeBg: ColCodeBackground, codeFg: ColCodeForeground,
    purpleHead: ColBrandPurpleHead, purpleDeep: ColBrandPurple,
    purpleLight: ColBrandPurpleLight, blue: ColBrandBlue, glow: ColGlow,
    edge: "#ffffff", shadow: "#000000",
    canvasParticle: CanvasParticle, canvasLink: CanvasLink,
    sourceScheme: "jenova-dark", preferDark: true)

  ## The light surfaces are the neutral ramp converted on its published scale
  ## rather than matched by eye.
  ##
  ## The brand hues are not neutral here, deliberately: this window's identity is
  ## the wordmark, so all four are kept and darkened to hold contrast on white.
  ## The dark palette's gold and light blue are chosen to glow on near-black and
  ## are close to invisible on it.
  LightPalette* = Palette(
    bg: "#ffffff", fg: "#0a0a0a", card: "#ffffff", popover: "#ffffff",
    primary: "#ede9f4",          ## the purple tint, not the dark purple
    secondary: "#b04a4a",        ## crimson, darkened to read on white
    muted: "#f5f5f5", mutedFg: "#737373",
    accent: "#a9762f",           ## gold, darkened — #e4b382 is unreadable here
    border: "#d4d4d4",
    sidebar: "#fbfbfb", sidebarAccent: "#f5f5f5",
    codeBg: "#f5f5f5", codeFg: "#8a5a12",
    purpleHead: "#7b52ab", purpleDeep: "#4b2c70",
    purpleLight: "#6f5bab",      ## darkened from #8e7cc3
    blue: "#6f63a8",             ## darkened from #aba0d9
    glow: "#7b52ab",
    edge: "#000000", shadow: "#000000",
    canvasParticle: (0.478, 0.322, 0.671),   ## the head purple, as rgb
    canvasLink: (0.435, 0.388, 0.659),
    sourceScheme: "Adwaita", preferDark: false)

## The palette in force, read by the canvas and the terminal — both paint outside
## the stylesheet and cannot pick a colour up from it.
var activePalette = DarkPalette

## Function purpose: the palette the canvas and the terminal read, since neither
## can pick a colour up from the stylesheet.
proc active*(): Palette = activePalette

## Action purpose: the sixteen ANSI slots the terminal hands the editor, derived
## from the brand rather than left at the built-in xterm palette — which is what
## makes the editor page look like a different application pasted in.
##
## The brand has four hues and a terminal needs six. Green has no brand
## equivalent and is the one invented value, kept low-saturation so it does not
## fight the purples beside it; blue is served by the light brand purple, because
## a true blue is what reads as "not this application".
##
## This governs only what the editor draws through ANSI. A configuration setting
## true-colour mode emits 24-bit escapes and bypasses the palette entirely.
const TerminalPalette* = [
  "#131313",  ##  0 black          — the window ground
  "#c96464",  ##  1 red            — ColSecondary, crimson
  "#8fb48a",  ##  2 green          — the one invented hue, desaturated on purpose
  "#e4b382",  ##  3 yellow         — ColAccent, gold
  "#8e7cc3",  ##  4 blue           — ColBrandPurpleLight standing in for blue
  "#7b52ab",  ##  5 magenta        — ColBrandPurpleHead
  "#aba0d9",  ##  6 cyan           — ColBrandBlue
  "#f0edf2",  ##  7 white          — ColForeground
  "#5e5966",  ##  8 bright black   — ColBorder
  "#dd8888",  ##  9 bright red
  "#a9c9a4",  ## 10 bright green
  "#f0cba3",  ## 11 bright yellow
  "#ab9ce0",  ## 12 bright blue
  "#9d6fd4",  ## 13 bright magenta
  "#c4bce8",  ## 14 bright cyan
  "#ffffff",  ## 15 bright white
]

## Function purpose: built as one string so the palette above is the only place
## a colour is written down.
##
## Selectors are GTK node names plus the style classes the window attaches.
## Anything sitting over the canvas is explicitly transparent: a GTK widget
## paints its own background by default, and an opaque one hides the canvas
## completely rather than subtly.
proc css*(p: Palette = DarkPalette): string =
  result = """
@define-color jenova_bg """ & p.bg & """;
@define-color jenova_fg """ & p.fg & """;
@define-color jenova_card """ & p.card & """;
@define-color jenova_popover """ & p.popover & """;
@define-color jenova_primary """ & p.primary & """;
@define-color jenova_secondary """ & p.secondary & """;
@define-color jenova_muted """ & p.muted & """;
@define-color jenova_muted_fg """ & p.mutedFg & """;
@define-color jenova_accent """ & p.accent & """;
@define-color jenova_border """ & p.border & """;
@define-color jenova_sidebar """ & p.sidebar & """;
@define-color jenova_sidebar_accent """ & p.sidebarAccent & """;
@define-color jenova_code_bg """ & p.codeBg & """;
@define-color jenova_code_fg """ & p.codeFg & """;
@define-color jenova_purple_head """ & p.purpleHead & """;
@define-color jenova_purple_deep """ & p.purpleDeep & """;
@define-color jenova_purple_light """ & p.purpleLight & """;
@define-color jenova_blue """ & p.blue & """;
@define-color jenova_glow """ & p.glow & """;
/* The two colours this sheet used to write literally. On dark, `edge` is a
   white top/left highlight and `shadow` is black; on light a white highlight is
   invisible, so the palette supplies both. */
@define-color jenova_edge """ & p.edge & """;
@define-color jenova_shadow """ & p.shadow & """;

/* ── Selection ────────────────────────────────────────────────────────────
   This sheet carried NO selection rule at all until 2026-08-31, so every
   selected run of text in the application — the message draft, the note body,
   a rename field, a code block — was painted in **the system accent**, which on
   a stock desktop is Adwaita blue. One unbranded colour, in the one place the
   user's eye is guaranteed to be.

   GTK4 puts selection on a subnode of whatever draws the text, and the node
   differs per widget (`text` under an entry, `text` under a textview, directly
   under a label), so the specific selectors are listed rather than relying on
   the bare `selection` node to inherit everywhere. */
selection,
label selection,
entry > text > selection,
textview > text > selection {
  background-color: @jenova_primary;
  color: @jenova_fg;
}

/* A selected row — the workspace tree and any list. Purple wash rather than the
   accent fill, so it reads as the same family as `.conv-active`'s left bar. */
row:selected,
list > row:selected {
  background-color: alpha(@jenova_purple_head, 0.35);
  color: @jenova_fg;
}

/* The one purely decorative rule here, and what makes the wordmark and the
   active chat read as lit rather than merely coloured. */
.glow-text {
  text-shadow: 0 0 8px alpha(@jenova_glow, 0.4);
}

/* The settings panel: opaque, and deliberately not glass. Glass works for the
   sidebar and the chat form because they sit at the window edge over the
   canvas; this sits in the middle over text, and at any usable alpha the
   transcript reads straight through the controls.

   **A blur is not available to fix it.** GTK 4.20 implements no
   `backdrop-filter` — the property does not exist in the library — and GSK's
   `gtk_snapshot_push_blur` blurs a widget's own children, not what is behind a
   sibling. So the answer is the Web UI's own: its settings dialog is
   `Dialog.Content` on `bg-background`, fully opaque, over a
   `fixed inset-0 bg-black/50` overlay. `.glass-panel` is applied to four things
   in `jca_web` and a dialog is none of them. */
.settings-panel {
  background-color: @jenova_popover;
  border: 1px solid alpha(@jenova_border, 0.6);
  border-radius: 18px;
  box-shadow: 0 18px 48px alpha(@jenova_shadow, 0.55);
}
/* The backdrop, and it earns its place twice: it dims the transcript so the
   panel is what the eye lands on, and it is what makes the panel read as modal
   rather than as another floating pane. `Dialog.Overlay`'s `bg-black/50`. */
.settings-scrim { background-color: alpha(@jenova_shadow, 0.5); }
/* A capped code block scrolls inside itself rather than pushing the rest of the
   transcript off screen; `fullHeightCodeBlocks` turns the cap off. */
.code-capped { border-radius: 4px; }
/* A markdown table is a real Grid of Labels and GTK draws no table chrome, so
   the rule of the thing is the header weight and a line under it. The border
   goes on the header cell rather than the Grid, which has no row to hang it
   on. */
.md-table {
  border: 1px solid @jenova_border;
  border-radius: 6px;
  background-color: alpha(@jenova_fg, 0.03);
}
.md-th {
  font-weight: bold;
  border-bottom: 1px solid @jenova_border;
  padding-bottom: 2px;
}
.md-td { color: @jenova_fg; }
/* A staged attachment above the composer, drawn as a chip so several read as a
   row of items rather than one run of text. */
.attach-chip {
  background-color: alpha(@jenova_fg, 0.07);
  border: 1px solid @jenova_border;
  border-radius: 12px;
  padding: 2px 4px 2px 10px;
}
/* The drop target is a Frame only because it needs a single-child setter; it
   must not look like one. */
.drop-zone {
  border: none;
  background: transparent;
}
/* Step 13a, the composer. `min-height` is a **floor**, which is the one thing a
   sizing API is good for and exactly what is wanted here — the ceiling is
   `ContentScroll.maxHeight`, a different mechanism that does not conflict with
   it (168 > 34). It guarantees a clickable target before a line of text exists,
   rather than depending on an empty TextView's natural height.

   The height cap is deliberately NOT here: GTK4 CSS has no `max-height`. A
   first version of this rule used one and `bin/jenova --check` reported it as
   an unknown property, which is the whole reason that check is run.
 */
.draft-view {
  background: transparent;
  padding: 6px 8px;
  min-height: 34px;
}
/* Sits over the empty view. It is deliberately **insensitive** so GTK's picking
   skips it and the click reaches the TextView underneath — the first version was
   sensitive and filled the overlay, and the composer could not be clicked into
   at all. `:disabled` is stated explicitly because that is the state it is
   always in: without it GTK dims the label on top of this colour and the
   placeholder fades to near-invisible against the panel. */
.draft-placeholder,
.draft-placeholder:disabled {
  color: @jenova_muted_fg;
  opacity: 1;
  padding: 6px 10px;
}
.attach-thumb {
  padding: 0;
  min-width: 0;
  min-height: 0;
  border-radius: 4px;
}
.settings-label { font-weight: bold; }
/* Secondary by size rather than by a second colour, which is how `.code-lang`
   and `.dim-note` already do it. */
.settings-help {
  color: @jenova_muted_fg;
  font-size: 0.85em;
}
/* The "Custom" badge — this parameter differs from what the server reported in
   `/props`. The Web UI uses an orange chip for the same signal; `@jenova_accent`
   is this palette's nearest equivalent and is already what `.brand-gold` carries
   on the third wordmark line. */
.settings-custom {
  color: @jenova_accent;
  font-size: 0.8em;
  font-weight: bold;
}
/* A field whose behaviour is not built yet. Muted rather than
   warning-coloured: it is a note about what is scheduled, not a problem with
   what the user just did. */
.settings-awaiting {
  color: @jenova_muted_fg;
  font-size: 0.8em;
  font-style: italic;
}

/* The window is the ground the canvas is painted on. Near-black, matching the
   Web UI's `bg-black` wrapper at `+layout.svelte`.

   No font-family and no font-size anywhere in this sheet: the user's system
   font at the user's size is correct, and a desktop application that overrides
   the desktop's own typography is what looks foreign. Relative sizes are used
   where a label must be secondary. */
window,
window.background {
  background-color: @jenova_bg;
  color: @jenova_fg;
}

/* Everything stacked over the canvas is transparent, or the canvas is invisible.
   Targeted by class rather than by descent: the tree is Overlay > Flap >
   {sidebar, chat column}, and element-path selectors broke silently the last
   time that shape changed. `.jenova-sidebar` sets its own translucent fill and
   wins on specificity. */
.chat-col,
.chat-col > box,
.main-area,
scrolledwindow,
scrolledwindow > viewport,
expander,
frame,
/* The transcript is a `ListView` now, and GtkListView paints its own list
   background over the neural canvas. Its rows do too, so both nodes are
   named — `listview > row` and not a descendant selector, because the row is
   a direct child and an element-path selector broke silently the last time
   this tree changed shape. */
listview,
listview > row,
columnview,
columnview > listview > row {
  background-color: transparent;
}

headerbar {
  background-color: alpha(@jenova_card, 0.72);
  color: @jenova_fg;
  border-bottom: 1px solid alpha(@jenova_border, 0.6);
  box-shadow: none;
}

headerbar .title { font-weight: bold; }
headerbar .subtitle {
  color: @jenova_muted_fg;
  font-size: 0.85em;
}

/* `.glass-panel` (app.css:213-220) minus the blur GTK4 cannot do. Without the
   blur the fill cannot separate the panel from its ground on its own — the two
   are the same colour — so the light top/left edge and the drop shadow are the
   whole of the depth cue, and the shadow was absent while the class itself was
   applied to no widget. */
.glass-panel {
  background-color: alpha(@jenova_bg, 0.4);
  border-top: 1px solid alpha(@jenova_edge, 0.1);
  border-left: 1px solid alpha(@jenova_edge, 0.1);
  border-radius: 10px;
  box-shadow: 0 8px 32px alpha(@jenova_shadow, 0.37);
}

/* The Neovim page. VTE paints its own opaque background unless
   `set_clear_background(false)` is called, which is why an alpha in
   `vte_terminal_set_colors` alone left it a solid slab. With that off, the
   background is this rule's.

   No radius, no drop shadow and no light edge: those belong to the glass
   panels, and carrying them makes the editor read as a card floating over the
   window rather than as a page. The transcript has none of them either and this
   is the same surface. The padding stays, because terminal text against a hard
   edge is unreadable. */
.nvim-term,
.nvim-term > vte-terminal,
vte-terminal.nvim-term {
  background-color: alpha(@jenova_bg, 0.35);
  padding: 8px;
}

/* GtkPaned's drag handle. Invisible at rest and brand-coloured under the
   pointer, the same way the scrollbars behave. */
paned > separator {
  background-color: alpha(@jenova_border, 0.35);
  min-width: 1px;
}
paned > separator:hover { background-color: @jenova_purple_head; }

/* ── Sidebar ──────────────────────────────────────────────────────────────
   owlkettle's Flap adds GTK's `.background` class to the flap child
   (`adw.nim:653`), which paints an opaque theme colour and would hide the
   canvas completely. This rule is loaded at user priority (600) against the
   theme's 200, so it wins — but it has to exist, or the panel is a solid slab.

   The Box carries `.glass-panel` too, which is the class the Web UI's own
   sidebar root carries (`ChatSidebar.svelte:177`). Everything here is what is
   specific to the sidebar and must override it: `rounded-r-[24px]` and square
   left corners, because the panel is flush against the window edge; and a fill
   one step lighter than the window, because a 55% tint of `@jenova_bg` over a
   `@jenova_bg` window is invisible and rendered the panel as a black slab.
   Declared after `.glass-panel` so the later rule wins at equal specificity. */
.jenova-sidebar,
.jenova-sidebar.background {
  background-color: alpha(@jenova_card, 0.55);
  border-radius: 0 24px 24px 0;
}

.sidebar-logo { border-radius: 4px; }

/* The wordmark is three stacked lines in three brand colours, uppercase and
   bold (`ChatSidebar.svelte:186-188`). One purple word on near-black measured
   about 2.9:1 and was the unreadable text in the panel header. */
.brand {
  font-weight: bold;
  letter-spacing: 0.02em;
  text-shadow: 0 0 8px alpha(@jenova_glow, 0.4);
}
.brand-purple  { color: @jenova_purple_head; }
.brand-crimson { color: @jenova_secondary; }
.brand-gold    { color: @jenova_accent; }

/* Tree containers. `ChatSidebarWorkspaceItem.svelte:27` frames every workspace
   as a card — `rounded-lg border border-white/5 bg-surface/20`. Without it the
   tree is undifferentiated text on the panel. A class beats the bare `expander`
   transparency rule above on specificity, which is why that rule can stay. */
.tree-node {
  background-color: alpha(@jenova_card, 0.5);
  border: 1px solid alpha(@jenova_edge, 0.05);
  border-radius: 8px;
  padding: 2px 4px;
}

/* The container's own title and disclosure arrow. `.tree-node` styled the card
   and left the text inside it at the inherited foreground, so a workspace name
   and a chat title were the same weight and colour and the tree read flat.

   **The node is `expander-widget`, not `expander`.** GTK3 named the widget
   `expander`; GTK4 renamed it and gave the *arrow* that name, so the
   `expander` entry in the transparency block above has been matching the
   triangle this whole time and never the widget. Both names are present in
   `libgtk-4.so`, which is how this was settled rather than guessed. The tree is
   `expander-widget > box > title > {expander, label}`, so `title` is addressed
   as a descendant and the arrow inherits `color` from it. */
expander-widget { background-color: transparent; }
expander-widget title {
  color: @jenova_purple_light;
  font-weight: bold;
}
expander-widget title:hover { color: @jenova_fg; }

.section-label {
  color: @jenova_accent;
  font-size: 0.8em;
  font-weight: bold;
  letter-spacing: 0.08em;
  margin: 6px 4px 2px 4px;
}

/* List rows — the sidebar's New Chat and every conversation. Padding and radius
   only; the left alignment is done in the widget tree, because GTK centres a
   Button's own label and no CSS property moves it. */
.row-btn {
  padding: 6px 8px;
  min-height: 0;
  border-radius: 6px;
  border-color: transparent;
  background-color: transparent;
  background-image: none;
  box-shadow: none;
}
.row-btn:hover { background-color: alpha(@jenova_sidebar_accent, 0.9); }

/* The rename / delete / new-child icons beside every row. A symbolic icon is
   painted in the widget's `color`, and `.row-btn` set none — so they inherited
   the full-strength foreground and every secondary action in the tree was as
   loud as the row it acted on. Muted at rest, brand on hover, and delete is the
   one that announces itself. */
.row-btn image { color: alpha(@jenova_muted_fg, 0.75); }
.row-btn:hover image { color: @jenova_purple_light; }

.conv-idle   { color: alpha(@jenova_fg, 0.72); }
.conv-active {
  background-color: alpha(@jenova_sidebar_accent, 0.95);
  color: @jenova_fg;
  box-shadow: inset 2px 0 0 @jenova_purple_head;
  text-shadow: 0 0 8px alpha(@jenova_glow, 0.4);
}

/* Message cards. The Web UI frames each turn; the role tint is what makes a
   long transcript scannable without reading it. */
.msg-card {
  background-color: alpha(@jenova_card, 0.55);
  border: 1px solid alpha(@jenova_border, 0.4);
  border-radius: 8px;
}
.msg-user   { border-left: 2px solid @jenova_purple_head; }
.msg-agent  { border-left: 2px solid @jenova_accent; }
/* A system turn is neither side of the conversation. Muted rather than given a
   third accent: it is context the user should be able to see and identify, not
   something competing with the exchange for attention. */
.msg-system { border-left: 2px solid @jenova_muted_fg; }

.msg-role {
  font-size: 0.8em;
  color: @jenova_muted_fg;
}
.msg-role-user   { color: @jenova_purple_head; }
.msg-role-agent  { color: @jenova_accent; }
.msg-role-system { color: @jenova_muted_fg; }

.msg-body { color: @jenova_fg; }

.code-block {
  background-color: @jenova_code_bg;
  border: 1px solid alpha(@jenova_border, 0.5);
  border-radius: 6px;
}
.code-lang {
  color: @jenova_muted_fg;
  font-size: 0.8em;
}
.code-body {
  font-family: monospace;
  color: @jenova_code_fg;
}

/* The empty-state and notice lines. Both are always present in the tree and
   vary only by text, so they must read as absent when empty. */
.dim-note {
  color: @jenova_muted_fg;
  font-size: 0.9em;
}

/* The note editor. GTK paints a TextView on the theme's base colour, so without
   this it is an opaque unthemed slab in the middle of the glass — the same
   defect the workspace tree had. `text` is the inner node that actually draws. */
textview,
textview text {
  background-color: alpha(@jenova_card, 0.55);
  color: @jenova_fg;
  border-radius: 6px;
}
textview { padding: 8px; }

entry {
  background-color: alpha(@jenova_card, 0.85);
  color: @jenova_fg;
  border: 1px solid alpha(@jenova_border, 0.8);
  border-radius: 6px;
  padding: 6px 8px;
  caret-color: @jenova_accent;
}
entry:focus-within {
  border-color: @jenova_purple_head;
  box-shadow: 0 0 0 1px alpha(@jenova_purple_head, 0.45);
}
entry placeholder { color: alpha(@jenova_muted_fg, 0.7); }

button {
  background-color: alpha(@jenova_card, 0.9);
  color: @jenova_fg;
  border: 1px solid alpha(@jenova_border, 0.7);
  border-radius: 6px;
  padding: 4px 10px;
}
button:hover { background-color: @jenova_sidebar_accent; border-color: @jenova_purple_head; }
button.flat { background-color: transparent; border-color: transparent; }
button.flat:hover { background-color: alpha(@jenova_sidebar_accent, 0.9); }

/* The send button is the one suggested action in the window. Purple, not the
   Adwaita blue, which is the single loudest tell that a GTK app is unthemed. */
button.suggested-action {
  background-color: @jenova_primary;
  color: @jenova_fg;
  border: 1px solid @jenova_purple_head;
}
button.suggested-action:hover { background-color: @jenova_purple_deep; }
button:disabled { color: alpha(@jenova_muted_fg, 0.6); }

popover > contents {
  background-color: @jenova_popover;
  color: @jenova_fg;
  border: 1px solid alpha(@jenova_border, 0.8);
  border-radius: 12px;
}

separator { background-color: alpha(@jenova_border, 0.5); }

/* Scrollbars: invisible until hovered, matching app.css:166-198. */
scrollbar { background-color: transparent; border: none; }
scrollbar slider {
  background-color: transparent;
  border-radius: 3px;
  min-width: 6px;
  min-height: 6px;
}
scrolledwindow:hover scrollbar slider { background-color: alpha(@jenova_muted_fg, 0.3); }
scrollbar slider:hover { background-color: alpha(@jenova_muted_fg, 0.5); }
"""

## Function purpose: separate from the text builder so the raw stylesheet stays
## testable with no GTK context.
proc stylesheet*(p: Palette = DarkPalette): Stylesheet =
  activePalette = p
  newStylesheet(css(p))

# Action purpose: owlkettle takes its stylesheets once, when the window is
# brewed, and exposes no way to change them afterwards — so switching theme
# without restarting needs the GTK calls it makes internally. All but two of
# them are already bound in its own bindings and are imported rather than
# redeclared.
#
# The display is typed as a bare pointer because owlkettle binds that type
# without exporting it, so it cannot be named from here. The value still comes
# from owlkettle's own accessor: it is re-typed at the boundary, not re-derived.
proc gtk_style_context_remove_provider_for_display(
  display: pointer, provider: GtkCssProvider) {.importc, cdecl.}

# libadwaita's own light/dark state, which is what "System" has to follow: it
# already tracks the desktop's colour-scheme preference, so asking it is one call
# where reading the XDG portal directly would be a settings client of its own.
# owlkettle binds `get_default` and `set_color_scheme` but not the getter.
proc adw_style_manager_get_dark(m: StyleManager): cint {.importc, cdecl.}

## The provider installed by the last palette change, kept so it can be removed
## before the next. Without it, switching theme repeatedly stacks providers on
## the display and the oldest still contributes whatever the newer ones do not
## override.
var overrideProvider = GtkCssProvider(nil)

## Function purpose: only callable after GTK is initialised, which happens when
## the window is brewed and not before. The style manager reaches the display
## manager, and GDK aborts the process outright when that is called first — no
## exception, no window. Use the plain resolver before the window exists and the
## live one after it.
proc systemPrefersDark*(): bool =
  let m = adw_style_manager_get_default()
  if pointer(m).isNil: return true
  adw_style_manager_get_dark(m) != 0

## Function purpose: turns the stored setting into a palette without touching
## GTK, so it is safe on the start-up path before the window exists.
##
## Action purpose: the system choice resolves to dark here and is corrected
## later. It cannot be resolved now, because asking libadwaita before GTK is up
## aborts the process — so the window opens on this application's own default and
## the after-build hook re-resolves it once there is a display. Keep this free of
## GTK calls: it is the one that runs first.
proc paletteFor*(choice: string): Palette =
  case choice
  of "light": LightPalette
  else: DarkPalette

## Function purpose: the same choice resolved properly, for callers that run
## after the window exists. This is the one that may ask the desktop.
proc livePaletteFor*(choice: string): Palette =
  case choice
  of "light": LightPalette
  of "dark": DarkPalette
  else: (if systemPrefersDark(): DarkPalette else: LightPalette)

## Function purpose: does this choice still need resolving against the desktop
## once there is a display? Only `system` does, and only then is the `afterBuild`
## re-resolve worth a redraw.
proc needsLiveResolve*(choice: string): bool =
  choice != "light" and choice != "dark"

## Function purpose: installed above owlkettle's own sheet rather than replacing
## it — that provider cannot be reached, so this one sits at a higher priority
## and wins on every property it redefines, which is all of them.
##
## The canvas and the terminal read the active palette instead, because they
## paint outside the stylesheet entirely.
proc applyPalette*(p: Palette) =
  activePalette = p
  let display = gdk_display_get_default()
  if pointer(display).isNil: return
  if not pointer(overrideProvider).isNil:
    gtk_style_context_remove_provider_for_display(cast[pointer](display),
                                                  overrideProvider)
    g_object_unref(pointer(overrideProvider))
  let sheet = css(p)
  overrideProvider = gtk_css_provider_new()
  gtk_css_provider_load_from_data(overrideProvider, sheet.cstring,
                                  sheet.len.csize_t)
  gtk_style_context_add_provider_for_display(display, overrideProvider, 700)
