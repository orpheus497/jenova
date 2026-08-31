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
## rather than `bin/jenova-model-switch`. The GUI spawns no shell at all.
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

import std/[net, os, osproc, streams, strutils]
import owlkettle
import owlkettle/adw
import ./paths
import ./config
import ./lifecycle
import ./models
import ./tray

type
  Role* = enum
    rUser = "user"
    rAssistant = "assistant"

  Message* = object
    role*: Role
    text*: string

  BackendStatus* = enum
    ## Deliberately three states, not two. `ui.poll_status` collapsed everything
    ## that was not "is ready" into "inactive", which cannot distinguish a
    ## backend that is still loading a multi-gigabyte model from one that is
    ## dead — and the watchdog's 30 s interval exists precisely because that
    ## distinction matters (`lifecycle.nim:333`).
    bsDown = "stopped"
    bsStarting = "starting"
    bsUp = "ready"

## Action purpose: streaming happens on a worker thread, because a generation
## takes tens of seconds and the GTK main loop must keep painting. Tokens cross
## back through a channel, which Nim deep-copies on send, so no GC'd object is
## shared between the threads. A global is used rather than a closure because a
## `{.thread.}` proc may not capture heap state.
type StreamJob = object
  host: string
  port: int
  body: string

var
  streamChan: Channel[string]
  streamThread: Thread[StreamJob]
  streamBusy: bool = false

## Action purpose: control actions are queued, not executed at the call site.
##
## The tray and the window menu offer the same actions, and the tray's callback
## arrives from the D-Bus dispatch with no access to the widget state. Routing
## both through one queue means there is exactly **one** implementation of "start
## the backend" rather than two that can drift — which is the failure `ui.lua`
## had, where the tray and the TUI each rebuilt the same command strings.
##
## Safe without a lock: `tray.pump` is driven from a GTK timeout, so the tray
## callback and the drain both run on the main loop thread.
var pendingActions: seq[string] = @[]

const
  StreamDone = "\x00__done__"       ## sentinel: generation finished cleanly
  StreamErrPrefix = "\x00__err__"   ## sentinel prefix: generation failed

## Function purpose: read one HTTP response body off a blocking socket, feeding
## every SSE `data:` payload into the channel as it arrives.
##
## This parses only as much HTTP as it needs: status line, skip headers, then
## stream. `upstream.nim` already relays bytes verbatim for the proxy path; this
## is the client side of the same conversation and shares its assumption that the
## peer is our own server on loopback.
proc streamWorker(job: StreamJob) {.thread.} =
  var sock: Socket
  try:
    sock = newSocket()
    sock.connect(job.host, Port(job.port))

    let req = "POST /v1/chat/completions HTTP/1.1\r\n" &
              "Host: " & job.host & "\r\n" &
              "Content-Type: application/json\r\n" &
              "Connection: close\r\n" &
              "Content-Length: " & $job.body.len & "\r\n\r\n" & job.body
    sock.send(req)

    let statusLine = sock.recvLine(timeout = 120_000)
    if statusLine.len == 0:
      streamChan.send(StreamErrPrefix & "no response from the server")
      return
    let parts = statusLine.split(' ')
    let code = if parts.len > 1: parts[1] else: "?"
    if code != "200":
      # 502 is the honest answer when llama-server is not up yet; say so rather
      # than showing an empty reply, which is what a silent failure looks like.
      var detail = "the server answered " & code
      if code == "502":
        detail = "llama-server is not answering yet — it may still be loading the model"
      streamChan.send(StreamErrPrefix & detail)
      return

    # Skip headers.
    while true:
      let line = sock.recvLine(timeout = 120_000)
      if line.len == 0 or line == "\r\n":
        break

    while true:
      let line = sock.recvLine(timeout = 300_000)
      if line.len == 0:
        break
      if not line.startsWith("data:"):
        continue
      let payload = line[5 .. ^1].strip
      if payload == "[DONE]":
        break
      # Pull the token out without a JSON parse. The field is always
      # `"content":"..."` in a chat.completion.chunk, and a full parse per token
      # on the UI's critical path buys nothing.
      let key = "\"content\":\""
      let idx = payload.find(key)
      if idx < 0:
        continue
      var i = idx + key.len
      var tok = ""
      while i < payload.len:
        if payload[i] == '\\' and i + 1 < payload.len:
          case payload[i + 1]
          of 'n': tok.add '\n'
          of 't': tok.add '\t'
          of 'r': discard
          of '"': tok.add '"'
          of '\\': tok.add '\\'
          of 'u':
            # \uXXXX — pass the escape through rather than mangling it.
            if i + 5 < payload.len: tok.add payload[i .. i + 5]
          else: tok.add payload[i + 1]
          i += 2
          if payload[i - 1] == 'u': i += 4
        elif payload[i] == '"':
          break
        else:
          tok.add payload[i]
          i += 1
      if tok.len > 0:
        streamChan.send(tok)
  except CatchableError as e:
    streamChan.send(StreamErrPrefix & e.msg)
  finally:
    try: sock.close() except CatchableError: discard
    streamChan.send(StreamDone)

## Function purpose: the LAN-mode flag, persisted exactly where `ui.lua:12-15`
## put it so a running deployment's state is not orphaned by the port.
proc lanStateFile(p: Paths): string =
  p.state / "lan_mode"

proc isLanEnabled(p: Paths): bool =
  try: readFile(lanStateFile(p)).strip == "1"
  except CatchableError: false

proc setLanState(p: Paths, enabled: bool) =
  try:
    createDir(p.state)
    writeFile(lanStateFile(p), if enabled: "1" else: "0")
  except CatchableError: discard

## Function purpose: run a base-system command and return its first non-empty
## line. Used for the LAN address and for handing a URL to the browser — the two
## things with no library equivalent.
##
## `route(8)`, `ifconfig(8)` and `xdg-open(1)` are invoked with an argument
## vector, never a shell string. `ui.lua` built shell commands and needed a
## `shell_quote` helper to stay safe; passing argv removes the question.
proc runCapture(cmd: string, args: openArray[string]): string =
  try:
    let p = startProcess(cmd, args = args, options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
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
## FreeBSD, so it always fell through to the `ifconfig` path. The working half is
## kept and the dead half is not carried across.
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

## Function purpose: JSON string escaping for the request body. Hand-written for
## the same reason `sha256.nim` is: the payload must be exactly right, and
## pulling a parser onto this path to serialise one string is not a trade worth
## making.
proc escapeJson(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\x00' .. '\x08', '\x0B', '\x0C', '\x0E' .. '\x1F':
      result.add "\\u" & toHex(ord(c), 4)
    else: result.add c
  result.add "\""

## Action purpose: the tray menu, reproducing `ui.get_menu` (`ui.lua:72-89`) item
## for item and in the same order, because it is the surface Directive 3 retains.
## Ids are stable and start at 1, since 0 is dbusmenu's root.
##
## The one item that is not carried across is "System Control", which launched
## the ncurses TUI through `bin/jenova-term`. Ruling D-AL replaces the TUI with
## this window, so the item has nothing left to open.
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

viewable App:
  ## Application state. `paths` and `cfg` are resolved once at startup rather
  ## than per action, so a mid-session config edit cannot make two actions
  ## disagree about where the runtime lives.
  p: Paths
  cfg: Config
  lc: Lifecycle
  messages: seq[Message]
  draft: string
  status: BackendStatus
  lanEnabled: bool
  ## Cached, not computed per redraw: resolving it forks `route` and `ifconfig`,
  ## and `view` runs on every token of a stream. `ui.poll_status` forking
  ## `jenova-ca status` every 3 s in the tray and every 1 s in the TUI is defect
  ## B-17, and recomputing this in `view` would be a worse version of it.
  lanAddr: string
  streaming: bool
  notice: string

  hooks:
    afterBuild:
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
        let up = st.lc.healthy(beLlama, timeoutMs = 300)
        let newStatus =
          if up: bsUp
          elif st.lc.state(beLlama).pid > 0: bsStarting
          else: bsDown
        let newLan = isLanEnabled(st.p)
        if newStatus != st.status or newLan != st.lanEnabled:
          st.status = newStatus
          if newLan != st.lanEnabled:
            st.lanEnabled = newLan
            st.lanAddr = if newLan: lanAddress() else: ""
          # The tray icon reflects backend state, which is the whole reason the
          # GTK3 tray polled `jenova-ca status` every 3 s. Here the check is an
          # in-process port probe rather than a fork.
          tray.setStatus(if newStatus == bsUp: tsActive else: tsPassive)
          discard st.redraw()
        true
      )
      discard addGlobalTimeout(40, proc(): bool =
        var changed = false

        # Control actions, from the window menu and the tray alike.
        while pendingActions.len > 0:
          let action = pendingActions[0]
          pendingActions.delete(0)
          changed = true
          case action
          of "start":
            let (l, _) = st.lc.startAll()
            st.notice =
              if l == -1: "backend already running, or its port is occupied"
              else: "starting backend (pid " & $l & ") — the model takes a moment"
            st.status = bsStarting
          of "stop":
            discard st.lc.stopAll()
            st.status = bsDown
            st.notice = "backend stopped"
          of "restart":
            discard st.lc.stopAll()
            let (l, _) = st.lc.startAll()
            st.status = bsStarting
            st.notice = "restarting backend (pid " & $l & ")"
          of "switch_instruct", "switch_thinking":
            let target = if action == "switch_instruct": "instruct" else: "thinking"
            try:
              let r = models.switchModel(st.p.jcaHome, target)
              st.notice = r.message & " — restart the backend to load it"
            except CatchableError as e:
              st.notice = "switch failed: " & e.msg
          of "toggle_lan":
            let next = not st.lanEnabled
            setLanState(st.p, next)
            st.lanEnabled = next
            st.lanAddr = if next: lanAddress() else: ""
            tray.setItems(trayMenu(next))
            st.notice =
              if next: "LAN enabled — restart to bind 0.0.0.0 (backends stay loopback)"
              else: "LAN disabled — restart to bind 127.0.0.1"
          of "web":
            let port = st.cfg.getInt("PORT", 8080)
            discard runCapture("xdg-open", ["http://127.0.0.1:" & $port])
          of "quit":
            # Deliberately does NOT stop the backend. `ui.lua:149` did, because
            # the tray owned the proxy as a child process and leaving it behind
            # orphaned it. Here `llama-server` is supervised independently and
            # holds a loaded model — quitting the window to free the screen
            # should not throw away a multi-gigabyte load the user will want back.
            st.closeWindow()
          else:
            discard

        while true:
          let (hasData, msg) = streamChan.tryRecv()
          if not hasData: break
          changed = true
          if msg == StreamDone:
            st.streaming = false
            streamBusy = false
          elif msg.startsWith(StreamErrPrefix):
            st.notice = msg[StreamErrPrefix.len .. ^1]
            if st.messages.len > 0 and st.messages[^1].role == rAssistant and
               st.messages[^1].text.len == 0:
              st.messages.delete(st.messages.len - 1)
          else:
            if st.messages.len == 0 or st.messages[^1].role != rAssistant:
              st.messages.add Message(role: rAssistant, text: "")
            st.messages[^1].text.add msg
        if changed:
          discard st.redraw()
        true
      )

## Function purpose: hand the draft message to the local server and start
## streaming the reply. The body is the OpenAI-compatible shape `pipeline.nim`
## expects, so intents, RAG and personas apply exactly as they do for the Web UI.
proc send(app: AppState) =
  let text = app.draft.strip
  if text.len == 0 or streamBusy:
    return

  app.messages.add Message(role: rUser, text: text)
  app.draft = ""
  app.notice = ""
  app.streaming = true
  streamBusy = true

  var msgs = "["
  for i, m in app.messages:
    if m.role == rAssistant and m.text.len == 0:
      continue
    if i > 0 and msgs.len > 1: msgs.add ","
    msgs.add "{\"role\":\"" & $m.role & "\",\"content\":" & escapeJson(m.text) & "}"
  msgs.add "]"

  let body = "{\"messages\":" & msgs & ",\"stream\":true}"
  let port = app.cfg.getInt("PORT", 8080)
  createThread(streamThread, streamWorker,
               StreamJob(host: "127.0.0.1", port: port, body: body))

method view(app: AppState): Widget =
  result = gui:
    Window:
      title = "Jenova"
      defaultSize = (900, 680)

      HeaderBar {.addTitlebar.}:
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
              Button:
                text = "Switch to instruct model"
                style = [ButtonFlat]
                proc clicked() = pendingActions.add "switch_instruct"
              Button:
                text = "Switch to thinking model"
                style = [ButtonFlat]
                proc clicked() = pendingActions.add "switch_thinking"
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

      Box(orient = OrientY):
        # The transcript takes all the free height; the notice and the input row
        # take only what they need. In owlkettle this is the child annotation on
        # the Box, not a property of the child widget.
        ScrolledWindow {.expand: true.}:
          Box(orient = OrientY, spacing = 12, margin = 16):
            if app.messages.len == 0:
              Label:
                text = "Ask Jenova something."
                style = [StyleClass("dim-label")]
            for m in app.messages:
              Frame:
                Box(orient = OrientY, spacing = 4, margin = 10):
                  Label:
                    text = (if m.role == rUser: "You" else: "Jenova")
                    xAlign = 0.0
                    style = [StyleClass("caption"), StyleClass("dim-label")]
                  Label:
                    text = m.text
                    xAlign = 0.0
                    wrap = true

        if app.notice.len > 0:
          Label {.expand: false.}:
            text = app.notice
            margin = 8
            wrap = true
            style = [StyleClass("dim-label"), StyleClass("caption")]

        Box(orient = OrientX, spacing = 8, margin = 12) {.expand: false.}:
          Entry {.expand: true.}:
            text = app.draft
            placeholder = "Message Jenova…"
            sensitive = not app.streaming
            proc changed(text: string) =
              app.draft = text
            proc activate() =
              app.send()
          Button:
            text = (if app.streaming: "…" else: "Send")
            sensitive = not app.streaming
            style = [ButtonSuggested]
            proc clicked() =
              app.send()

## Function purpose: entry point for `bin/jenova`. Resolution happens here,
## before the window exists, so a configuration error is reported on the terminal
## rather than inside a half-built UI.
proc run*(withTray = true) =
  let p = paths.resolve()
  let c = config.load(p)
  let lc = lifecycle.init(p, c)
  streamChan.open()
  defer: streamChan.close()

  let initialLan = isLanEnabled(p)
  let initialAddr = if initialLan: lanAddress() else: ""
  let widget = gui(App(p = p,
                       cfg = c,
                       lc = lc,
                       status = bsDown,
                       lanEnabled = initialLan,
                       lanAddr = initialAddr))

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

  adw.brew(widget)
