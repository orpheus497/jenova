## Script function and purpose: a conversation as a readable markdown
## transcript, both directions. The format is the Web UI's exactly — down to the
## `[agent]` suffix and the ornamental parameter lines — so a document written
## here opens there and the reverse; any "tidying" of it breaks that.
##
## Knows nothing about the database on purpose: plain values in and out, so the
## self-test can round-trip it with no fixture and the callers do the row work.
##
## **One thing does not survive the round trip, deliberately.** A system message
## whose content is empty is not written, because the format carries a system
## message as an HTML comment and an empty one would be `<!-- system:  -->` —
## a line that says nothing and that `fromMarkdown` would restore as a message
## the reader never sees. Every message with content round-trips; an empty
## system message is dropped rather than preserved.

import std/[algorithm, json, strutils]

type
  ## `timestamp` is carried because the document is sorted on it before writing
  ## and an increasing one is synthesised when reading; dropping it silently
  ## reorders an imported transcript.
  MdMessage* = object
    role*: string
    content*: string
    timestamp*: int64

  MdConversation* = object
    name*: string
    messages*: seq[MdMessage]

const
  ## Written under every topic and read back by nobody. Reproduced rather than
  ## dropped because a document that omits them is not the same document.
  HeaderLines = "- model: jenova\n- temperature: 0.7\n- top_p: 0.9\n---\n\n"

## Function purpose: one place decides a stored role, rather than each widget
## deciding for itself — a two-way `user`/`assistant` test elsewhere silently
## coerces a `system` row into the model's own prior words.
##
## Action purpose: the fallback to `assistant` is deliberate. Rows can carry
## roles this format never defined, and a turn of unknown provenance is safer
## attributed to the model than to the user or the system.
proc canonicalRole*(stored: string): string =
  case stored.toLowerAscii
  of "user": "user"
  of "system": "system"
  else: "assistant"

## Function purpose: a system turn becomes an HTML comment rather than a
## section, so it survives a round trip without appearing in the readable
## transcript. Its newlines flatten to spaces because `fromMarkdown` reads a
## comment one line at a time and a spanning one would not parse back.
proc toMarkdown*(name: string, messages: seq[MdMessage]): string =
  result = "# topic: " & name & " [agent]\n" & HeaderLines
  var sorted = messages
  sorted.sort(proc (a, b: MdMessage): int = cmp(a.timestamp, b.timestamp))
  for m in sorted:
    if m.role == "system":
      if m.content.strip.len > 0:
        result.add "<!-- system: " & m.content.replace("\n", " ") & " -->\n\n"
      continue
    # Action purpose: `assistant` is spelled `jenova` in this format and read
    # back as `assistant`; the pairing with `fromMarkdown` is what matters.
    let role = if m.role == "assistant": "jenova" else: m.role
    result.add "## " & role & "\n\n"
    result.add m.content & "\n\n"

## Function purpose: forgiving on purpose, because the input may be a file a
## user wrote by hand — a missing `[agent]` suffix still yields the name, text
## before the first heading is discarded, and a document with no headings parses
## to an empty named conversation rather than an error.
proc fromMarkdown*(md: string): MdConversation =
  var
    name = ""
    msgs: seq[MdMessage]
    currentRole = ""
    current: seq[string]
    stamp = 0'i64

  # Action purpose: a template rather than a nested proc, because a closure
  # capturing `result` is rejected by ARC as a memory-safety violation.
  template flush() =
    if currentRole.len > 0 and current.len > 0:
      msgs.add MdMessage(
        role: (if currentRole == "jenova": "assistant" else: currentRole),
        content: current.join("\n").strip, timestamp: stamp)
      stamp.inc
      current = @[]

  for line in md.splitLines:
    if line.startsWith("# topic:"):
      # Action purpose: both branches exist because the suffix is optional in
      # documents this has to read, not just in ones it writes.
      let rest = line[8 .. ^1].strip
      name =
        if rest.endsWith("[agent]"): rest[0 ..< rest.len - 7].strip
        else: rest
    elif line.startsWith("<!-- system:"):
      let body = line[12 .. ^1].strip
      if body.endsWith("-->"):
        msgs.add MdMessage(role: "system",
                           content: body[0 ..< body.len - 3].strip,
                           timestamp: stamp)
        stamp.inc
    elif line.startsWith("## "):
      flush()
      currentRole = line[3 .. ^1].strip.toLowerAscii
    elif currentRole.len > 0:
      current.add line
  flush()
  MdConversation(name: name, messages: msgs)

## Function purpose: an overload taking the JSON shape the database already
## speaks, so a caller with rows in hand builds no `MdMessage`s. A missing field
## takes its default rather than raising — an export is not the place to
## discover a null column.
proc toMarkdown*(name: string, rows: JsonNode): string =
  var msgs: seq[MdMessage]
  if rows.kind == JArray:
    for r in rows:
      msgs.add MdMessage(role: r{"role"}.getStr,
                         content: r{"content"}.getStr,
                         timestamp: r{"timestamp"}.getBiggestInt(0))
  toMarkdown(name, msgs)
