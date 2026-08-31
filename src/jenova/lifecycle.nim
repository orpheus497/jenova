## Script function and purpose: process lifecycle — starting, supervising and
## stopping `llama-server` and the embedding server, replacing the orchestration
## half of `bin/jenova-ca`.
##
## **Ruling D-AF makes this load-bearing rather than convenience.** `llama-server`
## is the inference engine, so the harness has to own its lifecycle: something
## must build its command line from the active hardware profile, start it, notice
## when it dies, and stop it cleanly. `bin/jenova-ca` did that in shell; this is
## the same job in the binary that already owns configuration and paths.
##
## **B-13 is fixed by construction here.** In `jenova-ca` the client-facing port
## was never started by `--daemon` — `PROXY_PID` was declared and never assigned,
## the proxy was spawned by the tray instead, and `_probe_health` targeted
## `$LLAMA_PORT`, so a wedged proxy read as healthy. In this core the HTTP server
## and the backend supervisor are the same process, so "the daemon is up" and
## ":8080 is answering" cannot disagree.
##
## The argument construction reproduces `bin/jenova-ca:119-200` exactly, because
## those flags are the accumulated result of tuning against real hardware and a
## paraphrase would change generation behaviour in ways no test here would catch.

## `osproc` and `strtabs` were dropped 2026-08-31: both became unused when
## `start` moved from `startProcess` to fork/dup2/execv (see the note at `start`),
## and an import that no longer carries anything is dead code by the Codebase
## Integrity Standard's third class.
import std/[os, strutils, strformat, posix, times, net]
import ./config
import ./paths

type
  Backend* = enum
    beLlama = "llama-server"
    beEmbed = "embed-server"

  ProcState* = object
    pid*: int
    running*: bool

  Lifecycle* = object
    paths*: Paths
    cfg*: Config
    llamaPort*: int
    embedPort*: int
    bindHost*: string

proc pidFileFor(l: Lifecycle, be: Backend): string =
  case be
  of beLlama: l.paths.state / "llama-server.pid"
  of beEmbed: l.paths.state / "llama-embed.pid"

proc logFileFor*(l: Lifecycle, be: Backend): string =
  case be
  of beLlama: l.paths.logDir / "llama-server.log"
  of beEmbed: l.paths.logDir / "llama-embed.log"

proc init*(p: Paths, c: Config): Lifecycle =
  result.paths = p
  result.cfg = c
  result.llamaPort = c.getInt("LLAMA_PORT", 8081)
  result.embedPort = c.getInt("LLAMA_EMBED_PORT", 8082)
  # Backends bind loopback regardless of --lan: ruling S-0 and D-E. Only the
  # client-facing port follows the LAN flag, so `--lan` cannot publish two
  # unauthenticated inference endpoints to the network.
  result.bindHost = c.get("BACKEND_BIND_HOST", "127.0.0.1")

## Function purpose: count the devices in a comma-separated `DEVICES` value.
## `-ts` is only meaningful with more than one, which is why `jenova-ca:157`
## counts before deciding to pass it.
proc deviceCount(devices: string): int =
  if devices.strip().len == 0: return 0
  for d in devices.split(','):
    if d.strip().len > 0: inc result

## Function purpose: build `llama-server`'s argument vector from the active
## profile, reproducing `bin/jenova-ca:119-236`.
##
## Two branches carry real tuning intent and are kept as they are:
##
## * **`NGL_AGENT=all`** uses `-fitt` auto-fit, and adds `-ts` only when more
##   than one device is present. This is the dual-GPU path.
## * **An explicit layer count** uses `-ngl N` and **skips `-fitt` and `-ts`
##   entirely** — they conflict with an explicit count, and passing both is how
##   a single-GPU UMA profile ends up mis-offloaded.
proc llamaArgs*(l: Lifecycle): seq[string] =
  let c = l.cfg
  let modelPath = c.get("MODEL_PATH")
  let devices = c.get("DEVICES")
  let nglAgent = c.get("NGL_AGENT", "all")
  let fitTarget = c.get("FIT_TARGET", "128")
  let tensorSplit = c.get("TENSOR_SPLIT")
  let kvCache = c.get("KV_CACHE_TYPE")

  result = @["-m", modelPath]

  if devices.strip().len > 0:
    result.add ["-dev", devices]

  result.add ["-sm", "layer"]
  if nglAgent.len == 0 or nglAgent == "all":
    result.add ["-fitt", fitTarget]
    if deviceCount(devices) > 1 and tensorSplit.strip().len > 0:
      result.add ["-ts", tensorSplit]
  else:
    result.add ["-ngl", nglAgent]

  if kvCache.strip().len > 0:
    result.add ["-ctk", kvCache, "-ctv", kvCache]

  result.add ["-c", $c.getInt("CTX_SIZE", 8192)]
  result.add ["-b", $c.getInt("BATCH_SIZE", 2048)]
  result.add ["-ub", $c.getInt("UBATCH_SIZE", 512)]
  result.add ["-np", $c.getInt("NUM_SLOTS", 1)]
  result.add ["-t", $c.getInt("THREADS", 4)]
  result.add ["-tb", $c.getInt("THREADS_BATCH", 4)]
  result.add ["-fa", "auto", "-cb", "--spm-infill", "--cache-prompt", "--offline"]
  result.add ["--host", l.bindHost, "--port", $l.llamaPort]

  # Speculative decoding, when a draft model exists and is not disabled.
  let draftPath = c.get("MODEL_DRAFT")
  if draftPath.len > 0 and fileExists(draftPath) and c.getInt("JENOVA_DRAFT", 1) != 0:
    result.add ["-md", draftPath]
    let draftDevice = c.get("DRAFT_DEVICE")
    if draftDevice.strip().len > 0:
      result.add ["-devd", draftDevice]
    result.add ["-ngld", c.get("DRAFT_NGL", "all")]
    result.add ["--spec-draft-n-max", "16", "--spec-draft-n-min", "4",
                "--spec-draft-p-min", "0.6"]

## Function purpose: the embedding server's arguments, from `jenova-ca:710-721`.
## **Vulkan is disabled and offload is zero deliberately** — the embedding model
## runs on CPU so it does not compete for VRAM with the agent model, which on a
## 4 GB card is the difference between both loading and neither.
proc embedArgs*(l: Lifecycle): seq[string] =
  @["-m", l.cfg.get("MODEL_EMBED"),
    "--embedding", "-dev", "none", "-ngl", "0",
    "-c", "4096", "-b", "512",
    "-t", $l.cfg.getInt("THREADS", 4),
    "--offline",
    "--host", l.bindHost, "--port", $l.embedPort]

proc readPid(path: string): int =
  if not fileExists(path): return 0
  try: parseInt(readFile(path).strip()) except CatchableError: 0

## Function purpose: is this pid alive? `kill(pid, 0)` tests for existence and
## permission without sending a signal — the same check `jenova-ca:404` makes
## with `kill -0`.
proc isAlive*(pid: int): bool =
  pid > 0 and kill(pid.Pid, 0) == 0

proc state*(l: Lifecycle, be: Backend): ProcState =
  let pid = readPid(pidFileFor(l, be))
  ProcState(pid: pid, running: isAlive(pid))

## Function purpose: start one backend, detached, with its output to a log.
## Returns 0 if it was already running or could not start.
##
## `LD_LIBRARY_PATH` is set from the resolved lib directory because
## `llama-server` needs its shared libraries and the source tree keeps them in
## `external/ext_bin/bin` — the same reason `jenova-ca:146` sets it. **This is
## also N-23's fix on the supervisor side:** the path is resolved from
## `paths.llamaLibDir`, which already distinguishes an installed layout from a
## source tree, rather than being hard-coded to either.
## Function purpose: is anything already bound to this backend's port? The pid
## file is not sufficient evidence on its own — if it is deleted or lost while
## the process lives, `state()` reports "not running" and a second
## `llama-server` gets started, which then fails to bind and dies. The port is
## the authority on whether the slot is occupied.
##
## `bin/jenova-ca:848` covered the same case with
## `pkill -f "llama-server.*--port.*$PORT"`. That kills by matching a command
## line, which can match something the harness does not own; checking the bind
## refuses to start a duplicate without killing anything.
proc portInUse*(port: int): bool =
  var s: Socket
  try:
    s = newSocket(buffered = false)
    s.connect("127.0.0.1", port.Port, timeout = 500)
    result = true
  except CatchableError:
    result = false
  finally:
    try:
      if not s.isNil: s.close()
    except CatchableError: discard

proc start*(l: Lifecycle, be: Backend): int =
  let existing = l.state(be)
  if existing.running:
    return existing.pid

  # An orphan holding the port: the pid file says nothing is running, but
  # something is. Starting a second copy would produce a bind failure and a
  # confusing log rather than an honest refusal.
  let port = if be == beLlama: l.llamaPort else: l.embedPort
  if portInUse(port):
    return -1

  let binary = l.paths.llamaServer
  if not fileExists(binary):
    return 0

  # Action purpose: refuse to exec with no model rather than handing
  # `llama-server` an empty `-m` and letting it fail with its own message. An
  # unresolved model path is a configuration problem, and the process that owns
  # the configuration should be the one to say so.
  let modelKey = if be == beLlama: "MODEL_PATH" else: "MODEL_EMBED"
  let model = l.cfg.get(modelKey)
  if model.len == 0 or not fileExists(model):
    return 0   # For the embed server this is a supported state, not a failure.

  let args = case be
             of beLlama: l.llamaArgs()
             of beEmbed: l.embedArgs()

  createDir(l.paths.logDir)
  createDir(l.paths.state)

  let logPath = logFileFor(l, be)

  # Action purpose: fork/dup2/exec rather than `startProcess`, and the reason is
  # a defect this replaced rather than a preference.
  #
  # `startProcess` with `poStdErrToStdOut` hands the child a **pipe**, and a pipe
  # nobody reads fills at roughly 64 KB and then **blocks the writer**.
  # `llama-server` prints device enumeration and per-layer offload progress while
  # loading a model — comfortably more than 64 KB — so it stalled mid-load and
  # never finished. The failure looked like "the model did not load" and was
  # invisible, because the same defect meant nothing was captured to diagnose it.
  #
  # Redirecting straight to a file, as `bin/jenova-ca` does with `> "$log" 2>&1`,
  # removes the pipe entirely: there is no buffer to fill and no reader to need.
  var argv: seq[string] = @[binary]
  argv.add args

  let pid = fork()
  if pid < 0:
    return 0
  if pid == 0:
    # Child. Detach from the controlling terminal so the backend survives this
    # process exiting, then point stdout and stderr at the log before exec.
    discard setsid()
    let fd = posix.open(logPath.cstring,
                        O_WRONLY or O_CREAT or O_APPEND, 0o644.Mode)
    if fd >= 0:
      discard dup2(fd, 1)
      discard dup2(fd, 2)
      if fd > 2: discard posix.close(fd)
    discard posix.close(0)

    let libDir = l.paths.llamaLibDir
    if dirExists(libDir):
      let existingPath = getEnv("LD_LIBRARY_PATH")
      putEnv("LD_LIBRARY_PATH",
             if existingPath.len > 0: libDir & ":" & existingPath else: libDir)
    if be == beEmbed:
      # CPU-only by design: the embedding model must not compete for VRAM with
      # the agent model.
      putEnv("GGML_VULKAN_DISABLE", "1")

    var cargs = allocCStringArray(argv)
    discard execv(binary.cstring, cargs)
    # Only reached if execv failed; the parent already has the pid, so exiting
    # non-zero is what makes the failure visible to the next status check.
    quit(127)

  try:
    writeFile(pidFileFor(l, be), $pid)
    let f = open(logPath, fmAppend)
    f.write(&"[{now()}] jenova-core started {binary} {args.join(\" \")}\n")
    f.close()
  except IOError, OSError:
    discard
  pid

## Function purpose: stop a backend. SIGTERM, a grace period, then SIGKILL —
## the escalation `jenova-ca:373-386` performs, because `llama-server` needs a
## moment to release GPU memory and killing it outright can leave the device in
## a state the next start has to recover from.
proc stop*(l: Lifecycle, be: Backend, graceMs = 2000): bool =
  let st = l.state(be)
  if not st.running:
    removeFile(pidFileFor(l, be))
    return true

  discard kill(st.pid.Pid, SIGTERM)
  let deadline = epochTime() + graceMs.float / 1000.0
  while epochTime() < deadline:
    if not isAlive(st.pid):
      removeFile(pidFileFor(l, be))
      return true
    sleep(50)

  discard kill(st.pid.Pid, SIGKILL)
  sleep(100)
  removeFile(pidFileFor(l, be))
  not isAlive(st.pid)

proc startAll*(l: Lifecycle): tuple[llama, embed: int] =
  (l.start(beLlama), l.start(beEmbed))

## Function purpose: is a backend answering HTTP, not merely holding a pid?
## **The distinction is the whole point of the watchdog.** `jenova-ca:258` probes
## the port for exactly this reason: a `llama-server` that has wedged — out of
## VRAM mid-load, or stuck on a request — keeps its pid and stops serving.
## A pid check alone reports that as healthy, which is the failure mode B-13
## produced from the other direction.
proc healthy*(l: Lifecycle, be: Backend, timeoutMs = 2000): bool =
  let port = if be == beLlama: l.llamaPort else: l.embedPort
  var s: Socket
  try:
    s = newSocket(buffered = false)
    s.connect("127.0.0.1", port.Port, timeout = timeoutMs)
    s.send("GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    var line = ""
    s.readLine(line, timeout = timeoutMs)
    result = line.contains("200")
  except CatchableError:
    result = false
  finally:
    try:
      if not s.isNil: s.close()
    except CatchableError: discard

proc stopAll*(l: Lifecycle): bool =
  let a = l.stop(beLlama)
  let b = l.stop(beEmbed)
  a and b

## Function purpose: the supervision loop, replacing `bin/jenova-ca:453`'s
## `_watchdog`. Runs on its own thread inside `serve`, so the harness supervises
## its own engine rather than depending on a separate shell process — which is
## what made B-13 possible in the first place.
##
## The three constants are `jenova-ca`'s and are kept:
##
## * **30 s interval** — long enough that a model still loading is not mistaken
##   for a dead one.
## * **3 consecutive failures** before acting — a single missed probe during a
##   long prompt ingestion is not a fault, and restarting on one would be worse
##   than the fault.
## * **60 s restart cooldown** — without it a backend that cannot start (bad
##   device, missing model) is restarted every interval forever, which turns a
##   configuration error into a fork bomb.
##
## **It checks health, not liveness.** A wedged `llama-server` keeps its pid; only
## the port tells the truth.
type WatchConfig* = object
  intervalMs*: int
  cooldownMs*: int
  maxFailures*: int

proc defaultWatch*(): WatchConfig =
  WatchConfig(intervalMs: 30_000, cooldownMs: 60_000, maxFailures: 3)

proc watchOnce*(l: Lifecycle, be: Backend, failures: var int,
                lastRestart: var float, wc: WatchConfig): string =
  ## One tick. Returns a log line, or empty when nothing happened. Separated
  ## from the loop so it can be tested without waiting 30 seconds.
  let st = l.state(be)
  if st.running and l.healthy(be):
    if failures > 0:
      failures = 0
      return &"{be}: recovered"
    return ""

  inc failures
  if failures < wc.maxFailures:
    return &"{be}: probe failed ({failures}/{wc.maxFailures})"

  let now = epochTime()
  if now - lastRestart < wc.cooldownMs.float / 1000.0:
    return &"{be}: unhealthy, holding off (cooldown)"

  lastRestart = now
  failures = 0
  discard l.stop(be)
  let pid = l.start(be)
  if pid == 0:
    return &"{be}: restart FAILED — check {l.logFileFor(be)}"
  &"{be}: restarted (pid {pid})"

## Function purpose: render status for the `status` verb. Reports each backend
## separately rather than collapsing to one word, because "the agent model is up
## but embeddings are not" is a real and common state — it is exactly what
## `search.lua` degrades to, and hiding it is how B-14 stayed invisible.
proc describe*(l: Lifecycle): string =
  var lines: seq[string]
  for be in [beLlama, beEmbed]:
    let st = l.state(be)
    let port = if be == beLlama: l.llamaPort else: l.embedPort
    if st.running:
      lines.add &"  {be}: running (pid {st.pid}) on {l.bindHost}:{port}"
    elif st.pid > 0:
      lines.add &"  {be}: NOT running (stale pid {st.pid})"
    else:
      lines.add &"  {be}: not running"
  lines.join("\n")
