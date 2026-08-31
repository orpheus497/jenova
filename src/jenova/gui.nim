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

import std/[json, net, os, oids, osproc, streams, strutils, tables, times]
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

type
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

proc loadNote(id: string): tuple[found: bool, title, content: string] =
  for r in db.query("SELECT title, content FROM notes WHERE id=?", [id]):
    if r.len >= 2: return (true, r[0], r[1])
  (false, "", "")

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
  noteBuffer: TextBuffer = newTextBuffer()
  expanded: Table[string, bool]
  renaming: string
  renameDraft: string
  search: string
  sidebarOpen: bool = true
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
      # Action purpose: the canvas frame clock, separate from the two above
      # because it is the only timer that redraws while nothing has happened.
      # `canvas.draw` is pure rendering and never asks for a redraw itself, so
      # without this the field would be static. Disabled by `CANVAS=0`, which
      # exists because this is the one thing in the window that costs CPU when
      # the program is idle.
      if st.cfg.get("CANVAS", "1") != "0":
        discard addGlobalTimeout(canvas.FrameMs, proc(): bool =
          canvas.step()
          # `queueFrame`, not `redraw`. `redraw()` diffs the entire widget tree,
          # so animating the canvas through it re-bound every signal handler in
          # the window thirty times a second — see the note in `canvas.nim`.
          canvas.queueFrame()
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
          elif action == "toggle_fullscreen":
            st.fullscreen = not st.fullscreen
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
            # The reply bumped `lastModified`, so the cached list is now in the
            # wrong order. Refreshed here rather than in `view` for the reason
            # `convs` is cached at all.
            st.convs = listConversations()
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

## Function purpose: switch the transcript to another conversation. Refused mid
## stream: tokens in flight are appended to `messages[^1]` by the drain timer,
## which would otherwise write the tail of one conversation into another.
proc selectConversation(app: AppState, id: string) =
  if app.streaming or id == app.convId: return
  app.convId = id
  app.messages = loadMessages(id)
  app.openNote = ""
  app.notice = ""

proc reloadTree(app: AppState) =
  app.convs = listConversations()
  app.workspaces = listWorkspaces()
  app.projects = listProjects()
  app.folders = listFolders()
  app.notes = listNotes()
  app.files = listFiles()

proc openNoteEditor(app: AppState, id: string) =
  if app.streaming: return
  let n = loadNote(id)
  if not n.found:
    app.notice = "note not found"
    return
  app.openNote = id
  app.noteTitle = n.title
  app.noteBuffer.text = n.content
  app.notice = ""

## Function purpose: write the open note back through `api.putEntity`, the same
## call the HTTP route makes, so the filesystem mirror and the per-workspace git
## repo apply exactly as they do for the Web UI. The parent ids are resent
## unchanged because `putEntity` writes the whole row.
proc saveNote(app: AppState) =
  if app.openNote.len == 0: return
  var node = %*{"id": app.openNote,
                "title": app.noteTitle,
                "content": app.noteBuffer.text(),
                "updatedAt": int(epochTime() * 1000)}
  for n in app.notes:
    if n.id == app.openNote:
      node["folderId"] = %n.folderId
      node["projectId"] = %n.projectId
      node["workspaceId"] = %n.workspaceId
  if api.putEntity("notes", node):
    app.reloadTree()
    app.notice = "note saved"
  else:
    app.notice = "could not save note"

proc newChat(app: AppState, wsId = "", projId = "", folderId = "") =
  if app.streaming: return
  let id = newConversation()
  if wsId.len > 0 or projId.len > 0 or folderId.len > 0:
    db.exec("UPDATE conversations SET workspaceId=?, projectId=?, folderId=? WHERE id=?",
            [wsId, projId, folderId, id])
  app.reloadTree()
  app.convId = id
  app.messages = @[]
  app.openNote = ""
  app.notice = ""

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
  let id = fssync.newUuid()
  var node = %*{"id": id, "title": "New note", "content": "",
                "workspaceId": wsId, "projectId": projId, "folderId": folderId,
                "updatedAt": int(epochTime() * 1000)}
  if api.putEntity("notes", node):
    app.reloadTree()
    app.openNoteEditor(id)
  else:
    app.notice = "could not create note"

proc deleteNode(app: AppState, entity, id: string) =
  if api.deleteEntity(entity, id):
    if entity == "conversations" and id == app.convId:
      app.convId = ""
      app.messages = @[]
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
      # `putEntity` writes the whole row, so the parent ids and the note's body
      # have to be resent or the rename would blank them.
      var node = %*{"id": id, "updatedAt": int(epochTime() * 1000)}
      node[if entity == "notes": "title" else: "name"] = %name
      if entity == "notes":
        let n = loadNote(id)
        node["content"] = %(if id == app.openNote: app.noteBuffer.text()
                            else: n.content)
        if id == app.openNote: app.noteTitle = name
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
      discard api.putEntity(entity, node)
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

## A read-only, syntax-highlighted code block (G-7). Declared here rather than in
## `sourceview.nim` because owlkettle's `renderable` emits an unexported type;
## the FFI stays in that module and this is only the widget around it.
##
## No ScrolledWindow wraps this and none should — owlkettle's never calls
## `set_propagate_natural_height`, which is what collapsed the plain-Label code
## blocks to their header (G-11). The view word-wraps instead.
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

proc messageBody(app: AppState, m: Message): Widget =
  ## User turns are plain text; only assistant output is markdown.
  if m.role == rUser:
    return gui:
      Label:
        text = m.text
        xAlign = 0.0
        wrap = true
        style = [StyleClass("msg-body")]

  gui:
    Box(orient = OrientY, spacing = 8):
      for b in markdown.parse(m.text):
        if b.kind == bkText:
          Label {.expand: false.}:
            text = b.text
            useMarkup = true
            xAlign = 0.0
            wrap = true
            style = [StyleClass("msg-body")]
        else:
          Frame {.expand: false.}:
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
              # No ScrolledWindow around this. owlkettle 3.0.0's ScrolledWindow
              # exposes only `child` and never calls
              # `gtk_scrolled_window_set_propagate_natural_height`, so it keeps
              # GTK's default of ignoring its child's natural size and reports a
              # near-zero minimum — which `expand: false` then grants, collapsing
              # every code block to its header. Wrapping is what the Web UI does
              # with a long line in any case.
              SourceCode {.expand: false.}:
                code = b.text
                language = b.lang
                style = [StyleClass("code-body")]

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
      shortcut = "F11"
      style = [ButtonFlat, StyleClass("row-btn")]
      proc clicked() = app.fullscreen = not app.fullscreen

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
          if entity == "notes": app.openNoteEditor(n.id)
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

method view(app: AppState): Widget =
  result = gui:
    Window:
      title = "Jenova"
      defaultSize = (900, 680)
      fullscreened = app.fullscreen

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

        ToggleButton {.addLeft.}:
          # Mirrors the Web UI's `Sidebar.Trigger`. A toggle rather than a plain
          # button so the control shows whether the panel is open, which a
          # one-way button cannot.
          icon = "sidebar-show-symbolic"
          tooltip = "Toggle sidebar"
          state = app.sidebarOpen
          proc changed(pressed: bool) =
            app.sidebarOpen = pressed

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
              Separator()
              Button:
                text = (if app.fullscreen: "Leave fullscreen" else: "Fullscreen")
                style = [ButtonFlat]
                proc clicked() = pendingActions.add "toggle_fullscreen"
              Separator()
              # The tray has carried the only Quit since it was written
              # (`trayMenu`, id 12). A desktop with no StatusNotifierWatcher gets
              # no tray, which left the headerbar's close button as the single
              # way out of the application.
              Button:
                text = "Quit"
                style = [ButtonFlat]
                proc clicked() = pendingActions.add "quit"

      # The canvas is the Overlay's main child, so it fills the window and every
      # widget below is stacked over it — the GTK equivalent of the Web UI's
      # `inset-0 z-0` canvas under a `z-10` content layer (`+layout.svelte`).
      # `theme.css()` makes those content widgets transparent; an opaque one
      # would hide the field entirely rather than tint it.
      Overlay:
        NeuralCanvas()

        Flap {.addOverlay.}:
          revealed = app.sidebarOpen
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
              placeholderText = "Search chats"
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
            # The transcript takes all the free height; the notice and the action
            # row take only what they need — the child annotation on the Box, not
            # a property of the child. The three children keep the same types in
            # the same order whether a note or the transcript is open, so
            # owlkettle's positional matching never swaps a widget out from under
            # the diff; only what is inside them changes.
            ScrolledWindow {.expand: true.}:
              Box(orient = OrientY, spacing = 12, margin = 16):
                if app.openNote.len > 0:
                  Entry {.expand: false.}:
                    text = app.noteTitle
                    placeholder = "Note title"
                    proc changed(text: string) = app.noteTitle = text
                  # A TextView owns a TextBuffer rather than a string, so it is
                  # driven from `app.noteBuffer` and read back on save — it
                  # cannot be bound to state per redraw the way an Entry is.
                  TextView:
                    buffer = app.noteBuffer
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
                for m in (if app.openNote.len > 0: @[] else: app.messages):
                  Frame {.expand: false.}:
                    style = [StyleClass("msg-card"),
                             StyleClass(if m.role == rUser: "msg-user" else: "msg-agent")]
                    Box(orient = OrientY, spacing = 4, margin = 10):
                      Label {.expand: false.}:
                        text = (if m.role == rUser: "YOU" else: "JENOVA")
                        xAlign = 0.0
                        style = [StyleClass("msg-role"),
                                 StyleClass(if m.role == rUser: "msg-role-user"
                                            else: "msg-role-agent")]
                      insert(app.messageBody(m)) {.expand: false.}

            Label {.expand: false.}:
              text = app.notice
              margin = (if app.notice.len > 0: 8 else: 0)
              wrap = true
              style = [StyleClass("dim-note")]

            Box(orient = OrientX, spacing = 8, margin = 12) {.expand: false.}:
              if app.openNote.len > 0:
                Button {.expand: false.}:
                  text = "Save note"
                  style = [ButtonSuggested]
                  proc clicked() = app.saveNote()
                Button {.expand: false.}:
                  text = "Close"
                  style = [ButtonFlat]
                  proc clicked() =
                    app.openNote = ""
                    app.notice = ""
                insert(app.fullscreenButton()) {.expand: false.}
              else:
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
                insert(app.fullscreenButton()) {.expand: false.}

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
                       convs = listConversations(),
                       workspaces = listWorkspaces(),
                       projects = listProjects(),
                       folders = listFolders(),
                       notes = listNotes(),
                       files = listFiles(),
                       logo = logo))

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

  # `ColorSchemeForceDark` is not a preference: the palette ported from the Web
  # UI is its *dark* theme only — the light one is `oklch`, which GTK4 CSS does
  # not parse — so a light-mode desktop would otherwise get dark text on
  # Adwaita's light chrome.
  adw.brew(widget,
           colorScheme = ColorSchemeForceDark,
           stylesheets = [theme.stylesheet()])
