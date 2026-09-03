## Script function and purpose: `AdwToastOverlay`, which owlkettle does not have.
##
## Report 05's Phase 3 lists a toast overlay as the home for the window's
## transient messages, and report 06 §4 lists it among the native idioms this
## window does not use. Neither noticed that **owlkettle 3.0.0 does not bind it
## at all** — not gated behind `AdwVersion` like `Banner` and `SwitchRow` are,
## simply absent: `grep -rn Toast owlkettle/` returns nothing, in `adw.nim` and
## in `bindings/adw.nim` alike. So this is report 06 §5's escape hatch, which
## `vte.nim`, `sourceview.nim` and `canvas.nim` already use: five `importc`
## declarations and one `renderable`.
##
## ## The problem a toast poses that a widget property does not
##
## owlkettle is declarative — a `renderable`'s properties are *state*, applied on
## every update until they change. **A toast is an event.** Raising one from a
## property hook that runs on every redraw would put a toast on screen per frame
## while a reply streams; raising one only when the *text* changes would swallow
## the second of two identical messages, so saving a note twice would confirm it
## once.
##
## Hence `serial`. The window increments it on every message it wants shown, and
## this widget compares that integer against the last one it raised. Identical
## text raised twice is two different serials and two toasts; the same serial
## seen on fifty consecutive frames is one.
##
## ## What it deliberately does not have
##
## **No button, and no event.** `AdwToast` can carry one, and it would be the
## obvious home for the window's Retry action — but a toast outlives several
## redraws, while owlkettle replaces a state's `EventObj` on *every* update and
## ARC frees the old one. A handler bound to a live toast would therefore be
## holding freed memory within a frame or two, which is exactly the SIGBUS
## `DraftView.submit` had (`gui.nim`, `connectEvents`). The window keeps Retry on
## the inline notice row instead, where the widget and the handler have the same
## lifetime. That is also the better split on its own terms: a message you have
## to act on should not time out.

import owlkettle
import owlkettle/widgetutils
from owlkettle/bindings/gtk import GtkWidget

type AdwToast = distinct pointer

# **No `header:` pragma on any of these, and that is load-bearing.** A `header:`
# makes Nim `#include` it in this module's C file; owlkettle's bindings declare
# the GTK functions the `renderable` macro emits calls to — `gtk_widget_set_*`
# for the inherited `BaseWidget` properties — as bare prototypes over `void*`,
# and the two collide as `conflicting types` in the one translation unit. That
# is precisely how `shortcuts.nim` stopped `bin/jenova` from building, and it is
# why `sourceview.nim` and `vte.nim` can carry headers and this cannot: neither
# of them names a function owlkettle also binds.
#
# The signatures are held instead by `libadwaita-1/adw-toast-overlay.h` and
# `adw-toast.h`, all four present since libadwaita 1.0, so no `AdwVersion` guard
# is needed:
#
#     GtkWidget *adw_toast_overlay_new      (void);
#     void       adw_toast_overlay_set_child(AdwToastOverlay *self, GtkWidget *child);
#     void       adw_toast_overlay_add_toast(AdwToastOverlay *self, AdwToast *toast);
#     AdwToast  *adw_toast_new              (const char *title);
#     void       adw_toast_set_timeout      (AdwToast *self, guint timeout);
proc adw_toast_overlay_new(): GtkWidget {.importc, cdecl.}
proc adw_toast_overlay_set_child(o: GtkWidget, child: GtkWidget)
  {.importc, cdecl.}
proc adw_toast_overlay_add_toast(o: GtkWidget, t: AdwToast) {.importc, cdecl.}
proc adw_toast_new(title: cstring): AdwToast {.importc, cdecl.}
proc adw_toast_set_timeout(t: AdwToast, seconds: cuint) {.importc, cdecl.}

renderable ToastOverlay of BaseWidget:
  ## Holds the window's content and floats transient messages over the bottom of
  ## it. It must *hold* the content rather than sit beside it: the overlay is
  ## what the toast is drawn in front of.
  child: Widget
  ## The text of the message to raise. Empty raises nothing, which is the state
  ## the window is in almost all of the time.
  message: string
  ## Bumped by the window for every message it wants shown. See the header: this
  ## is what turns a property into an event.
  serial: int
  ## Seconds on screen. `0` means "until the user dismisses it", which is
  ## `AdwToast`'s own meaning for zero and is deliberately not this widget's
  ## default — a message nobody has to dismiss is the whole point of a toast.
  timeout: int = 5

  ## The last serial actually raised. Compared against `serial`, never against
  ## `message`.
  fired {.private, onlyState.}: int

  hooks:
    beforeBuild:
      state.internalWidget = adw_toast_overlay_new()
      # -1 and not 0. The window's serial starts at 0, so a `fired` of 0 would
      # make the very first message look like one already shown — which is only
      # reachable when the window opens with a notice already set, and is
      # exactly the case where the message matters most.
      state.fired = -1

  hooks child:
    (build, update):
      state.updateChild(state.child, widget.valChild, adw_toast_overlay_set_child)

  hooks serial:
    property:
      if state.serial != state.fired:
        # Recorded before the message is tested, not after. An empty message is
        # a serial the window consumed without anything to say — a cleared
        # notice — and leaving `fired` behind would raise the *next* toast
        # twice.
        state.fired = state.serial
        if state.message.len > 0:
          let t = adw_toast_new(state.message.cstring)
          adw_toast_set_timeout(t, state.timeout.cuint)
          # `add_toast` takes ownership (transfer full in the GIR), so there is
          # nothing to unref here and nothing to keep: libadwaita queues it,
          # shows it, and disposes of it when it times out.
          adw_toast_overlay_add_toast(state.internalWidget, t)

  adder add:
    if widget.hasChild:
      raise newException(ValueError, "ToastOverlay takes one child; use a Box.")
    widget.hasChild = true
    widget.valChild = child

export ToastOverlay
