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

import std/tables
import owlkettle
import owlkettle/widgetutils
import owlkettle/bindings/gtk

type
  GVariantPtr = distinct pointer
  GtkShortcutFunc = proc (widget: GtkWidget, args: GVariantPtr,
                          data: pointer): cbool {.cdecl.}

# GTK's own callback action, absent from owlkettle's bindings. Declared through
# the header so a changed signature is a C compile error.
proc gtk_callback_action_new(callback: GtkShortcutFunc, data: pointer,
                             destroy: GDestroyNotify): GtkShortcutAction
  {.importc, cdecl, header: "gtk/gtk.h".}

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
        if not newChild.isNil: gtk_box_append(widget, newChild)
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
