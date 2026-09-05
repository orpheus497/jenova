## Script function and purpose: read the document the user is editing in Neovim,
## so a chat turn can be about what is on screen rather than what was last
## written to disk.
##
## Five expressions and a subprocess call, not an RPC client: `nvim --server
## <sock> --remote-expr` already evaluates Vimscript in the running editor and
## prints the result, so msgpack framing would reimplement what ships. Anything
## Neovim can do beyond describing the open buffer is out of scope here.

import std/[os, osproc, posix, sets, strutils, times]
import ./paths

const
  ## Kept short because `sun_path` is about 104 bytes on FreeBSD and `--listen`
  ## fails outright above it, with an error that names neither length nor path.
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

## Function purpose: the environment the embedded editor is spawned with. Pure
## and parameterised rather than reading `config` itself, so the self-test can
## assert it with no terminal and no window.
##
## Action purpose: returns the whole environment, not just the additions. VTE's
## `envv` *replaces* the child's environment when non-nil, so returning only the
## `JENOVA_*` keys spawns an editor with no `PATH`, `HOME` or display — which
## surfaces as "nvim: not found" and reads as a missing dependency.
##
## `XDG_CONFIG_HOME` and `NVIM_APPNAME` are both needed: the appname alone sends
## Neovim to `~/.config/jvim`, a symlink the user would have to create by hand,
## whereas pointing the config home at the project root makes `<root>/jvim` the
## config directory with no setup step.
proc editorEnv*(p: Paths, host: string, port, llamaPort, embedPort: int,
                lanMode: bool): seq[string] =
  var seen = initHashSet[string]()
  var extra = @[
    ("JENOVA_ROOT", p.root),
    ("JENOVA_CONNECT_HOST", host),
    ("JENOVA_HOST", host),
    ("JENOVA_PORT", $port),
    ("JENOVA_LLAMA_PORT", $llamaPort),
    ("JENOVA_LLAMA_EMBED_PORT", $embedPort),
    ("JENOVA_LAN_MODE", if lanMode: "1" else: "0")]
  # Action purpose: a missing `jvim/` must leave the editor exactly as it was.
  # Aiming Neovim at a directory that does not exist yields a bare start screen
  # and no explanation of why.
  if dirExists(p.root / "jvim"):
    extra.add ("XDG_CONFIG_HOME", p.root)
    extra.add ("NVIM_APPNAME", "jvim")
  for (k, v) in extra:
    seen.incl k
    result.add k & "=" & v
  for k, v in envPairs():
    if k notin seen:
      result.add k & "=" & v

## Function purpose: named here rather than at the call sites, so the spawn and
## the reader agree by construction instead of by convention.
proc socketPath*(p: Paths): string =
  p.state / SocketName

## Function purpose: `complete` says the child closed its output — the only
## state in which the data read is the whole answer. It is false on the deadline
## AND on a `poll` failure, which the previous wording ("false only on the
## deadline") did not admit.
##
## Action purpose: the two are not distinguished in the result, and that is
## deliberate rather than an omission: the caller's response to both is the
## same — terminate the child and answer "no document" — so a second flag would
## be read by nobody. What DID need separating is `EINTR`, which is not a
## failure at all. A signal arriving during the wait made `poll` answer -1, and
## treating that as a deadline killed a perfectly healthy editor's query. It is
## retried against the remaining time instead, so only a real error ends the
## read early.
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
      if errno == EINTR: continue   # a signal, not a failure — the deadline stands
      return (result.data, false)
    if ready == 0:
      return (result.data, false)          # deadline expired with nothing to read
    let n = posix.read(fd.cint, addr buf[0], buf.len)
    if n <= 0:
      return (result.data, true)           # EOF: the child is done writing
    result.data.add buf[0 ..< n]

## Function purpose: an absent editor answers `("", false)` rather than raising,
## because having no editor open is the normal state.
proc query*(sock, expression: string): tuple[value: string, ok: bool] =
  if sock.len == 0 or not fileExists(sock):
    # Action purpose: a unix socket is not a regular file to `fileExists`
    # everywhere, so this rejects only the obvious never-started case; a stale
    # socket still has to fail through the call below.
    if not dirExists(sock.parentDir):
      return ("", false)
  try:
    let p = startProcess("nvim",
                         args = ["--server", sock, "--remote-expr", expression],
                         options = {poUsePath})
    defer: p.close()
    # Action purpose: read against the deadline rather than reading first and
    # timing the wait. `readAll` blocks until the child closes stdout, so a
    # wedged editor would hold the caller with the timeout never applying; and a
    # large buffer overflows the pipe, so waiting without reading deadlocks it.
    let (output, complete) = readUntilDeadline(p.outputHandle, QueryTimeoutMs)
    if not complete:
      p.terminate()
      discard p.waitForExit(200)
      return ("", false)
    if p.waitForExit(QueryTimeoutMs) != 0:
      # A non-zero exit here is the stale-socket path: the file is present but
      # no editor is behind it.
      return ("", false)
    (output.strip(leading = false), true)
  except OSError, IOError:
    # Neovim absent or not on PATH. Not a defect: the feature has nothing to
    # read and says so the same way an unopened editor does.
    ("", false)

## Function purpose: one expression instead of five, for callers that only need
## to decide whether to offer the feature at all.
proc alive*(sock: string): bool =
  query(sock, "1").ok

## Function purpose: one subprocess per field, because `--remote-expr`
## evaluates one expression and five short calls on an explicit user action do
## not justify a multiplexing scheme.
##
## Action purpose: a buffer with no path is not a document. Sending a scratch
## buffer as "the file the user is editing" is a lie the model reasons from.
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

## Function purpose: `&filetype` doubles as the Markdown fence tag, and is the
## same string the source viewer maps, so the window highlights what the model
## was shown.
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
