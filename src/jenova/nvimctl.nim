## Script function and purpose: read the document the USER is editing in Neovim,
## so a chat turn can be about what is on screen rather than what was last
## written to disk (G-18, ruling D-AT).
##
## ## Why this is not an RPC client
##
## The obvious build is a msgpack-RPC client against `nvim --listen`. **It is not
## needed.** `nvim --server <sock> --remote-expr <vimscript>` evaluates the
## expression in the running editor and prints the result on stdout — Neovim
## ships it, and writing msgpack framing would be re-implementing something that
## already exists (Directive 3). Driving an installed binary is also what the
## program already does for `wl-copy`, `git`, `fetch` and `xdg-open`.
##
## So this module is **five expressions and a subprocess call**, not a general
## binding. Anything Neovim can do beyond describing the open buffer is out of
## scope and would be dead code.
##
## ## Two things measured rather than assumed
##
## * **The socket path must be short.** `--listen` on a 108-character path fails
##   with `Failed to --listen: invalid argument` — FreeBSD's `sun_path` is about
##   104 bytes. `$HOME/Jenova/state/` is well inside that. This was found by
##   running it, and it is the kind of fault that otherwise surfaces six steps
##   later looking like something else.
## * **`getline(1,"$")` returns the buffer, not the file.** That is the whole
##   point: unsaved edits are what the USER is looking at.

import std/[os, osproc, posix, strutils, times]
import ./paths

const
  SocketName = "nvim.sock"
  ## Long enough that a slow editor still answers, short enough that a hung one
  ## does not stall the chat turn that asked.
  QueryTimeoutMs = 2000

type
  Document* = object
    ## `found` is false for every "there is nothing to read" case — no socket, no
    ## editor, no file open — because the caller's question is the same in all of
    ## them and a raised exception would make an ordinary state exceptional.
    found*: bool
    path*: string
    filetype*: string
    text*: string
    line*: int
    modified*: bool

## Function purpose: where the editor listens. Named here rather than at the call
## sites so the spawn (G-19) and the reader agree by construction.
proc socketPath*(p: Paths): string =
  p.state / SocketName

## Function purpose: drain a child's stdout until EOF or the deadline, whichever
## comes first. `complete` is false only on the deadline, so the caller can tell
## a slow editor from a finished one and kill the former.
proc readUntilDeadline(fd: FileHandle, timeoutMs: int):
    tuple[data: string, complete: bool] =
  var buf = newString(4096)
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while true:
    let remaining = int((deadline - epochTime()) * 1000.0)
    if remaining <= 0:
      return (result.data, false)
    var pfd = TPollfd(fd: fd.cint, events: POLLIN, revents: 0)
    let ready = poll(addr pfd, 1.Tnfds, remaining.cint)
    if ready < 0:
      return (result.data, false)
    if ready == 0:
      return (result.data, false)          # deadline expired with nothing to read
    let n = posix.read(fd.cint, addr buf[0], buf.len)
    if n <= 0:
      return (result.data, true)           # EOF: the child is done writing
    result.data.add buf[0 ..< n]

## Function purpose: evaluate one Vimscript expression in the running editor.
## Returns `("", false)` rather than raising when there is no editor: an absent
## socket is the normal state, not an error.
proc query*(sock, expression: string): tuple[value: string, ok: bool] =
  if sock.len == 0 or not fileExists(sock):
    # A unix socket is not a regular file to `fileExists` on every platform, so
    # this is a cheap reject for the obvious "never started" case only; a stale
    # socket still has to fail through the call below.
    if not dirExists(sock.parentDir):
      return ("", false)
  try:
    let p = startProcess("nvim",
                         args = ["--server", sock, "--remote-expr", expression],
                         options = {poUsePath})
    defer: p.close()
    # Action purpose: read against the deadline rather than reading first and
    # timing the wait afterwards. `readAll` blocks until the child closes its
    # stdout, so a wedged editor held the caller indefinitely and `QueryTimeoutMs`
    # never applied — and `getline(1,"$")` on a large buffer exceeds the pipe, so
    # simply waiting without reading would deadlock the child instead.
    let (output, complete) = readUntilDeadline(p.outputHandle, QueryTimeoutMs)
    if not complete:
      p.terminate()
      discard p.waitForExit(200)
      return ("", false)
    if p.waitForExit(QueryTimeoutMs) != 0:
      # `--remote-expr` prints `E247: Failed to connect` on stderr and exits
      # non-zero when the server is gone. That is the stale-socket path.
      return ("", false)
    (output.strip(leading = false), true)
  except OSError, IOError:
    # Neovim not installed, or not on PATH. Not a defect — the feature simply
    # has nothing to read.
    ("", false)

## Function purpose: is there an editor answering on this socket? Cheaper than
## `activeDocument` when the caller only needs to decide whether to offer the
## feature at all.
proc alive*(sock: string): bool =
  query(sock, "1").ok

## Function purpose: everything a turn needs to talk about the open file. One
## call per field because `--remote-expr` evaluates one expression, and five
## short subprocesses on an explicit user action is not a cost worth a
## multiplexing scheme.
##
## **An unnamed buffer is not a document.** A scratch buffer has no path, and
## sending its contents as "the file the user is editing" would be a lie the
## model then reasons from.
proc activeDocument*(sock: string): Document =
  let (path, ok) = query(sock, "expand(\"%:p\")")
  if not ok or path.len == 0:
    return Document(found: false)

  let (text, textOk) = query(sock, "join(getline(1,\"$\"),\"\\n\")")
  if not textOk:
    return Document(found: false)

  result = Document(found: true, path: path, text: text)
  result.filetype = query(sock, "&filetype").value
  result.modified = query(sock, "&modified").value == "1"
  result.line = try: parseInt(query(sock, "line(\".\")").value) except ValueError: 0

## Function purpose: the document as a fenced block for the prompt. `&filetype`
## is Neovim's own label and is close enough to a Markdown fence tag to use
## directly — the same string `sourceview.resolveLanguage` already maps, so the
## GUI highlights what the model was shown.
proc asPromptContext*(d: Document): string =
  if not d.found: return ""
  result = "The user is editing " & d.path
  if d.modified:
    result.add " (unsaved changes)"
  result.add ", cursor on line " & $d.line & ".\n\n"
  result.add "```" & d.filetype & "\n"
  result.add d.text
  if not d.text.endsWith("\n"): result.add "\n"
  result.add "```\n"
