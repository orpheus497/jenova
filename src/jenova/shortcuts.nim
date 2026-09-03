## Window-wide keyboard shortcuts.
##
## owlkettle binds shortcuts to `Button.shortcut`, which fires a button's own
## `clicked` signal and cannot change after build (`widgets.nim:938` asserts it,
## marked TODO upstream). That is why this program had exactly one accelerator:
## every additional binding needed a button to hang it on, and every such button
## constrained the child count of its container.
##
## The controller here is the same GTK mechanism without the button. Bindings are
## data, so adding one costs a table entry rather than a widget, and no container
## acquires a positional constraint.

import owlkettle
import owlkettle/widgetutils
import owlkettle/bindings/gtk

type
  GVariantPtr = distinct pointer
  GtkShortcutFunc = proc (widget: GtkWidget, args: GVariantPtr,
                          data: pointer): cbool {.cdecl.}

# GTK's own callback action, absent from owlkettle's bindings.
#
# **No `header:` pragma, and that is not an oversight.** A `header:` makes Nim
# `#include` it in this module's C file, and owlkettle's bindings declare every
# GTK function they bind *without* one — as bare prototypes over `void*`. Both
# then land in the same translation unit, and the C compiler sees
# `gtk_box_new` declared twice with different types:
#
#     error: conflicting types for 'gtk_box_new';
#            have 'void *(int, int)'
#     note:  previous declaration ... 'GtkWidget *(GtkOrientation, int)'
#
# The first version of this module carried `header: "gtk/gtk.h"` for the good
# reason that a changed signature would then be a compile error. The effect was
# that it always was one: `bin/jenova` did not build at all, and `nim check`
# could not say so because it never runs a C compiler. `sourceview.nim` and
# `vte.nim` get away with their headers only because neither uses a GTK function
# owlkettle also binds; this module uses three (`gtk_box_new`, `gtk_box_append`,
# `gtk_box_remove`), so it cannot.
#
# The signature is therefore guaranteed by reading `gtk/gtkshortcutaction.h`,
# the way every other hand-declared prototype in `gui.nim` and `theme.nim` is:
#
#     GtkShortcutAction *gtk_callback_action_new (GtkShortcutFunc callback,
#                                                 gpointer        data,
#                                                 GDestroyNotify  destroy);
proc gtk_callback_action_new(callback: GtkShortcutFunc, data: pointer,
                             destroy: GDestroyNotify): GtkShortcutAction
  {.importc, cdecl.}

type
  Action* = proc () {.closure.}
  Binding* = tuple[accel: string, action: Action]

  BindingsObj = object
    actions: seq[proc ()]

  Bindings = ref BindingsObj

proc dispatch(widget: GtkWidget, args: GVariantPtr,
              data: pointer): cbool {.cdecl.} =
  # `data` is an index into the host's own sequence rather than a closure
  # pointer, because a Nim closure is two words and this callback carries one.
  let slot = cast[ptr tuple[owner: Bindings, index: int]](data)
  if slot != nil and slot.owner != nil and slot.index < slot.owner.actions.len:
    let fn = slot.owner.actions[slot.index]
    if fn != nil:
      fn()
      return cbool(1)
  cbool(0)

renderable ShortcutHost of BaseWidget:
  ## A box whose only job is to carry the controller. Its shortcuts answer
  ## anywhere in the window: `GTK_SHORTCUT_SCOPE_MANAGED` hands them to the
  ## nearest ancestor implementing `GtkShortcutManager`, which is the window.
  ## It must stay mapped to be reached, so it holds the content rather than
  ## sitting beside it.
  child: Widget
  bindings: seq[Binding]

  held {.private, onlyState.}: Bindings
  slots {.private, onlyState.}: seq[ptr tuple[owner: Bindings, index: int]]
  installed {.private, onlyState.}: seq[string]

  hooks:
    beforeBuild:
      state.internalWidget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
      state.held = Bindings()

  hooks child:
    (build, update):
      # The three-argument form: owlkettle's add/remove overload wants two
      # `cdecl` procs and a GtkBox needs both calls in one step anyway.
      proc replace(widget, oldChild, newChild: GtkWidget) =
        if not oldChild.isNil: gtk_box_remove(widget, oldChild)
        if not newChild.isNil:
          # **Both expands, and this is what makes the window fill.** A GtkBox
          # gives a child its *natural* size and hands the leftover only to
          # children that asked for it; owlkettle's own containers set this from
          # the `{.expand.}` adder annotation, and nothing sets it here because
          # this renderable is the parent. Without the two calls the whole window
          # collapsed to the natural height of its content — the canvas
          # disappeared and the composer sat a fifth of the way down an empty
          # window, on every page.
          gtk_widget_set_hexpand(newChild, cbool(1))
          gtk_widget_set_vexpand(newChild, cbool(1))
          gtk_box_append(widget, newChild)
      state.updateChild(state.child, widget.valChild, replace)

  hooks bindings:
    (build, update):
      if widget.hasBindings:
        state.bindings = widget.valBindings
      # The callbacks are refreshed every update because each one closes over
      # the application state, and only the accelerators are structural.
      state.held.actions = @[]
      for b in state.bindings:
        state.held.actions.add b.action

      var accels: seq[string]
      for b in state.bindings: accels.add b.accel
      if accels == state.installed: return

      # GTK has no way to remove one shortcut from a controller, so a changed
      # accelerator set means a new controller. The old one goes with the
      # widget only at destruction, so this is written to run rarely: the set is
      # declared once at startup and does not vary with application state.
      let controller = gtk_shortcut_controller_new()
      gtk_shortcut_controller_set_scope(controller, GTK_SHORTCUT_SCOPE_MANAGED)
      for i, b in state.bindings:
        let trigger = gtk_shortcut_trigger_parse_string(b.accel.cstring)
        if trigger.isNil: continue
        let slot = cast[ptr tuple[owner: Bindings, index: int]](
          alloc0(sizeof(tuple[owner: Bindings, index: int])))
        slot.owner = state.held
        slot.index = i
        state.slots.add slot
        let action = gtk_callback_action_new(dispatch, slot, nil)
        gtk_shortcut_controller_add_shortcut(
          controller, gtk_shortcut_new(trigger, action))
      gtk_widget_add_controller(state.internalWidget, controller)
      state.installed = accels

  adder add:
    if widget.hasChild:
      raise newException(ValueError, "ShortcutHost takes one child; use a Box.")
    widget.hasChild = true
    widget.valChild = child

export ShortcutHost, Binding, Action
