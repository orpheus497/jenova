## Script function and purpose: the chat composer's behaviour, kept out of the
## widget so it can be asserted (`composer-selftest`).
##
## The composer was a one-line `Entry` bound to a string, which is what blocked
## multi-line drafts, Shift+Enter, autogrow, the height cap and the height reset
## — six Web UI parity gaps behind one widget (`PLANS.md` Step 13a). A `TextView`
## fixes all six and takes one thing away: an `Entry` sends on Enter through
## `activate()`, and a `TextView` has no such signal because Enter is how a
## newline is typed.
##
## So the decision "does this keystroke send, or insert a newline" becomes real
## logic, and this module is where it lives rather than inside the key callback.
## `gui.nim` links into no test binary; this does.

type
  ## What the window should do with a keystroke that reached the composer.
  ## `caPass` means the composer has no opinion and GTK's own handling stands,
  ## which is every key that is not Enter — the overwhelming majority, and the
  ## reason this is three cases and not a bool.
  ComposerAction* = enum
    caPass, caSend, caNewline

const
  ## GDK keyvals. Declared here rather than imported because owlkettle's bindings
  ## do not carry `gdk/gdkkeysyms.h` at all, and three constants do not justify a
  ## header dependency. Enter arrives as one of three values depending on the
  ## keyboard and the layout: the main Return, the numeric keypad's, and the
  ## `ISO_Enter` some layouts emit.
  KeyReturn* = 0xff0d'u32
  KeyKpEnter* = 0xff8d'u32
  KeyIsoEnter* = 0xfe34'u32
  ## `GDK_SHIFT_MASK`. Tested as a mask and not compared for equality, because a
  ## modifier set carries lock and pointer-button bits the composer must ignore —
  ## Shift+Enter with CapsLock on is still Shift+Enter.
  ShiftMask* = 0x1'u32

## Function purpose: the send-or-newline rule, called from the composer's key
## controller. **Shift+Enter inserts a newline and plain Enter sends**, which is
## the frozen Web UI's own binding and the one every chat surface uses; anything
## else is left to GTK.
##
## **Shift is the only modifier that changes the answer.** Ctrl+Enter and
## Alt+Enter send, because neither is bound to anything else here and a user who
## holds a modifier and presses Enter is asking to send; the one binding that
## must not send is the one that means "I am still typing".
proc actionFor*(keyval, modifiers: uint32): ComposerAction =
  if keyval notin [KeyReturn, KeyKpEnter, KeyIsoEnter]:
    return caPass
  if (modifiers and ShiftMask) != 0: caNewline else: caSend

## Function purpose: whether a turn can be sent at all, called by `gui.send` so
## the rule is asserted where it is used rather than in a copy of it.
##
## **Attachments alone are a turn** (G-30): "look at this" with a picture and no
## words is a normal thing to send, and requiring text would refuse it. A send
## while a reply is streaming is refused because the transcript has nowhere to
## put a second one.
proc canSend*(text: string, attachments: int, streaming: bool): bool =
  not streaming and (text.len > 0 or attachments > 0)
