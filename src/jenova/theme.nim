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

/* `.glass-panel` (app.css:213-220) minus the blur GTK4 cannot do. The
   translucent fill, the light top/left edge and the drop shadow are what carry
   the depth; the blur is the part that is genuinely absent. */
.glass-panel {
  background-color: alpha(@jenova_bg, 0.4);
  border-top: 1px solid alpha(#ffffff, 0.1);
  border-left: 1px solid alpha(#ffffff, 0.1);
  border-radius: 10px;
}

/* ── Sidebar ──────────────────────────────────────────────────────────────
   owlkettle's Flap adds GTK's `.background` class to the flap child, which
   paints an opaque theme colour and would hide the canvas completely. This
   rule is loaded at user priority (600) against the theme's 200, so it wins —
   but it has to exist, or the panel is a solid slab. */
.jenova-sidebar,
.jenova-sidebar.background {
  background-color: alpha(@jenova_bg, 0.55);
  border-right: 1px solid alpha(@jenova_border, 0.45);
}

.sidebar-logo { border-radius: 4px; }

.brand {
  font-weight: bold;
  color: @jenova_purple_head;
}

.section-label {
  color: @jenova_muted_fg;
  font-size: 0.8em;
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
.conv-idle   { color: alpha(@jenova_fg, 0.72); }
.conv-active {
  background-color: alpha(@jenova_sidebar_accent, 0.95);
  color: @jenova_fg;
  box-shadow: inset 2px 0 0 @jenova_purple_head;
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
