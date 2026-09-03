## Script function and purpose: a conversation as a markdown document, both ways
## (`PLANS.md` Step 13b).
##
## The window could already move conversations as JSON (G-32), which is the
## shape `api.exportAll` writes and the frozen Web UI reads. **What it could not
## do is the other format the Web UI ships** — `MarkdownService.toMarkdown` and
## `fromMarkdown`, a readable transcript a user can keep, diff or paste
## somewhere. That is a `data-services` parity gap and this closes it.
##
## **Ported by reading `jca_web/src/lib/services/markdown.service.ts`, not a
## summary of it** (the rule D-BU was written under). The format is therefore
## the Web UI's exactly, down to the `[agent]` suffix and the three ornamental
## parameter lines — a document written here opens there and the reverse.
##
## This module knows nothing about the database on purpose: it takes and returns
## plain values, so `convmd-selftest` can round-trip it with no fixture and the
## callers in `gui.nim` and `api.nim` do the row work.

import std/[algorithm, json, strutils]

type
  ## One turn, in the order the document holds them. `timestamp` is carried
  ## because the Web UI sorts on it before writing and synthesises an increasing
  ## one when reading — dropping it would silently reorder an imported
  ## transcript.
  MdMessage* = object
    role*: string
    content*: string
    timestamp*: int64

  MdConversation* = object
    name*: string
    messages*: seq[MdMessage]

const
  ## The Web UI writes these three under every topic and reads none of them
  ## back. They are reproduced rather than dropped because a document that omits
  ## them is not the same document, and parity here is the whole point.
  HeaderLines = "- model: jenova\n- temperature: 0.7\n- top_p: 0.9\n---\n\n"

## Function purpose: render a conversation as the Web UI's markdown document.
##
## A system turn becomes an HTML comment rather than a section, which is what
## keeps it out of the readable transcript while surviving a round trip — and
## its newlines are flattened to spaces because a comment that spans lines would
## not parse back.
proc toMarkdown*(name: string, messages: seq[MdMessage]): string =
  result = "# topic: " & name & " [agent]\n" & HeaderLines
  var sorted = messages
  sorted.sort(proc (a, b: MdMessage): int = cmp(a.timestamp, b.timestamp))
  for m in sorted:
    if m.role == "system":
      if m.content.strip.len > 0:
        result.add "<!-- system: " & m.content.replace("\n", " ") & " -->\n\n"
      continue
    # `assistant` is written as `jenova` and read back as `assistant`. That is
    # the Web UI's own naming in this format and not a rename introduced here.
    let role = if m.role == "assistant": "jenova" else: m.role
    result.add "## " & role & "\n\n"
    result.add m.content & "\n\n"

## Function purpose: parse a markdown document back into a conversation.
##
## Deliberately forgiving in the same places the Web UI is: a `# topic:` line
## that does not carry the `[agent]` suffix still yields the name, and anything
## before the first `## role` heading is discarded rather than treated as a
## turn. A document with no headings at all parses to a named conversation with
## no messages, which is a better answer than an error for a file a user wrote
## by hand.
proc fromMarkdown*(md: string): MdConversation =
  var
    name = ""
    msgs: seq[MdMessage]
    currentRole = ""
    current: seq[string]
    stamp = 0'i64

  # A template rather than a closure: a nested proc that appended to `result`
  # would capture it, which ARC rejects outright as a memory-safety violation.
  template flush() =
    if currentRole.len > 0 and current.len > 0:
      msgs.add MdMessage(
        role: (if currentRole == "jenova": "assistant" else: currentRole),
        content: current.join("\n").strip, timestamp: stamp)
      stamp.inc
      current = @[]

  for line in md.splitLines:
    if line.startsWith("# topic:"):
      # The suffix is stripped when it is there and the whole remainder taken
      # when it is not — both branches the Web UI has.
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

## Function purpose: the same document from the JSON shape `api.exportAll` and
## the database already speak, so a caller with rows in hand does not have to
## build `MdMessage`s itself. Rows missing a field are taken at their defaults
## rather than refused — an export is not the place to discover a null column.
proc toMarkdown*(name: string, rows: JsonNode): string =
  var msgs: seq[MdMessage]
  if rows.kind == JArray:
    for r in rows:
      msgs.add MdMessage(role: r{"role"}.getStr,
                         content: r{"content"}.getStr,
                         timestamp: r{"timestamp"}.getBiggestInt(0))
  toMarkdown(name, msgs)
