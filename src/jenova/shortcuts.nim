## Script function and purpose: window-wide keyboard shortcuts, as a GTK
## controller rather than through owlkettle's own binding.
##
## owlkettle attaches a shortcut to a button, fires that button's own signal,
## and refuses to change it after build. Every additional accelerator therefore
## needs a button to hang it on, and every such button constrains the child
## count of its container. Here the bindings are data: adding one costs a table
## entry, and no container acquires a positional constraint.

import owlkettle
import owlkettle/widgetutils
import owlkettle/bindings/gtk

type
  GVariantPtr = distinct pointer
  GtkShortcutFunc = proc (widget: GtkWidget, args: GVariantPtr,
                          data: pointer): cbool {.cdecl.}

## Function purpose: wraps a Nim callback as a `GtkShortcutAction`, so a binding
## can run arbitrary code instead of activating a named GTK action. This is the
## piece owlkettle's bindings do not carry, and the reason this module declares
## anything at all.
# Action purpose: GTK's callback action, absent from owlkettle's bindings.
#
# Declared without a `header:` pragma, which is not an oversight. A header makes
# Nim include it in this module's C file, while owlkettle declares every GTK
# function it binds as a bare prototype over `void*`. Both land in the same
# translation unit and the C compiler sees the same symbol declared twice with
# different types — a build failure `nim check` cannot report, because it never
# runs a C compiler. The two other hand-bound modules escape this only because
# neither touches a function owlkettle also binds; this one touches three.
#
# The signature is guaranteed by reading `gtk/gtkshortcutaction.h` instead, the
# way every other hand-declared prototype in this program is.
proc gtk_callback_action_new(callback: GtkShortcutFunc, data: pointer,
                             destroy: GDestroyNotify): GtkShortcutAction
  {.importc, cdecl.}

type
  Action* = proc () {.closure.}
  Binding* = tuple[accel: string, action: Action]

  BindingsObj = object
    actions: seq[proc ()]

  Bindings = ref BindingsObj

## Function purpose: the one C callback every accelerator goes through, so the
## controller carries no closure — see the note on `data` below.
proc dispatch(widget: GtkWidget, args: GVariantPtr,
              data: pointer): cbool {.cdecl.} =
  # Action purpose: an index into the host's own sequence rather than a closure
  # pointer, because a Nim closure is two words and this callback carries one.
  let slot = cast[ptr tuple[owner: Bindings, index: int]](data)
  if slot != nil and slot.owner != nil and slot.index < slot.owner.actions.len:
    let fn = slot.owner.actions[slot.index]
    if fn != nil:
      fn()
      return cbool(1)
  cbool(0)

## A box whose only job is to carry the controller. Managed scope hands its
## shortcuts to the nearest ancestor that manages them, which is the window, so
## they answer anywhere in it — and it must stay mapped to be reached, which is
## why it holds the content rather than sitting beside it.
renderable ShortcutHost of BaseWidget:
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
      # The three-argument form, because owlkettle's add/remove overload wants
      # two `cdecl` procs and a box needs both calls in one step anyway.
      proc replace(widget, oldChild, newChild: GtkWidget) =
        if not oldChild.isNil: gtk_box_remove(widget, oldChild)
        if not newChild.isNil:
          # Action purpose: both expands, and this is what makes the window
          # fill. A box gives a child its *natural* size and hands the leftover
          # only to children that asked for it. owlkettle's own containers set
          # this from an adder annotation, and nothing sets it here because this
          # renderable is the parent — without the two calls the window
          # collapses to the natural height of its content.
          gtk_widget_set_hexpand(newChild, cbool(1))
          gtk_widget_set_vexpand(newChild, cbool(1))
          gtk_box_append(widget, newChild)
      state.updateChild(state.child, widget.valChild, replace)

  hooks bindings:
    (build, update):
      if widget.hasBindings:
        state.bindings = widget.valBindings
      # Refreshed on every update because each callback closes over application
      # state; only the accelerators themselves are structural.
      state.held.actions = @[]
      for b in state.bindings:
        state.held.actions.add b.action

      var accels: seq[string]
      for b in state.bindings: accels.add b.accel
      if accels == state.installed: return

      # Action purpose: GTK cannot remove one shortcut from a controller, so a
      # changed accelerator set means a whole new controller and the old one is
      # released only when the widget is. Written to run rarely: the set is
      # declared once at start-up and does not vary with application state.
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
