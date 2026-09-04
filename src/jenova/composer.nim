## Script function and purpose: the chat composer's decisions, kept out of the
## widget so they can be asserted — the window links into no test binary and
## this does.
##
## The composer is a `TextView`, which is what makes multi-line drafts possible
## and is also why "does this keystroke send or insert a newline" is real logic:
## a `TextView` has no activate signal, because Enter is how a newline is typed.

type
  ## `caPass` means the composer has no opinion and GTK's own handling stands,
  ## which covers every key but Enter — the reason this is three cases and not
  ## a bool.
  ComposerAction* = enum
    caPass, caSend, caNewline

const
  ## GDK keyvals, declared rather than imported because owlkettle's bindings do
  ## not carry `gdkkeysyms.h` and three constants do not justify a header
  ## dependency. Enter arrives as one of three values depending on the keyboard
  ## and layout, so all three are needed.
  KeyReturn* = 0xff0d'u32
  KeyKpEnter* = 0xff8d'u32
  KeyIsoEnter* = 0xfe34'u32
  ## `GDK_SHIFT_MASK`, tested as a mask rather than compared for equality: the
  ## modifier set carries lock and pointer-button bits, and Shift+Enter with
  ## CapsLock on is still Shift+Enter.
  ShiftMask* = 0x1'u32

## Function purpose: the send-or-newline rule, in one place rather than inside
## the key callback. Plain Enter sends and Shift+Enter inserts a newline, which
## is the binding every chat surface uses.
##
## Action purpose: Shift is the only modifier that changes the answer. Ctrl and
## Alt are bound to nothing else here, and a user holding a modifier over Enter
## is asking to send; the one binding that must not send means "still typing".
proc actionFor*(keyval, modifiers: uint32): ComposerAction =
  if keyval notin [KeyReturn, KeyKpEnter, KeyIsoEnter]:
    return caPass
  if (modifiers and ShiftMask) != 0: caNewline else: caSend

## Function purpose: attachments alone are a turn — a picture with no words is
## an ordinary thing to send, and requiring text would refuse it. Sending mid-
## reply is refused because the transcript has nowhere to put a second one.
proc canSend*(text: string, attachments: int, streaming: bool): bool =
  not streaming and (text.len > 0 or attachments > 0)

# ---------------------------------------------------------------------------
# Long paste
# ---------------------------------------------------------------------------

type
  Insertion* = object
    ## What one `changed` event on the composer's buffer did, as far as the
    ## long-paste rule cares about it.
    divert*: bool       ## the inserted run is long enough to become a file
    inserted*: string   ## the run that appeared
    remaining*: string  ## what the draft should be left holding

## Function purpose: `GtkTextView` has no paste signal, so a paste is detected
## from the buffer text alone. It is a single contiguous insertion, so `next` is
## `prev` with one run spliced in, recoverable in O(n) from the longest common
## prefix and suffix around it.
##
## **The length that decides is the inserted run's, and nothing about the
## draft's net length.** With `prev = P + D + S` and `next = P + I + S` the
## growth is `I.len - D.len`, so any test on the draft charges the paste for
## whatever it replaced. Two guards did that and both are gone: the growth
## against the threshold, and then `next.len <= prev.len`, which refused to look
## at all when the paste was smaller than the selection it landed on. Pasting
## 3 000 characters over 5 000 selected ones is a paste by every measure the user
## has, and it was left inline.
##
## Action purpose: **a deletion needs no guard of its own, which is why removing
## them is safe.** With nothing inserted, the common prefix and suffix meet and
## `inserted` is the empty string, so the threshold test below refuses it — the
## same test, for the same reason, rather than a special case that has to be kept
## in step. A threshold of zero means the feature is off and stays a guard,
## because it is about configuration and not about the edit.
proc classifyInsertion*(prev, next: string, threshold: int): Insertion =
  result.remaining = next
  if threshold <= 0: return

  var p = 0
  while p < prev.len and p < next.len and prev[p] == next[p]: inc p
  var sfx = 0
  while sfx < prev.len - p and sfx < next.len - p and
        prev[prev.len - 1 - sfx] == next[next.len - 1 - sfx]: inc sfx

  let inserted = next[p ..< next.len - sfx]
  if inserted.len < threshold: return

  result.divert = true
  result.inserted = inserted
  result.remaining = next[0 ..< p] & next[next.len - sfx .. ^1]

## Function purpose: a timestamp rather than a counter, so two pastes in one
## draft cannot collide and the name records when rather than how many.
proc pastedFileName*(stamp: int64): string =
  "pasted-" & $stamp & ".txt"
