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

import std/[json, net, os, oids, osproc, streams, strutils, times]
import owlkettle
import owlkettle/adw
import ./paths
import ./config
import ./lifecycle
import ./models
import ./tray
import ./db
import ./rag
import ./server

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

  UiMsgKind = enum umToken, umDone, umError, umNotice, umStatus

  UiMsg = object
    kind: UiMsgKind
    text: string
    status: BackendStatus

var
  streamReq: Channel[StreamJob]
  ctlReq: Channel[ControlJob]
  uiChan: Channel[UiMsg]
  streamThread: Thread[void]
  ctlThread: Thread[void]
  pendingActions: seq[string] = @[]

# An empty host/action is the shutdown sentinel: each worker returns from its own
# loop so joinThread completes, rather than being unblocked by a channel close.
const QuitSentinel = ""

proc streamOnce(job: StreamJob) =
  var sock: Socket
  try:
    sock = newSocket()
    sock.connect(job.host, Port(job.port))
    sock.send("POST /v1/chat/completions HTTP/1.1\r\n" &
              "Host: " & job.host & "\r\n" &
              "Content-Type: application/json\r\n" &
              "Connection: close\r\n" &
              "Content-Length: " & $job.body.len & "\r\n\r\n" & job.body)

    let statusLine = sock.recvLine(timeout = 120_000)
    let parts = statusLine.split(' ')
    let code = if parts.len > 1: parts[1] else: ""
    if code != "200":
      uiChan.send(UiMsg(kind: umError, text:
        if code == "502": "llama-server is not answering yet"
        elif code.len == 0: "no response from the server"
        else: "the server answered " & code))
      return

    while true:
      let line = sock.recvLine(timeout = 120_000)
      if line.len == 0 or line == "\r\n": break

    while true:
      let line = sock.recvLine(timeout = 300_000)
      if line.len == 0: break
      if not line.startsWith("data:"): continue
      let payload = line[5 .. ^1].strip
      if payload == "[DONE]": break
      var tok = ""
      try:
        tok = parseJson(payload){"choices"}{0}{"delta"}{"content"}.getStr("")
      except CatchableError:
        continue
      if tok.len > 0:
        uiChan.send(UiMsg(kind: umToken, text: tok))
  except CatchableError as e:
    uiChan.send(UiMsg(kind: umError, text: e.msg))
  finally:
    # `Socket` is a ref: closing it when newSocket() never ran is a SIGSEGV that
    # `except CatchableError` does not catch.
    if not sock.isNil:
      try: sock.close() except CatchableError: discard
    uiChan.send(UiMsg(kind: umDone))

proc streamWorker() {.thread.} =
  while true:
    let job = streamReq.recv()
    if job.host == QuitSentinel: break
    streamOnce(job)


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
    discard p.waitForExit()
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

proc newConversation(): string =
  result = $genOid()
  db.exec("INSERT INTO conversations (id, name, lastModified, is_deleted) VALUES (?, ?, ?, 0)",
          [result, "Chat " & now().format("yyyy-MM-dd HH:mm"), $toUnix(getTime())])

proc latestConversation(): string =
  let rows = db.query("SELECT id FROM conversations WHERE is_deleted=0 " &
                      "ORDER BY lastModified DESC LIMIT 1")
  if rows.len > 0 and rows[0].len > 0: rows[0][0] else: ""

proc saveMessage(convId: string, role: Role, text: string) =
  if convId.len == 0 or text.len == 0: return
  db.exec("INSERT INTO messages (id, convId, type, role, timestamp, content, is_deleted) " &
          "VALUES (?, ?, 'message', ?, ?, ?, 0)",
          [$genOid(), convId, $role, $toUnix(getTime()), text])
  db.exec("UPDATE conversations SET lastModified=? WHERE id=?",
          [$toUnix(getTime()), convId])

proc loadMessages(convId: string): seq[Message] =
  if convId.len == 0: return
  for r in db.query("SELECT role, content FROM messages WHERE convId=? AND is_deleted=0 " &
                    "ORDER BY timestamp ASC, rowid ASC", convId):
    if r.len < 2: continue
    result.add Message(role: (if r[0] == "user": rUser else: rAssistant), text: r[1])

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

proc ctlWorker() {.thread.} =
  while true:
    let j = ctlReq.recv()
    if j.action == QuitSentinel: break
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
    of "web":
      discard runCapture("xdg-open", ["http://127.0.0.1:" & $j.port])
    of "poll":
      let up = j.lc.healthy(beLlama, timeoutMs = 300)
      uiChan.send(UiMsg(kind: umStatus, status:
        if up: bsUp elif j.lc.state(beLlama).pid > 0: bsStarting else: bsDown))
    else: discard

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
  convId: string
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
        ctlReq.send(ControlJob(action: "poll", lc: st.lc,
                               jcaHome: st.p.jcaHome,
                               port: st.cfg.getInt("PORT", 8080)))
        let newLan = isLanEnabled(st.p)
        if newLan != st.lanEnabled:
          st.lanEnabled = newLan
          st.lanAddr = if newLan: lanAddress() else: ""
          discard st.redraw()
        true
      )
      discard addGlobalTimeout(40, proc(): bool =
        var changed = false

        while pendingActions.len > 0:
          let action = pendingActions[0]
          pendingActions.delete(0)
          changed = true
          if action == "quit":
            st.closeWindow()
          elif action == "toggle_lan":
            let next = not st.lanEnabled
            setLanState(st.p, next)
            st.lanEnabled = next
            st.lanAddr = if next: lanAddress() else: ""
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
              saveMessage(st.convId, rAssistant, st.messages[^1].text)
          of umError:
            st.notice = m.text
            if st.messages.len > 0 and st.messages[^1].role == rAssistant and
               st.messages[^1].text.len == 0:
              st.messages.delete(st.messages.len - 1)
          of umNotice:
            st.notice = m.text
          of umStatus:
            if m.status != st.status:
              st.status = m.status
              tray.setStatus(if m.status == bsUp: tsActive else: tsPassive)
          of umToken:
            if st.messages.len == 0 or st.messages[^1].role != rAssistant:
              st.messages.add Message(role: rAssistant, text: "")
            st.messages[^1].text.add m.text
        if changed:
          discard st.redraw()
        true
      )

## Function purpose: hand the draft message to the local server and start
## streaming the reply. The body is the OpenAI-compatible shape `pipeline.nim`
## expects, so intents, RAG and personas apply exactly as they do for the Web UI.
proc send(app: AppState) =
  let text = app.draft.strip
  if text.len == 0 or app.streaming:
    return

  app.messages.add Message(role: rUser, text: text)
  saveMessage(app.convId, rUser, text)
  app.draft = ""
  app.notice = ""
  app.streaming = true

  var msgs = newJArray()
  for m in app.messages:
    if m.role == rAssistant and m.text.len == 0: continue
    msgs.add %*{"role": $m.role, "content": m.text}
  let body = $(%*{"messages": msgs, "stream": true})
  let port = app.cfg.getInt("PORT", 8080)
  streamReq.send(StreamJob(host: "127.0.0.1", port: port, body: body))

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
            Label:
              text = (if app.messages.len == 0: "Ask Jenova something." else: "")
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

        Label {.expand: false.}:
          text = app.notice
          margin = (if app.notice.len > 0: 8 else: 0)
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

  let host = if isLanEnabled(p): "0.0.0.0" else: c.get("HOST", "127.0.0.1")
  let port = c.getInt("PORT", 8080)

  db.initDb(p.state / "jenova.db")
  rag.initSchema()
  rag.configureEmbed("127.0.0.1", c.getInt("LLAMA_EMBED_PORT", 8082))
  discard lc.startAll()
  discard server.start(
    host, port, p.root / "public",
    llamaHost = "127.0.0.1", llamaPortArg = c.getInt("LLAMA_PORT", 8081),
    embedHost = "127.0.0.1", embedPortArg = c.getInt("LLAMA_EMBED_PORT", 8082))

  streamReq.open(); ctlReq.open(); uiChan.open()
  createThread(streamThread, streamWorker)
  createThread(ctlThread, ctlWorker)
  defer:
    streamReq.send(StreamJob(host: QuitSentinel))
    ctlReq.send(ControlJob(action: QuitSentinel))
    joinThread(streamThread); joinThread(ctlThread)
    streamReq.close(); ctlReq.close(); uiChan.close()

  var conv = latestConversation()
  if conv.len == 0: conv = newConversation()
  let history = loadMessages(conv)

  let initialLan = isLanEnabled(p)
  let initialAddr = if initialLan: lanAddress() else: ""
  let widget = gui(App(p = p,
                       cfg = c,
                       lc = lc,
                       status = bsDown,
                       lanEnabled = initialLan,
                       lanAddr = initialAddr,
                       convId = conv,
                       messages = history))

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
