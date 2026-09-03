## Script function and purpose: the assertions for `tests/test_nvimctl.sh`.
## `nvimctl` is a Nim module with no `jenova-core` subcommand behind it, so
## unlike the other five suites this one cannot be driven by curl alone — it
## needs a compiled caller. The shell script owns the editor's lifecycle; this
## file owns what is true about the answers.
##
## **This check is proven able to fail** (BRIEFING: a suite that reports PASS
## while asserting nothing has shipped here twice). `test_nvimctl.sh` edits the
## buffer without saving and re-runs, and the text/modified assertions go red.

import jenova/nvimctl
import std/[os, strutils]

var fails = 0

proc check(name: string, cond: bool, got = "") =
  if cond:
    echo "ok   - ", name
  else:
    inc fails
    echo "FAIL - ", name,
         (if got.len > 0: "  (got: " & got.replace("\n", "\\n") & ")" else: "")

if paramCount() < 2:
  echo "usage: nvimctl_check <socket> <expected-basename> [--expect-dirty]"
  quit 2

let
  sock = paramStr(1)
  wantName = paramStr(2)
  expectDirty = paramCount() >= 3 and paramStr(3) == "--expect-dirty"

# The absent-editor path first. It is the state the program is in almost all the
# time, so it must be ordinary rather than exceptional.
const NoSuch = "/tmp/jenova-no-such.sock"
let none = activeDocument(NoSuch)
check("absent socket -> found=false", not none.found)
check("absent socket -> empty prompt context", none.asPromptContext().len == 0)
check("absent socket -> alive() false", not alive(NoSuch))

check("live socket -> alive() true", alive(sock))

let d = activeDocument(sock)
check("live socket -> found", d.found)
check("path is absolute and names the file",
      d.path.startsWith("/") and d.path.endsWith(wantName), d.path)
check("filetype is reported", d.filetype.len > 0, d.filetype)
check("cursor line is a real line number", d.line >= 1, $d.line)

# The point of the whole module: the BUFFER, not the file on disk.
if expectDirty:
  check("unsaved edit is visible in the buffer",
        "EDITED IN BUFFER" in d.text, d.text)
  check("modified flag follows the buffer", d.modified)
else:
  check("clean buffer matches the file", "EDITED IN BUFFER" notin d.text, d.text)
  check("modified flag is clear", not d.modified)

let ctx = d.asPromptContext()
check("prompt context fences with the filetype", "```" & d.filetype in ctx, ctx)
check("prompt context carries the buffer text", d.text.splitLines[0] in ctx)
check("prompt context names the path", d.path in ctx)

echo (if fails == 0: "ALL PASS" else: $fails & " FAILED")
quit(if fails == 0: 0 else: 1)
