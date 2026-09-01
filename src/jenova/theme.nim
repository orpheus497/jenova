## Script function and purpose: the Jenova visual identity as a GTK4 stylesheet,
## ported from the Web UI's `jca_web/src/app.css` so the desktop application and
## the LAN client look like one product (G-1/G-2, ruling D-AP).
##
## ## Why the palette lives here and not in `gui.nim`
##
## `canvas.nim` needs the same colours the stylesheet uses. Defining them once as
## Nim constants and generating the CSS from them means a colour cannot drift
## between the widgets and the thing painted behind them — which is exactly how
## the Web UI's own `--brand-*` block and its `NeuralCanvas` literals disagree
## today (the canvas hard-codes `rgba(221,183,255,…)`, which is in no token).
##
## ## What did NOT survive the port, stated rather than discovered later
##
## GTK4's CSS is a subset of the web's. Two Web UI properties have no equivalent
## and are approximated:
##
## * **`backdrop-filter: blur(40px)`** — the `.glass-panel` blur. GTK4 has no
##   backdrop filter. Approximated by a translucent fill over the canvas plus the
##   same top/left highlight, which carries the depth cue without the blur.
## * **`mix-blend-mode: screen`** on the canvas — see `canvas.nim`.
##
## Everything else transfers: the dark palette is pure hex (the Web UI's *light*
## theme is `oklch`, which is why only the dark one is ported), and GTK4 supports
## `@define-color`, `alpha()`, radii, borders and shadows directly.
##
## **Typography is deliberately NOT ported.** The Web UI names Inter and
## JetBrains Mono; this sheet names no font and no absolute size, so the window
## uses the desktop's own. A native application that overrides the system font is
## the thing that makes it look foreign.

import owlkettle

const
  ## The Web UI dark theme, `app.css:61-95`. Hex, not `oklch`, so it ports as-is.
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

  ## `app.css:134-144`, the brand block. `ColBrandPurpleHead` is the heading
  ## purple the sidebar logo uses inline (`ChatSidebar.svelte:187`), which is
  ## lighter than `ColPrimary` and is a separate value, not a mistake.
  ColBrandPurple* = "#4b2c70"
  ColBrandPurpleLight* = "#8e7cc3"
  ColBrandPurpleHead* = "#7b52ab"
  ColBrandBlue* = "#aba0d9"

  ## `NeuralCanvas.svelte:44,57`. These are the canvas's own literals and belong
  ## to no CSS token in the Web UI; they are named here so `canvas.nim` and any
  ## future particle tuning share one definition.
  CanvasParticle* = (0.867, 0.718, 1.0)   ## rgb(221,183,255)
  CanvasLink* = (0.725, 0.780, 0.894)     ## rgb(185,199,228)

  ## The same particle colour as hex, because `.glow-text` glows in it
  ## (`app.css:270-271`, `text-shadow: 0 0 8px rgba(221,183,255,0.4)`). One
  ## definition, two consumers: the canvas paints it and the stylesheet glows in
  ## it, and they drifted apart in the Web UI precisely because it had two.
  ColGlow* = "#ddb7ff"

## Action purpose: the sixteen ANSI slots VTE hands to `nvim`, derived from the
## brand rather than left at VTE's built-in xterm palette — which is what made
## the Neovim page look like a different application pasted into the window.
##
## **The brand has four hues and a terminal needs six.** Purple, gold, crimson
## and the light brand blue map directly; green has no brand equivalent and is
## the one invented value, kept deliberately low-saturation so it does not fight
## the purples it sits beside. Blue is served by `ColBrandPurpleLight` rather
## than an actual blue, because a true blue is the thing that reads as "not this
## application".
##
## **This governs only what `nvim` draws through ANSI.** A configuration that
## sets `termguicolors` emits 24-bit escapes and bypasses the palette entirely;
## that case is the USER's own colourscheme and is out of scope by D-AT.
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

## Function purpose: the stylesheet, built as one string so the palette constants
## above are the only place a colour is written down.
##
## Selectors are GTK node names (`window`, `headerbar`, `entry`) plus the style
## classes `gui.nim` attaches. Widgets that sit over the canvas are explicitly
## transparent — a GTK widget paints its own background by default, and an opaque
## one would hide the canvas completely rather than subtly.
proc css*(): string =
  result = """
@define-color jenova_bg """ & ColBackground & """;
@define-color jenova_fg """ & ColForeground & """;
@define-color jenova_card """ & ColCard & """;
@define-color jenova_popover """ & ColPopover & """;
@define-color jenova_primary """ & ColPrimary & """;
@define-color jenova_secondary """ & ColSecondary & """;
@define-color jenova_muted """ & ColMuted & """;
@define-color jenova_muted_fg """ & ColMutedForeground & """;
@define-color jenova_accent """ & ColAccent & """;
@define-color jenova_border """ & ColBorder & """;
@define-color jenova_sidebar """ & ColSidebar & """;
@define-color jenova_sidebar_accent """ & ColSidebarAccent & """;
@define-color jenova_code_bg """ & ColCodeBackground & """;
@define-color jenova_code_fg """ & ColCodeForeground & """;
@define-color jenova_purple_head """ & ColBrandPurpleHead & """;
@define-color jenova_purple_deep """ & ColBrandPurple & """;
@define-color jenova_purple_light """ & ColBrandPurpleLight & """;
@define-color jenova_blue """ & ColBrandBlue & """;
@define-color jenova_glow """ & ColGlow & """;

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

/* `app.css:270-271`. The one purely decorative rule ported, and it is what makes
   the wordmark and the active chat read as lit rather than merely coloured. */
.glow-text {
  text-shadow: 0 0 8px alpha(@jenova_glow, 0.4);
}

/* The settings panel (G-31). It floats over the whole window as an Overlay
   child, so it carries `.glass-panel`'s blur and border and adds only the
   things a panel needs that an edge-anchored sidebar does not: a radius on
   every corner and a shadow deep enough to separate it from the transcript
   behind it. */
.settings-panel {
  border-radius: 18px;
  box-shadow: 0 18px 48px alpha(black, 0.55);
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

/* The window is the ground the canvas is painted on. Near-black, matching the
   Web UI's `bg-black` wrapper at `+layout.svelte`.

   No font-family and no font-size anywhere in this sheet: the user's system
   font, at the user's size, is correct. The Web UI pulls Inter and JetBrains
   Mono from Google Fonts; a desktop application overriding the desktop's own
   typography is wrong, and copying that import would also import the B-01
   leak. Relative sizes (`0.8em`) are used where a label must be secondary. */
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
.doc-panel,
.doc-panel-closed,
scrolledwindow,
scrolledwindow > viewport,
expander,
frame {
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
  border-top: 1px solid alpha(#ffffff, 0.1);
  border-left: 1px solid alpha(#ffffff, 0.1);
  border-radius: 10px;
  box-shadow: 0 8px 32px alpha(#000000, 0.37);
}

/* The Neovim page. VTE paints its own opaque background unless
   `set_clear_background(false)` is called, which is why an alpha in
   `vte_terminal_set_colors` alone left it a solid slab. With that off, the
   background is this rule's.

   **No radius, no drop shadow, no light edge** — those are `.glass-panel`'s, and
   carrying them made the editor read as a card floating over the window rather
   than as a page (G-24). The transcript's ScrolledWindow has none of them
   either; this is the same surface, so it gets the same treatment. The padding
   stays, because terminal text against a hard edge is unreadable. */
.nvim-term,
.nvim-term > vte-terminal,
vte-terminal.nvim-term {
  background-color: alpha(@jenova_bg, 0.35);
  padding: 8px;
}

/* The document panel (G-25). One left border and nothing else: it is a second
   pane of the same window, not a card on top of it, so it gets the divider a
   split needs and none of `.glass-panel`'s floating cues. Empty when the panel
   is closed, which is why the rule may not paint a fill — a closed panel would
   otherwise leave a coloured sliver at the window edge. */
.doc-panel {
  border-left: 1px solid alpha(@jenova_border, 0.55);
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
  border: 1px solid alpha(#ffffff, 0.05);
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

.msg-role {
  font-size: 0.8em;
  color: @jenova_muted_fg;
}
.msg-role-user  { color: @jenova_purple_head; }
.msg-role-agent { color: @jenova_accent; }

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

## Function purpose: the stylesheet as owlkettle wants it at `brew`. Separate from
## `css()` so the raw text stays testable without a GTK context.
proc stylesheet*(): Stylesheet =
  newStylesheet(css())
