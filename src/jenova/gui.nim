## Script function and purpose: the native FreeBSD desktop application (N-S7) —
## a GTK4/libadwaita window built with owlkettle, replacing `jenova-ui/src/main.c`
## (C, GTK3, embedded LuaJIT, ncurses) and `lib/ui.lua` (Lua).
##
## It is two things at once, and that is deliberate: the **chat window**, which is
## new and is the actual product, and the **control surface**, which is not new
## and must be reproduced feature-for-feature under Directive 3. `lib/ui.lua`
## defines that surface exactly — start/stop/restart, model switching, the LAN
## toggle and its persisted state file, a status poll, and the web-UI opener —
## and every one of them is here.
##
## ## What got simpler by moving into the core
##
## `ui.lua:69` spawned `bin/jenova-ca proxy-serve` as a **child of the tray**.
## That is the mechanism of defect B-13: the client-facing port belonged to a
## different process from the supervisor, so "the daemon is up" and ":8080
## answers" could disagree, and a headless start had no `:8080` at all. Here the
## server, the supervisor and the window are one process and the tray owns
## nothing, so `proxy-serve` has no equivalent and needs none.
##
## Control actions therefore call `lifecycle` **in-process** rather than shelling
## out to a supervisor binary, and model switching calls `models.switchModel`
## rather than `bin/jenova-model-switch`.
##
## **Two things do still spawn a process, and this said "the GUI spawns no shell
## at all" while they did.** Neither is a supervisor and neither is a project
## script, which is the property that actually matters — but the sentence was
## wrong as written and a reader auditing it would have found it wrong:
##
## * `lanAddress` runs `route -n get default` and `ifconfig` through `sh -c` to
##   read the address LAN mode will publish. There is no libc call that answers
##   "the address on the default route" and reimplementing a routing-socket
##   query for a status line is not a trade worth making.
## * The "Open Web UI" action runs `xdg-open`, which is the documented way to
##   hand a URL to the desktop and is a declared dependency.
##
## Neither runs on the GTK thread. `lanAddress` did, which was a defect of its
## own (E-06): a wedged routing lookup blocked the window for as long as it
## took, holding the very frame that was meant to show the address. It is now a
## `lan_addr` job on the control worker answering with `umLanAddr`, which is
## `hwWorker`'s shape for `--list-devices` applied to a smaller probe. The one
## remaining synchronous call is at startup in `run`, before the window exists —
## there is no frame to block and nothing to deliver a message to yet.
##
## ## Why chat goes over HTTP to the local server
##
## The window could call `pipeline` directly, but it deliberately does not. Going
## through `127.0.0.1:$PORT` means the desktop client exercises **the same path
## the Web UI and any LAN client use** — intent detection, RAG, personas, tool
## stripping and the cache all apply identically, and a bug in that path cannot
## show up in one client and not the other. It also keeps inference isolated in
## `llama-server`, so a GUI fault cannot kill a generation (N-7).
##
## The socket is raw rather than `std/httpclient` for the reason `websearch.nim`
## shells to base `fetch(1)`: this project has spent seven stages removing
## dependencies, and a localhost request needs no TLS stack.

import std/[atomics, base64, json, net, os, oids, osproc, posix,
            streams,
            strutils, tables, times]
import owlkettle
import owlkettle/adw
import owlkettle/cairo
import ./theme
import ./canvas
import ./paths
import ./config
import ./lifecycle
import ./models
import ./tray
import ./db
import ./rag
import ./server
import ./api
import ./markdown
import ./fssync
import ./sourceview
import ./nvimctl
import ./vte
import ./pipeline
import ./workspace
import ./settings
import ./sha256
import ./hardware
import ./composer
import ./shortcuts
import ./convmd

type
  ## A-70. **`rSystem` is not decoration — its absence corrupted conversations.**
  ## System rows reach `messages`: `convmd.fromMarkdown` reads `<!-- system: … -->`
  ## back as a system turn and 13b's import writes that role through faithfully.
  ## With only two cases, `listMessages` coerced it to `rAssistant` on the way
  ## in, and because every other site reads *this enum* rather than the row, the
  ## damage spread from there: the outbound body sent the persona to the model as
  ## the assistant's own prior words on every later turn, and export wrote
  ## `## jenova` over `<!-- system: … -->`, **destroying the evidence in the file
  ## itself.** The string values are what `$` produces, so adding the case
  ## repairs the send, the export and the render together, and every row already
  ## stored keeps its correct `"system"` and heals at the next read.
  Role* = enum
    rUser = "user"
    rAssistant = "assistant"
    rSystem = "system"

  ## What `llama-server` reported about one turn. **These are its numbers, not
  ## ours** — the server measures prompt and generation separately and this
  ## carries both rather than a single elapsed time, because "slow" almost always
  ## means a long prompt re-read rather than slow generation, and one figure
  ## cannot tell those apart. Field names match the server's `result_timings`
  ## exactly so there is nothing to translate when reading either side.
  Timings* = object
    promptN*: int          ## prompt tokens *evaluated* — not the whole prompt,
                           ## which is this plus `cacheN` (A-5)
    promptMs*: float
    predictedN*: int       ## tokens generated
    predictedMs*: float
    cacheN*: int           ## prompt tokens reused from cache rather than re-read

  Message* = object
    role*: Role
    text*: string
    ## The `messages` row this came from. **Empty means it is not saved yet** —
    ## an assistant turn is a live buffer while it streams and only becomes a row
    ## when it completes. Every action but copy needs it: without an id there was
    ## nothing to edit, delete or update, which is why G-28 was a state-shape
    ## change before it was a set of buttons.
    id*: string
    ## The model's reasoning, kept apart from the answer (G-39). `llama-server`
    ## separates it into `reasoning_content` when the request asks it to; left
    ## inline it appears in the reply as a `<think>` block the user has to read
    ## past.
    thinking*: string
    ## Which model produced this turn, as the server named it. Per message rather
    ## than per conversation because switching models mid-chat is a menu item.
    model*: string
    timings*: Timings
    ## 12d-3: this reply came from the response cache rather than the model.
    ## **Deliberately not persisted.** It is a property of how *this* generation
    ## was answered, not of the turn — reloading the conversation tomorrow and
    ## seeing "cached" would be a claim about a request nobody made.
    cacheHit*: bool
    ## The turn this one follows (G-29). Empty for the first turn of a
    ## conversation. **Two messages sharing a parent are alternative versions of
    ## the same turn** — that is the whole of branching, and it is why editing or
    ## regenerating adds a row rather than overwriting one.
    parent*: string
    ## G-30. The turn's attachments, as the JSON text of the `messages.extra`
    ## column — **the frozen Web UI's own array shape** (D-Z), so a conversation
    ## moves between the two surfaces without conversion. Carried as text rather
    ## than a `JsonNode` because `Message` crosses a thread channel and a
    ## `JsonNode` is a `ref`.
    extra*: string

  ## G-30. A staged attachment is `pipeline.Attachment` — the type moved below
  ## the widget layer with the classifier that produces it, so both are
  ## assertable. This alias is kept because the widgets read better for it.
  PendingAttachment* = pipeline.Attachment

  BackendStatus* = enum
    ## Deliberately three states, not two. `ui.poll_status` collapsed everything
    ## that was not "is ready" into "inactive", which cannot distinguish a
    ## backend that is still loading a multi-gigabyte model from one that is
    ## dead — and the watchdog's 30 s interval exists precisely because that
    ## distinction matters (`lifecycle.nim:333`).
    bsDown = "stopped"
    bsStarting = "starting"
    bsUp = "ready"

# Two persistent workers: `stream` runs one generation at a time, `control` runs
# supervision. Separate so a stop is not queued behind a generation.
type
  StreamJob = object
    host: string
    port: int
    body: string

  ControlJob = object
    action: string
    lc: Lifecycle
    jcaHome: string
    port: int
    ## The reply an `index` job is about. Only the id travels: the worker reads
    ## the committed row itself, so nothing has to copy message text across the
    ## channel and the worker cannot index a turn that was never written (T-17).
    msgId: string
    ## S-1: which profile an `apply_profile` job should deploy.
    profileName: string
    ## 8a: which `.gguf` a `switch_path` job should make active.
    modelPath: string

  UiMsgKind = enum
    umToken, umDone, umError, umNotice, umStatus,
    ## G-39: reasoning arrives on its own channel because it is a separate field
    ## on the wire and belongs in a separate place on screen.
    umThinking,
    ## G-33: the server's own measurements, and the model it used.
    umTimings, umModel,
    ## G-33: the backend's context window and loaded model, from `/props`.
    umProps,
    ## S-1: the detected hardware and the profile ranking. Detection shells out
    ## to `sysctl` and `llama-server --list-devices`, so it runs on the control
    ## worker and arrives here.
    umHardware,
    ## 12d-3: this turn was answered from the response cache. Sent once, on the
    ## response head, before any token.
    umCacheHit,
    ## E-06: the address LAN mode publishes. Reading it shells out to `route`
    ## and `ifconfig`, so it is computed on the control worker and arrives here
    ## — the same shape `umHardware` uses for `--list-devices`.
    umLanAddr

  UiMsg = object
    kind: UiMsgKind
    text: string
    status: BackendStatus
    timings: Timings
    ctx: int
    ## G-31: `default_generation_settings.params` from `/props`, as JSON text.
    ## Carried as text and parsed on arrival so no `JsonNode` — a ref type —
    ## crosses the channel between threads.
    params: string
    ## G-30: does the loaded model accept images? From `/props.modalities`.
    vision: bool
    ## G-35: may the USER honestly be offered a Retry for this failure?
    retryable: bool
    ## S-1. Both are plain value types all the way down — objects, ints and
    ## `seq[string]` — so they deep-copy across the channel the way `timings`
    ## does. Nothing here is a `ref`.
    hw: hardware.Hardware
    scores: seq[hardware.Score]

var
  streamReq: Channel[StreamJob]
  ctlReq: Channel[ControlJob]
  uiChan: Channel[UiMsg]
  streamThread: Thread[void]
  ctlThread: Thread[void]
  # S-1. Hardware detection has its **own** worker and is not on `ctlReq`.
  # `llama-server --list-devices` initialises Vulkan and is unbounded, and the
  # control worker is a single serial queue that also services start, stop,
  # restart and the three-second poll — so a slow probe there stalls every one
  # of them and the window hangs on "starting". It did. (D-BQ.)
  hwReq: Channel[ControlJob]
  hwThread: Thread[void]
  pendingActions: seq[string] = @[]
  # G-30. The drop callback is a bare C function pointer and cannot carry a
  # closure, so it only ever appends here; the timer that already runs on the
  # GTK thread drains it with the app state in hand. Same shape as
  # `pendingActions`, and for the same reason — a GTK callback must not reach
  # into the widget tree.
  droppedPaths: seq[string] = @[]
  # Set the moment "quit" is drained. `closeWindow` destroys the window and with
  # it every GtkWidget in the tree, so anything that touches a widget afterwards
  # is touching freed memory — which is the SIGBUS in all ten cores of
  # 2026-08-31. Every timeout checks this and removes itself.
  quitting = false
# An empty host/action is the shutdown sentinel: each worker returns from its own
# loop so joinThread completes, rather than being unblocked by a channel close.
const QuitSentinel = ""

# G-33, the stop button. **Two variables and not one**, because a flag alone
# cannot stop a generation: the stream worker spends its life blocked inside
# `sock.recvLine`, and a flag it is not executing to check does nothing. So the
# socket's file descriptor is published here and `shutdown(2)` on it is what
# unblocks that read immediately — the flag then tells the loop the failure was
# asked for rather than a real error.
#
# An `int` fd is what crosses the thread boundary, never the `Socket`: `Socket`
# is a `ref`, and closing one from another thread while its owner is inside a
# read is a use-after-free. `shutdown` on a raw descriptor is safe, and is the
# same thing a cancelled HTTP client does anywhere.
var
  streamCancel: Atomic[bool]
  streamFd: Atomic[int]

# Action purpose: **-1, not the zero an `Atomic[int]` starts at.** Zero is a
# perfectly valid descriptor — it is stdin — so a Stop pressed before anything
# had ever streamed would have called `shutdown` on this process's own stdin.
streamFd.store(-1)

## Function purpose: stop the generation in flight. Safe to call when nothing is
## streaming — the fd is -1 and this does nothing.
##
## Action purpose: this runs on the **GTK thread**, directly from the button,
## rather than being posted to the control worker. `PLANS.md` 7a proposed the
## worker because a stop must never queue behind a generation — but an atomic
## store and one `shutdown` syscall neither block nor allocate, so doing it
## inline satisfies that requirement more completely than a queue does: there is
## no queue to be behind. (**D-BO**.)
proc cancelStream() =
  streamCancel.store(true)
  let fd = streamFd.load()
  if fd >= 0:
    discard posix.shutdown(SocketHandle(fd), posix.SHUT_RDWR)

proc streamOnce(job: StreamJob) =
  var sock: Socket
  # Sent once per generation rather than per chunk: the model name repeats on
  # every one of potentially thousands of chunks, and each send crosses a channel
  # to the GTK thread and forces a redraw.
  var lastModel = ""
  # Cleared here rather than by the canceller, so a stop pressed between two
  # generations cannot cancel the next one before it has sent a byte.
  streamCancel.store(false)
  try:
    sock = newSocket()
    sock.connect(job.host, Port(job.port))
    streamFd.store(sock.getFd().int)
    sock.send("POST /v1/chat/completions HTTP/1.1\r\n" &
              "Host: " & job.host & "\r\n" &
              "Content-Type: application/json\r\n" &
              "Connection: close\r\n" &
              "Content-Length: " & $job.body.len & "\r\n\r\n" & job.body)

    let statusLine = sock.recvLine(timeout = 120_000)
    let parts = statusLine.split(' ')
    let code = if parts.len > 1: parts[1] else: ""
    if code != "200":
      # Action purpose: **the body is read now, and it was thrown away before.**
      # llama-server puts the whole diagnosis in it — including, for a context
      # overflow, the prompt size and the context size — and dropping it left
      # "the server answered 400" as the entire report (G-35). Headers first,
      # then whatever body arrives before the connection closes.
      var body = ""
      try:
        while true:
          let h = sock.recvLine(timeout = 5_000)
          if h.len == 0 or h == "\r\n": break
        while true:
          let chunk = sock.recvLine(timeout = 5_000)
          if chunk.len == 0: break
          body.add chunk
      except CatchableError:
        discard
      let status = try: parseInt(code) except ValueError: 0
      let ce = pipeline.classifyError(status, body)
      uiChan.send(UiMsg(kind: umError, text: ce.message,
                        retryable: ce.retryable))
      return

    # Action purpose: 12d-3. **The headers were skipped, not read**, and that is
    # why a cache hit has always been invisible here. `server.handle` has sent
    # `X-Cache: HIT` on the hit path since the route was written, and this loop
    # discarded it along with everything else — so a cached turn was
    # indistinguishable from a live one and no screen run could tell the
    # mechanism worked at all. The Web UI's `ChatMessageStatistics` shows a
    # Cache Hit badge from this same header; this is the parity gap behind it.
    #
    # Only this one header is inspected. A general header table would cross the
    # channel per turn for no other reader.
    while true:
      let line = sock.recvLine(timeout = 120_000)
      if line.len == 0 or line == "\r\n": break
      if line.toLowerAscii.startsWith("x-cache:") and
         line.toLowerAscii.contains("hit"):
        uiChan.send(UiMsg(kind: umCacheHit))

    while true:
      # Checked before the read as well as relied on after it: if the stop lands
      # between two chunks the loop leaves here, and if it lands while blocked
      # inside `recvLine` the `shutdown` ends that read and the `except` below
      # sees the flag.
      if streamCancel.load(): break
      let line = sock.recvLine(timeout = 300_000)
      if line.len == 0: break
      if not line.startsWith("data:"): continue
      let payload = line[5 .. ^1].strip
      if payload == "[DONE]": break
      var node: JsonNode
      try:
        node = parseJson(payload)
      except CatchableError:
        continue
      # Action purpose: four things come out of one chunk and only the first was
      # ever read. `timings` and `model` are **top level**, not inside `choices` —
      # reading them from the delta finds nothing, which is the shape mistake
      # this comment exists to prevent.
      let delta = node{"choices"}{0}{"delta"}
      let tok = delta{"content"}.getStr("")
      let reasoning = delta{"reasoning_content"}.getStr("")
      if reasoning.len > 0:
        uiChan.send(UiMsg(kind: umThinking, text: reasoning))
      if tok.len > 0:
        uiChan.send(UiMsg(kind: umToken, text: tok))
      let model = node{"model"}.getStr("")
      if model.len > 0 and model != lastModel:
        lastModel = model
        uiChan.send(UiMsg(kind: umModel, text: model))
      let t = node{"timings"}
      if t != nil and t.kind == JObject:
        # `timings_per_token` makes the server send this on every chunk, so the
        # figures on screen are live rather than appearing only once the reply has
        # finished. The last one to arrive is the final, complete measurement.
        uiChan.send(UiMsg(kind: umTimings, timings: Timings(
          promptN: t{"prompt_n"}.getInt(0),
          promptMs: t{"prompt_ms"}.getFloat(0.0),
          predictedN: t{"predicted_n"}.getInt(0),
          predictedMs: t{"predicted_ms"}.getFloat(0.0),
          cacheN: t{"cache_n"}.getInt(0))))
  except CatchableError as e:
    # Action purpose: a cancelled read fails, and that failure is the stop
    # working. Reporting it would put "Connection reset by peer" on screen every
    # single time the USER pressed Stop (G-33).
    if not streamCancel.load():
      # A transport failure has no status line to read, so it is classified from
      # the exception instead — which is how a timeout comes to be reported as a
      # timeout rather than as whatever the socket layer called it (G-35).
      let ce = pipeline.classifyError(0, exceptionMsg = e.msg)
      uiChan.send(UiMsg(kind: umError, text: ce.message,
                        retryable: ce.retryable))
  finally:
    streamFd.store(-1)
    # `Socket` is a ref: closing it when newSocket() never ran is a SIGSEGV that
    # `except CatchableError` does not catch.
    if not sock.isNil:
      try: sock.close() except CatchableError: discard
    # Always sent, cancelled or not — `umDone` is what saves the reply with the
    # text it reached and the parent that makes it a sibling (D-BG). A stop must
    # keep the partial answer, not discard it.
    uiChan.send(UiMsg(kind: umDone))

proc streamWorker() {.thread.} =
  while true:
    let job = streamReq.recv()
    if job.host == QuitSentinel: break
    streamOnce(job)

## Function purpose: one short GET against the local server, returning the body.
## It exists for `/props`, which `routes.nim` already forwards to `llama-server`,
## so the window reads the backend's real configuration through the same front
## door as everything else rather than opening a second connection to :8081.
##
## The body is extracted between the first `{` and the last `}` rather than by
## honouring `Content-Length` or de-chunking: this reads one small JSON object
## from a local server, and reproducing an HTTP body parser to do it would be a
## worse version of `upstream.nim`.
proc httpGetLocal(host: string, port: int, path: string): string =
  var sock: Socket
  var raw = ""
  try:
    sock = newSocket()
    sock.connect(host, Port(port))
    sock.send("GET " & path & " HTTP/1.1\r\nHost: " & host &
              "\r\nConnection: close\r\n\r\n")
    let statusLine = sock.recvLine(timeout = 2000)
    if not statusLine.contains(" 200"): return ""
    while true:
      let line = sock.recvLine(timeout = 2000)
      if line.len == 0 or line == "\r\n": break
    while true:
      let line = sock.recvLine(timeout = 2000)
      if line.len == 0: break
      raw.add line
  except CatchableError:
    return ""
  finally:
    if not sock.isNil:
      try: sock.close() except CatchableError: discard
  let a = raw.find('{')
  let b = raw.rfind('}')
  if a < 0 or b <= a: "" else: raw[a .. b]

## Function purpose: the context window one conversation actually gets, and the
## model the backend has loaded, read from `llama-server`'s own `/props`.
##
## **This is not `CTX_SIZE` from the config.** `llama-server` gives each parallel
## slot `n_ctx / n_parallel`, and then caps that to the model's training context
## — so with `-c 32768 -np 2` a conversation has 16384, and less again if the
## model was trained shorter. Deriving it from the config would overstate the
## room remaining by the slot count, silently, and only on long conversations.
## Action purpose: the same response also carries the server's **own** sampling
## values, under `default_generation_settings.params`. The settings dialog shows
## them as each field's placeholder and marks a field "Custom" when the stored
## value differs (G-31), which is what stops someone chasing a parameter they
## never set. They are read from the call that was already being made rather than
## from a second one — this proc is a socket round trip and the reason it runs on
## the control thread at all.
proc fetchProps(host: string, port: int):
    tuple[ctx: int, model: string, params: string, vision: bool] =
  let body = httpGetLocal(host, port, "/props")
  if body.len == 0: return (0, "", "", false)
  try:
    let n = parseJson(body)
    let gen = n{"default_generation_settings"}
    let params = gen{"params"}
    # G-30: `modalities.vision` is the server's own answer to "can this model
    # look at a picture", set from the loaded projector. It is what decides
    # whether attaching an image is offered or refused with a reason.
    (gen{"n_ctx"}.getInt(0),
     n{"model_alias"}.getStr(""),
     (if params != nil and params.kind == JObject: $params else: ""),
     n{"modalities"}{"vision"}.getBool(false))
  except CatchableError:
    (0, "", "", false)


## Function purpose: the LAN-mode flag, persisted exactly where `ui.lua:12-15`
## put it so a running deployment's state is not orphaned by the port.
proc lanStateFile(p: Paths): string =
  p.state / "lan_mode"

proc isLanEnabled(p: Paths): bool =
  try: readFile(lanStateFile(p)).strip == "1"
  except CatchableError: false

## Function purpose: persist the LAN flag, and **say whether it stuck** (E-03).
##
## Action purpose: this discarded the failure, and the toggle then lied. The
## state file is what the *next* start binds from — nothing in this process
## re-reads it to decide a bind — so a write that failed on a read-only state
## directory or a full disk left the window showing "LAN enabled", the tray
## item flipped, the address in the title bar, and the flag on disk still off.
## The user is told the thing they asked for happened; it did not, and they find
## out at the restart the notice told them to perform.
##
## A `bool` rather than a raise: the caller is a menu action on the GTK thread
## and has a notice line to put this in, which is a better answer than an
## exception crossing the timeout callback.
proc setLanState(p: Paths, enabled: bool): bool =
  try:
    createDir(p.state)
    writeFile(lanStateFile(p), if enabled: "1" else: "0")
    true
  except CatchableError:
    false

## Function purpose: run a base-system command and return its first non-empty
## line. Used for the LAN address and for handing a URL to the browser — the two
## things with no library equivalent.
##
## `route(8)`, `ifconfig(8)` and `xdg-open(1)` are invoked with an argument
## vector, never a shell string. `ui.lua` built shell commands and needed a
## `shell_quote` helper to stay safe; passing argv removes the question.
## `ctlWorker` is serial and also carries backend start and stop, so a child
## that never exits would wedge backend control, not just the LAN readout.
##
## The wait comes before the read for that reason: `readAll` blocks until the
## pipe reaches EOF, which a hung child never gives. Waiting first bounds it,
## and reading after the child is gone cannot block.
##
## That ordering is only safe while the output stays under one pipe buffer —
## `osproc.waitForExit` warns that a child without `poParentStreams` can fill
## its output buffer and deadlock. Both callers here produce a single short
## line, so the child always completes its write and exits without a reader.
proc runCapture(cmd: string, args: openArray[string],
                timeoutMs = 5000): string =
  try:
    let p = startProcess(cmd, args = args, options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    if p.waitForExit(timeoutMs) < 0:
      p.kill()
      discard p.waitForExit()
    let outp = p.outputStream.readAll()
    for line in outp.splitLines():
      if line.strip.len > 0:
        return line.strip
    ""
  except CatchableError:
    ""

## Function purpose: the address shown when LAN mode is on, reproducing
## `ui.get_status_info` (`ui.lua:186-219`) — the default-route interface's
## address, falling back to the first non-loopback address.
##
## The original ran `ip route get`, an iproute2 command that does not exist on
proc lanAddress(): string =
  let iface = runCapture("sh", ["-c",
    "route -n get default 2>/dev/null | awk '/interface:/{print $2}'"])
  if iface.len > 0:
    let addr4 = runCapture("sh", ["-c",
      "ifconfig " & quoteShell(iface) & " 2>/dev/null | awk '/inet /{print $2; exit}'"])
    if addr4.len > 0:
      return addr4
  runCapture("sh", ["-c",
    "ifconfig 2>/dev/null | awk '/inet / && !/127\\.0\\.0\\.1/ {print $2; exit}'"])

type
  ## G-21. `kind` is the table name `api.restoreEntity` takes; `label` is what
  ## the row shows, which differs per table — a note has a title, a message has
  ## only its text.
  TrashItem = tuple[kind, id, label, detail: string]

  ConvItem = tuple[id, name, folderId, projectId, workspaceId: string]
  NodeItem = tuple[id, parent, name: string]
  ## A note or a file asset. Structurally identical to `ConvItem` — both carry
  ## the same three parent ids — so one set of tree helpers places all three.
  LeafItem = tuple[id, name, folderId, projectId, workspaceId: string]

proc listWorkspaces(): seq[NodeItem] =
  for r in db.query("SELECT id, name FROM workspaces WHERE is_deleted=0 ORDER BY name"):
    if r.len >= 2: result.add (id: r[0], parent: "", name: r[1])

proc listProjects(): seq[NodeItem] =
  for r in db.query("SELECT id, workspaceId, name FROM projects WHERE is_deleted=0 ORDER BY name"):
    if r.len >= 3: result.add (id: r[0], parent: r[1], name: r[2])

proc listFolders(): seq[NodeItem] =
  for r in db.query("SELECT id, projectId, name FROM folders WHERE is_deleted=0 ORDER BY name"):
    if r.len >= 3: result.add (id: r[0], parent: r[1], name: r[2])

## Function purpose: the sidebar's conversation list. Ordered by `lastModified`
## descending, which is what `ChatSidebar` shows and the order a user expects —
## the thing they were last working on is at the top, not the thing they created
## first.
proc listConversations(): seq[ConvItem] =
  for r in db.query("SELECT id, name, folderId, projectId, workspaceId " &
                    "FROM conversations WHERE is_deleted=0 " &
                    "ORDER BY lastModified DESC"):
    if r.len >= 5:
      result.add (id: r[0], name: r[1], folderId: r[2],
                  projectId: r[3], workspaceId: r[4])

## Notes and file assets hang off the same three parent ids as a conversation, so
## the tree can place them beside one. Notes are ordered by recency like the
## conversation list; assets by name, which is what `FilesView` shows.
proc listNotes(): seq[LeafItem] =
  for r in db.query("SELECT id, title, folderId, projectId, workspaceId " &
                    "FROM notes WHERE is_deleted=0 ORDER BY updatedAt DESC"):
    if r.len >= 5:
      result.add (id: r[0], name: r[1], folderId: r[2],
                  projectId: r[3], workspaceId: r[4])

proc listFiles(): seq[LeafItem] =
  for r in db.query("SELECT id, name, folderId, projectId, workspaceId " &
                    "FROM fileAssets WHERE is_deleted=0 ORDER BY name"):
    if r.len >= 5:
      result.add (id: r[0], name: r[1], folderId: r[2],
                  projectId: r[3], workspaceId: r[4])

## Action purpose: `isFocusNote` is read here and not left to the context builder
## because the window has to *show* the flag to let the user change it (G-50).
## The truth test is `workspace.isFocusValue` rather than a comparison written
## here: the same cell decides whether `workspace.contextFor` treats the note as
## a rule, and a second notion of "set" would make the toggle disagree with the
## behaviour it controls.
proc loadNote(id: string): tuple[found: bool, title, content: string, focus: bool] =
  for r in db.query("SELECT title, content, isFocusNote FROM notes WHERE id=?", [id]):
    if r.len >= 3: return (true, r[0], r[1], workspace.isFocusValue(r[2]))
  (false, "", "", false)

## Function purpose: the columns a file-asset rename has to carry forward.
## `api.writeRow` is `INSERT OR REPLACE` over **every** column, so any field the
## caller omits is written empty — a rename that sent only the name blanked the
## content, and `fssync.syncFileAsset` then wrote a zero-byte file and trashed
## the original (T-13). Read back as strings: `api.f` stringifies either way.
proc loadFileAsset(id: string): tuple[found: bool, content, size, kind, uploadDate: string] =
  for r in db.query(
      "SELECT content, size, type, uploadDate FROM fileAssets WHERE id=?", [id]):
    if r.len >= 4: return (true, r[0], r[1], r[2], r[3])
  (false, "", "", "", "")

proc newConversation(): string =
  result = $genOid()
  db.exec("INSERT INTO conversations (id, name, lastModified, is_deleted) VALUES (?, ?, ?, 0)",
          [result, "Chat " & now().format("yyyy-MM-dd HH:mm"), $toUnix(getTime())])

proc latestConversation(): string =
  let rows = db.query("SELECT id FROM conversations WHERE is_deleted=0 " &
                      "ORDER BY lastModified DESC LIMIT 1")
  if rows.len > 0 and rows[0].len > 0: rows[0][0] else: ""

## Action purpose: `timings` is a TEXT column, so the measurements are stored as
## JSON in it rather than as five new columns. The schema already had the column
## and `jca_web` is frozen against this table (D-Z), so widening it is neither
## necessary nor free. The keys are the server's own names.
proc timingsToJson(t: Timings): string =
  if t.predictedN == 0 and t.promptN == 0: return ""
  $(%*{"prompt_n": t.promptN, "prompt_ms": t.promptMs,
       "predicted_n": t.predictedN, "predicted_ms": t.predictedMs,
       "cache_n": t.cacheN})

proc timingsFromJson(s: string): Timings =
  if s.len == 0: return
  try:
    let n = parseJson(s)
    Timings(promptN: n{"prompt_n"}.getInt(0), promptMs: n{"prompt_ms"}.getFloat(0.0),
            predictedN: n{"predicted_n"}.getInt(0),
            predictedMs: n{"predicted_ms"}.getFloat(0.0),
            cacheN: n{"cache_n"}.getInt(0))
  except CatchableError:
    Timings()

## Returns the id of the row it wrote, empty if it wrote nothing. The caller
## keeps it on the in-memory message: a turn with no id cannot be edited or
## deleted, and re-reading the row back to find one would race the next insert.
##
## `thinking`, `model` and `timings` are columns the schema has always carried and
## **nothing has ever written** (G-33, G-39). They are filled here rather than by a
## later UPDATE so a reply is one row written once.
proc saveMessage(convId: string, role: Role, text: string,
                 thinking = "", model = "", timings = Timings(),
                 parent = "", extra = ""): string =
  # Action purpose: **a turn with no visible text but with reasoning is still a
  # turn.** This refused anything with an empty `content`, which was harmless
  # while the transcript was a flat list and is not now: `umDone` read the empty
  # id back as "nothing happened", so the reply stayed on screen, stayed out of
  # the tree, and left the next message attaching to a stale parent. A reasoning
  # model whose whole reply is reasoning hits this every time.
  if convId.len == 0 or (text.len == 0 and thinking.len == 0): return ""
  result = $genOid()
  db.exec("INSERT INTO messages (id, convId, type, role, timestamp, content, " &
          "thinking, model, timings, parent, extra, is_deleted) " &
          "VALUES (?, ?, 'message', ?, ?, ?, ?, ?, ?, ?, ?, 0)",
          [result, convId, $role, $toUnix(getTime()), text,
           thinking, model, timingsToJson(timings), parent, extra])
  db.exec("UPDATE conversations SET lastModified=? WHERE id=?",
          [$toUnix(getTime()), convId])

## **Every** message in the conversation, ordered oldest first — the tree, not
## the transcript. `ORDER BY` is what makes the ordering meaningful to
## `api.siblingsIn` and `api.deepestFrom`, which read "newest" as "last", so it
## is part of the contract rather than a tidy default.
proc loadMessages(convId: string): seq[Message] =
  if convId.len == 0: return
  for r in db.query("SELECT role, content, id, thinking, model, timings, " &
                    "parent, extra FROM messages WHERE convId=? AND " &
                    "is_deleted=0 ORDER BY timestamp ASC, rowid ASC", convId):
    if r.len < 8: continue
    # A-70: the lossy read. Anything that was not "user" became `rAssistant`,
    # so a stored "system" row lost its identity here and nowhere else. The
    # decision itself is `convmd.canonicalRole` so it can be asserted — this
    # file links into no test binary — and this is only the mapping onto the
    # enum, which cannot be got wrong without failing to compile.
    result.add Message(role: (case convmd.canonicalRole(r[0])
                              of "user": rUser
                              of "system": rSystem
                              else: rAssistant),
                       text: r[1], id: r[2], thinking: r[3], model: r[4],
                       timings: timingsFromJson(r[5]), parent: r[6],
                       extra: r[7])

## The turn the reader is currently on, persisted so reopening a conversation
## returns to the branch they were reading rather than to whichever version
## happens to be newest. `conversations.currNode` has always existed for this.
proc loadLeaf(convId: string): string =
  if convId.len == 0: return ""
  let rows = db.query("SELECT currNode FROM conversations WHERE id=?", convId)
  if rows.len > 0 and rows[0].len > 0: rows[0][0] else: ""

proc saveLeaf(convId, leaf: string) =
  if convId.len == 0: return
  db.exec("UPDATE conversations SET currNode=? WHERE id=?", [leaf, convId])

## Function purpose: the (id, parent) pairs `api`'s tree walk works over, in the
## order it expects — oldest first, so "newest" means "last".
proc edgesOf(all: seq[Message]): seq[api.MsgEdge] =
  for m in all: result.add (m.id, m.parent)

proc trayMenu(lanEnabled: bool): seq[TrayItem] =
  @[
    TrayItem(kind: tiAction, id: 1, label: "Open Web UI", action: "web"),
    TrayItem(kind: tiSeparator, id: 2),
    TrayItem(kind: tiAction, id: 3, label: "Start backend", action: "start"),
    TrayItem(kind: tiAction, id: 4, label: "Stop backend", action: "stop"),
    TrayItem(kind: tiAction, id: 5, label: "Restart backend", action: "restart"),
    TrayItem(kind: tiSeparator, id: 6),
    TrayItem(kind: tiAction, id: 7, label: "Switch to instruct model",
             action: "switch_instruct"),
    TrayItem(kind: tiAction, id: 8, label: "Switch to thinking model",
             action: "switch_thinking"),
    TrayItem(kind: tiSeparator, id: 9),
    TrayItem(kind: tiAction, id: 10,
             label: (if lanEnabled: "Disable LAN access" else: "Enable LAN access"),
             action: "toggle_lan"),
    TrayItem(kind: tiSeparator, id: 11),
    TrayItem(kind: tiAction, id: 12, label: "Quit", action: "quit"),
  ]

## Function purpose: the reason the backend gave for exiting, so the notice says
## something actionable instead of "it exited".
##
## Action purpose: **the last error line, searched from the end.** The log is
## hundreds of kilobytes and grows across runs, so only the tail is read; a
## failed model load puts its diagnosis in the final few lines and the
## interesting one is the last line marked `E`. Falls back to naming the file,
## which is still better than silence.
proc lastBackendError(logPath: string): string =
  const Tail = 8192
  var text = ""
  try:
    let f = open(logPath)
    defer: f.close()
    let size = f.getFileSize()
    if size > Tail: f.setFilePos(size - Tail)
    text = f.readAll()
  except CatchableError:
    return "see " & logPath
  let lines = text.splitLines
  var fallback = ""
  for i in countdown(lines.high, 0):
    let t = lines[i].strip
    if t.len == 0: continue
    # llama.cpp's own severity marker: `0.04.076.241 E llama_model_load: …`.
    # The vulkan allocator prints without one, so that prefix is matched too.
    if not (t.contains(" E ") or t.startsWith("ggml_vulkan:")): continue
    # Action purpose: **the last error line is the least useful one.** llama.cpp
    # ends a failed load with "exiting due to model loading error", which says
    # only that it failed; the line that says *why* — the allocator running out
    # of device memory, say — is a few lines above it. So the epilogue lines are
    # kept as a fallback and the search continues past them for a real cause.
    if t.contains("exiting due to") or t.contains("cleaning up before exit") or
       t.contains("failed to load model") or t.contains("common_init_"):
      if fallback.len == 0: fallback = t
      continue
    return (if t.len > 180: t[0 ..< 180] & "…" else: t) & "  (" & logPath & ")"
  if fallback.len > 0:
    return (if fallback.len > 180: fallback[0 ..< 180] & "…" else: fallback) &
           "  (" & logPath & ")"
  "see " & logPath

proc ctlWorker() {.thread.} =
  # Whether `/props` has been read for the backend currently up. Cleared when it
  # goes down, so a restart or a model switch re-reads it rather than reporting
  # the previous model's context window (G-33).
  var propsRead = false
  # Whether existing history has been put into the retrieval index in this
  # process (T-17). Not cleared on a restart: the backfill is incremental and
  # what it already indexed stays indexed.
  var backfilled = false
  var embedConfigured = false
  # Whether this start's failure has already been reported. Reset by `start` and
  # `restart` so a retry is announced again, and by the backend coming up.
  var exitAnnounced = false
  while true:
    let j = ctlReq.recv()
    if j.action == QuitSentinel: break
    if j.action in ["stop", "restart"]: propsRead = false
    # A new attempt is a new chance to fail, and its failure must be announced.
    if j.action in ["start", "restart"]: exitAnnounced = false
    # Action purpose: `rag`'s embedding address is a threadvar, so it is set on
    # whichever thread configured it — the main one — and this worker would
    # otherwise fall back to the default port and silently index without vectors
    # on a host that moved the embedding server. Once per thread, not per job:
    # the address cannot change for the life of the process, and the poll runs
    # every three seconds for as long as the window is open.
    if not embedConfigured and j.action in ["index", "poll"]:
      embedConfigured = true
      rag.configureEmbed("127.0.0.1", j.lc.embedPort)
    case j.action
    of "start":
      let (l, _) = j.lc.startAll()
      uiChan.send(UiMsg(kind: umNotice, text:
        if l == -1: "port in use; backend not started" else: "starting backend (pid " & $l & ")"))
      uiChan.send(UiMsg(kind: umStatus, status: bsStarting))
    of "stop":
      discard j.lc.stopAll()
      uiChan.send(UiMsg(kind: umNotice, text: "backend stopped"))
      uiChan.send(UiMsg(kind: umStatus, status: bsDown))
    of "restart":
      discard j.lc.stopAll()
      let (l, _) = j.lc.startAll()
      uiChan.send(UiMsg(kind: umNotice, text: "restarting backend (pid " & $l & ")"))
      uiChan.send(UiMsg(kind: umStatus, status: bsStarting))
    of "switch_instruct", "switch_thinking":
      let target = if j.action == "switch_instruct": "instruct" else: "thinking"
      try:
        let r = models.switchModel(j.jcaHome, target)
        uiChan.send(UiMsg(kind: umNotice, text: r.message & " - restart to load it"))
      except CatchableError as e:
        uiChan.send(UiMsg(kind: umNotice, text: "switch failed: " & e.msg))
    of "switch_path":
      # 8a. The selector's own switch. It goes to the worker rather than running
      # inline for the reason the two named ones do — it renames files under
      # `models/agent`, and the GTK thread is drawing while it happens.
      try:
        let r = models.switchToPath(j.jcaHome, j.modelPath)
        uiChan.send(UiMsg(kind: umNotice,
                          text: r.message & " - restart to load it"))
      except CatchableError as e:
        uiChan.send(UiMsg(kind: umNotice, text: "switch failed: " & e.msg))
    of "web":
      discard runCapture("xdg-open", ["http://127.0.0.1:" & $j.port])
    of "lan_addr":
      # E-06. **This is three `sh -c` invocations and it used to run on the GTK
      # thread**, straight from the LAN toggle and from the three-second poll
      # that notices the flag changed underneath it. `route -n get default` is
      # usually instant and is not always: on a host whose routing lookup is
      # slow or wedged, the window froze for as long as it took, holding the
      # frame that was meant to show the address.
      #
      # It goes here rather than to `hwWorker` because it is short and bounded,
      # which is exactly what that worker exists to keep off this queue.
      uiChan.send(UiMsg(kind: umLanAddr, text: lanAddress()))
    of "poll":
      let up = j.lc.healthy(beLlama, timeoutMs = 300)
      # Action purpose: **`running`, not `pid > 0`.** `state` already resolves
      # liveness with `kill(pid, 0)`; this read only the pid, and a pidfile
      # outlives the process it names. So a backend that started and then
      # exited — an out-of-memory model load takes about four seconds — left
      # `pid > 0` true forever and the window sat on "starting" with nothing
      # ever contradicting it. That is the whole defect.
      let ps = j.lc.state(beLlama)
      uiChan.send(UiMsg(kind: umStatus, status:
        if up: bsUp elif ps.running: bsStarting else: bsDown))

      # Action purpose: a dead process whose pidfile survives is the *only*
      # evidence the backend was asked to run and failed — `pid > 0` with
      # `running` false cannot happen any other way, because nothing writes a
      # pidfile without forking. Announced **once** per start, or the notice
      # line would rewrite itself every three seconds.
      if not up and ps.pid > 0 and not ps.running:
        if not exitAnnounced:
          exitAnnounced = true
          uiChan.send(UiMsg(kind: umNotice, text:
            "the backend started and then exited — " &
            lastBackendError(j.lc.logFileFor(beLlama))))
      elif up:
        exitAnnounced = false
      # Read once per backend lifetime, on this thread: `/props` is a socket
      # round trip and the poll already runs here every few seconds, so it costs
      # nothing extra and never touches the GTK loop.
      if up and not propsRead:
        propsRead = true
        let (ctx, model, params, vision) = fetchProps("127.0.0.1", j.port)
        if ctx > 0 or model.len > 0 or params.len > 0:
          uiChan.send(UiMsg(kind: umProps, ctx: ctx, text: model,
                            params: params, vision: vision))
      elif not up:
        propsRead = false
      # Action purpose: put existing history into the retrieval index once, and
      # **not until the embedding server answers** (T-17). Running it at startup
      # would index every past message during the seconds the embedder is still
      # loading, storing chunks with no vector and leaving the whole of history
      # keyword-only. The poll already runs here every three seconds, so waiting
      # costs nothing and needs no timer of its own. `backfillChats` is
      # incremental, so a later start does no work twice.
      if not backfilled and j.lc.healthy(beEmbed, timeoutMs = 300):
        backfilled = true
        let n = rag.backfillChats()
        # W-06: and the notes and files, which were never indexed at all. Same
        # gate, same reason — both need the embedder up or they store chunks
        # with no vector and end up keyword-only for ever.
        let w = rag.backfillWorkspace()
        if n > 0 or w > 0:
          var parts: seq[string]
          if n > 0: parts.add $n & " past messages"
          if w > 0: parts.add $w & " notes and files"
          uiChan.send(UiMsg(kind: umNotice,
                            text: "indexed " & parts.join(" and ") & " for recall"))
    of "index":
      # Blocking is the point of doing it here: embedding a turn is an HTTP
      # round trip to the embedding server, and on the GTK thread that is a
      # frozen transcript. Failure is silent by design — retrieval degrades, the
      # conversation does not.
      discard rag.indexExchange(j.msgId)
    else: discard

## Function purpose: hardware detection and profile apply, on a worker of their
## own (S-1, **D-BQ**).
##
## Action purpose: **this is not on `ctlReq`, and that is the whole point.**
## `hardware.detect` shells `llama-server --list-devices`, which initialises
## Vulkan and is unbounded. The control worker is one serial queue that also
## services start, stop, restart and the three-second poll, so a slow probe
## there leaves every one of them unprocessed — the window sits on "starting"
## and the buttons do nothing. That is exactly what shipped at 16:19 and it is
## why this thread exists. A probe that hangs now costs the Hardware screen and
## nothing else.
proc hwWorker() {.thread.} =
  while true:
    let j = hwReq.recv()
    if j.action == QuitSentinel: break
    try:
      let profs = hardware.listProfiles(j.lc.paths.root)
      if j.action == "apply_profile":
        let (found, prof) = hardware.findByName(profs, j.profileName)
        if not found:
          uiChan.send(UiMsg(kind: umNotice,
                            text: "no such profile: " & j.profileName))
          continue
        let r = hardware.applyProfile(prof, j.lc.paths.jcaHome)
        uiChan.send(UiMsg(kind: umNotice, text: r.msg))
      # Both actions end by reporting the current state, so applying a profile
      # shows it as current without the USER reopening the screen.
      let h = hardware.detect(j.lc.paths.llamaServer, j.lc.paths.llamaLibDir)
      uiChan.send(UiMsg(kind: umHardware, hw: h,
                        scores: hardware.scoreAll(profs, h),
                        text: hardware.currentProfile(profs,
                                j.lc.paths.jcaHome).name))
    except CatchableError as e:
      uiChan.send(UiMsg(kind: umNotice,
                        text: "hardware detection failed: " & e.msg))

viewable App:
  ## Application state. `paths` and `cfg` are resolved once at startup rather
  ## than per action, so a mid-session config edit cannot make two actions
  ## disagree about where the runtime lives.
  p: Paths
  cfg: Config
  lc: Lifecycle
  ## **`messages` is the active path, `allMessages` is the tree** (G-29). A
  ## conversation is not a list: editing a turn or regenerating a reply adds an
  ## alternative version beside the old one, and what is on screen is one route
  ## from the root down to `leaf`. Every widget reads `messages`; every branch
  ## operation reads `allMessages`.
  messages: seq[Message]
  allMessages: seq[Message]
  ## The (id, parent) pairs of `allMessages`, cached rather than rebuilt where
  ## they are used. The sibling counter needs them **once per message per
  ## redraw**, and with `timings_per_token` the transcript redraws several times
  ## a second — so building them there allocates a fresh sequence per message per
  ## frame. That is defect B-17's shape with a tree walk behind it instead of a
  ## fork, which is the same reason `convs` and `lanAddr` are cached.
  edges: seq[api.MsgEdge]
  ## The turn at the end of the visible path, persisted as `conversations.currNode`.
  leaf: string
  ## Step 13a. **A plain string, and that is the point.** The composer is a
  ## multi-line `DraftView` now, but it reports every keystroke back through an
  ## owlkettle event exactly as the `Entry` did — so the draft stays ordinary
  ## state, `view` re-runs when it changes, and the placeholder is a state test
  ## rather than a question asked of GTK.
  ##
  ## The first version held it in a `TextBuffer` instead. Nothing then re-ran
  ## `view` on a keystroke, and the placeholder never went away.
  draft: string
  status: BackendStatus
  lanEnabled: bool
  ## Cached, not computed per redraw: resolving it forks `route` and `ifconfig`,
  ## and `view` runs on every token of a stream. `ui.poll_status` forking
  ## `jenova-ca status` every 3 s in the tray and every 1 s in the TUI is defect
  ## B-17, and recomputing this in `view` would be a worse version of it.
  lanAddr: string
  convId: string
  streaming: bool
  notice: string
  ## G-35: whether the notice currently on screen is a failure worth offering a
  ## Retry for. Set only by `umError`, and cleared by every other writer of
  ## `notice`, so a stale Retry cannot outlive the error that earned it.
  noticeRetryable: bool
  ## G-30: does the loaded model accept images? Read once per backend lifetime
  ## from `/props.modalities.vision`, and what decides whether an image can be
  ## attached at all.
  serverVision: bool
  ## G-30: the attachment being previewed full-size. **The whole attachment and
  ## not just its `data:` URL** (G-40) — the preview needs the identity key to
  ## look its decoded pixbuf up, and carrying only the payload was what forced
  ## the old code to re-hash it on every frame.
  previewAtt: PendingAttachment
  ## G-30. Attachments staged on the composer, not yet sent. Cleared when the
  ## turn they belong to is posted. Each is a `messages.extra` element in the
  ## Web UI's own shape (D-Z), kept as parsed fields here only so the strip can
  ## draw a name and a size without re-parsing on every redraw.
  pending: seq[PendingAttachment]
  ## G-33. `ctxSize` is the context **one conversation** gets — `llama-server`'s
  ## per-slot figure from `/props`, not `CTX_SIZE` from the config, which is the
  ## total shared across parallel slots. Zero until the backend has been up long
  ## enough to answer, and the context readout is hidden rather than guessed
  ## while it is.
  ctxSize: int
  serverModel: string
  ## Sidebar state. `convs` is cached rather than queried in `view` for the same
  ## reason `lanAddr` is: `view` runs on every token of a stream and on every
  ## canvas frame, and a SELECT per frame would be defect B-17 with a database
  ## behind it instead of a fork.
  convs: seq[ConvItem]
  workspaces: seq[NodeItem]
  projects: seq[NodeItem]
  folders: seq[NodeItem]
  notes: seq[LeafItem]
  files: seq[LeafItem]
  ## The note open in the main area, or empty for the transcript. The buffer is
  ## built once and refilled per note: a `TextView` owns a `TextBuffer`, not a
  ## string, so it cannot be driven from `view` the way an `Entry` can.
  openNote: string
  noteTitle: string
  ## Whether the open note is a FOCUS note — a rule that escapes its own level
  ## and applies across the whole workspace tree (G-50, D-BU). Held as state
  ## rather than read out of the row per frame, because the toggle has to show an
  ## edit that is not saved yet, the same way the title `Entry` does.
  noteFocus: bool
  ## 8c-3. A note reads as rendered markdown and is edited as plain text, which
  ## is the Web UI's own split and is forced anyway: a `TextView` shows the
  ## characters it holds and cannot render them.
  noteEditing: bool
  ## 8c-4. The row as it was loaded, so Cancel can restore it and Close can tell
  ## whether anything would be lost. Kept beside the live values rather than
  ## re-read on demand: the row changes under a Save and the comparison has to
  ## be against what the *editor* started from.
  noteOrigTitle: string
  noteOrigContent: string
  noteOrigFocus: bool
  noteBuffer: TextBuffer = newTextBuffer()
  ## The message being edited in place (G-28), by row id, or empty. A second
  ## buffer rather than reusing `noteBuffer`: the note editor and the transcript
  ## can both be open, and sharing one `TextBuffer` would make each overwrite the
  ## other's text.
  editingMsg: string
  editBuffer: TextBuffer = newTextBuffer()
  expanded: Table[string, bool]
  renaming: string
  renameDraft: string
  search: string
  sidebarOpen: bool = true
  editorOpen: bool
  ## Bound to the Window's `fullscreened`, which the application had never set —
  ## so nothing in the program could leave fullscreen once the compositor put it
  ## there. owlkettle exposes no window-state event, so this cannot *observe* a
  ## compositor-initiated fullscreen; it can only drive one. Escaping that case
  ## therefore takes two toggles, which is still an exit where there was none.
  fullscreen: bool
  ## Decoded once at startup, not per redraw: `view` runs on every canvas frame,
  ## and re-decoding a 165 KB JPEG thirty times a second is the same mistake as
  ## re-forking `ifconfig`. A nil pixbuf is survivable — `Picture` renders empty
  ## — so a missing icon file costs the logo, not the window.
  logo: Pixbuf
  ## G-31. `opts` is what is saved and what reaches the request body; `draft` is
  ## what the open dialog is editing. **Two copies, deliberately:** the dialog has
  ## a Cancel, and a single copy edited in place would apply every keystroke to
  ## the next generation and have nothing to revert to.
  opts: settings.Settings
  optsDraft: settings.Settings
  settingsOpen: bool
  settingsSection: settings.SettingSection
  ## S-1. The hardware screen is its own panel rather than a settings section,
  ## because `settings.SettingSection` is the Web UI parity set (D-BL) and the
  ## parity assertion in `hardware-selftest`'s sibling `pipeline-selftest`
  ## checks it key for key — a Jenova-only section added there would turn it red
  ## for no defect. `hwDetecting` is what the panel shows while the control
  ## worker is out; detection is never run on this thread.
  ## 8a: the model selector. `modelList` is filled when the panel opens and
  ## never from `view` — enumerating the tree on every frame is the per-frame
  ## cost G-40 was, in a new place.
  modelsOpen: bool
  modelList: seq[models.InstalledModel]
  modelFilter: string

  hardwareOpen: bool
  ## G-21. Everything deleted is a soft delete and had no surface at all, which
  ## makes a delete indistinguishable from data loss — the hazard the confirm
  ## dialog (G-36) names but cannot answer on its own. Cached in `trashItems` for
  ## the reason `convs` is: `view` runs on every canvas frame, and seven table
  ## scans per frame is B-17 with a database behind it.
  trashOpen: bool
  trashItems: seq[TrashItem]
  ## A-18-2. The **path-addressed** half of the trash, which has no database row
  ## at all: files deleted through `/api/storage`. `restoreMirror` cannot see
  ## them — it looks an item up by id — so they were listed nowhere and cleared
  ## by nothing, and until A-17 they were not even enumerated. Deliberately a
  ## second list rather than merged into `trashItems`: one is addressed by id
  ## and the other by path, and unifying them would mean inventing an identity
  ## for rows that do not have one.
  trashFiles: seq[fssync.TrashEntry]
  hwDetecting: bool
  hw: hardware.Hardware
  hwScores: seq[hardware.Score]
  hwCurrent: string
  ## The two multi-line fields. A `TextView` owns a `TextBuffer` rather than a
  ## string, so — exactly as the note editor and the in-place message edit
  ## already do — each is filled when the dialog opens and read back on save.
  ## Separate buffers because both fields can be on screen in one session and
  ## one shared buffer would make each overwrite the other.
  sysBuffer: TextBuffer = newTextBuffer()
  customBuffer: TextBuffer = newTextBuffer()
  ## The server's own sampling values from `/props`, shown as each field's
  ## placeholder. Empty until the backend has been up long enough to answer,
  ## which is why a field with no entry here simply shows no placeholder rather
  ## than claiming a default it has not read.
  serverDefaults: Table[string, string]
  ## Which messages are being shown as raw text (G-31's raw-output toggle), by
  ## row id. Per message and not a global mode, because the point is to compare
  ## one rendered turn against its source.
  rawMsgs: Table[string, bool]

  hooks:
    afterBuild:
      # Action purpose: **resolve a "System" theme here and not in `run`.**
      # `run` executes before `adw.brew`, and `brew` is what calls `adw_init` —
      # asking libadwaita for the desktop's colour scheme before that reaches
      # `gdk_display_manager_get`, which **aborts the process**. The first
      # version of this setting did exactly that and every launch died in 0.09 s
      # with `Gdk-ERROR: gdk_display_manager_get() was called before gtk_init()`.
      # By here GTK is up, so the question can be asked. `run` opens on the
      # static default and this corrects it before the first frame.
      if theme.needsLiveResolve(state.opts.get("theme")):
        theme.applyPalette(theme.livePaletteFor(state.opts.get("theme")))

      # Action purpose: two timers, at deliberately different rates.
      #
      # The status poll is 3 s, matching the tray's cadence in `ui.lua` — slow
      # enough not to matter, fast enough that the header is not stale after a
      # start or stop.
      #
      # The stream drain is 40 ms. It is separate because it is a UI-latency
      # concern, not a health concern: tokens arriving at generation speed must
      # reach the view without waiting on a health interval.
      let st = state
      discard addGlobalTimeout(3000, proc(): bool =
        if quitting: return false
        ctlReq.send(ControlJob(action: "poll", lc: st.lc,
                               jcaHome: st.p.jcaHome,
                               port: st.cfg.getInt("PORT", 8080)))
        let newLan = isLanEnabled(st.p)
        if newLan != st.lanEnabled:
          st.lanEnabled = newLan
          # E-06: asked for, not computed here. The title bar shows the mode
          # immediately and gains the address when the worker answers.
          st.lanAddr = ""
          if newLan:
            ctlReq.send(ControlJob(action: "lan_addr", lc: st.lc))
          discard st.redraw()
        true
      )
      # Action purpose: the canvas frame clock, separate from the two above
      # because it is the only timer that redraws while nothing has happened.
      # `canvas.draw` is pure rendering and never asks for a redraw itself, so
      # without this the field would be static. Disabled by `CANVAS=0`, which
      # exists because this is the one thing in the window that costs CPU when
      # the program is idle.
      if st.cfg.get("CANVAS", "1") != "0":
        discard addGlobalTimeout(canvas.FrameMs, proc(): bool =
          # `queueFrame` addresses the DrawingArea directly, so after
          # `closeWindow` it would queue a draw on a freed widget.
          if quitting: return false
          canvas.step()
          # `queueFrame`, not `redraw`. `redraw()` diffs the entire widget tree,
          # so animating the canvas through it re-bound every signal handler in
          # the window thirty times a second — see the note in `canvas.nim`.
          canvas.queueFrame()
          true
        )

      discard addGlobalTimeout(40, proc(): bool =
        var changed = false

        # G-30: files dropped on the window. The GTK drop callback is a bare C
        # function pointer that only appends to `droppedPaths`; the work happens
        # here, on the GTK thread, with the app state in hand — the same shape
        # `pendingActions` uses, and for the same reason.
        while droppedPaths.len > 0:
          let path = droppedPaths[0]
          droppedPaths.delete(0)
          changed = true
          # `readAttachment` and not `attachFile`: this runs inside the
          # `viewable`'s own hook, where a proc taking `AppState` does not yet
          # exist. That is the reason the decision is a pure proc above.
          if not state.streaming:
            let r = pipeline.readAttachment(path, state.serverDefaults.len > 0,
                                   state.serverVision)
            if r.ok:
              state.pending.add r.att
              state.notice = "attached " & r.att.name
            else:
              state.notice = r.err

        while pendingActions.len > 0:
          let action = pendingActions[0]
          pendingActions.delete(0)
          changed = true
          if action == "quit":
            # **Return, do not fall through.** `closeWindow` finalises the
            # window and every widget under it; the `redraw()` at the bottom of
            # this callback would then diff a tree of freed GtkWidgets and
            # disconnect a signal from poisoned memory. That is the crash — it
            # fired on *exit*, which is why every session looked fine and left a
            # core behind. `false` also removes this timeout, so it cannot fire
            # again against the dead tree.
            quitting = true
            st.closeWindow()
            return false
          elif action == "toggle_fullscreen":
            st.fullscreen = not st.fullscreen
          elif action == "toggle_lan":
            let next = not st.lanEnabled
            # E-03: **nothing moves unless the flag was actually written.** The
            # next start binds from that file, so flipping the window, the tray
            # and the title bar over a failed write would report a change that
            # will not survive the restart the notice asks for.
            if not setLanState(st.p, next):
              st.notice = "could not write the LAN setting to " &
                          st.p.state & " — it is unchanged"
            else:
              st.lanEnabled = next
              st.lanAddr = ""
              if next: ctlReq.send(ControlJob(action: "lan_addr", lc: st.lc))
              tray.setItems(trayMenu(next))
              st.notice = if next: "LAN enabled - restart to bind 0.0.0.0"
                          else: "LAN disabled - restart to bind 127.0.0.1"
          else:
            ctlReq.send(ControlJob(action: action, lc: st.lc,
                                   jcaHome: st.p.jcaHome,
                                   port: st.cfg.getInt("PORT", 8080)))

        while true:
          let (hasData, m) = uiChan.tryRecv()
          if not hasData: break
          changed = true
          case m.kind
          of umDone:
            st.streaming = false
            if st.messages.len > 0 and st.messages[^1].role == rAssistant:
              # An assistant turn that already has a row is one that was
              # *continued* — the model extended text that had already been
              # saved. Updating it is what stops the transcript gaining a second
              # copy of the same reply every time one is resumed (G-28).
              if st.messages[^1].id.len > 0:
                discard api.patchMessage(%*{
                  "id": st.messages[^1].id,
                  "content": st.messages[^1].text,
                  "thinking": st.messages[^1].thinking,
                  "model": st.messages[^1].model,
                  "timings": timingsToJson(st.messages[^1].timings)})
                # The tree holds its own copy of this turn, and the path holds
                # another. Updating only the row leaves the tree carrying the
                # text from *before* the reply was extended, and the next redraw
                # that rebuilds the path from the tree would put it back on
                # screen — undoing the continuation without touching the database.
                for t in st.allMessages.mitems:
                  if t.id == st.messages[^1].id:
                    t.text = st.messages[^1].text
                    t.thinking = st.messages[^1].thinking
                    t.model = st.messages[^1].model
                    t.timings = st.messages[^1].timings
                # A continued reply is longer than the text already indexed, so
                # the entry is rewritten from the row that was just patched
                # (T-17). Idempotent — `indexContent` forgets the path first.
                ctlReq.send(ControlJob(action: "index", lc: st.lc,
                                       msgId: st.messages[^1].id))
              else:
                # The parent is the turn before it on the branch that was posted.
                # A regenerate re-posted the conversation truncated to that turn,
                # so the new reply lands beside the old one rather than after it —
                # which is the whole of how a branch is made (G-29).
                let parent =
                  if st.messages.len > 1: st.messages[^2].id else: ""
                let saved = saveMessage(
                  st.convId, rAssistant, st.messages[^1].text,
                  st.messages[^1].thinking, st.messages[^1].model,
                  st.messages[^1].timings, parent)
                st.messages[^1].id = saved
                st.messages[^1].parent = parent
                if saved.len > 0:
                  st.allMessages.add st.messages[^1]
                  st.edges = edgesOf(st.allMessages)
                  st.leaf = saved
                  saveLeaf(st.convId, saved)
                  # Action purpose: the exchange is complete, so this is the
                  # first moment the question can be indexed without the
                  # request that asked it retrieving itself (T-17). The worker
                  # indexes this reply and its parent — the user turn — from
                  # the two rows now committed.
                  ctlReq.send(ControlJob(action: "index", lc: st.lc,
                                         msgId: saved))
                else:
                  # Nothing was generated at all. **Leaving it in the path is the
                  # ghost bubble the USER saw**: an empty card, visible until the
                  # next rebuild, absent from the tree, and with `leaf` still on
                  # the previous turn — so the next message attached to a stale
                  # parent and became an unwanted sibling.
                  st.messages.delete(st.messages.len - 1)
            # The reply bumped `lastModified`, so the cached list is now in the
            # wrong order. Refreshed here rather than in `view` for the reason
            # `convs` is cached at all.
            st.convs = listConversations()
          of umError:
            st.notice = m.text
            st.noticeRetryable = m.retryable
            if st.messages.len > 0 and st.messages[^1].role == rAssistant and
               st.messages[^1].text.len == 0:
              st.messages.delete(st.messages.len - 1)
          of umNotice:
            st.notice = m.text
            st.noticeRetryable = false
          of umLanAddr:
            # E-06. Only kept while LAN is on: a reply that arrives after the
            # user switched it back off would put an address in the title bar
            # for a mode the window is no longer in.
            if st.lanEnabled: st.lanAddr = m.text
          of umHardware:
            st.hw = m.hw
            st.hwScores = m.scores
            st.hwCurrent = m.text
            st.hwDetecting = false
          of umStatus:
            if m.status != st.status:
              st.status = m.status
              tray.setStatus(if m.status == bsUp: tsActive else: tsPassive)
          of umToken:
            if st.messages.len == 0 or st.messages[^1].role != rAssistant:
              st.messages.add Message(role: rAssistant, text: "")
            st.messages[^1].text.add m.text
          of umThinking:
            # Reasoning arrives before any answer token, so the assistant turn
            # usually has to be created here rather than by `umToken` (G-39).
            if st.messages.len == 0 or st.messages[^1].role != rAssistant:
              st.messages.add Message(role: rAssistant, text: "")
            st.messages[^1].thinking.add m.text
          of umCacheHit:
            # Arrives on the response head, before any token, so the assistant
            # turn usually does not exist yet — same ordering as `umThinking`.
            if st.messages.len == 0 or st.messages[^1].role != rAssistant:
              st.messages.add Message(role: rAssistant, text: "")
            st.messages[^1].cacheHit = true
          of umModel:
            if st.messages.len > 0 and st.messages[^1].role == rAssistant:
              st.messages[^1].model = m.text
          of umTimings:
            # Overwritten rather than accumulated: each report from the server is
            # the running total for this turn, not a delta.
            if st.messages.len > 0 and st.messages[^1].role == rAssistant:
              st.messages[^1].timings = m.timings
          of umProps:
            st.serverVision = m.vision
            if m.ctx > 0: st.ctxSize = m.ctx
            if m.text.len > 0: st.serverModel = m.text
            # Flattened to strings on arrival rather than kept as JSON, because
            # the only consumer is a placeholder and a string comparison against
            # the stored value. Numbers are rendered by `$`, so an integer server
            # default reads as `40` and not `40.0`.
            if m.params.len > 0:
              try:
                let n = parseJson(m.params)
                if n.kind == JObject:
                  for k, v in n:
                    st.serverDefaults[k] =
                      case v.kind
                      of JString: v.getStr
                      of JInt: $v.getInt
                      of JFloat: formatFloat(v.getFloat, ffDecimal, -1).strip(
                                   leading = false, chars = {'0'}).strip(
                                   leading = false, chars = {'.'})
                      of JBool: (if v.getBool: "1" else: "0")
                      of JArray:
                        # `samplers` is the one array here, and it is exactly the
                        # semicolon-separated order the field accepts — so the
                        # placeholder shows the server's real sampler order
                        # rather than nothing, which is what it showed before.
                        var parts: seq[string]
                        for e in v:
                          if e.kind == JString: parts.add e.getStr
                        parts.join(";")
                      else: ""
              except CatchableError:
                discard
        if changed:
          discard st.redraw()
        true
      )

## Function purpose: the visible transcript for a tree and a leaf, and the leaf
## it settled on (G-29). A free function rather than a method on the window
## because the first transcript has to be built before the window exists, and two
## copies of a tree walk is exactly the drift `api`'s pure helpers were extracted
## to avoid.
##
## When the leaf is missing or unknown — a fresh conversation, or one whose
## `currNode` points at a turn since deleted — it falls back to the newest branch
## from the oldest root.
##
## **That fallback is not a migration, and treating it as one is the defect that
## shipped.** Messages written before branching have a NULL `parent`, so every one
## of them is a root: the fallback then yields a path of exactly one message and
## `siblingsIn` reads the whole conversation as versions of a single turn.
## `db.migrateMessageParents` chains them at startup, and that is what makes
## existing history readable — not this (**D-BG**).
proc pathOf(all: seq[Message], leaf: string): tuple[path: seq[Message], leaf: string] =
  let edges = edgesOf(all)
  var byId = initTable[string, int]()
  for i, m in all: byId[m.id] = i

  result.leaf = leaf
  if leaf.len == 0 or not byId.hasKey(leaf):
    var root = ""
    for m in all:
      if m.parent.len == 0:
        root = m.id
        break
    result.leaf = if root.len > 0: api.deepestFrom(edges, root) else: ""

  for id in api.pathTo(edges, result.leaf):
    if byId.hasKey(id): result.path.add all[byId[id]]

## Function purpose: recompute the visible transcript after anything that changes
## the shape of the conversation.
proc rebuildPath(app: AppState) =
  let (path, leaf) = pathOf(app.allMessages, app.leaf)
  app.messages = path
  app.leaf = leaf
  app.edges = edgesOf(app.allMessages)

## Function purpose: empty every per-message render cache (M-01).
##
## **Forward-declared, because the three things it empties are each declared
## beside their first user further down** — `mdMemo` above the note editor,
## `attachMemo` above the send path, `thumbCache` above the thumbnail decoder —
## and each of those placements carries its own reasoning that moving the
## declaration up here would break. The one caller that needs them all is
## `selectConversation`, which is above all three.
proc clearRenderMemos()

## Function purpose: forget one message id in every render cache (M-01), for the
## one thing that makes an entry dead while the conversation stays open.
proc forgetRenderMemos(id: string)

## Function purpose: load a conversation's tree and the branch last being read.
proc loadConversation(app: AppState, convId: string) =
  app.allMessages = loadMessages(convId)
  app.leaf = loadLeaf(convId)
  app.rebuildPath()

## Function purpose: record a newly saved turn as the end of the visible path.
## The tree, the path and the persisted `currNode` all move together — leaving
## any one of them behind is what makes a transcript disagree with itself.
proc appendTurn(app: AppState, m: Message) =
  app.allMessages.add m
  app.leaf = m.id
  saveLeaf(app.convId, m.id)
  app.rebuildPath()

## Function purpose: switch the transcript to another conversation. Refused mid
## stream: tokens in flight are appended to `messages[^1]` by the drain timer,
## which would otherwise write the tail of one conversation into another.
proc selectConversation(app: AppState, id: string) =
  if app.streaming or id == app.convId: return
  # M-01. **This is where the leak was.** `mdMemo`, `attachMemo` and
  # `thumbCache` are module-level `var`s keyed by message id, and nothing —
  # not this, not `loadConversation`, not `deleteMessage` — ever dropped an
  # entry. So every message ever rendered kept its parsed blocks, its parsed
  # `extra` (including each image's full base64, held twice over) and its
  # decoded pixbuf for the life of the process, for conversations closed hours
  # ago. The transcript draws one branch of one conversation, so the moment the
  # conversation changes every entry in all three is dead.
  clearRenderMemos()
  app.convId = id
  app.loadConversation(id)
  app.openNote = ""
  app.notice = ""

proc reloadTree(app: AppState) =
  app.convs = listConversations()
  app.workspaces = listWorkspaces()
  app.projects = listProjects()
  app.folders = listFolders()
  app.notes = listNotes()
  app.files = listFiles()

## `view` re-parsed every message's full text on every frame, which a long
## conversation paid on every streamed token (G-40). Declared here rather than
## beside `attachMemo` because the note editor below is its first user: it
## renders through this memo and, unlike the transcript, has to invalidate it.
var mdMemo: markdown.BlockMemo

proc openNoteEditor(app: AppState, id: string) =
  if app.streaming: return
  let n = loadNote(id)
  if not n.found:
    app.notice = "note not found"
    return
  app.openNote = id
  app.noteTitle = n.title
  app.noteFocus = n.focus
  app.noteBuffer.text = n.content
  # 8c-3: a note opens as it reads, not as it is typed — the Web UI's default
  # and the safer one, since a stray keystroke in a view cannot alter a note.
  app.noteEditing = false
  app.noteOrigTitle = n.title
  app.noteOrigContent = n.content
  app.noteOrigFocus = n.focus
  # A-26. The memo keys on the note id, which does not change across an edit, so
  # it must be told. This is also the external-change path: `pullNotesFromDisk`
  # re-opens the note through here after `api.pullNotes` rewrites the row.
  mdMemo.invalidate(id)
  app.notice = ""

## Function purpose: whether the open note carries an edit that is not in the
## row yet (8c-4). Close asks this before discarding the buffer, which is the
## one action in this editor that could destroy something the user typed.
proc noteDirty(app: AppState): bool =
  app.openNote.len > 0 and
    (app.noteTitle != app.noteOrigTitle or
     app.noteFocus != app.noteOrigFocus or
     app.noteBuffer.text() != app.noteOrigContent)

## Function purpose: write the open note back through `api.putEntity`, the same
## call the HTTP route makes, so the filesystem mirror and the per-workspace git
## repo apply exactly as they do for the Web UI.
##
## Action purpose: `isFocusNote` is sent explicitly and the parent ids are still
## resent, even though `putEntity` now carries forward any column this node
## omits (D-CC). The flag is not a carry-forward case — it is a value this screen
## *owns* while the note is open, so a toggle the user has just flipped has to
## reach the row. Written as `1`/`0` rather than a JSON boolean because the Web
## UI writes the column that way and both surfaces read it back.
proc saveNote(app: AppState) =
  if app.openNote.len == 0: return
  var node = %*{"id": app.openNote,
                "title": app.noteTitle,
                "content": app.noteBuffer.text(),
                "isFocusNote": (if app.noteFocus: 1 else: 0),
                "updatedAt": int(epochTime() * 1000)}
  for n in app.notes:
    if n.id == app.openNote:
      node["folderId"] = %n.folderId
      node["projectId"] = %n.projectId
      node["workspaceId"] = %n.workspaceId
  if api.putEntity("notes", node):
    app.reloadTree()
    # 8c-3/8c-4: the saved values become the baseline, so the note is no longer
    # dirty and Cancel from here restores what was just written rather than what
    # the editor happened to open with.
    app.noteOrigTitle = app.noteTitle
    app.noteOrigContent = app.noteBuffer.text()
    app.noteOrigFocus = app.noteFocus
    # A-26. The other half: an edit that leaves the character count unchanged —
    # a transposition, a word swapped for one the same length — matches the
    # memo's length stamp, so without this the view keeps rendering the text
    # that was just replaced. `cancelNoteEdit` needs no such call: it restores
    # the buffer *from* the baseline, which is what the memo already holds.
    mdMemo.invalidate(app.openNote)
    app.noteEditing = false
    app.notice = "note saved"
  else:
    app.notice = "could not save note"

## Function purpose: leave edit mode, putting back what the row holds (8c-3).
## The Web UI's Cancel does the same, and it is the reason the baseline is kept:
## without it "cancel" could only mean "stop typing", which changes nothing and
## is not what the button says.
proc cancelNoteEdit(app: AppState) =
  app.noteTitle = app.noteOrigTitle
  app.noteBuffer.text = app.noteOrigContent
  app.noteFocus = app.noteOrigFocus
  app.noteEditing = false
  app.notice = ""

## Function purpose: close the note editor, refusing to throw away unsaved work
## silently (8c-4). Everything else in this window that can lose data asks first
## — G-36 put a dialog on every delete for exactly this reason — and Close was
## the one remaining action that simply dropped the buffer.
##
## Action purpose: three answers, not two. "Discard" and "Save and close" are
## both things the user plainly means at that moment, and offering only one of
## them makes the other require cancelling the dialog and starting again.
## Function purpose: ask before anything that would throw the note buffer away,
## and answer whether to go ahead (8c-4). **Shared, because Close is not the
## only door.** Clicking a different note in the tree and creating a new one both
## replace the buffer, and those are easier to hit by accident than the Close
## button is — one click, with no warning that anything was pending.
proc confirmLoseNoteEdits(app: AppState): bool =
  if not app.noteDirty: return true
  # Action purpose: three answers, not two. "Discard" and "Save" are both things
  # the user plainly means at that moment, and offering only one makes the other
  # require cancelling the dialog and starting the action again.
  let (res, _) = app.open: gui:
    MessageDialog:
      title = "Unsaved changes"
      message = "\"" & (if app.noteTitle.len > 0: app.noteTitle
                        else: "Untitled note") &
                "\" has changes that are not saved.\n\n" &
                "Continuing without saving will lose them."
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Discard"
        res = DialogReject
        style = [ButtonDestructive]
      DialogButton {.addButton.}:
        text = "Save"
        res = DialogAccept
        style = [ButtonSuggested]
  case res.kind
  of DialogAccept:
    app.saveNote()
    # A failed save must not proceed: carrying on would lose exactly what the
    # dialog was protecting. `saveNote` re-baselines only when the write landed,
    # so `noteDirty` is the honest answer to "did it save".
    not app.noteDirty
  of DialogReject: true
  else: false

proc closeNote(app: AppState) =
  if not app.confirmLoseNoteEdits(): return
  app.openNote = ""
  app.noteEditing = false
  app.notice = ""

## Function purpose: open a note the way the tree opens one — through the
## unsaved-changes guard. `openNoteEditor` deliberately does not carry the guard
## itself: it is also the call that *follows* a create, where the guard has
## already been asked and asking twice would be the defect.
proc openNoteGuarded(app: AppState, id: string) =
  if app.openNote.len > 0 and app.openNote != id and
     not app.confirmLoseNoteEdits(): return
  app.openNoteEditor(id)

proc newChat(app: AppState, wsId = "", projId = "", folderId = "") =
  if app.streaming: return
  let id = newConversation()
  if wsId.len > 0 or projId.len > 0 or folderId.len > 0:
    db.exec("UPDATE conversations SET workspaceId=?, projectId=?, folderId=? WHERE id=?",
            [wsId, projId, folderId, id])
  app.reloadTree()
  # M-01: the other point at which a rendered conversation is replaced.
  # `newChat` does not go through `selectConversation`, so without this the
  # memos keep every message of the conversation just left until the caps
  # eventually push them out — which is a bound, not a release.
  clearRenderMemos()
  app.convId = id
  app.messages = @[]
  app.allMessages = @[]
  app.leaf = ""
  app.openNote = ""
  app.notice = ""
  # G-31. On by default, matching the Web UI: a new chat is usually the moment
  # you want the list of the old ones. Never *closes* it — the setting is
  # "auto-show", and a toggle that also hid the sidebar would fight the user.
  if app.opts.getBool("autoShowSidebarOnNewChat"): app.sidebarOpen = true

proc createNode(app: AppState, entity, parentCol, parentId: string) =
  let id = $genOid()
  var node = %*{"id": id, "name": "New " & entity[0 ..< entity.len - 1]}
  if parentCol.len > 0: node[parentCol] = %parentId
  if api.putEntity(entity, node):
    app.reloadTree()
    app.expanded[id] = true
    app.renaming = id
    app.renameDraft = node["name"].getStr
  else:
    app.notice = "could not create " & entity

## `notes` keys its name column `title`, not `name`, so it cannot go through
## `createNode`'s generic node shape. Creating one opens it immediately —
## a new empty note that is not on screen is indistinguishable from nothing
## having happened.
##
## **The id must be a real UUID, not a `genOid`.** `fssync.physicalPath` refuses
## anything else and `upsert` then deletes the row it has already written, so an
## OID-keyed note is created and destroyed inside one call.
##
## **All three ancestor ids are written, not just the immediate parent.** The
## tree matches on the full triple, so a note carrying only its `folderId` is
## saved and then invisible.
proc createNote(app: AppState, wsId, projId, folderId: string) =
  # 8c-4: asked before the row is written, not after. Guarding the `openNoteEditor`
  # below instead would leave an orphan "New note" behind whenever the user
  # cancelled the dialog.
  if not app.confirmLoseNoteEdits(): return
  let id = fssync.newUuid()
  var node = %*{"id": id, "title": "New note", "content": "",
                "workspaceId": wsId, "projectId": projId, "folderId": folderId,
                "updatedAt": int(epochTime() * 1000)}
  if api.putEntity("notes", node):
    app.reloadTree()
    app.openNoteEditor(id)
    # 8c-3: a note that has just been created is opened to be written, not read.
    # `openNoteEditor` defaults to the view, which is right for an existing note
    # and would show a new one as an empty page with no obvious way in.
    app.noteEditing = true
  else:
    app.notice = "could not create note"

proc deleteNode(app: AppState, entity, id: string) =
  # G-36. Every delete in the tree and the conversation list fired on a single
  # click. The argument for having no dialog was that deletes are soft — but
  # with no trash view (G-21) a soft delete is indistinguishable from data loss,
  # so the two answer each other and this is the half that lands first.
  #
  # Action purpose: **the child count is shown**, because the cascade is the
  # part that surprises: deleting a workspace takes its projects, folders,
  # notes, assets and every conversation in them. `api.cascadeCount` derives
  # that from the same table the cascade itself runs off.
  let kids = api.cascadeCount(entity, id)
  let what = case entity
             of "conversations": "this conversation"
             of "workspaces": "this workspace"
             of "projects": "this project"
             of "folders": "this folder"
             of "notes": "this note"
             of "fileAssets": "this file"
             else: "this item"
  let (res, _) = app.open: gui:
    MessageDialog:
      title = "Delete"
      message =
        (if kids > 0:
           "Delete " & what & " and the " & $kids &
           (if kids == 1: " item" else: " items") & " inside it?"
         else: "Delete " & what & "?") &
        "\n\nIt can be restored from the trash."
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Delete"
        res = DialogAccept
        style = [ButtonDestructive]
  if res.kind != DialogAccept: return

  if api.deleteEntity(entity, id):
    if entity == "conversations" and id == app.convId:
      app.convId = ""
      app.messages = @[]
      app.allMessages = @[]
      app.leaf = ""
    if entity == "notes" and id == app.openNote:
      app.openNote = ""
    app.reloadTree()
  else:
    app.notice = "could not delete"

proc commitRename(app: AppState, entity, id: string) =
  let name = app.renameDraft.strip
  if name.len > 0:
    if entity == "conversations":
      db.exec("UPDATE conversations SET name=? WHERE id=?", [name, id])
      app.reloadTree()
    elif entity == "notes" or entity == "fileAssets":
      # `api.writeRow` is INSERT OR REPLACE over every column, and a field this
      # node omits used to be written empty: renaming a file asset blanked its
      # `content`, `size`, `type` and `uploadDate`, and `fssync.syncFileAsset`
      # then wrote a zero-byte file over the real one and trashed the original
      # (T-13). **`putEntity` now merges a partial node onto the stored row
      # (D-CC), so that trap is closed at the boundary** rather than here.
      #
      # The explicit resends below stay, and are not redundant: what they carry
      # is not the *stored* value but the **open editor's** value, which the
      # merge cannot know — a note renamed with unsaved text in the buffer must
      # keep that text, not the row's. Same reason `isFocusNote` is sent from
      # `app.noteFocus` for the open note: an unsaved toggle travels with the
      # unsaved text or the two disagree after one rename.
      var node = %*{"id": id, "updatedAt": int(epochTime() * 1000)}
      node[if entity == "notes": "title" else: "name"] = %name
      if entity == "notes":
        let n = loadNote(id)
        node["content"] = %(if id == app.openNote: app.noteBuffer.text()
                            else: n.content)
        node["isFocusNote"] = %(if (if id == app.openNote: app.noteFocus
                                    else: n.focus): 1 else: 0)
        if id == app.openNote: app.noteTitle = name
      else:
        let f = loadFileAsset(id)
        node["content"] = %f.content
        node["size"] = %f.size
        node["type"] = %f.kind
        node["uploadDate"] = %f.uploadDate
      for n in (if entity == "notes": app.notes else: app.files):
        if n.id == id:
          node["folderId"] = %n.folderId
          node["projectId"] = %n.projectId
          node["workspaceId"] = %n.workspaceId
      discard api.putEntity(entity, node)
      app.reloadTree()
    else:
      var node = %*{"id": id, "name": name}
      for n in app.projects:
        if n.id == id: node["workspaceId"] = %n.parent
      for n in app.folders:
        if n.id == id: node["projectId"] = %n.parent
      # A container rename now moves its directory, and a move that cannot be
      # done rolls the row back (T-14). Discarding the result would leave the
      # sidebar showing the old name with no explanation of why it did not take.
      if not api.putEntity(entity, node):
        app.notice = "could not rename: the folder on disk could not be moved"
      app.reloadTree()
  app.renaming = ""

## Function purpose: the conversation list as the sidebar should show it —
## filtered by the search box. Case-insensitive substring, matching
## `ChatSidebarSearch`'s behaviour rather than inventing a ranking nobody asked
## for.
proc visibleConvs(app: AppState): seq[ConvItem] =
  let q = app.search.strip.toLowerAscii
  if q.len == 0: return app.convs
  for c in app.convs:
    if c.name.toLowerAscii.contains(q):
      result.add c

## Function purpose: post the transcript exactly as it currently stands and start
## streaming. The body is the OpenAI-compatible shape `pipeline.nim` expects, so
## intents, RAG and personas apply exactly as they do for the Web UI.
##
## Split out of `send` because regenerate and continue post the same body from a
## different starting state — regenerate after dropping the reply being redone,
## continue with the partial reply still in place as the tail (G-28).
##
## `continuing` is what makes that tail mean *extend this*. **Ending the array
## with an assistant message is necessary and not sufficient:** `llama-server`
## applies the chat template with `add_generation_prompt = true` unless the
## request says otherwise, which closes the assistant turn and opens a fresh one —
## so the model re-answers instead of carrying on. That is what shipped, and
## `continue_final_message` is the field that fixes it (**D-BH**).
## G-40. **One parse of a message's `extra`, shared by the two paths that need
## it.** `view` runs on every frame and `postConversation` rebuilds the whole
## history on every send; both used to parse every payload themselves, which is
## what made attaching anything freeze the window. Declared here because the
## send path is the first user of it — the transcript's is `attachmentsOf`
## below. `pipeline.ParseMemo` is where the parsing and the assertions live.
var attachMemo: pipeline.ParseMemo

proc postConversation(app: AppState, continuing = false) =
  app.notice = ""
  app.streaming = true

  var msgs = newJArray()
  # G-31: the stored system message goes in first, as a `system` role.
  # `pipeline.injectSystem` puts Jenova's own persona **above** an existing
  # system message rather than replacing it, so this adds to the persona instead
  # of competing with it — which is why the field is described as "beneath".
  let sys = app.opts.get("systemMessage").strip
  if sys.len > 0:
    msgs.add %*{"role": "system", "content": sys}
  for m in app.messages:
    if m.role == rAssistant and m.text.len == 0: continue
    # G-30: a turn with attachments sends an OpenAI content *array* rather than
    # a string. `pipeline.contentFor` builds it — below the widget layer, and in
    # the frozen Web UI's own part order (D-Z) — and returns a plain string
    # unchanged when there is nothing attached, so every request without
    # attachments is byte-identical to what this sent before.
    # G-40: **built from the memo, not re-parsed.** This rebuilds the whole
    # history on every turn, on the GTK thread, so re-parsing each message's
    # `extra` here charged the send a pass over every payload in the
    # conversation — on top of the one `view` was already charging per frame.
    var extraNode: JsonNode = nil
    if m.extra.len > 0:
      extraNode = attachMemo.extraNodeFor(m.id, m.extra)
    var turn = %*{"role": $m.role,
                  "content": pipeline.contentFor(m.text, extraNode)}
    # G-31, Developer: a reasoning turn's thinking is sent back so the model can
    # see its own chain of thought across turns, unless the setting strips it.
    # The field is only ever added to an assistant turn that has one, so the
    # default costs nothing on a non-reasoning model.
    if m.role == rAssistant and m.thinking.len > 0 and
       not app.opts.getBool("excludeReasoningFromContext"):
      turn["reasoning_content"] = %m.thinking
    msgs.add turn
  # The body is built by `pipeline.chatBody`, not here, so a self-test can see
  # it. Continue shipped broken twice while the body lived in this file, where
  # nothing below the window could assert it — and the sampling parameters are
  # merged in there for the same reason.
  let port = app.cfg.getInt("PORT", 8080)
  # G-43: the notes and files of whatever this chat belongs to. Read from
  # `app.convs`, which the sidebar already keeps current, so this costs no query
  # of its own. An unassigned chat resolves to the global scope, which is *not*
  # everything — see `workspace.contextFor`.
  var wsCtx = ""
  for c in app.convs:
    if c.id == app.convId:
      wsCtx = workspace.contextFor(c.folderId, c.projectId, c.workspaceId)
      break
  streamReq.send(StreamJob(host: "127.0.0.1", port: port,
                           body: pipeline.chatBody(msgs, continuing, app.opts,
                                                   wsCtx)))

## Function purpose: a conversation's name, taken from the message that started
## it (G-31). The Web UI titles a chat from its first message and this window
## left every one called "New chat", which is what made the sidebar unusable
## once there were more than a handful.
##
## First line only, and cut on a word boundary: a title is a sidebar row, and a
## paragraph in it pushes the delete button off the edge.
proc titleFrom(text: string): string =
  const Limit = 48
  var line = text.strip.splitLines()[0].strip
  if line.len == 0: return ""
  if line.len > Limit:
    let cut = line.rfind(' ', last = Limit)
    line = (if cut > Limit div 2: line[0 ..< cut] else: line[0 ..< Limit]) & "…"
  line

proc retitleConversation(app: AppState, text: string) =
  let name = titleFrom(text)
  if name.len == 0 or app.convId.len == 0: return
  db.exec("UPDATE conversations SET name=? WHERE id=?", [name, app.convId])
  app.convs = listConversations()

proc attachFile(app: AppState, path: string) =
  let r = pipeline.readAttachment(path, app.serverDefaults.len > 0,
                                  app.serverVision)
  if r.ok:
    app.pending.add r.att
    app.notice = "attached " & r.att.name
  else:
    app.notice = r.err

## Function purpose: file a long paste as a text attachment (W-01).
##
## Action purpose: it goes through `pipeline.Attachment` directly rather than
## through `readAttachment`, because there is no file to read — the bytes are
## already in hand. The cap is still honoured: a paste past
## `MaxAttachmentBytes` is refused with the same message a file gets, because
## the reason is the same and a paste that silently vanished would be worse than
## one that stayed in the box.
proc attachPastedText(app: AppState, text: string) =
  if text.len > pipeline.MaxAttachmentBytes:
    app.notice = "that paste is too large to attach — " &
                 $((text.len + 1024 * 1024 - 1) div (1024 * 1024)) & " MB " &
                 "against a limit of " &
                 $(pipeline.MaxAttachmentBytes div (1024 * 1024)) & " MB"
    return
  let name = composer.pastedFileName(epochTime().int64)
  app.pending.add pipeline.Attachment(
    kind: "TEXT", name: name, payload: text, bytes: text.len,
    key: name & ":" & $text.len)
  app.notice = "long paste attached as " & name &
               " — it goes to the model as a file rather than as your message"

proc attachDialog(app: AppState) =
  let (res, state) = app.open: gui:
    FileChooserDialog:
      title = "Attach files"
      action = FileChooserOpen
      selectMultiple = true
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Attach"
        res = DialogAccept
        style = [ButtonSuggested]
  if res.kind != DialogAccept: return
  for f in FileChooserDialogState(state).filenames:
    app.attachFile(f)

## G-30, thumbnails. **A `data:` URL is decoded to a file under the cache dir and
## the pixbuf is loaded from there**, rather than a `GdkPixbufLoader` being
## hand-declared: `gdk_pixbuf_new_from_file_at_scale` is already in owlkettle's
## bindings and already wrapped as `loadPixbuf`, and rule 5 says check what
## exists before writing a proto. The file is named for the digest of its own
## bytes, so it is written once and every later redraw is a cache hit — which is
## what makes this safe to call from `view`, where it runs on every frame.
var thumbCache: Table[string, Pixbuf]
## M-01. Insertion order, so the oldest decoded thumbnails can be dropped.
var thumbOrder: seq[string]

const ThumbCacheCap = 64
  ## M-01. How many decoded thumbnails may be held.
  ##
  ## **A `Pixbuf` is the third copy of an image this window keeps.** The bytes
  ## are already in `attachMemo` twice — once as the parsed `extra` node and
  ## once as `Attachment.payload` — and a fourth copy is on disk under
  ## `cacheDir`. This one is decoded, so it is the largest: a 4000x3000 photo
  ## scaled to 900 is still megabytes of pixels.
  ##
  ## 64 is far more than the transcript can show at once, so the cap never
  ## engages while reading; `clearRenderMemos` below is what actually recovers
  ## the memory on a conversation switch, and this is the ceiling for a single
  ## conversation with more images than that in one branch.

## G-40. **The key is the attachment's identity, never a digest of its bytes.**
## This proc is called from `view`, so it runs on every frame — and the previous
## version built its key as `sha256(dataUrl)`, one line above the cache lookup it
## was meant to satisfy. The decode was cached and the key was not, so a
## multi-megabyte hash ran on every redraw and the window stopped responding.
## **Nothing in here may touch `payload` on the cache-hit path.**
proc attachmentPixbuf(app: AppState, a: PendingAttachment, size: int): Pixbuf =
  if a.payload.len == 0: return nil
  # An attachment always carries a key; the fallback is for one built before
  # `key` existed, and is still O(1).
  let ident = if a.key.len > 0: a.key else: a.name & ":" & $a.payload.len
  let key = $size & ":" & ident
  if thumbCache.hasKey(key): return thumbCache[key]
  # Only cache a *successful* load: caching nil would make one unreadable image
  # permanently unreadable, including after the cause was fixed.
  let comma = a.payload.find(',')
  if comma < 0: return nil
  var bytes = ""
  try: bytes = base64.decode(a.payload[comma + 1 .. ^1])
  except CatchableError: return nil
  # The digest here is on the miss path only — once per attachment per size, not
  # once per frame — and names the file so identical images share one.
  # A subdirectory Jenova owns, not `cacheDir` itself: `CACHE_DIR` is
  # operator-configurable, and `paths.sweepCache` deletes from here. A filename
  # prefix is not ownership — see `paths.AttachCacheDir`.
  let dir = app.p.attachCacheDir
  let file = dir / "attach-" & sha256.sha256(bytes)
  try:
    createDir(dir)
    if not fileExists(file): writeFile(file, bytes)
    result = loadPixbuf(file, size, size, preserveAspectRatio = true)
    if not thumbCache.hasKey(key):
      thumbOrder.add key
      # Batch eviction, for the reason `markdown.evict` gives: this runs from
      # `view`, and a per-insert `delete(0)` is an O(n) shift on a path that
      # must do no work proportional to anything.
      if thumbOrder.len > ThumbCacheCap:
        let drop = max(1, ThumbCacheCap div 4)
        for i in 0 ..< drop: thumbCache.del(thumbOrder[i])
        thumbOrder = thumbOrder[drop .. ^1]
    thumbCache[key] = result
  except CatchableError:
    # A file that is not a decodable image is not an error worth a notice — the
    # chip falls back to its name and type.
    return nil

proc attachmentsOf(m: Message): seq[PendingAttachment] =
  attachMemo.attachmentsFor(m.id, m.extra)

## M-01. The definitions of the two declared above `loadConversation`. Placed
## here because this is the first point at which all three memos exist.
##
## `thumbCache` holds GTK objects rather than plain values, but dropping the
## entry is the whole of the release: GTK reference-counts a `GdkPixbuf`, and
## the toolkit frees it once nothing holds a reference. The decoded file under
## `cacheDir` deliberately survives — it is named for the digest of its own
## bytes, so it is the thing that makes a re-open cheap, and `paths.sweepCache`
## is what bounds it.
proc clearRenderMemos() =
  mdMemo.clear()
  attachMemo.clear()
  thumbCache.clear()
  thumbOrder.setLen(0)

proc forgetRenderMemos(id: string) =
  if id.len == 0: return
  mdMemo.invalidate(id)
  attachMemo.forget(id)
  # A thumbnail is keyed by size and attachment identity rather than by message
  # id, so there is no single key to drop here. The entries are bounded by
  # `ThumbCacheCap` and cleared on every conversation switch, which is the two
  # bounds that matter; scanning the table for a message's thumbnails would be
  # work proportional to the cache on a path that is already O(1).
  discard

## Function purpose: the staged attachments as the JSON text that goes into the
## `messages.extra` column, in the Web UI's shape (D-Z).
proc pendingExtra(app: AppState): string =
  if app.pending.len == 0: return ""
  var arr = newJArray()
  for a in app.pending:
    if a.kind == "IMAGE":
      arr.add %*{"type": "IMAGE", "name": a.name, "base64Url": a.payload}
    elif a.kind == "PDF":
      # The Web UI's own PDF shape, so `contentFor` sends it as that surface
      # does and an exported conversation still opens there (D-BP).
      # `processedAsImages` is false because this reader extracts text, never
      # page images — and `contentFor` branches on exactly that flag.
      arr.add %*{"type": "PDF", "name": a.name, "content": a.payload,
                 "processedAsImages": false}
    else:
      arr.add %*{"type": "TEXT", "name": a.name, "content": a.payload}
  $arr

## Function purpose: file an attachment as a workspace artefact as well as an
## inline payload (G-44, ruling D-BV). **Both, not either** — Q-34 was answered
## "parity with the Web UI", so `messages.extra` keeps the base64 exactly as
## D-BP stores it and a conversation still moves between this window and the
## frozen `jca_web` unconverted. The row is written *in addition*.
##
## **Why it matters beyond the tree:** `workspace.contextFor` already reads
## `fileAssets` and renders it, and nothing had ever written one — the reader
## existed and the writer did not, so a file dropped into a chat was invisible to
## the very workspace it was dropped into.
##
## Written through `api.putEntity` and not SQL here, because that route also
## mirrors the bytes to disk through `fssync.syncFileAsset` and applies the same
## cascades the HTTP surface does. **A chat with no workspace files nothing** —
## a global artefact would be visible to every unassigned chat, which is not
## where the USER put it.
proc fileAttachmentsAsArtefacts(app: AppState) =
  if app.pending.len == 0: return
  var folderId, projectId, workspaceId: string
  for c in app.convs:
    if c.id == app.convId:
      folderId = c.folderId; projectId = c.projectId; workspaceId = c.workspaceId
      break
  if folderId.len == 0 and projectId.len == 0 and workspaceId.len == 0: return

  let now = epochTime().int
  for a in app.pending:
    # An image's `content` is left empty deliberately: the column is the text a
    # model can be shown, and `workspace.contextFor` renders an empty one as
    # "(Binary file, content not available for direct reading)" — which is the
    # Web UI's own wording for exactly this case. The bytes are already in
    # `messages.extra` and go to the model as an image part.
    let isText = a.kind != "IMAGE"
    # A-69. The id must be a real UUID for the same reason `createNote` above
    # says so: `fssync.physicalPath` refuses a 24-character `genOid`, so
    # `syncFileAsset` fails and `upsert` deletes the row it has already
    # written. Every attachment reported "could not file …" until this line.
    let node = %*{
      "id": fssync.newUuid(), "folderId": folderId, "projectId": projectId,
      "workspaceId": workspaceId, "name": a.name,
      "size": (if isText: a.payload.len else: 0),
      "type": (if isText: "text/plain" else: "image/*"),
      "uploadDate": now,
      "content": (if isText: a.payload else: "")}
    if not api.putEntity("fileAssets", node):
      app.notice = "Attached, but could not file " & a.name & " in the workspace"

proc send(app: AppState) =
  let text = app.draft.strip
  # Step 13a: the rule itself is `composer.canSend`, below the widget layer,
  # so it is asserted here at its own call site rather than in a copy of it.
  if not composer.canSend(text, app.pending.len, app.streaming):
    return
  # The first turn names the conversation. Checked before the message is
  # appended, because after it the path is never empty.
  let isFirstTurn = app.messages.len == 0

  # The row id comes back so the message can be edited or deleted without
  # re-reading the table to find which row it became. The parent is the turn at
  # the end of the branch currently being read, which is what attaches the new
  # message to *this* branch rather than to whichever one is newest (G-29).
  let parent = if app.messages.len > 0: app.messages[^1].id else: ""
  let extra = app.pendingExtra()
  let id = saveMessage(app.convId, rUser, text, parent = parent, extra = extra)
  app.appendTurn(Message(role: rUser, text: text, id: id, parent: parent,
                         extra: extra))
  if isFirstTurn: app.retitleConversation(text)
  app.draft = ""
  # G-44: filed as workspace artefacts before `pending` is cleared, and after the
  # message row exists — so a failure here leaves the turn intact and only the
  # filing undone, which is the recoverable half.
  app.fileAttachmentsAsArtefacts()
  app.reloadTree()
  # Cleared only once the turn carrying them is saved, so a failed save does not
  # silently drop the files the USER picked.
  app.pending = @[]
  app.postConversation()

## Function purpose: the actions a message can carry (G-28). **Every one of them
## is refused mid-stream** — the drain timer appends each token to
## `messages[^1]`, so mutating the sequence underneath it would write the tail of
## a reply into the wrong turn. That is the same hazard `selectConversation`
## refuses for, and it is why these are guarded rather than merely greyed out.
## Deleting a turn takes **everything under it** with it, on every branch. A
## reply to a question that is no longer there is not a conversation, and leaving
## the descendants as orphans would make them unreachable rather than gone —
## invisible in the transcript and still counted by every sibling counter.
proc deleteMessage(app: AppState, idx: int) =
  if app.streaming or idx < 0 or idx >= app.messages.len: return
  # The id alone, not the whole message: copying the object would copy the reply
  # text with it, and a long reply is the largest string in this program.
  let id = app.messages[idx].id
  # A turn that never became a row — an assistant reply abandoned mid-stream —
  # has nothing to delete but should still leave the transcript.
  if id.len == 0:
    app.messages.delete(idx)
    return

  # Collect the subtree before deleting any of it: `api.deleteEntity` soft-deletes
  # one row, and re-reading the tree between deletes would lose the links.
  var doomed = @[id]
  var scan = 0
  while scan < doomed.len and scan < 4096:
    let cur = doomed[scan]
    inc scan
    for m in app.allMessages:
      if m.parent == cur and m.id notin doomed: doomed.add m.id

  for victim in doomed:
    if not api.deleteEntity("messages", victim):
      app.notice = "could not delete that message"
      return
    # M-01: a deleted turn's parsed blocks, parsed attachments and decoded
    # thumbnail can never be drawn again. Dropped here rather than left to the
    # caps, because a deleted message is the one entry that is *certainly* dead
    # while the conversation it belonged to is still open.
    forgetRenderMemos(victim)
  if app.editingMsg in doomed: app.editingMsg = ""

  # The reader lands on the deleted turn's parent, which is the nearest thing
  # still on their branch.
  let parent = app.messages[idx].parent
  var kept: seq[Message]
  for m in app.allMessages:
    if m.id notin doomed: kept.add m
  app.allMessages = kept
  app.leaf = parent
  saveLeaf(app.convId, parent)
  app.rebuildPath()

## Function purpose: move to another version of a turn (G-29) — what the
## prev/next arrows beside a "2 of 3" counter do.
##
## The reader lands on the deepest continuation of the version they chose, not on
## the switch point, so picking an older answer shows the conversation that
## followed *it* rather than stranding them mid-transcript.
proc switchSibling(app: AppState, id: string, delta: int) =
  if app.streaming or id.len == 0: return
  let edges = app.edges
  let sibs = api.siblingsIn(edges, id)
  if sibs.len < 2: return
  let at = sibs.find(id)
  if at < 0: return
  let next = (at + delta + sibs.len) mod sibs.len
  app.leaf = api.deepestFrom(edges, sibs[next])
  saveLeaf(app.convId, app.leaf)
  app.rebuildPath()

proc startEdit(app: AppState, idx: int) =
  if app.streaming or idx < 0 or idx >= app.messages.len: return
  if app.messages[idx].id.len == 0: return
  app.editingMsg = app.messages[idx].id
  app.editBuffer.text = app.messages[idx].text

proc cancelEdit(app: AppState) =
  app.editingMsg = ""

## Function purpose: save an edited turn as a **new version of it** and answer
## again (G-29).
##
## **It no longer overwrites the message, and that is the point of the tree.**
## Until branching existed this saved in place and did not resend, because
## re-answering would have destroyed every turn that followed (D-BF). Now the old
## version and its replies stay where they are, reachable through the counter on
## the turn, and the edit becomes a sibling with its own continuation.
proc saveEdit(app: AppState) =
  if app.editingMsg.len == 0 or app.streaming: return
  let text = app.editBuffer.text().strip
  var at = -1
  for i, m in app.messages:
    if m.id == app.editingMsg: at = i
  if at < 0 or text.len == 0:
    app.editingMsg = ""
    return

  let parent = app.messages[at].parent
  let role = app.messages[at].role
  let id = saveMessage(app.convId, role, text, parent = parent)
  if id.len == 0:
    app.notice = "could not save that edit"
    return
  app.editingMsg = ""
  # G-31: editing the turn the conversation was named after renames it to match,
  # and `askForTitleConfirmation` decides whether that is asked first. Only the
  # **first** turn, because it is the only one the name was ever taken from.
  let wasFirst = at == 0 and role == rUser
  app.appendTurn(Message(role: role, text: text, id: id, parent: parent))
  if wasFirst:
    if not app.opts.getBool("askForTitleConfirmation"):
      app.retitleConversation(text)
    else:
      let (res, _) = app.open: gui:
        MessageDialog:
          title = "Rename conversation"
          message = "Rename this conversation to \"" & titleFrom(text) & "\"?"
          DialogButton {.addButton.}:
            text = "Keep the old name"
            res = DialogCancel
          DialogButton {.addButton.}:
            text = "Rename"
            res = DialogAccept
            style = [ButtonSuggested]
      if res.kind == DialogAccept: app.retitleConversation(text)
  # Only a user turn is worth re-answering. Editing a reply records a different
  # version of what the model said and stops there — asking it to answer its own
  # answer is not a turn.
  if role == rUser: app.postConversation()

## Function purpose: ask again and keep the previous answer (G-29).
##
## **The old reply is not deleted.** It becomes one version of the turn and the
## new one becomes another, side by side under the same question, which is what
## the counter on the message steps through. Until the tree existed this deleted
## the reply and could only be offered on the last message; both restrictions are
## gone (D-BF).
proc regenerate(app: AppState, idx: int) =
  if app.streaming or idx < 0 or idx >= app.messages.len: return
  if app.messages[idx].role != rAssistant: return
  # Re-post the conversation as it stood *before* this reply. The new answer is
  # then saved against the same parent, which is what makes the two siblings.
  app.messages.setLen(idx)
  app.leaf = if idx > 0: app.messages[^1].id else: ""
  app.postConversation()

## Function purpose: ask the model to carry on from a reply that stopped early.
## The partial text stays in place as the tail of the request **and the request
## says to continue it** (D-BH); the drain timer appends to that same message and
## `umDone` updates its row rather than inserting a second one.
##
## Refused when the turn carries reasoning, which is the Web UI's own guard
## (`ChatMessageAssistant.svelte:460`). Resuming the visible answer of a turn whose
## thinking is held separately asks the model to continue text it did not stop on.
proc continueReply(app: AppState) =
  if app.streaming or app.messages.len == 0: return
  if app.messages[^1].role != rAssistant or app.messages[^1].text.len == 0: return
  if app.messages[^1].thinking.len > 0: return
  app.postConversation(continuing = true)

proc projectsOf(app: AppState, wsId: string): seq[NodeItem] =
  for n in app.projects:
    if n.parent == wsId: result.add n

proc foldersOf(app: AppState, prId: string): seq[NodeItem] =
  for n in app.folders:
    if n.parent == prId: result.add n

proc convsIn(app: AppState, ws, pr, fd: string): seq[ConvItem] =
  for c in app.visibleConvs():
    if c.workspaceId == ws and c.projectId == pr and c.folderId == fd:
      result.add c

## The search box filters notes and assets by the same case-insensitive
## substring it applies to conversations, so one query narrows the whole tree
## rather than only part of it.
proc leavesIn(app: AppState, items: seq[LeafItem],
              ws, pr, fd: string): seq[LeafItem] =
  let q = app.search.strip.toLowerAscii
  for n in items:
    if n.workspaceId == ws and n.projectId == pr and n.folderId == fd and
       (q.len == 0 or n.name.toLowerAscii.contains(q)):
      result.add n

proc rowLabel(app: AppState, entity, id, name: string): Widget =
  ## A tree row: its name, or an Entry while it is being renamed.
  if app.renaming == id:
    gui:
      Entry:
        text = app.renameDraft
        proc changed(t: string) = app.renameDraft = t
        proc activate() = app.commitRename(entity, id)
  else:
    gui:
      Label:
        text = name
        xAlign = 0.0
        ellipsize = EllipsizeEnd

## The particle field, as its own widget rather than owlkettle's `DrawingArea`.
## Declared here for the same reason `SourceCode` is — the `renderable` macro
## emits an unexported type — with the FFI in `canvas.nim`.
##
## The point of the split is the frame clock: owlkettle repaints a `DrawingArea`
## only from its `update` hook, so animating one costs a **full widget-tree
## diff per frame**. This widget is repainted directly by `canvas.queueFrame`.
renderable NeuralCanvas of BaseWidget:
  hooks:
    beforeBuild:
      state.internalWidget = canvas.newArea()

## Closing the tab destroys the widget and ends the `nvim` session with it.
renderable NvimTerminal of BaseWidget:
  hooks:
    beforeBuild:
      state.internalWidget = vte.newNvimTerminal()

## A read-only, syntax-highlighted code block (G-7). Declared here rather than in
## `sourceview.nim` because owlkettle's `renderable` emits an unexported type;
## the FFI stays in that module and this is only the widget around it.
##
## No ScrolledWindow wraps this and none should — owlkettle's never calls
## `set_propagate_natural_height`, which is what collapsed the plain-Label code
## blocks to their header (G-11). The view word-wraps instead.
# Action purpose: the transcript follows a reply as it streams (G-31's
# `disableAutoScroll`). owlkettle's `ScrolledWindow` exposes only `child` — no
# adjustment — so the follow has to be its own renderable, which is the same
# reason `SourceCode` is one.
#
# Three of the four calls needed are already in owlkettle's bindings; only the
# adjustment *getters* are missing, so only those are declared. Imported by name
# rather than wholesale: `gui.nim` already pulls in `owlkettle`, `adw` and
# `cairo`, and a fourth open import invites a collision for no benefit.
# `updateChild` lives in `owlkettle/widgetutils`, which `owlkettle.nim` imports
# but does not re-export — so a renderable declared outside the library has to
# import it directly. `SourceCode` and `NvimTerminal` never needed it because
# neither takes a child widget.
import owlkettle/widgetutils
# `mainloop` is imported by `owlkettle.nim` but not re-exported, the same as
# `widgetutils` above — so `--check`'s build-without-present path has to reach
# for it directly.
from owlkettle/mainloop import setupApp, AppConfig

# Declared rather than imported: pulling it in from `owlkettle/bindings/adw`
# also binds that module's name, which then collides with `owlkettle/adw` and
# makes every `adw.brew` in this file ambiguous. One line avoids that entirely.
proc adw_init() {.importc: "adw_init", cdecl.}

from owlkettle/bindings/gtk import GtkAdjustment, GtkWidget, GType, GValue,
  cbool, GConnectFlags, GdkClipboard, GAsyncResult, GAsyncReadyCallback,
  GError, gdk_display_get_default, gdk_display_get_clipboard,
  G_TYPE_STRING, g_signal_connect_data, g_signal_connect,
  g_signal_handler_disconnect,
  gtk_scrolled_window_new, gtk_scrolled_window_set_child,
  gtk_scrolled_window_get_vadjustment, gtk_adjustment_set_value,
  gtk_frame_new, gtk_frame_set_child,
  # Step 13a's composer owns its own `GtkTextView` and buffer, so it needs the
  # buffer surface directly. **All of it is already in owlkettle's bindings** —
  # checked before declaring anything, per rule 5. The private field that looked
  # like a blocker (`TextBufferObj.gtk`) is not needed at all: the buffer is
  # created here and attached with `set_buffer`, both exported.
  GtkTextBuffer, GtkTextIter, GtkTextTagTable, OwnedGtkString, `$`,
  gtk_text_view_new, gtk_text_view_set_buffer, gtk_text_view_set_editable,
  gtk_text_buffer_new, gtk_text_buffer_set_text, gtk_text_buffer_get_text,
  gtk_text_buffer_get_char_count,
  gtk_text_buffer_get_start_iter, gtk_text_buffer_get_end_iter
# `connect`, `disconnect` and `redraw(EventObj)` — the machinery a renderable
# uses to expose a GTK signal as an owlkettle event, which is what `Entry` does
# and what the first composer did not do. `owlkettle.nim` imports this module
# without re-exporting it, so it is imported here by name.
import owlkettle/widgetutils

proc gtk_adjustment_get_value(a: GtkAdjustment): cdouble {.importc, cdecl.}
proc gtk_adjustment_get_upper(a: GtkAdjustment): cdouble {.importc, cdecl.}
proc gtk_adjustment_get_page_size(a: GtkAdjustment): cdouble {.importc, cdecl.}

# G-41. Declared rather than imported because **none of the three is in
# owlkettle's bindings** — checked before writing them, per rule 5. They are what
# makes a `ScrolledWindow` size to its content instead of collapsing, which
# owlkettle's own `ScrolledWindow` has no way to express: it exposes `child` and
# nothing else.
proc gtk_scrolled_window_set_propagate_natural_height(
  sw: GtkWidget, p: cbool) {.importc, cdecl.}
proc gtk_scrolled_window_set_propagate_natural_width(
  sw: GtkWidget, p: cbool) {.importc, cdecl.}
proc gtk_scrolled_window_set_policy(sw: GtkWidget, h, v: cint) {.importc, cdecl.}
# Step 13a. The composer's height ceiling. Declared here with the other three
# for the same reason — owlkettle's `ScrolledWindow` exposes `child` and nothing
# else — and checked against the bindings first, per rule 5.
proc gtk_scrolled_window_set_max_content_height(
  sw: GtkWidget, h: cint) {.importc, cdecl.}
## G-42. Not in owlkettle's bindings — `hAlign` there is a `Box` *packing*
## property set by the parent, and this has to be the widget's own, because the
## call site inserts every markdown block through one `insert` and a table is the
## only kind that must not stretch.
proc gtk_widget_set_halign(w: GtkWidget, align: cint) {.importc, cdecl.}

const
  ## `GtkPolicyType`. Named rather than passed as bare integers, because
  ## `set_policy(w, 1, 2)` at the call site says nothing about what it does.
  PolicyAutomatic = cint(1)
  PolicyNever = cint(2)
  ## `GtkAlign`. `FILL` is the default and is what made a table stretch — which
  ## is why `ContentScroll` overrides it to `START`. The composer needs it back:
  ## an input field that hugs its content is a field with nothing to click.
  AlignFillG = cint(0)
  AlignStartG = cint(1)

## G-41. Whether the transcript is currently following a reply, and whether the
## reader is sitting at the bottom. **Two separate facts and they must stay
## separate:** `pinned` is "a generation is running and following is enabled",
## `sticky` is "the reader has not scrolled away". Following happens only when
## both hold. Module-level for the reason `droppedPaths` is — a GTK signal
## handler is a bare C function pointer with no place to put state, and there is
## exactly one transcript.
var scrollPinned = false
var scrollSticky = true

## Action purpose: **this is why following used to fall behind and then stop.**
## The old version read the adjustment inside the widget's own update hook, which
## runs *before* GTK has re-measured the newly appended token — so `upper` was
## still the pre-token height and the view was left one token short every frame.
## Once a reply grew faster than the 64px slack, the gap exceeded the threshold,
## the "am I near the bottom?" test began answering no, and following stopped
## altogether for the rest of the generation.
##
## `changed` fires *after* the new content has been measured, which is the only
## moment the real bottom is known.
proc onAdjChanged(adj: GtkAdjustment, data: pointer) {.cdecl.} =
  if not scrollPinned or not scrollSticky: return
  if pointer(adj).isNil: return
  let bottom = gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj)
  if bottom > 0.0 and gtk_adjustment_get_value(adj) < bottom:
    gtk_adjustment_set_value(adj, bottom)

## Action purpose: the reader's intent, recorded whenever the view moves —
## **before** the next block of content changes where the bottom is. Scrolling up
## to re-read something mid-generation must not be yanked back on the next token,
## and scrolling back down must resume following without waiting for the reply to
## end. 64px of slack so "as good as at the bottom" counts as at the bottom.
proc onAdjValue(adj: GtkAdjustment, data: pointer) {.cdecl.} =
  if pointer(adj).isNil: return
  let bottom = gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj)
  scrollSticky = bottom - gtk_adjustment_get_value(adj) < 64.0

## A scrolling transcript that follows a reply while `pin` is set.
##
## **It only follows when the reader is already near the bottom.** That is what
## makes it tolerable rather than infuriating. `disableAutoScroll` turns the whole
## thing off.
renderable AutoScroll of BaseWidget:
  child: Widget
  pin: bool

  hooks:
    beforeBuild:
      state.internalWidget = gtk_scrolled_window_new(
        GtkAdjustment(nil), GtkAdjustment(nil))
    afterBuild:
      # Attached once, on build; GTK owns the handlers from here. The adjustment
      # belongs to the ScrolledWindow and outlives every redraw, so this cannot
      # re-bind per frame the way a `gui:` property would.
      let adj = gtk_scrolled_window_get_vadjustment(state.internalWidget)
      if not pointer(adj).isNil:
        discard g_signal_connect_data(pointer(adj), "changed",
                                      cast[pointer](onAdjChanged), nil, nil,
                                      GConnectFlags(0))
        discard g_signal_connect_data(pointer(adj), "value-changed",
                                      cast[pointer](onAdjValue), nil, nil,
                                      GConnectFlags(0))

  hooks child:
    (build, update):
      state.updateChild(state.child, widget.valChild, gtk_scrolled_window_set_child)

  hooks pin:
    (build, update):
      if widget.hasPin: state.pin = widget.valPin
      # Entering a generation re-arms following even if the reader had scrolled
      # away during the previous one — otherwise a single scroll-up would
      # silently disable it for the rest of the session.
      if state.pin and not scrollPinned: scrollSticky = true
      scrollPinned = state.pin

  adder add:
    if widget.hasChild:
      raise newException(ValueError, "AutoScroll takes one child; use a Box.")
    widget.hasChild = true
    widget.valChild = child

## G-41. A `ScrolledWindow` that **sizes to its content's height** and scrolls
## only sideways, for a table or any other block that must not be clipped to an
## arbitrary height.
##
## **owlkettle's `ScrolledWindow` cannot express this** — it exposes `child` and
## nothing else — and a bare one reports a near-zero minimum height, so it
## collapses whatever is inside it to a stub. That is what made tables render at
## a fixed small size regardless of how many rows they had, and it is the same
## root cause as the G-11 code-block collapse.
##
## **Natural *height* propagates; natural *width* deliberately does not.** A wide
## table must not widen the transcript, so the horizontal axis stays scrollable
## while the vertical axis simply takes the room the rows need.
## Function purpose: apply a `ContentScroll`'s sizing, given its ceiling.
##
## **It exists because a `property` hook alone is silently overwritten, and that
## is not a theory — it is how the composer shipped with no width.** owlkettle's
## generated `build` runs `beforeBuild`, then `buildState` — which is where every
## field's `property` hook runs — and then **`afterBuild` last**
## (`widgetdef.nim`, `genBuild`/`genBuildState`). So a `property` hook that
## configures the widget is undone by an `afterBuild` that configures it
## differently, and `genUpdateState` re-runs a property hook only when the value
## *changes*, which a literal never does. Both hooks therefore call this, and the
## two paths cannot drift.
proc applyScrollSizing(w: GtkWidget, maxHeight: int) =
  gtk_scrolled_window_set_propagate_natural_height(w, cbool(1))
  if maxHeight > 0:
    # Action purpose: a ceiling means this is an **input field**, which needs the
    # opposite of every rule below. An empty `TextView`'s natural width is
    # roughly zero, so hugging the content collapses the composer to a sliver at
    # the left edge with nothing to click — exactly what happened.
    #
    # Vertical scrolls past the ceiling, or the extra lines are simply cut off.
    # Horizontal never scrolls, because the view **wraps** instead — see
    # `DraftView`, which sets the wrap mode owlkettle has no property for.
    gtk_scrolled_window_set_max_content_height(w, maxHeight.cint)
    gtk_scrolled_window_set_propagate_natural_width(w, cbool(0))
    gtk_widget_set_halign(w, AlignFillG)
    gtk_scrolled_window_set_policy(w, PolicyNever, PolicyAutomatic)
  else:
    # G-42, unchanged and still the default. **This was `0` and that is why a
    # table rendered larger than its rows.** G-41 turned natural-width
    # propagation off so a wide table could not widen the whole transcript,
    # which worked — and left the scroller with no width of its own, so the
    # vertical `Box` stretched it to the full column on the default
    # `GTK_ALIGN_FILL`. The collapse was fixed and nothing constrained the
    # result back down.
    #
    # The pair below is the actual answer: **natural width is the content's
    # width, and the widget aligns to the start instead of filling.** GTK then
    # allocates the lesser of the two — the table's own width when it fits, the
    # column's when it does not, with the horizontal scrollbar taking the
    # remainder under `PolicyAutomatic`.
    #
    # G-41's concern does not come back, and it is worth saying why rather than
    # trusting it: the enclosing `AutoScroll` never calls
    # `set_propagate_natural_width` either, so it reports its own small natural
    # width upward and absorbs whatever this one asks for. The window cannot be
    # widened by a table.
    gtk_scrolled_window_set_propagate_natural_width(w, cbool(1))
    gtk_widget_set_halign(w, AlignStartG)
    gtk_scrolled_window_set_policy(w, PolicyAutomatic, PolicyNever)

renderable ContentScroll of BaseWidget:
  child: Widget
  ## Step 13a. A ceiling in pixels, or 0 for none — which is what every
  ## transcript block passes and is why the default keeps their behaviour
  ## exactly as it was. The composer is the one caller that sets it: propagating
  ## natural height makes the box grow with the draft, and without a ceiling it
  ## would grow until it had eaten the transcript.
  ##
  ## **Not a `sizeRequest` and not CSS.** A sizing API sets a *floor*, which is
  ## the opposite of what is wanted, and GTK4 CSS has no `max-height` at all.
  maxHeight: int = 0

  hooks:
    beforeBuild:
      state.internalWidget = gtk_scrolled_window_new(
        GtkAdjustment(nil), GtkAdjustment(nil))
    afterBuild:
      applyScrollSizing(state.internalWidget, state.maxHeight)

  hooks maxHeight:
    property:
      applyScrollSizing(state.internalWidget, state.maxHeight)

  hooks child:
    (build, update):
      state.updateChild(state.child, widget.valChild, gtk_scrolled_window_set_child)

  adder add:
    if widget.hasChild:
      raise newException(ValueError, "ContentScroll takes one child; use a Box.")
    widget.hasChild = true
    widget.valChild = child

# G-30, drag-and-drop. Four protos, declared because **none of them is in
# owlkettle's bindings** — checked before writing them, per rule 5.
# `g_signal_connect_data`, `GValue` and `G_TYPE_STRING` are already there and are
# used rather than re-declared.
#
# Action purpose: **`G_TYPE_STRING`, not `GDK_TYPE_FILE_LIST`.** A file manager
# offers `text/uri-list` for a file drag, and GTK converts that to a string for
# us — so the drop arrives as newline-separated `file://` URIs and needs no
# `GdkFileList` unboxing, which would mean three more protos and a boxed-list
# walk. The trade is that a drop of plain text is also accepted, and that is
# handled below rather than being a defect.
type GtkDropTarget = distinct pointer

proc gtk_drop_target_new(typ: GType, actions: cuint): GtkDropTarget
  {.importc, cdecl.}
proc gtk_widget_add_controller(w: GtkWidget, c: GtkDropTarget)
  {.importc, cdecl.}
proc g_value_get_string(v: ptr GValue): cstring {.importc, cdecl.}

const GdkActionCopy = 1.cuint

# G-30, paste. **Three protos, and only three** — `GdkClipboard`,
# `GAsyncResult`, `GAsyncReadyCallback`, `gdk_display_get_default` and
# `gdk_display_get_clipboard` are all already in owlkettle's bindings and are
# imported rather than re-declared (rule 5).
#
# Action purpose: the pasted image is **written to a PNG and then handed to the
# same queue a dropped file uses**. That is deliberate: `gdk_texture_save_to_png`
# already exists, so this needs no pixel unpacking, and the attachment then
# takes exactly the path a picked or dropped file takes — one implementation,
# three ways in.
type GdkTexture = distinct pointer

proc gdk_clipboard_read_texture_async(c: GdkClipboard, cancellable: pointer,
                                      cb: GAsyncReadyCallback, data: pointer)
  {.importc, cdecl.}
proc gdk_clipboard_read_texture_finish(c: GdkClipboard, res: GAsyncResult,
                                       err: ptr GError): GdkTexture
  {.importc, cdecl.}
proc gdk_texture_save_to_png(t: GdkTexture, filename: cstring): cbool
  {.importc, cdecl.}

var
  ## Where a pasted image is written. Set once at startup, because the clipboard
  ## callback is a bare C function and cannot be given the paths object.
  pasteDir = ""

proc onPasted(obj: pointer, res: GAsyncResult, data: pointer) {.cdecl.} =
  var err = GError(nil)
  let tex = gdk_clipboard_read_texture_finish(GdkClipboard(obj), res, err.addr)
  # No image on the clipboard is the ordinary case, not a failure: the button is
  # always there and most of the time the clipboard holds text.
  if pointer(tex).isNil or pasteDir.len == 0: return
  let file = pasteDir / "pasted-" & $epochTime().int & ".png"
  try:
    createDir(pasteDir)
    if gdk_texture_save_to_png(tex, file.cstring) != cbool(0):
      droppedPaths.add file
  except CatchableError: discard

proc pasteImage() =
  let display = gdk_display_get_default()
  if pointer(display).isNil: return
  let clip = gdk_display_get_clipboard(display)
  # `pointer(clip)` and not `clip.isNil`: the `isNil` borrow lives in the
  # bindings module and this file imports it by name, so the operator is not in
  # scope here — the same note `AutoScroll` carries for `GtkAdjustment`.
  if pointer(clip).isNil: return
  gdk_clipboard_read_texture_async(clip, nil, onPasted, nil)

proc onDrop(target: GtkDropTarget, value: ptr GValue, x, y: cdouble,
            data: pointer): cbool {.cdecl.} =
  if value.isNil: return cbool(0)
  let raw = g_value_get_string(value)
  if raw.isNil: return cbool(0)
  for line in ($raw).splitLines:
    let t = line.strip
    # Only a file URI is an attachment. Dropped plain text is not silently
    # turned into a file, because a text drop is a different intention.
    if t.startsWith("file://"): droppedPaths.add pipeline.uriToPath(t)
  cbool(1)

## A drop target over the chat column (G-30), which is the Web UI's
## `ChatScreenDragOverlay`. A renderable for the reason `AutoScroll` is one:
## owlkettle exposes no way to reach a widget's `GtkWidget` from a `gui:` block,
## and a controller has to be attached to one.
renderable DropZone of BaseWidget:
  child: Widget

  hooks:
    beforeBuild:
      # A Frame, not a Box: `updateChild` needs a real *setter*, and
      # `gtk_box_append` only ever adds — swapping the child would stack them.
      # The frame border is removed by `.drop-zone` in `theme.nim`.
      state.internalWidget = gtk_frame_new(nil)
    afterBuild:
      # Attached once, on build. GTK owns the controller from here.
      let target = gtk_drop_target_new(G_TYPE_STRING, GdkActionCopy)
      discard g_signal_connect_data(pointer(target), "drop",
                                    cast[pointer](onDrop), nil, nil,
                                    GConnectFlags(0))
      gtk_widget_add_controller(state.internalWidget, target)

  hooks child:
    (build, update):
      state.updateChild(state.child, widget.valChild, gtk_frame_set_child)

  adder add:
    if widget.hasChild:
      raise newException(ValueError, "DropZone takes one child; use a Box.")
    widget.hasChild = true
    widget.valChild = child

# Step 13a. The composer's own widget. Four protos: the key controller's three,
# and the wrap mode. Everything else it needs — `gtk_text_view_new`, the buffer
# surface, `g_signal_connect` — is already in owlkettle's bindings and is
# imported rather than re-declared (rule 5).
type GtkEventController = distinct pointer

proc gtk_event_controller_key_new(): GtkEventController {.importc, cdecl.}
proc gtk_event_controller_set_propagation_phase(c: GtkEventController,
                                                phase: cint) {.importc, cdecl.}
proc gtk_widget_add_controller(w: GtkWidget, c: GtkEventController)
  {.importc, cdecl.}
# owlkettle's `TextView` has no wrap property — checked in `widgets.nim`, per
# rule 5 — and a GtkTextView defaults to `GTK_WRAP_NONE`, so a long draft
# scrolls sideways instead of wrapping. This view is built here, so it is set
# directly on the widget rather than found by walking a tree.
proc gtk_text_view_set_wrap_mode(v: GtkWidget, mode: cint) {.importc, cdecl.}
# `GtkScrollable`'s vertical policy. It defaults to `GTK_SCROLL_MINIMUM`
# (`gtkenums.h`, value 0), under which a scrolled window negotiates against the
# child's *minimum* height — so `propagate-natural-height` has nothing to grow
# and the box scrolls instead of expanding. That is one of the two candidates
# for the composer not resizing, and setting it costs one call.
proc gtk_scrollable_set_vscroll_policy(s: GtkWidget, policy: cint)
  {.importc, cdecl.}

const
  PhaseCapture = 1.cint
  ## `GTK_WRAP_WORD_CHAR` — break on a word, and inside a word when one word is
  ## wider than the box. The same value `sourceview.nim` uses for a code block.
  WrapWordChar = 3.cint
  ## `GTK_SCROLL_NATURAL`.
  ScrollNatural = 1.cint

## Function purpose: the composer's `GtkTextBuffer` text, as a Nim string.
proc bufferText(buffer: GtkTextBuffer): string =
  var a, b: GtkTextIter
  gtk_text_buffer_get_start_iter(buffer, a.addr)
  gtk_text_buffer_get_end_iter(buffer, b.addr)
  $gtk_text_buffer_get_text(buffer, a.addr, b.addr, cbool(1))

## The chat composer (Step 13a). **A renderable that owns its own `GtkTextView`
## and buffer, rather than owlkettle's `TextView`** — and that is the whole
## repair, not a stylistic preference.
##
## owlkettle's `TextView` declares no events at all, so nothing re-ran `view`
## when the user typed: the placeholder never cleared, and the widget could only
## be configured by walking the tree to find it. This exposes the buffer's
## `changed` signal as an owlkettle event exactly the way `Entry` does
## (`widgets.nim`, `Entry`'s `connectEvents`), which puts the draft back into
## ordinary state and makes every one of those problems disappear rather than be
## worked around.
renderable DraftView of BaseWidget:
  text: string
  buffer {.private, onlyState.}: GtkTextBuffer
  ## The key controller. Held in state because it is created once and GTK owns
  ## it, while the handler bound to it is re-bound on every update — see
  ## `connectEvents`.
  keyCtl {.private, onlyState.}: GtkEventController

  proc changed(text: string) ## Every keystroke, so the draft stays in state.
  proc submit()              ## Enter, per `composer.actionFor`.

  hooks:
    beforeBuild:
      # The buffer is made here and attached, rather than taken from owlkettle's
      # `TextBuffer` — whose `gtk` field is private. Two exported calls replace
      # the field that looked like a blocker.
      state.buffer = gtk_text_buffer_new(GtkTextTagTable(nil))
      state.internalWidget = gtk_text_view_new()
      gtk_text_view_set_buffer(state.internalWidget, state.buffer)
      # Action purpose: the key controller is created **here**, not in
      # `afterBuild`, because `connectEvents` runs inside `buildState` — before
      # `afterBuild` — and needs it. GTK owns the controller from the moment it
      # is added; only the *handler* on it is re-bound per update, below.
      #
      # CAPTURE phase so Enter is seen *before* the view inserts a newline; in
      # the bubble phase the newline is already in the buffer by then.
      state.keyCtl = gtk_event_controller_key_new()
      gtk_event_controller_set_propagation_phase(state.keyCtl, PhaseCapture)
      gtk_widget_add_controller(state.internalWidget, state.keyCtl)
    afterBuild:
      gtk_text_view_set_wrap_mode(state.internalWidget, WrapWordChar)
      # So the enclosing `ContentScroll`'s natural-height propagation has a
      # growing number to propagate.
      gtk_scrollable_set_vscroll_policy(state.internalWidget, ScrollNatural)
    connectEvents:
      # **Both handlers are bound here, and that is the whole point of this
      # hook.** owlkettle replaces `state.changed` and `state.submit` with fresh
      # `EventObj`s on *every* update (`genUpdateState`), and ARC frees the old
      # ones — so a handler bound once, in `afterBuild`, holds a pointer that is
      # dead after the first redraw. **That is exactly what crashed:** `submit`
      # was bound in `afterBuild`, every keystroke redrew and replaced the
      # object, and the first Enter dereferenced freed memory — SIGBUS, with
      # `keyCallback` as frame 0 of the core. `disconnectEvents` below and this
      # hook run as a pair on every update, which is what keeps them live.
      #
      # The callbacks are declared **inside the hook**, as `Entry` does, because
      # the generated state type does not exist until the renderable is
      # complete — a proc above it cannot name `DraftViewState`.
      proc changedCallback(buffer: GtkTextBuffer,
                           data: ptr EventObj[proc (text: string)]) {.cdecl.} =
        let text = bufferText(buffer)
        DraftViewState(data[].widget).text = text
        data[].callback(text)
        data[].redraw()

      proc keyCallback(c: GtkEventController, keyval, keycode: cuint,
                       modifiers: cuint,
                       data: ptr EventObj[proc ()]): cbool {.cdecl.} =
        case composer.actionFor(keyval.uint32, modifiers.uint32)
        of composer.caSend:
          if data.isNil or data[].callback.isNil: return cbool(0)
          data[].callback()
          data[].redraw()
          # TRUE: handled here, so the newline is never inserted as well.
          cbool(1)
        # Shift+Enter and everything else are GTK's: the view inserts the
        # newline itself and needs no help doing it.
        of composer.caNewline, composer.caPass: cbool(0)

      # Connected to the **buffer**, not the widget, because that is what emits
      # `changed` — so `state.connect`, which always uses `internalWidget`, is
      # not usable here and its two lines are reproduced instead.
      if not state.changed.isNil:
        state.changed.widget = state
        state.changed.handler = g_signal_connect(
          pointer(state.buffer), "changed", cast[pointer](changedCallback),
          state.changed[].addr)
      # And to the controller, for the same reason and with the same lifetime.
      if not state.submit.isNil:
        state.submit.widget = state
        state.submit.handler = g_signal_connect(
          pointer(state.keyCtl), "key-pressed", cast[pointer](keyCallback),
          state.submit[].addr)
    disconnectEvents:
      if not state.changed.isNil and state.changed.handler > 0:
        g_signal_handler_disconnect(pointer(state.buffer),
                                    state.changed.handler)
        state.changed.handler = 0
      if not state.submit.isNil and state.submit.handler > 0:
        g_signal_handler_disconnect(pointer(state.keyCtl),
                                    state.submit.handler)
        state.submit.handler = 0

  hooks text:
    property:
      # Action purpose: **compare before writing, and this is not defensive
      # padding.** `gtk_text_buffer_set_text` replaces the contents and drops the
      # cursor at the start, so writing on every redraw would yank the caret to
      # the beginning while the user was typing. `Entry` needs no such guard
      # because `GtkEditable` preserves the position; a buffer does not.
      if bufferText(state.buffer) != state.text:
        gtk_text_buffer_set_text(state.buffer, state.text.cstring,
                                 state.text.len.cint)
    read:
      state.text = bufferText(state.buffer)

renderable SourceCode of BaseWidget:
  code: string
  language: string
  buffer {.private, onlyState.}: GtkSourceBuffer

  hooks:
    beforeBuild:
      let (view, buffer) = newSourceWidget()
      state.buffer = buffer
      state.internalWidget = view

  hooks code:
    property:
      setSourceText(state.buffer, state.code)

  hooks language:
    property:
      setSourceLanguage(state.buffer, state.language)

proc copyToClipboard(text: string) =
  try:
    let p = startProcess("wl-copy", args = [text], options = {poUsePath})
    discard p.waitForExit()
    p.close()
  except CatchableError: discard

const
  ## Above this many lines a code block is capped and scrolls inside itself, so
  ## one long answer cannot push the rest of the transcript off screen. Roughly a
  ## screenful, which is the point at which scrolling the block beats scrolling
  ## the conversation.
  CodeCapLines = 24
  CodeCapPx = 360

## Function purpose: render one markdown block as a widget. Extracted from
## `messageBody` (8c-3) so a note is shown through the transcript's own
## renderer — tables, capped code blocks, the copy button and all — instead of
## growing a second copy beside it that drifts. **`messageBody`'s child
## structure is unchanged**: it still contributes exactly one widget per block,
## in the same order, so nothing about how owlkettle diffs a transcript moves.
##
## The `{.expand: false.}` annotations live at the call sites and not here,
## because they are the parent's adder properties rather than the widget's.
proc mdBlock(app: AppState, b: markdown.Block): Widget =
  if b.kind == bkText:
    # A-48's activation was attempted here as a `MarkupLabel` renderable owning
    # its own `GtkLabel` with `activate-link` connected, and **reverted: it
    # segfaults on the first `view` build.** Not the markup — four builds with
    # byte-identical markup showed an empty-bodied handler is safe and one
    # touching `app` is fatal, dying at `b.text.countLines` in the *code-block*
    # branch. **A link therefore still renders and its click is unhandled.**
    # See `TODOS.md` A-48; the allowlist and the markup assertions are unaffected.
    gui:
      Label:
        text = b.text
        useMarkup = true
        xAlign = 0.0
        wrap = true
        style = [StyleClass("msg-body")]
  elif b.kind == bkTable:
    # G-34. **A real `Grid`, because Pango has no table.** A model asked to
    # compare things answers with one, and it used to render as raw pipes.
    # It scrolls horizontally inside itself: a wide table must not widen
    # the whole transcript, and a `Label` cannot be relied on to shrink.
    #
    # G-41: **`ContentScroll`, not `ScrolledWindow`.** A bare owlkettle
    # `ScrolledWindow` reports a near-zero minimum height, so it clipped
    # every table to a stub no matter how many rows it had — the same
    # collapse as G-11. `ContentScroll` takes the height the rows need and
    # keeps the horizontal scrolling that the width argument above wants.
    gui:
      ContentScroll:
        style = [StyleClass("md-table")]
        Grid(rowSpacing = 2, columnSpacing = 16, margin = 8):
          for rowIdx, row in b.rows:
            for colIdx, cell in row:
              Label {.x: colIdx, y: rowIdx.}:
                text = cell
                useMarkup = true
                # Row 0 is the header; every other row takes the column's
                # own alignment from the `:---:` markers.
                xAlign = (if colIdx < b.aligns.len: b.aligns[colIdx]
                          else: 0.0)
                wrap = true
                style = [StyleClass(
                  if rowIdx == 0: "md-th" else: "md-td")]
  else:
    gui:
      Frame:
        style = [StyleClass("code-block")]
        Box(orient = OrientY, spacing = 4, margin = 8):
          Box(orient = OrientX) {.expand: false.}:
            Label {.expand: false, hAlign: AlignFill.}:
              text = (if b.lang.len > 0: b.lang else: "code")
              xAlign = 0.0
              style = [StyleClass("code-lang")]
            Button {.expand: false.}:
              icon = "edit-copy-symbolic"
              tooltip = "Copy"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = copyToClipboard(b.text)
          # Action purpose: **the cap, and why it is a `sizeRequest` rather
          # than CSS.** GTK4 CSS has no `max-height` — only `min-*` — so a
          # long block is capped by putting it in a ScrolledWindow with an
          # explicit height (G-31's `fullHeightCodeBlocks`).
          #
          # That is safe here for the same reason it was fatal at G-11:
          # owlkettle's ScrolledWindow never calls
          # `set_propagate_natural_height`, so it reports a near-zero minimum
          # and collapses a child to nothing — **unless it is given a height
          # to hold**, which is exactly what a cap is. An uncapped block
          # still gets no ScrolledWindow at all.
          #
          # Only long blocks are wrapped: `sizeRequest` is a *minimum*, so
          # capping a four-line snippet would pad it to 360px of empty
          # scroller instead of shrinking anything.
          if b.text.countLines > CodeCapLines and
             not app.opts.getBool("fullHeightCodeBlocks"):
            ScrolledWindow {.expand: false.}:
              sizeRequest = (-1, CodeCapPx)
              style = [StyleClass("code-capped")]
              SourceCode:
                code = b.text
                language = b.lang
                style = [StyleClass("code-body")]
          else:
            SourceCode {.expand: false.}:
              code = b.text
              language = b.lang
              style = [StyleClass("code-body")]

proc messageBody(app: AppState, m: Message): Widget =
  ## User turns are plain text and assistant output is markdown — unless
  ## `renderUserContentAsMarkdown` is set, which is the Web UI's own option and
  ## the reason the two branches share the renderer below rather than the user
  ## branch returning early in every case (G-31).
  ##
  ## The raw-output toggle short-circuits both: it exists to show the exact text
  ## the model produced, so it must bypass the renderer rather than configure it
  ## — which is how you tell a markdown bug from a model that really wrote that.
  let raw = m.id.len > 0 and app.rawMsgs.getOrDefault(m.id, false)
  if raw or (m.role == rUser and
             not app.opts.getBool("renderUserContentAsMarkdown")):
    return gui:
      Label:
        text = m.text
        xAlign = 0.0
        wrap = true
        style = [StyleClass(if raw: "code-body" else: "msg-body")]

  gui:
    Box(orient = OrientY, spacing = 8):
      # G-30: a sent turn shows what was attached to it. Read from the row's
      # `extra`, so it survives a restart and is the same list the request
      # carried — not a copy kept beside it that could disagree.
      if m.extra.len > 0:
        Box(orient = OrientX, spacing = 6) {.expand: false.}:
          for a in attachmentsOf(m):
            Box(orient = OrientX, spacing = 4) {.expand: false.}:
              style = [StyleClass("attach-chip")]
              if a.kind == "IMAGE":
                let pb = app.attachmentPixbuf(a, 64)
                if not pb.isNil:
                  Button {.expand: false.}:
                    tooltip = "Preview " & a.name
                    style = [ButtonFlat, StyleClass("attach-thumb")]
                    proc clicked() =
                      app.previewAtt = a
                    Picture:
                      pixbuf = pb
                      contentFit = ContentContain
              Label {.expand: false.}:
                text = (if a.kind == "IMAGE": "🖼 " else: "📄 ") & a.name
                style = [StyleClass("settings-help")]
      for b in mdMemo.blocksFor(m.id, m.text):
        insert(app.mdBlock(b)) {.expand: false.}

## Function purpose: the numbers the Web UI shows under a reply (G-33) — tokens
## generated and their rate, tokens read in, how much of the context window the
## turn used and what is left of it, and which model produced it.
##
## **Built as one string rather than a row of badge widgets, deliberately.** The
## transcript rebuilds every message on every token of a stream, and
## `timings_per_token` means that is now several times a second with live
## numbers; four extra widgets per message inside that loop is the cost
## `canvas.queueFrame` exists to avoid. One `Label` whose text changes is the
## cheap shape.
##
## Empty until the server has actually reported something, so a message from
## before this existed shows nothing rather than a row of zeroes.
proc statsLine(app: AppState, m: Message): string =
  let t = m.timings
  # 12d-3. **Tested before the timings guard, not after it.** A cached reply is
  # replayed from stored bytes, so its `timings` are whatever the original turn
  # reported — and a hit stored before `timings_per_token` was asked for carries
  # none at all, which would return "" here and hide the badge on exactly the
  # turns it exists to explain.
  if m.cacheHit and t.predictedN <= 0 and t.promptN <= 0: return "cached"
  if t.predictedN <= 0 and t.promptN <= 0: return ""
  var parts: seq[string]
  if m.cacheHit: parts.add "cached"

  if t.predictedN > 0:
    var s = $t.predictedN & " out"
    if t.predictedMs > 0:
      s.add "  " & formatFloat(t.predictedN.float * 1000.0 / t.predictedMs,
                               ffDecimal, 1) & " tok/s"
      s.add "  " & formatFloat(t.predictedMs / 1000.0, ffDecimal, 1) & "s"
    parts.add s

  if t.promptN > 0:
    # `cache_n` is the part of the prompt the server did not have to read again.
    # Worth showing because a turn that feels slow is nearly always a cold
    # prompt rather than slow generation, and those two look identical without
    # it.
    var s = $t.promptN & " in"
    if t.cacheN > 0: s.add " (" & $t.cacheN & " cached)"
    if t.promptMs > 0:
      s.add "  " & formatFloat(t.promptN.float * 1000.0 / t.promptMs,
                               ffDecimal, 0) & " tok/s"
    parts.add s

  # Only ever with a real figure from `/props`. Deriving the window from
  # `CTX_SIZE` would overstate what is left by the slot count, and again by
  # whatever the model's training context capped it to.
  if app.ctxSize > 0:
    # A-5. **`cacheN` is part of the prompt and was omitted.** `prompt_n` is
    # only what this request had to *evaluate*; the prefix the server reused is
    # reported separately as `cache_n` and occupies the context just the same.
    # Jenova passes `--cache-prompt` on every start, so reuse is the normal
    # case and the error was exactly `cache_n` — which grows with the
    # conversation, making the figure least wrong when nobody cares and most
    # wrong when a USER consults it to decide whether to start a new chat.
    # `chat.svelte.ts` sums the same three, so this is parity as well as a fix.
    let used = t.cacheN + t.promptN + t.predictedN
    parts.add $used & "/" & $app.ctxSize & " ctx  " &
              $max(0, app.ctxSize - used) & " left"

  let model = (if m.model.len > 0: m.model else: app.serverModel)
  # G-31: the identifier in full when asked for. The shortened form is the
  # default because a model path is long and the statistics line is one row; the
  # full one is what distinguishes two quantisations of the same model.
  if model.len > 0:
    parts.add (if app.opts.getBool("showRawModelNames"): model
               else: model.extractFilename.changeFileExt(""))

  parts.join("    ")

## Function purpose: wrap `statsLine` in a widget, so it is built **once** per
## message per redraw rather than once to test it and again to display it. With
## `timings_per_token` the transcript redraws several times a second, so that
## difference is the whole reason this is a proc.
##
## An empty `Box` is what a message with no statistics gets: a Box with no
## children requests no size, which is the same reason the document panel is one.
proc messageStats(app: AppState, idx: int, m: Message): Widget =
  # G-31: two settings, and they are not the same one. `showMessageStats`
  # governs the footer under a finished reply. `keepStatsVisible` governs
  # whether it survives the end of generation when that footer is off — the
  # live numbers are worth watching during a generation even to someone who
  # does not want them afterwards, which is the distinction the Web UI draws
  # between its processing indicator and its per-message footer.
  let live = app.streaming and idx == app.messages.len - 1
  let show = app.opts.getBool("showMessageStats") or live or
             app.opts.getBool("keepStatsVisible")
  let line = (if show: app.statsLine(m) else: "")
  gui:
    Box(orient = OrientY):
      if line.len > 0:
        Label {.expand: false.}:
          text = line
          xAlign = 0.0
          wrap = true
          style = [StyleClass("dim-note")]

## Function purpose: the toolbar under a message (G-28). The Web UI gives every
## message five actions; this window had none — one copy button on code blocks
## was the whole of it, so there was no way to correct a mistake short of
## starting the conversation again.
##
## **Regenerate and continue are offered on the last message only, and edit does
## not resend.** Both restrictions are the same restriction: re-answering a turn
## that has turns after it produces an alternative version of all of them, which
## is a branch (`PLANS.md` Step 3). Offering it before the tree exists would
## destroy the following turns rather than letting you choose between them.
##
## Copy has no id requirement — text is text. Everything else is hidden until the
## message is a row, because there is nothing to act on until then.
## Function purpose: copy a conversation into a new one, up to and including one
## message (Step 13b, and P-A6 for the `atMessageId` half).
##
## Action purpose: **`api.forkConversation` has taken an `atMessageId` since it
## was written and this window has only ever passed an empty one.** With no
## message named it forks from the conversation's own read position, which is
## what the sidebar's fork button means; naming a message is what the Web UI's
## per-message fork does, and it is the difference between "carry on from here"
## and "carry on from wherever I happened to be". The parameter was already
## there — only a caller was missing.
##
## Opened rather than merely listed: a fork is made in order to carry on in it,
## and leaving the user on the original is the opposite of what they asked for.
proc forkFrom(app: AppState, sourceId, atMessageId: string) =
  # Action purpose: **the guard is here and not on the buttons, because one of
  # the two callers had no guard at all.** The per-message fork is drawn
  # `sensitive = not app.streaming`; the sidebar's fork row is not, so mid-
  # generation it reached this proc, created the fork in the database, and then
  # `selectConversation` refused to open it — leaving a conversation the user
  # never sees and a "forked" notice for something that did not appear to
  # happen. Refusing at the one place both callers pass through cannot drift
  # the way two `sensitive` expressions can.
  if app.streaming: return
  let (ok, newId, msg) = api.forkConversation(sourceId, atMessageId, "")
  if not ok:
    app.notice = "fork failed: " & msg
    return
  app.convs = listConversations()
  app.reloadTree()
  app.selectConversation(newId)
  app.notice = (if atMessageId.len > 0: "forked from this message" else: "forked")

proc messageActions(app: AppState, idx: int, m: Message): Widget =
  let isLast = idx == app.messages.len - 1
  # The versions of this turn (G-29). One means it was never branched, and the
  # control is not drawn — a "1 of 1" counter on every message is noise.
  let sibs = (if m.id.len > 0: api.siblingsIn(app.edges, m.id) else: @[])
  let at = (if sibs.len > 1: sibs.find(m.id) else: -1)
  gui:
    Box(orient = OrientX, spacing = 4):
      if at >= 0:
        Button {.expand: false.}:
          icon = "go-previous-symbolic"
          tooltip = "Previous version"
          sensitive = not app.streaming
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() = app.switchSibling(m.id, -1)
        Label {.expand: false.}:
          text = $(at + 1) & "/" & $sibs.len
          style = [StyleClass("dim-note")]
        Button {.expand: false.}:
          icon = "go-next-symbolic"
          tooltip = "Next version"
          sensitive = not app.streaming
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() = app.switchSibling(m.id, 1)
      Button {.expand: false.}:
        icon = "edit-copy-symbolic"
        tooltip = "Copy"
        style = [ButtonFlat, StyleClass("row-btn")]
        # W-01: `copyTextAttachmentsAsPlainText` was drawn, validated, saved and
        # read by nothing. What it decides lives in `pipeline.copyTextFor`, below
        # the widget layer, so it is assertable without a window.
        proc clicked() =
          copyToClipboard(pipeline.copyTextFor(
            m.text, m.attachmentsOf(),
            app.opts.getBool("copyTextAttachmentsAsPlainText")))
      # P-A6. The Web UI forks from any message; this window could only fork a
      # whole conversation from its sidebar row, so exploring an alternative
      # from halfway up a transcript meant forking the lot and deleting
      # forward.
      if m.id.len > 0:
        Button {.expand: false.}:
          icon = "edit-cut-symbolic"
          tooltip = "Fork from here — copy this conversation up to this " &
                    "message into a new one"
          sensitive = not app.streaming
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() = app.forkFrom(app.convId, m.id)
      # G-31, Developer: off by default and opt-in, because it is a debugging
      # control — the Web UI gates it behind the same switch for the same reason.
      if app.opts.getBool("showRawOutputSwitch") and m.id.len > 0:
        Button {.expand: false.}:
          icon = "format-text-rich-symbolic"
          tooltip = (if app.rawMsgs.getOrDefault(m.id, false):
                       "Show formatted" else: "Show raw text")
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() =
            app.rawMsgs[m.id] = not app.rawMsgs.getOrDefault(m.id, false)
      if m.role == rUser and m.id.len > 0:
        Button {.expand: false.}:
          icon = "document-edit-symbolic"
          tooltip = "Edit"
          sensitive = not app.streaming
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() = app.startEdit(idx)
      if m.role == rAssistant and m.id.len > 0:
        Button {.expand: false.}:
          icon = "view-refresh-symbolic"
          tooltip = "Regenerate"
          sensitive = not app.streaming
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() = app.regenerate(idx)
        # Continue extends a reply in place rather than making another version of
        # it, so it stays on the last turn: there is nothing to extend in the
        # middle of a conversation that already has an answer after it. **And it
        # is hidden on a turn that carries reasoning**, which is the Web UI's own
        # guard — see `continueReply` and D-BH.
        #
        # **D-BH's deliberate divergence ends here.** It was shown
        # unconditionally because with no settings surface an opt-in flag would
        # have made the feature unreachable rather than optional. There is a
        # settings surface now, so it is opt-in and off by default, matching the
        # Web UI's `enableContinueGeneration: false` (G-31).
        if isLast and m.thinking.len == 0 and
           app.opts.getBool("enableContinueGeneration"):
          Button {.expand: false.}:
            icon = "media-playback-start-symbolic"
            tooltip = "Continue"
            sensitive = not app.streaming
            style = [ButtonFlat, StyleClass("row-btn")]
            proc clicked() = app.continueReply()
      if m.id.len > 0:
        Button {.expand: false.}:
          icon = "user-trash-symbolic"
          tooltip = "Delete"
          sensitive = not app.streaming
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() = app.deleteMessage(idx)

## Function purpose: the fullscreen control, and it lives in the bottom action
## row rather than the HeaderBar **because GTK4 hides a titlebar set through
## `gtk_window_set_titlebar` while the window is fullscreened**. The menu item
## added at 19:02 went with it, so entering fullscreen removed the only way to
## leave — the top of the window is cut off and the control is inside the part
## that vanished. This button is always mapped, which is also what makes its
## `F11` accelerator reachable: owlkettle attaches the shortcut controller to the
## button itself at `GTK_SHORTCUT_SCOPE_MANAGED`, so a popover child would only
## answer while the popover is open.
proc fullscreenButton(app: AppState): Widget =
  gui:
    Button:
      icon = (if app.fullscreen: "view-restore-symbolic"
              else: "view-fullscreen-symbolic")
      tooltip = (if app.fullscreen: "Leave fullscreen (F11)" else: "Fullscreen (F11)")
      style = [ButtonFlat, StyleClass("row-btn")]
      proc clicked() = app.fullscreen = not app.fullscreen

## Function purpose: copy a conversation's current branch into a new one
## (Step 13b). The work is `api.forkConversation`; this is the surface it never
## had — `forkedFromConversationId` and its whole delete cascade already existed
## and nothing in the program could create the relationship.
##
## The fork is taken at the conversation's own `currNode`, which is the turn that
## conversation is being read at — so forking the one on screen forks what is on
## screen, and forking another row forks where that row was left.
## The sidebar's fork: no message named, so `api.forkConversation` forks from the
## conversation's own read position. One implementation with the per-message
## fork above it (P-A6) rather than two that could drift.
proc forkConversationRow(app: AppState, id: string) =
  app.forkFrom(id, "")

proc convRow(app: AppState, c: ConvItem): Widget =
  gui:
    Box(orient = OrientX, spacing = 2):
      # hAlign fill rather than expand: hexpand propagates up the tree and would
      # make the whole sidebar demand half the window.
      Button {.expand: false, hAlign: AlignFill.}:
        style = [ButtonFlat, StyleClass("row-btn"),
                 StyleClass(if c.id == app.convId: "conv-active" else: "conv-idle")]
        proc clicked() = app.selectConversation(c.id)
        insert(app.rowLabel("conversations", c.id, c.name))
      Button {.expand: false.}:
        icon = "document-edit-symbolic"
        tooltip = "Rename"
        style = [ButtonFlat, StyleClass("row-btn")]
        proc clicked() =
          app.renaming = c.id
          app.renameDraft = c.name
      # Step 13b.
      Button {.expand: false.}:
        icon = "edit-copy-symbolic"
        tooltip = "Fork — copy this conversation's current branch into a new one"
        style = [ButtonFlat, StyleClass("row-btn")]
        proc clicked() = app.forkConversationRow(c.id)
      Button {.expand: false.}:
        icon = "user-trash-symbolic"
        tooltip = "Delete"
        style = [ButtonFlat, StyleClass("row-btn")]
        proc clicked() = app.deleteNode("conversations", c.id)

## Function purpose: a note or file-asset row. Same shape as `convRow` — an
## activating button, a rename and a delete — but a file asset has no editor to
## open, because its content may be binary; it is listed, renamed and deleted.
proc leafRow(app: AppState, entity: string, n: LeafItem): Widget =
  gui:
    Box(orient = OrientX, spacing = 2):
      Button {.expand: false, hAlign: AlignFill.}:
        sensitive = entity == "notes"
        style = [ButtonFlat, StyleClass("row-btn"),
                 StyleClass(if entity == "notes" and n.id == app.openNote:
                              "conv-active" else: "conv-idle")]
        proc clicked() =
          if entity == "notes": app.openNoteGuarded(n.id)
        insert(app.rowLabel(entity, n.id,
                            (if entity == "notes": "▤  " else: "◫  ") & n.name))
      Button {.expand: false.}:
        icon = "document-edit-symbolic"
        tooltip = "Rename"
        style = [ButtonFlat, StyleClass("row-btn")]
        proc clicked() =
          app.renaming = n.id
          app.renameDraft = n.name
      Button {.expand: false.}:
        icon = "user-trash-symbolic"
        tooltip = "Delete"
        style = [ButtonFlat, StyleClass("row-btn")]
        proc clicked() = app.deleteNode(entity, n.id)

proc nodeTools(app: AppState, entity, id: string, ws, pr, fd: string,
               makes: seq[(string, string)]): Widget =
  ## The action strip under a container: rename it, delete it, and create the
  ## things it can hold. `ws`/`pr`/`fd` are the container's full ancestry, not
  ## just its own id — a chat or note is placed by all three, and one carrying
  ## only its immediate parent is saved and then never matched by the tree.
  gui:
    Box(orient = OrientX, spacing = 2):
      insert(app.rowLabel(entity, id, "")) {.expand: false, hAlign: AlignFill.}
      for m in makes:
        Button {.expand: false.}:
          icon = (case m[0]
                  of "chat": "chat-message-new-symbolic"
                  of "note": "document-new-symbolic"
                  else: "folder-new-symbolic")
          tooltip = (case m[0]
                     of "chat": "New chat here"
                     of "note": "New note here"
                     else: "New " & m[0])
          style = [ButtonFlat, StyleClass("row-btn")]
          proc clicked() =
            case m[0]
            of "chat": app.newChat(ws, pr, fd)
            of "note": app.createNote(ws, pr, fd)
            else: app.createNode(m[0], m[1], id)
      Button {.expand: false.}:
        icon = "document-edit-symbolic"
        tooltip = "Rename"
        style = [ButtonFlat, StyleClass("row-btn")]
        proc clicked() =
          app.renaming = id
          app.renameDraft = ""
      Button {.expand: false.}:
        icon = "user-trash-symbolic"
        tooltip = "Delete"
        style = [ButtonFlat, StyleClass("row-btn")]
        proc clicked() = app.deleteNode(entity, id)

## Function purpose: the main area of the chat column — the Neovim page, the note
## editor, or the transcript. Extracted from `view` so the `Paned` that G-25 adds
## can take it as one child without reindenting the whole transcript, and so the
## editor/transcript switch has one place rather than being read out of a deeply
## nested tree.
proc mainArea(app: AppState): Widget =
  ## **The Box is not decoration and must not be removed.** `Paned` asserts that
  ## neither of its children ever changes widget type
  ## (`owlkettle/widgets.nim:1341`, `assert newChild.isNil`), and this area is
  ## `NvimTerminal` or `ScrolledWindow` depending on the page. Returning either
  ## one directly killed the application on the first click of the Neovim
  ## button. `Box` is the container that *does* handle a child changing type —
  ## its children hook removes the old widget and inserts the new one — so the
  ## swap happens one level down, where it is supported.
  gui:
    Box(orient = OrientY):
      style = [StyleClass("main-area")]
      if app.editorOpen:
        # No margin: the editor is a *page*, filling its side of the split the way
        # the transcript's ScrolledWindow does. A margin plus `.nvim-term`'s former
        # radius and drop shadow is what made it read as a floating card rather
        # than a view you navigated to (G-24).
        NvimTerminal {.expand: true.}:
          style = [StyleClass("nvim-term")]
      else:
        # G-31: `AutoScroll`, not `ScrolledWindow` — the transcript follows a
        # streaming reply unless `disableAutoScroll` says otherwise. Pinned only
        # while a generation is running; a finished conversation stays where the
        # reader left it.
        AutoScroll {.expand: true.}:
          pin = app.streaming and not app.opts.getBool("disableAutoScroll")
          Box(orient = OrientY, spacing = 12, margin = 16):
            if app.openNote.len > 0:
              Box(orient = OrientX, spacing = 8) {.expand: false.}:
                # 8c-3: the title is a heading while reading and a field while
                # editing, which is the Web UI's own split. The two are
                # different widget types, so owlkettle rebuilds rather than
                # reusing state — the safe direction, and the reason the mode
                # switch cannot carry a half-updated `Entry` into a `Label`.
                if app.noteEditing:
                  Entry {.expand: true.}:
                    text = app.noteTitle
                    placeholder = "Note title"
                    proc changed(text: string) = app.noteTitle = text
                else:
                  Label {.expand: true.}:
                    text = (if app.noteTitle.len > 0: app.noteTitle
                            else: "Untitled note")
                    xAlign = 0.0
                    ellipsize = EllipsizeEnd
                    style = [StyleClass("brand")]
                # G-50: the only way to mark a note FOCUS from this window. The
                # flag has existed in the schema since it was written and
                # `workspace.contextFor` has given it the escape behaviour since
                # G-43 — a FOCUS note reaches every chat in the workspace tree
                # rather than only its own level (D-BU) — and until now it could
                # be set from nowhere but the Web UI, which is a D-BC defect.
                # `view-pin-symbolic` is the metaphor the Web UI's own note
                # header uses.
                #
                # It is here and not in the button row below. That was once
                # load-bearing: the row held the program's only
                # shortcut-carrying button, and owlkettle's `Button.shortcut`
                # asserts its value never changes, so a fourth child shifted the
                # shortcut onto another button's state and aborted the
                # process on opening a note. No button carries a shortcut any
                # more — they all live on the window's own controller — so the
                # placement is now only a layout choice.
                ToggleButton {.expand: false.}:
                  icon = "view-pin-symbolic"
                  state = app.noteFocus
                  tooltip = (if app.noteFocus:
                               "FOCUS note: applies across the whole workspace. " &
                               "Click to make it a normal note, then Save"
                             else:
                               "Make this a FOCUS note — a rule the model sees " &
                               "in every chat in this workspace. Save to apply")
                  style = [ButtonFlat]
                  proc changed(state: bool) = app.noteFocus = state
                # 8c-3: one button, two labels — the mode switch. A second
                # conditional widget here would be free (nothing in this Box
                # carries a shortcut), but one button that says what it does is
                # clearer than two that swap places.
                Button {.expand: false.}:
                  text = (if app.noteEditing: "Cancel" else: "Edit")
                  style = [ButtonFlat]
                  tooltip = (if app.noteEditing:
                               "Discard these changes and go back to reading"
                             else: "Edit this note")
                  proc clicked() =
                    if app.noteEditing: app.cancelNoteEdit()
                    else: app.noteEditing = true
                # 8c-5: delete over the same confirmation every other delete in
                # this window uses (G-36), which names the cascade.
                #
                # **A FOCUS note is refused rather than hidden.** The Web UI
                # omits the button entirely; a disabled one with the reason on
                # it says why, and a control that vanishes reads as a bug. The
                # protection is the same: a workspace-wide rule should not go in
                # one click from the note it happens to be written in.
                Button {.expand: false.}:
                  icon = "user-trash-symbolic"
                  style = [ButtonFlat, StyleClass("row-btn")]
                  sensitive = not app.noteFocus
                  tooltip = (if app.noteFocus:
                               "Un-pin this note before deleting it — it is a " &
                               "FOCUS rule for the whole workspace"
                             else: "Delete this note")
                  proc clicked() =
                    let id = app.openNote
                    app.deleteNode("notes", id)
              if app.noteEditing:
                # A TextView owns a TextBuffer rather than a string, so it is
                # driven from `app.noteBuffer` and read back on save — it
                # cannot be bound to state per redraw the way an Entry is.
                TextView:
                  buffer = app.noteBuffer
              elif app.noteOrigContent.len == 0:
                # 8c-6: an empty note says so. A blank pane is indistinguishable
                # from a note that failed to load.
                Label {.expand: false.}:
                  text = "This note is empty. Click Edit to write in it."
                  xAlign = 0.0
                  style = [StyleClass("dim-note")]
              else:
                # 8c-3: rendered through the transcript's own block renderer, so
                # a note's tables, code blocks and emphasis look exactly as they
                # do in a reply rather than nearly so.
                #
                # Action purpose: **the source is `noteOrigContent`, not
                # `noteBuffer.text()`, and that is the Step 7c rule rather than a
                # preference.** `view` runs on every frame and nothing in it may
                # do work proportional to a payload; reading a `TextBuffer`
                # copies the whole note out of GTK each time, which is the same
                # defect as the per-frame `sha256` that froze the window on an
                # attachment (G-40, D-BQ). The memo behind `blocksFor` would
                # still have re-parsed nothing, but the copy happens before it.
                #
                # It is also exactly right: view mode is only ever reachable
                # with the buffer equal to the stored text. Edit mode's only
                # exits are Cancel, which restores, and Save, which writes and
                # then re-baselines — so there is no state in which the rendered
                # note and the buffer disagree.
                Box(orient = OrientY, spacing = 8) {.expand: false.}:
                  for b in mdMemo.blocksFor(app.openNote, app.noteOrigContent):
                    insert(app.mdBlock(b)) {.expand: false.}
            # Every child here is `expand: false`, and the annotations are
            # the whole point. **`Box`'s adder defaults to `expand: true`**,
            # which in a *vertical* Box sets `vexpand` — so an unannotated
            # message card stretches to take an equal share of the viewport
            # height, and two replies in a tall window each become half a
            # screen. That is the "weirdly huge" bubbles. A transcript sizes
            # to its content and scrolls; it never divides the space up.
            Label {.expand: false.}:
              text = (if app.openNote.len > 0: ""
                      elif app.messages.len == 0: "Ask Jenova something."
                      else: "")
              style = [StyleClass("dim-note")]
            for i, m in (if app.openNote.len > 0: @[] else: app.messages):
              Frame {.expand: false.}:
                # A-70: a system turn is neither the user's nor the model's, and
                # labelling it "JENOVA" is the visible half of presenting the
                # persona as something the model said. The Web UI draws it as
                # its own kind (`ChatMessageSystem.svelte`) and so does this.
                style = [StyleClass("msg-card"),
                         StyleClass(case m.role
                                    of rUser: "msg-user"
                                    of rSystem: "msg-system"
                                    else: "msg-agent")]
                Box(orient = OrientY, spacing = 4, margin = 10):
                  Label {.expand: false.}:
                    text = (case m.role
                            of rUser: "YOU"
                            of rSystem: "SYSTEM"
                            else: "JENOVA")
                    xAlign = 0.0
                    style = [StyleClass("msg-role"),
                             StyleClass(case m.role
                                        of rUser: "msg-role-user"
                                        of rSystem: "msg-role-system"
                                        else: "msg-role-agent")]
                  # Editing varies what is *inside* the card, never the card's
                  # own type — the swap happens among a `Box`'s children, which
                  # is the one place owlkettle handles a child changing type.
                  if app.editingMsg.len > 0 and app.editingMsg == m.id:
                    # A TextView owns a TextBuffer rather than a string, so the
                    # edit is driven from `app.editBuffer` and read back on save,
                    # exactly as the note editor is and for the same reason.
                    TextView {.expand: false.}:
                      buffer = app.editBuffer
                    Box(orient = OrientX, spacing = 4) {.expand: false.}:
                      Button {.expand: false.}:
                        text = "Save"
                        style = [ButtonSuggested, StyleClass("row-btn")]
                        proc clicked() = app.saveEdit()
                      Button {.expand: false.}:
                        text = "Cancel"
                        style = [ButtonFlat, StyleClass("row-btn")]
                        proc clicked() = app.cancelEdit()
                  else:
                    # G-39: the model's reasoning, above the answer and folded
                    # away. **It defaults open only while this turn is streaming**
                    # — a reasoning model can think for a long time before its
                    # first answer token, and a collapsed box during that silence
                    # looks like nothing is happening. Once the reply lands the
                    # default flips back to closed, so a finished transcript is
                    # answers rather than working-out, unless the reader said
                    # otherwise by clicking.
                    if m.thinking.len > 0:
                      Expander {.expand: false.}:
                        label = "Reasoning"
                        # Open while this turn is streaming, and **open whenever
                        # the answer is empty** — a reasoning model can put its
                        # entire reply in `reasoning_content`, and a collapsed box
                        # above an empty card is indistinguishable from the model
                        # having said nothing.
                        # G-31 adds the third case: `showThoughtInProgress`
                        # makes open-while-generating the standing default
                        # rather than something the reader re-opens each turn.
                        expanded = app.expanded.getOrDefault(
                          "think:" & (if m.id.len > 0: m.id else: "live"),
                          m.text.len == 0 or
                          app.opts.getBool("showThoughtInProgress") or
                          (app.streaming and i == app.messages.len - 1))
                        proc activate(on: bool) =
                          app.expanded["think:" & (if m.id.len > 0: m.id
                                                   else: "live")] = on
                        Label:
                          text = m.thinking
                          xAlign = 0.0
                          wrap = true
                          margin = 6
                          style = [StyleClass("dim-note")]
                    insert(app.messageBody(m)) {.expand: false.}
                    insert(app.messageStats(i, m)) {.expand: false.}
                    insert(app.messageActions(i, m)) {.expand: false.}


## Function purpose: the top bar, and **it is a body widget, not a titlebar.**
## It was `HeaderBar {.addTitlebar.}` on a `Window`, which meant
## `gtk_window_set_titlebar` — and **GTK4 hides that while the window is
## fullscreened.** The USER: *"when going to fullscreen the top bar is
## missing."* That took the sidebar toggle, the app menu (Quit included) and the
## status line with it; G-13c had already moved the fullscreen control to the
## bottom row for exactly this reason, one control at a time.
##
## The window is now an `AdwWindow` — *"a Window that does not have a title
## bar"* — with this bar as an ordinary widget inside the content, which is the
## pattern owlkettle's own `AdwWindow` example uses. It stays mapped in
## fullscreen, and the whole class of titlebar-only-in-windowed-mode problems
## goes with it.
##
## **It sits atop the chat column rather than spanning the window** because the
## Web UI's sidebar is full height (`h-full glass-panel rounded-r-[24px]`,
## `ChatSidebar.svelte:177`), so a bar above the sidebar would not be parity.
## Function purpose: open the settings panel on a copy of the stored values, and
## fill the two text buffers from it. Opening is where the copy is taken, so
## Cancel is simply discarding the copy and nothing has to be undone.
proc openSettings(app: AppState) =
  app.optsDraft = app.opts
  app.sysBuffer.text = app.opts.get("systemMessage")
  app.customBuffer.text = app.opts.get("custom")
  app.settingsOpen = true
  app.notice = ""

## Function purpose: validate the edited copy, store it, and make it live. The
## text buffers are read back here rather than on every keystroke — a `TextView`
## has no per-change binding the way an `Entry` does, and polling one from `view`
## would run on every canvas frame.
proc saveSettings(app: AppState) =
  app.optsDraft["systemMessage"] = app.sysBuffer.text()
  app.optsDraft["custom"] = app.customBuffer.text()
  # Refused before storing, not at merge time: `settings.applyTo` runs on the way
  # to the model, and a value silently dropped there is indistinguishable from a
  # parameter the server ignored.
  let (ok, key, msg) = settings.validate(app.optsDraft)
  if not ok:
    app.notice = "settings not saved — " & key & " " & msg
    return
  if not settings.save(app.p, app.optsDraft):
    app.notice = "settings could not be written to " & app.p.state
    return
  app.opts = app.optsDraft
  # Applied immediately rather than on next start. owlkettle takes its
  # stylesheets once at `brew` and offers no way to change them, so
  # `theme.applyPalette` installs an override provider above owlkettle's own —
  # see the note there. Done after the store, so a theme that somehow fails to
  # apply is still the one that comes back on the next launch.
  # `livePaletteFor`, not `paletteFor`: the window exists by the time anything
  # can be saved, so "System" can be resolved properly here.
  theme.applyPalette(theme.livePaletteFor(app.optsDraft.get("theme")))
  app.settingsOpen = false
  app.notice = "settings saved"

## Function purpose: write every live row to a file the import below — and the
## frozen Web UI's — can read back (G-32). The dump is built by `api.exportAll`,
## which declares its columns once; this proc only chooses the file.
proc exportConversations(app: AppState) =
  let (res, state) = app.open: gui:
    FileChooserDialog:
      title = "Export conversations"
      action = FileChooserSave
      initialPath = app.p.state
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Export"
        res = DialogAccept
        style = [ButtonSuggested]
  if res.kind != DialogAccept: return
  let names = FileChooserDialogState(state).filenames
  if names.len == 0: return
  try:
    writeFile(names[0], pretty(api.exportAll()))
    app.notice = "exported to " & names[0]
  except CatchableError as e:
    app.notice = "export failed: " & e.msg

## Function purpose: read a dump back in, through the same transactional route
## the HTTP surface uses, then reload what is on screen so the imported rows are
## visible without a restart.
proc importConversations(app: AppState) =
  let (res, state) = app.open: gui:
    FileChooserDialog:
      title = "Import conversations"
      action = FileChooserOpen
      initialPath = app.p.state
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Import"
        res = DialogAccept
        style = [ButtonSuggested]
  if res.kind != DialogAccept: return
  let names = FileChooserDialogState(state).filenames
  if names.len == 0: return
  var node: JsonNode
  try:
    node = parseJson(readFile(names[0]))
  except CatchableError:
    app.notice = "import failed: " & names[0] & " is not valid JSON"
    return
  let (ok, msg) = api.importAll(node)
  if not ok:
    app.notice = "import failed: " & msg
    return
  # The import writes rows directly, so nothing on screen knows about them yet.
  app.convs = listConversations()
  app.reloadTree()
  app.notice = "imported from " & names[0]

## Function purpose: write the open conversation as the Web UI's markdown
## document (Step 13b). The JSON pair above moves the whole database between the
## two surfaces; this moves **one readable transcript**, which is the other
## format `jca_web` ships and the only one a user can read, diff or paste
## somewhere. The format itself is `convmd.nim` and is asserted there.
proc exportConversationMarkdown(app: AppState) =
  if app.convId.len == 0:
    app.notice = "no conversation open to export"
    return
  var name = "conversation"
  for c in app.convs:
    if c.id == app.convId: name = c.name
  let (res, state) = app.open: gui:
    FileChooserDialog:
      title = "Export this conversation as markdown"
      action = FileChooserSave
      initialPath = app.p.state
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Export"
        res = DialogAccept
        style = [ButtonSuggested]
  if res.kind != DialogAccept: return
  let names = FileChooserDialogState(state).filenames
  if names.len == 0: return
  # Built from the visible path rather than every row, so what is written is the
  # branch being read — the same rule the transcript and `forkConversation`
  # follow. Exporting every branch flattened would produce a document with the
  # alternatives interleaved and no way to tell them apart.
  var msgs: seq[convmd.MdMessage]
  for i, m in app.messages:
    msgs.add convmd.MdMessage(role: $m.role, content: m.text,
                              timestamp: i.int64)
  try:
    writeFile(names[0], convmd.toMarkdown(name, msgs))
    app.notice = "exported to " & names[0]
  except CatchableError as e:
    app.notice = "export failed: " & e.msg

## Function purpose: read one of those documents back as a new conversation.
## Written through `api.importAll`, so it takes the same transactional path the
## JSON import and the HTTP route take rather than inserting rows itself.
proc importConversationMarkdown(app: AppState) =
  let (res, state) = app.open: gui:
    FileChooserDialog:
      title = "Import a markdown conversation"
      action = FileChooserOpen
      initialPath = app.p.state
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Import"
        res = DialogAccept
        style = [ButtonSuggested]
  if res.kind != DialogAccept: return
  let names = FileChooserDialogState(state).filenames
  if names.len == 0: return
  var doc: convmd.MdConversation
  try:
    doc = convmd.fromMarkdown(readFile(names[0]))
  except CatchableError as e:
    app.notice = "import failed: " & e.msg
    return
  if doc.messages.len == 0:
    app.notice = "import failed: no turns found in " & names[0]
    return

  let convId = $genOid()
  var msgs = newJArray()
  var parent = ""
  for m in doc.messages:
    let id = $genOid()
    msgs.add %*{"id": id, "convId": convId, "type": "message", "role": m.role,
                "timestamp": m.timestamp, "parent": parent, "children": "[]",
                "content": m.content}
    parent = id
  let conv = %*{"id": convId,
                "name": (if doc.name.len > 0: doc.name else: "Imported"),
                "lastModified": (epochTime() * 1000).int64,
                "currNode": parent}
  var payload = newJObject()
  var convArr = newJArray()
  convArr.add conv
  payload["conversations"] = convArr
  payload["messages"] = msgs
  let (ok, msg) = api.importAll(payload)
  if not ok:
    app.notice = "import failed: " & msg
    return
  app.convs = listConversations()
  app.reloadTree()
  app.notice = "imported " & $doc.messages.len & " turns from " & names[0]

## Function purpose: bring edits made outside the window back into the database
## (Step 13b) — a note changed in the embedded Neovim, in another editor, or
## over `/api/storage`. The reconcile is `api.pullNotes`; this reports what it
## did, because a sync that says nothing is indistinguishable from one that did
## not run.
proc pullNotesFromDisk(app: AppState) =
  let (updated, failed) = api.pullNotes()
  app.reloadTree()
  # An open note is re-read, or the editor would keep showing the text that was
  # just replaced underneath it. **Only when it has no unsaved edit** — 8c-4's
  # rule is that nothing drops what the user typed without asking, and a sync
  # they triggered is not a licence to break it.
  if app.openNote.len > 0 and not app.noteDirty():
    app.openNoteEditor(app.openNote)
  app.notice =
    if failed > 0: $updated & " notes updated from disk, " & $failed & " failed"
    elif updated == 0: "no notes on disk differ from the database"
    else: $updated & " notes updated from disk"

## Function purpose: the visible half of a `value|label` option list, and the
## index of the stored value in it. Two small procs rather than expressions
## inside the widget tree, because `view` runs on every canvas frame and a
## `split` per option per frame belongs in a proc that reads once.
proc optionLabels(d: settings.SettingDef): seq[string] =
  for o in d.options: result.add o.split('|')[^1]

proc optionIndex(d: settings.SettingDef, value: string): int =
  for i, o in d.options:
    if o.split('|')[0] == value: return i
  0

## Function purpose: one settings field, drawn from its declaration rather than
## hand-written per key — the field list lives in `settings.nim` and adding one
## there is the whole of adding one here.
##
## Action purpose: **the placeholder is the server's own value and the "Custom"
## badge marks a divergence from it** (G-31). Together they answer the question
## the Web UI added this indicator for: whether a parameter is set because you
## set it, or because `llama-server` chose it. An empty field is not sent at all,
## which is why the placeholder is the honest thing to show in it.
proc settingsField(app: AppState, d: settings.SettingDef): Widget =
  let stored = app.optsDraft.get(d.key)
  # Action purpose: **the server's name for this parameter, not ours.** Only
  # `typ_p` differs — `/props` reports it as `typical_p` — and that one mismatch
  # left its placeholder blank on the first build while every other field
  # worked, which is exactly the shape of bug that survives a demo.
  let serverDef = app.serverDefaults.getOrDefault(settings.propsNameFor(d), "")
  # Ghost text falls back to `llama-server`'s own compiled-in default, so a box
  # is never blank before the backend answers. Safe to state as fact because
  # **Jenova passes no sampling flags on the command line**, so the server always
  # starts from these — checked in `lifecycle.nim` and both conf files.
  let ghost = (if serverDef.len > 0: serverDef else: d.appDefault)
  # "Custom" compares against the **server's** value and never against the static
  # fallback: the badge means "this differs from what your server is actually
  # using", and comparing to a constant would make it lie whenever the two differ.
  let isCustom = stored.len > 0 and serverDef.len > 0 and stored != serverDef
  gui:
    Box(orient = OrientY, spacing = 2):
      Box(orient = OrientX, spacing = 6) {.expand: false.}:
        Label {.expand: true.}:
          text = d.label
          xAlign = 0.0
          style = [StyleClass("settings-label")]
        if isCustom:
          Label {.expand: false.}:
            text = "Custom"
            style = [StyleClass("settings-custom")]
        # A field whose feature has not been built yet says so, rather than
        # presenting a control that silently does nothing (**D-BL**). The value
        # is still stored, so it is live the moment the feature lands.
        if d.awaiting.len > 0:
          Label {.expand: false.}:
            text = "not yet in effect"
            tooltip = "Takes effect with " & d.awaiting
            style = [StyleClass("settings-awaiting")]
        if d.kind == skBool:
          Switch {.expand: false, vAlign: AlignCenter.}:
            state = app.optsDraft.getBool(d.key)
            proc changed(on: bool) =
              app.optsDraft[d.key] = (if on: "1" else: "0")

      # `if`/`elif` and not a `case`: owlkettle's `gui` DSL parses a child block
      # as a two-element node and a `case` arm is not one — it fails the
      # `child.len == 2` assertion in `guidsl.nim:150` at compile time.
      if d.kind == skText:
        # Driven from a buffer for the reason the note editor is: a TextView owns
        # its text and cannot be bound to state per redraw the way an Entry is.
        TextView {.expand: false.}:
          buffer = (if d.key == "custom": app.customBuffer else: app.sysBuffer)
      elif d.kind == skSelect:
        DropDown {.expand: false.}:
          items = optionLabels(d)
          selected = optionIndex(d, stored)
          proc select(i: int) =
            if i >= 0 and i < d.options.len:
              app.optsDraft[d.key] = d.options[i].split('|')[0]
      elif d.kind != skBool:
        Entry {.expand: false.}:
          text = stored
          placeholder = (if ghost.len > 0: "Default: " & ghost else: "")
          proc changed(t: string) =
            app.optsDraft[d.key] = t

      if d.help.len > 0:
        Label {.expand: false.}:
          text = d.help
          xAlign = 0.0
          wrap = true
          style = [StyleClass("settings-help")]

## Function purpose: the settings surface (G-31) — the sections of the Web UI's
## `ChatSettings`, minus the two the USER excluded and the fields whose feature
## does not exist here yet (**D-BK**, and `settings.OmittedFields` names every
## one).
##
## Action purpose: **an overlay child of the window, not a second window.** It is
## the floating panel the USER asked for, and it costs no window lifecycle: the
## Overlay already stacks the sidebar Flap over the canvas, so a second child is
## the shape this window is built in. A separate `Window` would need its own
## close path, and every crash in this project's history was a widget outliving
## the thing that owned it (G-25, and the eleven quit-path crashes).
## Function purpose: read every soft-deleted row into `trashItems` (G-21). The
## column list comes from `api.deletedRows`, which reuses `Entities`' own
## declaration — a query written here would drift from it the first time a
## column was added.
##
## **The order is the restore order, not alphabetical.** Containers are listed
## before what lives in them, so a user working down the list restores a
## workspace before the notes inside it; restoring a child alone still works,
## because `api.restoreItem` revives its ancestry upward anyway.
proc refreshTrash(app: AppState) =
  app.trashItems = @[]
  const tables = ["workspaces", "projects", "folders", "conversations",
                  "notes", "fileAssets", "messages"]
  for t in tables:
    for row in api.deletedRows(t):
      if row.len == 0: continue
      # The label column differs per table and the first column is always the
      # id, so a name is looked for rather than assumed to be at a fixed index.
      var label = ""
      case t
      of "workspaces", "projects", "folders", "conversations", "fileAssets":
        if row.len > 1: label = row[1]
      of "notes":
        for cell in row[1 .. ^1]:
          if cell.len > 0 and cell != "null": label = cell; break
      of "messages":
        for cell in row[1 .. ^1]:
          if cell.len > 20: label = cell; break
      else: discard
      if label.strip.len == 0: label = "(untitled)"
      # A message is its own text and can be a page of it; the row is one line.
      label = label.splitLines()[0]
      if label.len > 72: label = label[0 ..< 72] & "…"
      let noun =
        case t
        of "workspaces": "Workspace"
        of "projects": "Project"
        of "folders": "Folder"
        of "conversations": "Conversation"
        of "notes": "Note"
        of "fileAssets": "File"
        else: "Message"
      app.trashItems.add (kind: t, id: row[0], label: label, detail: noun)

  # A-18-2. The other half, and it is a different kind of thing rather than more
  # of the same: files deleted through `/api/storage` never had a row, so no
  # amount of walking `deletedRows` finds them. `fssync.getTrash` is the only
  # way to see them and it had exactly one caller, in the HTTP route — so from
  # the window these accumulated for ever, invisible and unclearable.
  app.trashFiles = @[]
  try:
    app.trashFiles = fssync.getTrash()
  except CatchableError:
    # Reading the trash tree is filesystem work and can fail; an empty list is
    # the honest answer here, and the panel says so rather than showing nothing
    # and implying the trash is empty.
    app.notice = "Could not read the trash directories"

proc openTrash(app: AppState) =
  app.refreshTrash()
  app.notice = ""
  app.trashOpen = true

## Function purpose: undo one soft delete. Goes through `api.restoreEntity` and
## not a direct `is_deleted=0`, because that route also revives the item's
## ancestry — a note inside a deleted folder would otherwise come back invisible
## — and re-indexes a restored message for retrieval, which nothing did until
## 8b (D-BI left deletion forgetting with no counterpart).
proc restoreFromTrash(app: AppState, item: TrashItem) =
  # A-18-1. **`restoreEntityOutcome`, not `restoreEntity`** — and this call is
  # the whole feature. The tri-state existed for a while with nothing reading
  # it, which made it a mechanism and not a feature: the window went on printing
  # plain success whether or not the file came back, which is the false
  # reassurance the trash view was built to end.
  let (ok, outcome) = api.restoreEntityOutcome(item.kind, item.id)
  if ok:
    app.notice =
      case outcome
      # The only outcome the user is told about. `rmNoPhysicalForm` is the
      # ordinary answer for a conversation or a message — mentioning a file
      # there would be noise on the commonest restore of all.
      of fssync.rmFileMissing:
        item.detail & " restored: " & item.label &
          " — but its file was not in the trash and has not come back"
      else:
        item.detail & " restored: " & item.label
    app.refreshTrash()
    # `reloadTree` already re-reads the conversations along with every container,
    # so the sidebar shows the restored item without a second query.
    app.reloadTree()
  else:
    app.notice = "Could not restore that " & item.detail.toLowerAscii

## Function purpose: put back a file that never had a database row (A-18-2).
##
## Addressed by path, not by id, which is the whole reason it cannot share
## `restoreFromTrash`: `fssync.restoreTrash` reads the sidecar for the original
## location and moves the file back, and there is no row to un-delete. Its
## containment is resolved rather than lexical since A-19 — which matters here
## more than anywhere, because this is the first surface that hands that
## primitive a path the user picked off a list.
proc restoreTrashFile(app: AppState, entry: fssync.TrashEntry) =
  if fssync.restoreTrash(entry.path, ""):
    app.notice = "Restored " & entry.name
    app.refreshTrash()
  else:
    # The sidecar carries the destination; without it there is nowhere to put
    # the file back to, and refusing is better than guessing at a location.
    app.notice = "Could not restore " & entry.name &
                 " — its original location is not recorded"

## Function purpose: empty every trash directory, behind a confirmation that
## states what is destroyed and that it does not come back (A-18-3).
##
## **The confirmation is not optional and it is not politeness.** Every delete
## in this application shows a dialog promising "It can be restored from the
## trash" — emptying revokes a promise the product has already made, so the
## dialog has to say what it takes and that the taking is final. An irreversible
## destructive action behind a soft confirmation is the defect, not the missing
## button.
##
## **It deliberately says nothing reassuring beyond that.** There is no
## authentication on any route in this program (A-55), so wording that implied
## the trash was private would be a claim this product cannot make.
proc emptyTrashConfirmed(app: AppState) =
  let fileCount = app.trashFiles.len
  let rowCount = app.trashItems.len
  if fileCount == 0 and rowCount == 0:
    app.notice = "The trash is already empty"
    return

  let (res, _) = app.open: gui:
    MessageDialog:
      title = "Empty the trash?"
      message = "This deletes " & $fileCount &
                (if fileCount == 1: " file" else: " files") &
                " from the trash directories on disk.\n\n" &
                "It cannot be undone. Nothing emptied here can be restored.\n\n" &
                (if rowCount > 0:
                   "The " & $rowCount &
                   (if rowCount == 1: " deleted item" else: " deleted items") &
                   " listed above keep their database rows and stay " &
                   "restorable, but any file belonging to them is destroyed " &
                   "with the rest."
                 else: "")
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Empty Trash"
        res = DialogAccept
        style = [ButtonDestructive]
  if res.kind != DialogAccept: return

  # `emptyTrash` reports a partial failure as `false`, and that distinction is
  # kept: a "done" over a trash that is still half full is the same class of
  # lie as a restore that reports success without moving anything.
  if fssync.emptyTrash():
    app.notice = "Trash emptied"
  else:
    app.notice = "Some items could not be deleted from the trash"
  app.refreshTrash()

## Function purpose: the trash screen (G-21). Everything deleted in this
## application is a soft delete and there was no way to see or undo one, which
## is what makes an accidental delete look like data loss.
##
## It draws only; the listing is `api.deletedRows` and the undo is
## `api.restoreEntity`, both of which the HTTP routes already used and which are
## asserted without a window.
proc trashPanel(app: AppState): Widget =
  gui:
    Box(orient = OrientY):
      # Same shape as the settings and hardware panels: always in the tree,
      # insensitive when closed so it does not swallow clicks.
      sensitive = app.trashOpen
      style = (if app.trashOpen: @[StyleClass("settings-scrim")]
               else: newSeq[StyleClass]())
      if app.trashOpen:
        Box(orient = OrientY, spacing = 8, margin = 24) {.hAlign: AlignCenter,
                                                          vAlign: AlignCenter.}:
          sizeRequest = (720, 560)
          style = [StyleClass("settings-panel")]

          Box(orient = OrientX, spacing = 8) {.expand: false.}:
            Label {.expand: true.}:
              text = "Trash"
              xAlign = 0.0
              style = [StyleClass("brand"), StyleClass("brand-purple")]
            Button {.expand: false.}:
              icon = "view-refresh-symbolic"
              tooltip = "Refresh"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.refreshTrash()
            # A-18-3. `fssync.emptyTrash` existed with one caller, in the HTTP
            # route, so from the window the trash trees were write-only: things
            # went in on every delete and nothing ever came out or cleared.
            Button {.expand: false.}:
              text = "Empty Trash"
              tooltip = "Delete every file in the trash directories, permanently"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.emptyTrashConfirmed()
            Button {.expand: false.}:
              icon = "window-close-symbolic"
              tooltip = "Close"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.trashOpen = false

          ScrolledWindow {.expand: true.}:
            Box(orient = OrientY, spacing = 6, margin = 4):
              # A-18-2: the empty state has to account for BOTH lists. Saying
              # "nothing has been deleted" while the file section below listed
              # entries would be the same false reassurance the trash view was
              # built to end.
              if app.trashItems.len == 0 and app.trashFiles.len == 0:
                Label {.expand: false.}:
                  text = "Nothing has been deleted."
                  xAlign = 0.0
                  style = [StyleClass("settings-help")]
              if app.trashItems.len > 0:
                Label {.expand: false.}:
                  text = "Restoring a container brings back what was inside " &
                         "it. Restoring something inside a deleted container " &
                         "brings the container back too."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]
                for item in app.trashItems:
                  Box(orient = OrientX, spacing = 8) {.expand: false.}:
                    Label {.expand: false.}:
                      text = item.detail
                      xAlign = 0.0
                      sizeRequest = (110, -1)
                      style = [StyleClass("settings-label")]
                    Label {.expand: true.}:
                      text = item.label
                      xAlign = 0.0
                      ellipsize = EllipsizeEnd
                    Button {.expand: false.}:
                      text = "Restore"
                      style = [ButtonFlat, StyleClass("row-btn")]
                      proc clicked() = app.restoreFromTrash(item)

              # A-18-2. Kept as its own section rather than merged above: these
              # are addressed by path and have no database row, so they cannot
              # share the row list's Restore, and presenting them as though they
              # were the same kind of thing would be a false claim about what
              # restoring one does.
              if app.trashFiles.len > 0:
                Label {.expand: false.}:
                  text = "Deleted files"
                  xAlign = 0.0
                  style = [StyleClass("settings-label")]
                Label {.expand: false.}:
                  text = "Files deleted from the workspace tree itself. These " &
                         "have no database entry — restoring one puts the file " &
                         "back where it was recorded as having come from."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]
                for entry in app.trashFiles:
                  Box(orient = OrientX, spacing = 8) {.expand: false.}:
                    Label {.expand: false.}:
                      text = (if entry.workspace.len > 0: entry.workspace
                              else: "File")
                      xAlign = 0.0
                      sizeRequest = (110, -1)
                      style = [StyleClass("settings-label")]
                    Label {.expand: true.}:
                      text = entry.name
                      xAlign = 0.0
                      ellipsize = EllipsizeEnd
                    Button {.expand: false.}:
                      text = "Restore"
                      style = [ButtonFlat, StyleClass("row-btn")]
                      proc clicked() = app.restoreTrashFile(entry)

## Function purpose: open the hardware screen and ask the control worker for a
## detection. Opening always re-detects rather than showing a cached result —
## the whole point of the screen is to say what this machine *is*, and a stale
## answer on it is worse than a spinner.
proc openHardware(app: AppState) =
  app.hardwareOpen = true
  app.hwDetecting = true
  app.notice = ""
  hwReq.send(ControlJob(action: "hardware", lc: app.lc))

## Function purpose: deploy a profile. The apply itself is a file copy, but it
## is sent to the worker anyway so the re-detection that follows it does not run
## on the GTK thread.
proc applyHardwareProfile(app: AppState, name: string) =
  app.hwDetecting = true
  hwReq.send(ControlJob(action: "apply_profile", lc: app.lc, profileName: name))

## Function purpose: the hardware screen (S-1, D-BC) — which profile this
## machine matched, the score that decided it, what was detected, and a button
## to deploy any of them. It replaces `detect-hardware.sh`, which had not run
## since its `lib/` was archived.
##
## Everything it shows comes from `hardware.nim`; this proc only draws. That is
## deliberate and is what let the scoring be asserted in `hardware-selftest`
## with no window at all.
proc hardwarePanel(app: AppState): Widget =
  gui:
    Box(orient = OrientY):
      # Same shape as the settings panel: always in the tree, insensitive when
      # closed so it does not swallow clicks. See the note there.
      sensitive = app.hardwareOpen
      style = (if app.hardwareOpen: @[StyleClass("settings-scrim")]
               else: newSeq[StyleClass]())
      if app.hardwareOpen:
        Box(orient = OrientY, spacing = 8, margin = 24) {.hAlign: AlignCenter,
                                                          vAlign: AlignCenter.}:
          sizeRequest = (720, 560)
          style = [StyleClass("settings-panel")]

          Box(orient = OrientX, spacing = 8) {.expand: false.}:
            Label {.expand: true.}:
              text = "Hardware"
              xAlign = 0.0
              style = [StyleClass("brand"), StyleClass("brand-purple")]
            Button {.expand: false.}:
              icon = "view-refresh-symbolic"
              tooltip = "Detect again"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.openHardware()
            Button {.expand: false.}:
              icon = "window-close-symbolic"
              tooltip = "Close"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.hardwareOpen = false

          ScrolledWindow {.expand: true.}:
            Box(orient = OrientY, spacing = 14, margin = 4):
              if app.hwDetecting:
                Label {.expand: false.}:
                  text = "Detecting…"
                  xAlign = 0.0
                  style = [StyleClass("settings-help")]
              else:
                Label {.expand: false.}:
                  text = "Detected"
                  xAlign = 0.0
                  style = [StyleClass("settings-label")]
                Label {.expand: false.}:
                  text = app.hw.osName & " " & app.hw.osRelease & "\n" &
                         app.hw.cpuModel & " (" & $app.hw.cpuThreads &
                           " threads)\n" &
                         (if app.hw.gpuDevices.len == 0:
                            "no GPU reported by llama-server --list-devices"
                          else: app.hw.gpuDevices.join("\n")) & "\n" &
                         $app.hw.ramGiB & " GiB RAM · " & $app.hw.swapGiB &
                           " GiB swap · " & app.hw.storage
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]

                Label {.expand: false.}:
                  text = "Profiles"
                  xAlign = 0.0
                  style = [StyleClass("settings-label")]
                Label {.expand: false.}:
                  text = "Highest score wins. A profile marked opt-in is " &
                         "never selected automatically and can only be " &
                         "applied by hand. Applying one writes " &
                         "jenova.conf and leaves your jenova.local.conf " &
                         "untouched; restart the backend for it to take " &
                         "effect."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]

                for s in app.hwScores:
                  Box(orient = OrientY, spacing = 2) {.expand: false.}:
                    Box(orient = OrientX, spacing = 8) {.expand: false.}:
                      Label {.expand: true.}:
                        text = s.profile.name &
                               (if s.profile.name == app.hwCurrent:
                                  "  — current" else: "") &
                               (if s.disqualified: "  — not eligible"
                                else: "  — score " & $s.points)
                        xAlign = 0.0
                        wrap = true
                      Button {.expand: false.}:
                        text = "Apply"
                        style = [ButtonFlat, StyleClass("row-btn")]
                        sensitive = s.profile.name != app.hwCurrent
                        proc clicked() =
                          app.applyHardwareProfile(s.profile.name)
                    if s.profile.desc.len > 0:
                      Label {.expand: false.}:
                        text = s.profile.desc
                        xAlign = 0.0
                        wrap = true
                        style = [StyleClass("settings-help")]
                    # Why it scored what it scored. This is the half D-BC's
                    # screen exists for: a number with no reason behind it is
                    # not an explanation of which hardware was matched.
                    for w in s.why:
                      Label {.expand: false.}:
                        text = "· " & w
                        xAlign = 0.0
                        wrap = true
                        style = [StyleClass("settings-help")]

## Function purpose: open the model selector, reading the tree once (8a, G-20).
##
## Action purpose: the enumeration happens **here and not in `view`**. It is a
## directory walk with a `getFileSize` per entry — cheap, but `view` runs on
## every frame, and doing it there is the class of defect G-40 was.
proc openModels(app: AppState) =
  app.modelList = models.available(app.lc.paths.jcaHome)
  app.modelFilter = ""
  app.modelsOpen = true

## Function purpose: make one model active, on the worker (8a).
proc switchToModel(app: AppState, path: string) =
  ctlReq.send(ControlJob(action: "switch_path", jcaHome: app.lc.paths.jcaHome,
                         modelPath: path))
  app.modelsOpen = false

## Function purpose: the model selector (G-20, G-48) — the models in
## `models/instruct` and `models/thinking`, which one is active, and a switch per
## row.
##
## **This is the window's only way to switch (D-CB).** The two named items that
## sat in the app menu are gone; the tray keeps its pair, because a D-Bus menu
## cannot host a searchable list.
##
## What it draws comes from `models.available`; this proc only lays it out,
## which is what let the enumeration and the switch be asserted in
## `models-selftest` with no window.
proc modelsPanel(app: AppState): Widget =
  gui:
    Box(orient = OrientY):
      # Same shape as the settings and hardware panels: always in the tree,
      # insensitive when closed so it does not swallow clicks.
      sensitive = app.modelsOpen
      style = (if app.modelsOpen: @[StyleClass("settings-scrim")]
               else: newSeq[StyleClass]())
      if app.modelsOpen:
        Box(orient = OrientY, spacing = 8, margin = 24) {.hAlign: AlignCenter,
                                                          vAlign: AlignCenter.}:
          sizeRequest = (720, 560)
          style = [StyleClass("settings-panel")]

          Box(orient = OrientX, spacing = 8) {.expand: false.}:
            Label {.expand: true.}:
              text = "Models"
              xAlign = 0.0
              style = [StyleClass("brand"), StyleClass("brand-purple")]
            Button {.expand: false.}:
              icon = "view-refresh-symbolic"
              tooltip = "Re-read the model directory"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.openModels()
            Button {.expand: false.}:
              icon = "window-close-symbolic"
              tooltip = "Close"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.modelsOpen = false

          SearchEntry {.expand: false.}:
            text = app.modelFilter
            placeholderText = "Search models"
            proc changed(t: string) = app.modelFilter = t

          ScrolledWindow {.expand: true.}:
            Box(orient = OrientY, spacing = 14, margin = 4):
              if app.modelList.len == 0:
                # D-CB: name both folders that were actually looked in. "No
                # models found" over a tree the user knows has models in it is
                # the report that sends them looking in the wrong place.
                Label {.expand: false.}:
                  text = "No .gguf files in " & app.lc.paths.jcaHome &
                         "/models/instruct or " & app.lc.paths.jcaHome &
                         "/models/thinking."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]
              else:
                Label {.expand: false.}:
                  text = "Switching relinks models/agent. The model it " &
                         "replaces stays where it is, in its own folder. It " &
                         "does not reload the backend — llama-server holds " &
                         "the old weights until it is restarted."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]

                for m in app.modelList:
                  if app.modelFilter.len == 0 or
                     app.modelFilter.toLowerAscii in m.name.toLowerAscii or
                     app.modelFilter.toLowerAscii in m.role.toLowerAscii:
                    Box(orient = OrientY, spacing = 2) {.expand: false.}:
                      Box(orient = OrientX, spacing = 8) {.expand: false.}:
                        Label {.expand: true.}:
                          text = m.name & (if m.active: "  — active" else: "")
                          xAlign = 0.0
                          wrap = true
                        Button {.expand: false.}:
                          text = "Switch"
                          style = [ButtonFlat, StyleClass("row-btn")]
                          sensitive = not m.active
                          proc clicked() = app.switchToModel(m.path)
                      Label {.expand: false.}:
                        text = (if m.role.len > 0: m.role else: "models") &
                               " · " & $((m.bytes + 1024 * 1024 - 1) div
                                         (1024 * 1024)) & " MB"
                        xAlign = 0.0
                        style = [StyleClass("settings-help")]

## Function purpose: the full-size attachment preview (G-30), the Web UI's
## `DialogChatAttachmentPreview`. Same overlay shape as the settings and hardware
## panels — always in the tree, insensitive when closed so it does not swallow
## clicks. See the note in `settingsPanel`.
proc previewPanel(app: AppState): Widget =
  gui:
    Box(orient = OrientY):
      sensitive = app.previewAtt.payload.len > 0
      style = (if app.previewAtt.payload.len > 0: @[StyleClass("settings-scrim")]
               else: newSeq[StyleClass]())
      if app.previewAtt.payload.len > 0:
        Box(orient = OrientY, spacing = 8, margin = 24) {.hAlign: AlignCenter,
                                                          vAlign: AlignCenter.}:
          style = [StyleClass("settings-panel")]
          Box(orient = OrientX, spacing = 8) {.expand: false.}:
            Label {.expand: true.}:
              text = app.previewAtt.name
              xAlign = 0.0
              style = [StyleClass("settings-label")]
            Button {.expand: false.}:
              icon = "window-close-symbolic"
              tooltip = "Close"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() =
                app.previewAtt = PendingAttachment()
          # 900 rather than the natural size: a large photograph would otherwise
          # size the panel past the window, and a `Picture` has no maximum of
          # its own.
          let pb = app.attachmentPixbuf(app.previewAtt, 900)
          if pb.isNil:
            Label {.expand: true.}:
              text = "This image could not be decoded for preview."
              style = [StyleClass("settings-help")]
          else:
            Picture {.expand: true.}:
              pixbuf = pb
              contentFit = ContentContain

proc settingsPanel(app: AppState): Widget =
  gui:
    Box(orient = OrientY):
      # Always in the tree, empty when closed — the document panel's shape, and
      # for the same reason: an Overlay child that comes and goes is a child
      # count that changes under owlkettle's positional matching.
      #
      # Action purpose: **`sensitive` is what makes a closed panel click
      # through.** An empty Box still takes the Overlay's whole allocation, so
      # without this the window would be covered by an invisible widget that
      # swallowed every click. GTK4's default pick skips insensitive widgets.
      sensitive = app.settingsOpen
      # The scrim. On the wrapper rather than the panel so it covers the whole
      # window, and only while the panel is open — an always-painted scrim would
      # dim the application permanently.
      style = (if app.settingsOpen: @[StyleClass("settings-scrim")]
               else: newSeq[StyleClass]())
      if app.settingsOpen:
        Box(orient = OrientY, spacing = 8, margin = 24) {.hAlign: AlignCenter,
                                                          vAlign: AlignCenter.}:
          sizeRequest = (720, 560)
          # **Not `.glass-panel`.** See the rule in `theme.nim`: this is opaque
          # because the USER reported reading the transcript through it, GTK4
          # has no `backdrop-filter` to blur it with, and the Web UI's own
          # settings dialog is opaque over a dimmed overlay in any case.
          style = [StyleClass("settings-panel")]

          Box(orient = OrientX, spacing = 8) {.expand: false.}:
            Label {.expand: true.}:
              text = "Settings"
              xAlign = 0.0
              style = [StyleClass("brand"), StyleClass("brand-purple")]
            Button {.expand: false.}:
              icon = "window-close-symbolic"
              tooltip = "Close without saving"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.settingsOpen = false

          # The section switcher. A row of flat buttons rather than a sidebar:
          # the panel is 720 wide and a 260-wide nav inside it would leave the
          # fields narrower than the sidebar they sit beside.
          Box(orient = OrientX, spacing = 4) {.expand: false.}:
            for s in settings.SettingSection:
              Button {.expand: false.}:
                text = $s
                style = [if s == app.settingsSection: ButtonSuggested
                         else: ButtonFlat, StyleClass("row-btn")]
                proc clicked() = app.settingsSection = s

          ScrolledWindow {.expand: true.}:
            Box(orient = OrientY, spacing = 14, margin = 4):
              if app.settingsSection == ssImportExport:
                # G-32. The backend is `api.importAll` over the same
                # transactional path `POST /api/db/import` uses; this is the
                # front end the desktop application did not have.
                Label {.expand: false.}:
                  text = "Write every conversation and message to a JSON " &
                         "file, or read one back. A file exported by the Web " &
                         "UI is accepted as well as one exported here."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]
                Box(orient = OrientX, spacing = 8) {.expand: false.}:
                  Button {.expand: false.}:
                    text = "Export…"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    proc clicked() = app.exportConversations()
                  Button {.expand: false.}:
                    text = "Import…"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    proc clicked() = app.importConversations()
                # Step 13b. The Web UI ships two formats and the window had one.
                Label {.expand: false.}:
                  text = "Or move a single conversation as readable markdown " &
                         "— the same document the Web UI writes."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]
                Box(orient = OrientX, spacing = 8) {.expand: false.}:
                  Button {.expand: false.}:
                    text = "Export this chat…"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    sensitive = app.convId.len > 0
                    proc clicked() = app.exportConversationMarkdown()
                  Button {.expand: false.}:
                    text = "Import markdown…"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    proc clicked() = app.importConversationMarkdown()
                # Step 13b. The mirror was write-only: `fssync` wrote a note's
                # `.md` on every save and nothing read one back, so an edit made
                # in the embedded Neovim never returned to the database.
                Label {.expand: false.}:
                  text = "Notes are mirrored to disk as markdown. If one was " &
                         "edited outside this window — in the Neovim page, or " &
                         "another editor — this brings the change back in."
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("settings-help")]
                Box(orient = OrientX, spacing = 8) {.expand: false.}:
                  Button {.expand: false.}:
                    text = "Sync notes from disk"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    proc clicked() = app.pullNotesFromDisk()
              else:
                for d in settings.fieldsIn(app.settingsSection):
                  insert(app.settingsField(d)) {.expand: false.}

          Box(orient = OrientX, spacing = 8) {.expand: false.}:
            Label {.expand: true.}:
              text = "Stored in " & app.p.state
              xAlign = 0.0
              ellipsize = EllipsizeStart
              style = [StyleClass("settings-help")]
            Button {.expand: false.}:
              text = "Cancel"
              style = [ButtonFlat, StyleClass("row-btn")]
              proc clicked() = app.settingsOpen = false
            Button {.expand: false.}:
              text = "Save"
              style = [ButtonSuggested, StyleClass("row-btn")]
              proc clicked() = app.saveSettings()

proc topBar(app: AppState): Widget =
  gui:
    # No adder annotation here — a `gui` tree's top-level widget may not carry
    # one. `expand: false` is applied where this is inserted instead.
    HeaderBar:
      WindowTitle {.addTitle.}:
        title = "Jenova"
        subtitle = (case app.status
                    of bsUp: "ready"
                    of bsStarting: "starting — loading model"
                    of bsDown: "stopped") &
                   # Reproduces `ui.get_status_info`'s mode string: the LAN
                   # address is shown, not just the fact of LAN mode, because
                   # the address is the thing you need in order to connect a
                   # phone or second machine to it.
                   (if app.lanEnabled:
                      "  ·  LAN " & (if app.lanAddr.len > 0: app.lanAddr
                                     else: "0.0.0.0")
                    else: "  ·  local 127.0.0.1")

      Button {.addLeft.}:
        # Mirrors the Web UI's `Sidebar.Trigger`. A plain `Button`: the state it
        # would otherwise carry is shown by the icon, the way `fullscreenButton`
        # does it, so there is no `state` property to bind and no second writer
        # racing the Flap's own `changed`.
        icon = (if app.sidebarOpen: "sidebar-show-symbolic"
                else: "sidebar-show-right-symbolic")
        tooltip = (if app.sidebarOpen: "Hide sidebar" else: "Show sidebar")
        proc clicked() =
          app.sidebarOpen = not app.sidebarOpen

      Button {.addRight.}:
        icon = (if app.editorOpen: "go-previous-symbolic" else: "text-editor-symbolic")
        tooltip = (if app.editorOpen: "Back to chat" else: "Neovim")
        style = [ButtonFlat]
        proc clicked() =
          app.editorOpen = not app.editorOpen

      # G-21. In the bar and not the app menu for the same reason the delete
      # confirmations exist (G-36): the two answer each other. A confirmation
      # tells the user what a delete will take; this is where they go when they
      # did it anyway.
      Button {.addRight.}:
        icon = "user-trash-symbolic"
        tooltip = "Trash"
        style = [ButtonFlat]
        proc clicked() = app.openTrash()

      # G-31. In the bar rather than in the app menu because it is a surface the
      # user opens repeatedly while tuning a model, not a one-off action like
      # restarting a backend.
      Button {.addRight.}:
        icon = "emblem-system-symbolic"
        tooltip = "Settings"
        style = [ButtonFlat]
        proc clicked() = app.openSettings()

      # S-1: choosing a hardware profile was two shell scripts that no longer
      # ran, so this was reachable from nowhere at all (D-BC).
      Button {.addRight.}:
        icon = "computer-symbolic"
        tooltip = "Hardware profile"
        style = [ButtonFlat]
        proc clicked() = app.openHardware()

      # 8a, G-20, G-48: the model list, and since D-CB the window's only way to
      # change model. `models.discover` had no caller anywhere in the program, so
      # before it there was no list to draw at all.
      Button {.addRight.}:
        icon = "drive-multidisk-symbolic"
        tooltip = "Models"
        style = [ButtonFlat]
        proc clicked() = app.openModels()

      MenuButton {.addRight.}:
        icon = "open-menu-symbolic"
        Popover:
          Box(orient = OrientY, spacing = 4, margin = 8):
            # Every item enqueues; none of them acts. The queue is drained in
            # the afterBuild timer, which is also where the tray's identical
            # menu lands — one implementation, reachable two ways.
            Button:
              text = "Start backend"
              style = [ButtonFlat]
              proc clicked() = pendingActions.add "start"
            Button:
              text = "Stop backend"
              style = [ButtonFlat]
              proc clicked() = pendingActions.add "stop"
            Button:
              text = "Restart backend"
              style = [ButtonFlat]
              proc clicked() = pendingActions.add "restart"
            Separator()
            # G-48, D-CB: **one** way to switch in the window. The two named
            # items that stood here — "Switch to instruct model" and "Switch to
            # thinking model" — are removed on the USER's instruction, which is
            # the only removal Directive 3 permits. The tray keeps its pair,
            # because a D-Bus menu cannot host a searchable list and taking them
            # out would leave it with no way to change model at all.
            Button:
              text = "Models…"
              style = [ButtonFlat]
              proc clicked() = app.openModels()
            Separator()
            Button:
              # The label states the action, not the state, because a toggle
              # labelled with its current value is ambiguous about what
              # clicking it does — `ui.lua:73` had the same reasoning.
              text = (if app.lanEnabled: "Disable LAN access"
                      else: "Enable LAN access")
              style = [ButtonFlat]
              proc clicked() = pendingActions.add "toggle_lan"
            Button:
              text = "Open Web UI"
              style = [ButtonFlat]
              proc clicked() = pendingActions.add "web"
            Separator()
            Button:
              text = (if app.fullscreen: "Leave fullscreen" else: "Fullscreen")
              style = [ButtonFlat]
              proc clicked() = pendingActions.add "toggle_fullscreen"
            Separator()
            # The tray has carried the only Quit since it was written
            # (`trayMenu`, id 12). A desktop with no StatusNotifierWatcher gets
            # no tray, which left the window's own close button as the single
            # way out of the application.
            Button:
              text = "Quit"
              style = [ButtonFlat]
              proc clicked() = pendingActions.add "quit"

## The window's keyboard bindings, in one place. Adding one is a row here, not
## a button somewhere with a `shortcut` on it.
proc keyBindings(app: AppState): seq[shortcuts.Binding] =
  # Added one at a time rather than as a literal: a seq literal takes its type
  # from its first element, and the first of these has no side effects while the
  # rest do.
  result.add (accel: "F11",
              action: shortcuts.Action(proc () =
                app.fullscreen = not app.fullscreen))
  result.add (accel: "<Ctrl>n",
              action: shortcuts.Action(proc () = app.newChat()))
  result.add (accel: "<Ctrl>b",
              action: shortcuts.Action(proc () =
                app.sidebarOpen = not app.sidebarOpen))
  result.add (accel: "<Ctrl>comma",
              action: shortcuts.Action(proc () =
                if app.settingsOpen: app.settingsOpen = false
                else: app.openSettings()))
  # Stop a generation. Plain Escape belongs to GTK for popovers and dialogs.
  result.add (accel: "<Ctrl>Escape",
              action: shortcuts.Action(proc () =
                if app.streaming: cancelStream()))

method view(app: AppState): Widget =
  result = gui:
    # `AdwWindow`, not `Window`: it has no titlebar slot, so the top bar is an
    # ordinary widget that stays mapped in fullscreen. See `topBar`.
    AdwWindow:
      defaultSize = (900, 680)
      fullscreened = app.fullscreen

      # Every binding lives on this one controller, at
      # `GTK_SHORTCUT_SCOPE_MANAGED`, so they answer anywhere in the window. It
      # wraps the content rather than sitting beside it because a controller on
      # an unmapped widget is never reached.
      ShortcutHost:
        bindings = app.keyBindings()

        # The canvas is the Overlay's main child, so it fills the window and every
        # widget below is stacked over it — the GTK equivalent of the Web UI's
        # `inset-0 z-0` canvas under a `z-10` content layer (`+layout.svelte`).
        # `theme.css()` makes those content widgets transparent; an opaque one
        # would hide the field entirely rather than tint it.
        Overlay:
          NeuralCanvas()

          Flap {.addOverlay.}:
            revealed = app.sidebarOpen
            # G-31. `FlapFoldNever` keeps the sidebar in the layout instead of
            # letting it fold itself away on a narrow window, which is what the Web
            # UI's "always show on desktop" does.
            foldPolicy = (if app.opts.getBool("alwaysShowSidebarOnDesktop"):
                            FlapFoldNever else: FlapFoldAuto)
            transitionType = FlapTransitionOver
            proc changed(revealed: bool) =
              # The Flap folds itself on a narrow window and can be swiped shut, so
              # `sidebarOpen` has to follow the widget rather than lead it —
              # otherwise the toggle button reports a state the panel is not in.
              app.sidebarOpen = revealed

            # Box's adder defaults to expand: true, so every child is marked.
            Box(orient = OrientY, spacing = 6, margin = 10) {.addFlap, width: 260.}:
              sizeRequest = (260, -1)
              # `.glass-panel` is the class the Web UI's sidebar root carries;
              # `.jenova-sidebar` overrides the parts specific to this edge.
              style = [StyleClass("glass-panel"), StyleClass("jenova-sidebar")]

              Box(orient = OrientX, spacing = 10) {.expand: false.}:
                Picture {.expand: false, hAlign: AlignCenter, vAlign: AlignCenter.}:
                  # The pixbuf is already 48x48 (see `run`), so the natural size is
                  # small and nothing here has to fight it. `AlignCenter` stops the
                  # Box stretching it to fill the row's height.
                  pixbuf = app.logo
                  contentFit = ContentScaleDown
                  style = [StyleClass("sidebar-logo")]
                # Three stacked lines, one colour each. A Box of Labels rather than
                # one markup Label so each line keeps a style class and the palette
                # stays in `theme.nim` instead of becoming an inline span.
                Box(orient = OrientY) {.expand: false, hAlign: AlignFill.}:
                  Label {.expand: false.}:
                    text = "JENOVA"
                    xAlign = 0.0
                    style = [StyleClass("brand"), StyleClass("brand-purple")]
                  Label {.expand: false.}:
                    text = "COGNITIVE"
                    xAlign = 0.0
                    style = [StyleClass("brand"), StyleClass("brand-crimson")]
                  Label {.expand: false.}:
                    text = "ARCHITECTURE"
                    xAlign = 0.0
                    style = [StyleClass("brand"), StyleClass("brand-gold")]

              Button {.expand: false.}:
                sensitive = not app.streaming
                style = [ButtonFlat, StyleClass("row-btn")]
                proc clicked() = app.newChat()
                # A Label child rather than `text`, because GTK centres a Button's
                # own label and no CSS property moves it — `text-align` does not
                # apply. This is the only way to get a left-aligned list row.
                Label:
                  text = "＋   New Chat"
                  xAlign = 0.0

              SearchEntry {.expand: false.}:
                text = app.search
                # 8c-6: it said "Search chats" and has never only searched chats —
                # `leavesIn` filters notes and files by the same string, so a
                # note-title search was built, working and undiscoverable because
                # the box denied doing it.
                placeholderText = "Search chats, notes and files"
                proc changed(text: string) =
                  app.search = text

              Box(orient = OrientX) {.expand: false.}:
                Label {.expand: false, hAlign: AlignFill.}:
                  text = "WORKSPACES"
                  xAlign = 0.0
                  style = [StyleClass("section-label")]
                Button {.expand: false.}:
                  icon = "folder-new-symbolic"
                  tooltip = "New workspace"
                  style = [ButtonFlat, StyleClass("row-btn")]
                  proc clicked() = app.createNode("workspaces", "", "")

              ScrolledWindow {.expand: true.}:
                Box(orient = OrientY, spacing = 1):

                  for ws in app.workspaces:
                    Expander {.expand: false.}:
                      label = ws.name
                      style = [StyleClass("tree-node")]
                      expanded = app.expanded.getOrDefault(ws.id, false)
                      proc activate(on: bool) = app.expanded[ws.id] = on

                      Box(orient = OrientY, spacing = 1, margin = 4):
                        insert(app.nodeTools("workspaces", ws.id, ws.id, "", "",
                               @[("projects", "workspaceId"), ("note", "workspaceId"),
                                 ("chat", "")])) {.expand: false.}

                        for pr in app.projectsOf(ws.id):
                          Expander {.expand: false.}:
                            label = pr.name
                            style = [StyleClass("tree-node")]
                            expanded = app.expanded.getOrDefault(pr.id, false)
                            proc activate(on: bool) = app.expanded[pr.id] = on

                            Box(orient = OrientY, spacing = 1, margin = 4):
                              insert(app.nodeTools("projects", pr.id, ws.id, pr.id, "",
                                     @[("folders", "projectId"), ("note", "projectId"),
                                       ("chat", "")])) {.expand: false.}

                              for fd in app.foldersOf(pr.id):
                                Expander {.expand: false.}:
                                  label = fd.name
                                  style = [StyleClass("tree-node")]
                                  expanded = app.expanded.getOrDefault(fd.id, false)
                                  proc activate(on: bool) = app.expanded[fd.id] = on

                                  Box(orient = OrientY, spacing = 1, margin = 4):
                                    insert(app.nodeTools("folders", fd.id, ws.id, pr.id, fd.id,
                                           @[("note", "folderId"), ("chat", "")])) {.expand: false.}
                                    for n in app.leavesIn(app.notes, ws.id, pr.id, fd.id):
                                      insert(app.leafRow("notes", n)) {.expand: false.}
                                    for f in app.leavesIn(app.files, ws.id, pr.id, fd.id):
                                      insert(app.leafRow("fileAssets", f)) {.expand: false.}
                                    for c in app.convsIn(ws.id, pr.id, fd.id):
                                      insert(app.convRow(c)) {.expand: false.}

                              for n in app.leavesIn(app.notes, ws.id, pr.id, ""):
                                insert(app.leafRow("notes", n)) {.expand: false.}
                              for f in app.leavesIn(app.files, ws.id, pr.id, ""):
                                insert(app.leafRow("fileAssets", f)) {.expand: false.}
                              for c in app.convsIn(ws.id, pr.id, ""):
                                insert(app.convRow(c)) {.expand: false.}

                        for n in app.leavesIn(app.notes, ws.id, "", ""):
                          insert(app.leafRow("notes", n)) {.expand: false.}
                        for f in app.leavesIn(app.files, ws.id, "", ""):
                          insert(app.leafRow("fileAssets", f)) {.expand: false.}
                        for c in app.convsIn(ws.id, "", ""):
                          insert(app.convRow(c)) {.expand: false.}

                  Label {.expand: false.}:
                    text = "CHATS"
                    xAlign = 0.0
                    style = [StyleClass("section-label")]
                  # Always present so the list's container never changes shape;
                  # only its text varies. The rows themselves are the one place
                  # children legitimately come and go.
                  Label {.expand: false.}:
                    text = (if app.visibleConvs().len == 0:
                              (if app.search.len > 0: "No matches." else: "No chats yet.")
                            else: "")
                    xAlign = 0.0
                    style = [StyleClass("dim-note")]
                  for c in app.convsIn("", "", ""):
                    insert(app.convRow(c)) {.expand: false.}

            # ── Chat column ───────────────────────────────────────────────────
            Box(orient = OrientY):
              style = [StyleClass("chat-col")]

              # The top bar lives here, not in a titlebar slot — GTK4 hides a
              # `gtk_window_set_titlebar` titlebar in fullscreen, which is what
              # made it vanish. Atop the chat column rather than spanning the
              # window because the Web UI's sidebar is full height.
              insert(app.topBar()) {.expand: false.}
              # The transcript takes all the free height; the notice and the action
              # row take only what they need — the child annotation on the Box, not
              # a property of the child. The three children keep the same types in
              # the same order whether a note or the transcript is open, so
              # owlkettle's positional matching never swaps a widget out from under
              # the diff; only what is inside them changes.
              #
              # D-BW removed the document panel, and with it the horizontal Box
              # that existed only to sit the panel beside this column. The
              # `Box`-not-`Paned` reasoning it carried still applies one level
              # down and lives at `mainArea`, which is the widget that actually
              # changes type between a `ScrolledWindow` and an `NvimTerminal`.
              DropZone {.expand: true.}:
                # G-30: the drop target wraps the chat column, which is the
                # Web UI's `ChatScreenDragOverlay` position.
                style = [StyleClass("drop-zone")]
                insert(app.mainArea())
              # G-30: what is staged, above the composer, each removable. The
              # Web UI shows thumbnails; this shows the name, the type and the
              # size, because a GTK thumbnail means decoding the image on the
              # GTK thread and the strip has to stay cheap to redraw.
              if app.pending.len > 0 and not app.editorOpen:
                Box(orient = OrientX, spacing = 6, margin = 8) {.expand: false.}:
                  for idx, a in app.pending:
                    Box(orient = OrientX, spacing = 4) {.expand: false.}:
                      style = [StyleClass("attach-chip")]
                      # G-30: a real thumbnail for an image, which is what the Web
                      # UI's `ChatAttachmentThumbnailImage` shows. Decoded once
                      # and cached by digest — `view` runs on every frame.
                      if a.kind == "IMAGE":
                        let pb = app.attachmentPixbuf(a, 40)
                        if not pb.isNil:
                          Button {.expand: false.}:
                            tooltip = "Preview " & a.name
                            style = [ButtonFlat, StyleClass("attach-thumb")]
                            proc clicked() =
                              app.previewAtt = a
                            Picture:
                              pixbuf = pb
                              contentFit = ContentContain
                      Label {.expand: false.}:
                        text = (if a.kind == "IMAGE": "🖼 " else: "📄 ") &
                               a.name & "  (" & $(a.bytes div 1024) & " KiB)"
                        style = [StyleClass("settings-help")]
                      Button {.expand: false.}:
                        icon = "window-close-symbolic"
                        tooltip = "Remove"
                        style = [ButtonFlat, StyleClass("row-btn")]
                        proc clicked() =
                          if idx < app.pending.len: app.pending.delete(idx)

              Box(orient = OrientX, spacing = 8) {.expand: false.}:
                margin = (if app.notice.len > 0 and not app.editorOpen: 8 else: 0)
                Label {.expand: true.}:
                  # The notice is chat feedback — "backend restarted", "note
                  # saved". It has nothing to say about the editor page and a
                  # stale line under a full-screen editor reads as an error in it.
                  text = (if app.editorOpen: "" else: app.notice)
                  xAlign = 0.0
                  wrap = true
                  style = [StyleClass("dim-note")]
                # G-35: a failure the USER can do something about offers the
                # action rather than describing it. Only for the kinds
                # `pipeline.classifyError` marked retryable — a context overflow
                # is not one of them, because retrying it fails identically.
                if app.noticeRetryable and not app.editorOpen and
                   not app.streaming:
                  Button {.expand: false.}:
                    text = "Retry"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    proc clicked() =
                      app.notice = ""
                      app.noticeRetryable = false
                      app.postConversation()

              Box(orient = OrientX, spacing = 8, margin = 12) {.expand: false.}:
                # Action purpose: three branches, not two. This tested only
                # `app.openNote`, so the editor page fell through to the *chat*
                # row and showed a message box and a Send button under Neovim —
                # with no way to leave except the top-bar icon. A page gets the
                # controls of the page it is, which is the shape the note editor
                # already had (G-24).
                if app.editorOpen:
                  Label {.expand: true.}:
                    text = "Neovim — " & app.p.workspaces
                    xAlign = 0.0
                    ellipsize = EllipsizeStart
                    style = [StyleClass("dim-note")]
                  Button {.expand: false.}:
                    text = "Close"
                    style = [ButtonFlat]
                    proc clicked() = app.editorOpen = false
                  insert(app.fullscreenButton()) {.expand: false.}
                elif app.openNote.len > 0:
                  # `sensitive` rather than a conditional widget: a stable
                  # child count is still the cheaper thing to reason about when
                  # owlkettle matches states positionally.
                  Button {.expand: false.}:
                    text = "Save note"
                    style = [ButtonSuggested]
                    sensitive = app.noteEditing
                    tooltip = (if app.noteEditing: "Save this note"
                               else: "Click Edit to change this note")
                    proc clicked() = app.saveNote()
                  Button {.expand: false.}:
                    text = "Close"
                    style = [ButtonFlat]
                    proc clicked() = app.closeNote()
                  insert(app.fullscreenButton()) {.expand: false.}
                else:
                  # G-30: the paperclip, and it is one of three ways in rather
                  # than the only one. **This said "a file picker only —
                  # drag-and-drop and paste are not here yet" long after both
                  # landed**: the paste button is eight lines below, and
                  # `DropZone` has wrapped the whole chat column since G-30. A
                  # comment that under-reports what a surface can do sends the
                  # next reader to build it a second time.
                  Button {.expand: false.}:
                    icon = "mail-attachment-symbolic"
                    tooltip = "Attach a file"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    sensitive = not app.streaming
                    proc clicked() = app.attachDialog()
                  # G-30: paste. GTK's Entry already pastes text on Ctrl+V; what
                  # it cannot do is take an image off the clipboard, which is the
                  # Web UI's third route in. A button rather than a key binding,
                  # because a key binding for it would be invisible.
                  Button {.expand: false.}:
                    icon = "edit-paste-symbolic"
                    tooltip = "Attach an image from the clipboard"
                    style = [ButtonFlat, StyleClass("row-btn")]
                    sensitive = not app.streaming
                    proc clicked() = pasteImage()
                  # Step 13a. **A `TextView`, not an `Entry`** — six parity gaps
                  # were all downstream of the composer being one line bound to a
                  # string: multi-line drafts, Shift+Enter, autogrow, the height
                  # cap and the height reset. `ContentScroll` supplies the growth
                  # and the ceiling — natural-height propagation up to
                  # `maxHeight` — and `DraftView` supplies the rest, including the
                  # one thing an `Entry` gave free: Enter sends, Shift+Enter does
                  # not.
                  #
                  # **The child count of this row is unchanged at five and
                  # `fullscreenButton` is still last** (G-51).
                  Overlay {.expand: true.}:
                    ContentScroll:
                      # Roughly eight lines, which is where the Web UI's own
                      # textarea stops growing.
                      maxHeight = 168
                      DraftView:
                        text = app.draft
                        style = [StyleClass("draft-view")]
                        # GTK pastes into the `GtkTextView` directly, so there is
                        # no paste signal to intercept — a paste reaches this
                        # window only as a large single insertion in a `changed`,
                        # which `composer.classifyInsertion` recovers by diff.
                        #
                        # Writing the shortened draft back is sound because
                        # `DraftView`'s `text` property hook compares against the
                        # buffer and rewrites it only when they differ.
                        proc changed(text: string) =
                          let ins = composer.classifyInsertion(
                            app.draft, text,
                            app.opts.appInt("pasteLongTextToFileLen"))
                          if ins.divert:
                            app.attachPastedText(ins.inserted)
                            app.draft = ins.remaining
                          else:
                            app.draft = text
                        proc submit() = app.send()
                    # Directive 3: a `TextView` has no placeholder and the `Entry`
                    # this replaces had one, so it is drawn rather than dropped.
                    #
                    # **A plain state test.** The first version asked the buffer
                    # (`charCount`) and nothing re-ran `view` on a keystroke, so
                    # the placeholder sat over the user's text indefinitely. With
                    # `changed` feeding `app.draft`, owlkettle redraws on every
                    # keystroke and this branch is simply correct.
                    #
                    # Action purpose: **the alignments and `sensitive` are what
                    # keep the box clickable, and both are required.** A first
                    # version had neither and the composer could not be clicked
                    # into at all: owlkettle's `addOverlay` adder defaults to
                    # `hAlign: AlignFill, vAlign: AlignFill` (`widgets.nim`), so
                    # the Label was stretched over the whole composer, and a
                    # GtkLabel is targetable by default — it sat on top of the
                    # view and took every click. `xAlign`/`yAlign` do **not** do
                    # this; they align the text *inside* the Label.
                    if app.draft.len == 0:
                      Label {.addOverlay, hAlign: AlignStart, vAlign: AlignStart.}:
                        text = "Message Jenova…"
                        # GTK4 skips insensitive widgets when it picks a target,
                        # so this cannot intercept a click even if an alignment is
                        # changed later.
                        sensitive = false
                        style = [StyleClass("draft-placeholder")]
                  # G-33: the send button becomes a stop button mid-generation,
                  # which is what the Web UI's `ChatFormActionSubmit` does. It
                  # previously just greyed out, so once a generation started there
                  # was no way to cancel it short of quitting the application.
                  Button:
                    text = (if app.streaming: "Stop" else: "Send")
                    style = [if app.streaming: ButtonDestructive
                             else: ButtonSuggested]
                    proc clicked() =
                      if app.streaming: cancelStream()
                      else: app.send()
                  insert(app.fullscreenButton()) {.expand: false.}

          # G-31. Last child of the Overlay, so it stacks above the Flap and the
          # chat column rather than under them — the floating panel, over the
          # whole window and the canvas behind it.
          insert(app.settingsPanel()) {.addOverlay.}
          insert(app.hardwarePanel()) {.addOverlay.}
          insert(app.modelsPanel()) {.addOverlay.}
          insert(app.trashPanel()) {.addOverlay.}
          insert(app.previewPanel()) {.addOverlay.}

## Function purpose: entry point for `bin/jenova`. Resolution happens here,
## before the window exists, so a configuration error is reported on the terminal
## rather than inside a half-built UI.
proc run*(withTray = true, checkOnly = false) =
  let p = paths.resolve()
  let c = config.load(p)
  let lc = lifecycle.init(p, c)

  let host = if isLanEnabled(p): "0.0.0.0" else: c.get("HOST", "127.0.0.1")
  let port = c.getInt("PORT", 8080)

  db.initDb(p.state / "jenova.db")
  # M-02. Every image ever attached, pasted or previewed is decoded into
  # `cacheDir` under a digest name, and until now nothing ever removed one — so
  # the directory grew for the life of the install with no way to reclaim it
  # short of `rm -rf`. Swept once, here, rather than on the decode path:
  # `sweepCache` stats a directory, and doing that where a thumbnail is decoded
  # would put filesystem work inside `view` (G-40).
  #
  # Deliberately silent. A cache that cannot be pruned is not a reason to refuse
  # to open the window, and there is no window yet to say it in.
  discard paths.sweepCache(p.attachCacheDir)
  rag.initSchema()
  rag.configureEmbed("127.0.0.1", c.getInt("LLAMA_EMBED_PORT", 8082))
  # `Editor:` reads whatever is open in the editor listening here. Configured
  # unconditionally: `nvimctl` treats an absent socket as "no document", so this
  # costs nothing on a host with no Neovim running.
  pipeline.configureEditor(nvimctl.socketPath(p))
  # T-3: the history trim's budget. The window posts to its own :8080, so the
  # request goes through `pipeline.prepare` exactly as the Web UI's does and one
  # trim covers both — but the budget still has to be set in each process that
  # runs a pipeline, and this one runs its own.
  pipeline.configureHistoryBudget(c.getInt("CTX_SIZE", 8192),
                                  c.getInt("NUM_SLOTS", 1))
  # G-45: the editor is spawned with an environment that loads the in-tree
  # `jvim/` configuration and tells its Jenova layer where this process is
  # listening. `127.0.0.1` and not `host`: the editor runs beside the server, and
  # `host` is `0.0.0.0` in LAN mode, which is a bind address rather than a
  # reachable one.
  vte.configure(nvimctl.socketPath(p), p.workspaces,
                nvimctl.editorEnv(p, "127.0.0.1", port,
                                  c.getInt("LLAMA_PORT", 8081),
                                  c.getInt("LLAMA_EMBED_PORT", 8082),
                                  isLanEnabled(p)))
  # Before the window exists, because `applyScheme` asks for `jenova-dark` first
  # and a search path appended later would be too late for the blocks already on
  # screen. Silent on failure by design — see `installScheme`.
  sourceview.installScheme(p.state / "styles")
  # G-30: the clipboard callback is a bare C function and cannot be handed the
  # paths object, so where a pasted image is written is set once, here.
  # The same owned subdirectory the decoder writes to, so pasted images are
  # swept too — they were accumulating with nothing removing them.
  pasteDir = p.attachCacheDir
  # Action purpose: `--check` stops short of everything that touches the
  # machine. It still builds the **whole** widget tree under a real GTK, which
  # is the half a compile cannot see — see the note above `brew` below.
  if not checkOnly:
    discard lc.startAll()
  if not checkOnly:
    discard server.start(
      host, port, p.root / "public",
      llamaHost = "127.0.0.1", llamaPortArg = c.getInt("LLAMA_PORT", 8081),
      embedHost = "127.0.0.1", embedPortArg = c.getInt("LLAMA_EMBED_PORT", 8082))

  streamReq.open(); ctlReq.open(); hwReq.open(); uiChan.open()
  createThread(streamThread, streamWorker)
  createThread(ctlThread, ctlWorker)
  createThread(hwThread, hwWorker)
  defer:
    streamReq.send(StreamJob(host: QuitSentinel))
    ctlReq.send(ControlJob(action: QuitSentinel))
    hwReq.send(ControlJob(action: QuitSentinel))
    joinThread(streamThread); joinThread(ctlThread); joinThread(hwThread)
    streamReq.close(); ctlReq.close(); hwReq.close(); uiChan.close()
    # T-5. **The embedding server, and deliberately not the agent one.** Quitting
    # left `llama-embed` running with nothing attached to it — this `defer` sent
    # the workers their quit sentinel and stopped no backend at all. Leaving the
    # *agent* model loaded is the deliberate half: reloading gigabytes into VRAM
    # on every start is worse than an idle process, and it is why `stopAll` is
    # not what is called here.
    #
    # After the joins, never before: the control worker owns the stop/restart
    # jobs, and stopping a backend underneath a job still running one is how a
    # restart ends up starting a server this is about to kill.
    #
    # `lifecycle.stop` already clears a pid file whose process is gone — the
    # `not st.running` branch — so the stale-pid half of T-5 needs nothing new.
    if not checkOnly:
      discard lc.stop(beEmbed)

  var conv = latestConversation()
  if conv.len == 0: conv = newConversation()
  # The first transcript is a path through the tree like every later one, so it
  # is computed the same way rather than by taking every row in order (G-29).
  let allHistory = loadMessages(conv)
  let (history, startLeaf) = pathOf(allHistory, loadLeaf(conv))

  let initialLan = isLanEnabled(p)
  let initialAddr = if initialLan: lanAddress() else: ""
  # Read once, here, and used three times below — for the window state, for the
  # palette, and for the colour scheme handed to `brew`. Loading it three times
  # would let a file written between the calls give the window one theme and the
  # stylesheet another.
  let startOpts = settings.load(p)
  # Action purpose: the sidebar logo, decoded once. `png/jenova.jpg` is the same
  # image the Web UI serves as `/jenova.jpg`, so both surfaces show one mark.
  # A failure here is not fatal by design — see the `logo` field.
  var logo: Pixbuf
  try:
    # Action purpose: decoded **at** 48x48, not decoded and then asked to be
    # small. `sizeRequest` and CSS `min-width` both set a *minimum*, so neither
    # can shrink a widget — a Picture takes its natural size from the pixbuf, and
    # `png/jenova.jpg` is a large square banner. Scaling at load is the only
    # thing that actually caps it. 48 matches the Web UI's `w-12 h-12` tile.
    logo = loadPixbuf(p.root / "png" / "jenova.jpg", 48, 48,
                      preserveAspectRatio = true)
  except CatchableError:
    discard

  let widget = gui(App(p = p,
                       cfg = c,
                       lc = lc,
                       status = bsDown,
                       lanEnabled = initialLan,
                       lanAddr = initialAddr,
                       convId = conv,
                       messages = history,
                       allMessages = allHistory,
                       edges = edgesOf(allHistory),
                       leaf = startLeaf,
                       convs = listConversations(),
                       workspaces = listWorkspaces(),
                       projects = listProjects(),
                       folders = listFolders(),
                       notes = listNotes(),
                       files = listFiles(),
                       logo = logo,
                       # G-31. Read once here rather than per turn: `view` runs on
                       # every canvas frame and `postConversation` on every send,
                       # and re-reading a file in either is the shape of defect
                       # B-17. A missing or malformed file is the defaults, so
                       # this cannot stop the window opening.
                       opts = startOpts,
                       optsDraft = startOpts,
                       settingsSection = ssGeneral))

  if withTray:
    # The tray is started before the main loop but pumped from inside it; see
    # tray.pump. A desktop with no StatusNotifierWatcher simply gets no icon —
    # `start` returns false and the window is unaffected, because the window is
    # the application and the tray is an addition to it.
    if tray.start("Jenova", "jenova", "Jenova — local AI workspace",
                  trayMenu(initialLan),
                  proc (action: string) = pendingActions.add action):
      discard addGlobalTimeout(100, proc(): bool =
        tray.pump()
        true
      )

  # Action purpose: the palette is a setting now (G-31), so the colour scheme is
  # forced to **match the palette** rather than forced to dark unconditionally.
  # The reason it was pinned still holds and is why this is forced rather than
  # left at `Default`: Adwaita's own chrome — menus, tooltips, the file chooser —
  # has to agree with the sheet, and a light desktop under the dark palette gave
  # dark text on light chrome. `paletteFor` resolves "system" by asking
  # libadwaita what the desktop actually wants.
  # **Nothing here may touch GTK.** `brew` is what calls `adw_init`, so a GTK or
  # libadwaita call on this line runs before there is a display and aborts the
  # process. `paletteFor` is GTK-free for exactly that reason; "System" opens on
  # the static default and the window's `afterBuild` hook re-resolves it.
  let startPalette = theme.paletteFor(startOpts.get("theme"))

  # Action purpose: **the smoke test that would have caught the abort.**
  # `nimble gui` exiting 0 says the widget tree compiles; it says nothing about
  # whether the program reaches its first frame, and this window shipped a
  # 100%-reproducible SIGABRT that a clean compile could not see (D-AR).
  #
  # `--check` does what `brew` does minus the two things that make running the
  # product intrusive: it calls `adw_init`, installs the stylesheet and **builds
  # the entire widget tree**, including every `afterBuild` hook — then returns
  # without `runMainloop`, so **no window is ever presented**. Combined with the
  # skips above it starts no backend, binds no port and touches no GPU, which is
  # what makes it usable under D-BJ where starting the application is not.
  if checkOnly:
    adw_init()
    discard setupApp(AppConfig(widget: widget, icons: @[], darkTheme: false,
                               stylesheets: @[theme.stylesheet(startPalette)]))
    echo "jenova --check: GTK initialised, window tree built, no window shown"
    return

  adw.brew(widget,
           # `Default` for System, so libadwaita follows the desktop for its own
           # chrome; forced otherwise, so Adwaita's menus and dialogs agree with
           # a palette the user picked against the desktop's preference.
           colorScheme = (if theme.needsLiveResolve(startOpts.get("theme")):
                            ColorSchemeDefault
                          elif startPalette.preferDark: ColorSchemeForceDark
                          else: ColorSchemeForceLight),
           stylesheets = [theme.stylesheet(startPalette)])
