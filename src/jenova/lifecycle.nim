## Script function and purpose: starting, supervising and stopping the two
## inference backends. `llama-server` is the engine, so this harness owns its
## lifecycle: building its command line from the active hardware profile,
## starting it, noticing when it dies, and stopping it cleanly.
##
## The HTTP server and this supervisor are the same process by design. Split
## across two, "the daemon is up" and "the client port answers" can disagree,
## and a wedged front end reads as healthy.
##
## The argument construction below is tuning accumulated against real hardware;
## a paraphrase changes generation behaviour in ways nothing here would catch.

import std/[os, strutils, strformat, posix, times, net]
import ./config
import ./paths

# Action purpose: `std/posix` binds `fcntl` and `lockf` but none of the flag
# constants they take, so these come from the headers rather than being written
# as numbers a libc could disagree with.
let
  FdSetFd {.importc: "F_SETFD", header: "<fcntl.h>".}: cint
  FdCloexec {.importc: "FD_CLOEXEC", header: "<fcntl.h>".}: cint
  LockTry {.importc: "F_TLOCK", header: "<unistd.h>".}: cint
  LockRelease {.importc: "F_ULOCK", header: "<unistd.h>".}: cint

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

## Function purpose: named here so the writer, `stop` and the watchdog cannot
## disagree about where a backend records itself.
proc pidFileFor(l: Lifecycle, be: Backend): string =
  case be
  of beLlama: l.paths.state / "llama-server.pid"
  of beEmbed: l.paths.state / "llama-embed.pid"

## Function purpose: exported because the window reads the tail of this file to
## report why a backend failed to start.
proc logFileFor*(l: Lifecycle, be: Backend): string =
  case be
  of beLlama: l.paths.logDir / "llama-server.log"
  of beEmbed: l.paths.logDir / "llama-embed.log"

## Function purpose: resolves the ports and bind host once, so nothing below
## re-reads configuration and gets a different answer mid-run.
proc init*(p: Paths, c: Config): Lifecycle =
  result.paths = p
  result.cfg = c
  result.llamaPort = c.getInt("LLAMA_PORT", 8081)
  result.embedPort = c.getInt("LLAMA_EMBED_PORT", 8082)
  # Action purpose: backends bind loopback whatever the LAN flag says. Only the
  # client-facing port follows it, so enabling LAN mode cannot publish two
  # unauthenticated inference endpoints to the network.
  result.bindHost = c.get("BACKEND_BIND_HOST", "127.0.0.1")

## Function purpose: the tensor-split flag is only meaningful with more than one
## device, so the count decides whether it is passed at all.
proc deviceCount(devices: string): int =
  if devices.strip().len == 0: return 0
  for d in devices.split(','):
    if d.strip().len > 0: inc result

## Function purpose: the agent backend's argument vector, built from the active
## profile. Two branches carry real tuning intent: `all` layers uses auto-fit and
## adds a tensor split only with more than one device, while an explicit layer
## count skips both — they conflict with an explicit count, and passing them
## together is how a single-GPU profile ends up mis-offloaded.
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
  # Action purpose: a listed key is always present and merely empty when no conf
  # sets it, so the default belongs here rather than in `get`, which substitutes
  # only for a missing key. Getting that wrong emits a flag with an empty value.
  let flashAttn = c.get("JENOVA_FLASH_ATTN").strip
  result.add ["-fa", if flashAttn.len > 0: flashAttn else: "auto"]
  if c.getInt("JENOVA_MLOCK", 0) != 0: result.add "--mlock"
  if c.getInt("JENOVA_MMAP", 1) == 0: result.add "--no-mmap"
  result.add ["-cb", "--spm-infill", "--cache-prompt", "--offline"]
  result.add ["--host", l.bindHost, "--port", $l.llamaPort]

  # Speculative decoding, only when a draft model exists and is not disabled.
  let draftPath = c.get("MODEL_DRAFT")
  if draftPath.len > 0 and fileExists(draftPath) and c.getInt("JENOVA_DRAFT", 1) != 0:
    result.add ["-md", draftPath]
    let draftDevice = c.get("DRAFT_DEVICE")
    if draftDevice.strip().len > 0:
      result.add ["-devd", draftDevice]
    result.add ["-ngld", c.get("DRAFT_NGL", "all")]
    result.add ["--spec-draft-n-max", "16", "--spec-draft-n-min", "4",
                "--spec-draft-p-min", "0.6"]

## Function purpose: Vulkan is disabled and offload is zero deliberately — the
## embedding model runs on CPU so it does not compete for VRAM with the agent
## model, which on a small card is the difference between both loading and
## neither.
proc embedArgs*(l: Lifecycle): seq[string] =
  @["-m", l.cfg.get("MODEL_EMBED"),
    "--embedding", "-dev", "none", "-ngl", "0",
    "-c", "4096", "-b", "512",
    "-t", $l.cfg.getInt("THREADS", 4),
    "--offline",
    "--host", l.bindHost, "--port", $l.embedPort]

## Function purpose: an absent or unparseable pid file answers zero, which every
## caller already treats as "not running".
proc readPid(path: string): int =
  if not fileExists(path): return 0
  try: parseInt(readFile(path).strip()) except CatchableError: 0

## Function purpose: `setsid` detaches the controlling terminal but does not
## reparent, so a backend stays this process's child — and an unreaped one
## becomes a zombie for which `kill(pid, 0)` still succeeds. Every liveness
## answer below is wrong without this: a dead backend reads as running, `stop`
## spins its grace period on a corpse, and the watchdog logs restarts it never
## performed.
##
## Action purpose: a targeted `waitpid` rather than ignoring `SIGCHLD`. Ignoring
## it auto-reaps process-wide and is one line, but it also stops every
## `waitForExit` elsewhere in this program from collecting its own child, and
## four callers depend on that return value.
##
## `WNOHANG` means this never blocks. A pid that is not this process's child —
## which is what a pid file from a previous run holds — fails with `ECHILD` and
## changes nothing, so the `kill` test below stays the authority there.
proc reapIfExited(pid: int) =
  if pid <= 0: return
  var status: cint = 0
  discard waitpid(Pid(pid), status, WNOHANG)

## Function purpose: `kill(pid, 0)` tests existence and permission without
## sending a signal, but cannot distinguish a running process from a zombie — so
## the reap has to run first or this answers true for a backend that has exited.
proc isAlive*(pid: int): bool =
  if pid <= 0: return false
  reapIfExited(pid)
  kill(pid.Pid, 0) == 0

## Function purpose: pairs the pid with a liveness answer, so no caller can act
## on one without the other.
proc state*(l: Lifecycle, be: Backend): ProcState =
  let pid = readPid(pidFileFor(l, be))
  ProcState(pid: pid, running: isAlive(pid))

## Function purpose: the pid file is not sufficient evidence on its own — lose
## it while the process lives and the slot reads as free, so a second backend is
## started that then fails to bind and dies. The port is the authority on
## whether the slot is occupied.
##
## Action purpose: checking the bind rather than matching a command line to kill.
## A pattern match can hit a process this harness does not own; a bind check
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

## The ceiling on one backend log before rotation. Each start prints device
## enumeration and per-layer offload progress — comfortably more than 64 KB —
## and the watchdog restarts a failing backend every minute, so an unrotated log
## grows without bound inside the user's home directory.
const MaxLogBytes* = 8 * 1024 * 1024

## Function purpose: keeps one log and one previous generation, so the pair is
## bounded at roughly twice the ceiling plus whatever the current run adds.
##
## Action purpose: rotation happens at start, never while running. A mid-run
## rotation moves a file two duplicated descriptors are still writing to, and on
## a log opened for append the child keeps writing to the renamed inode while
## the new file stays empty — losing exactly the output it meant to preserve.
## Before the fork is the only point at which no descriptor is open on it.
##
## Failure is silent by design: a log that cannot be rotated is not a reason to
## refuse to start a backend.
proc rotateLog*(path: string) =
  try:
    if not fileExists(path): return
    if getFileSize(path) <= MaxLogBytes: return
    let prev = path & ".1"
    discard tryRemoveFile(prev)
    moveFile(path, prev)
  except CatchableError:
    discard

## Function purpose: one lock file per backend, so starting the agent model does
## not block starting the embedder.
proc lockFileFor*(l: Lifecycle, be: Backend): string =
  pidFileFor(l, be) & ".lock"

## Function purpose: the window between "nothing is running" and "the pid file
## names my child" is open across processes, not only threads — the window's
## control worker and a separate `serve` watchdog can both reach `start` for one
## backend, both see the slot free, and both fork. The later pid-file write then
## names whichever child lost the bind.
##
## Action purpose: `lockf` rather than an `O_EXCL` lock file, because the kernel
## releases it when the holder exits and a process killed mid-start leaves
## nothing to clean up.
##
## The wait is a bounded retry rather than a blocking one: a holder wedged
## partway through would make a blocking wait indefinite, and the caller is the
## serial control worker or the watchdog. Losing the race is worth a second of
## waiting; it is not worth hanging backend control. The bound is a retry count
## rather than a clock so it cannot be moved by one.
const
  LockTries = 100
  LockRetryMs = 10

type
  ## Three outcomes, and only the first one permits a fork. Exported for the
  ## same reason `rotateLog` is: the distinction between them is not visible in
  ## `start`'s return value — a refusal and a missing binary both answer 0 — so
  ## the only way to assert it is to call the lock directly.
  StartLock* = enum
    slHeld,         ## this process owns the lock for this backend
    slContended,    ## another process is inside `start` for this backend
    slUnavailable   ## the lock could not be taken at all

## Function purpose: two failures, and they are not the same — but neither is a
## state to fork in, so `status` says which happened and the caller stops on
## both.
##
## Action purpose: **failing closed.** An earlier version proceeded unlocked
## when the lock file could not be opened, on the reasoning that an unwritable
## state directory is reported elsewhere. It is not reported *here*, and the
## consequence is specific: two callers both find the slot free, both fork, and
## a multi-gigabyte model is loaded twice. The same directory holds the pid
## file, so a lifecycle that cannot open the lock cannot track or stop what it
## would start either. This matches what `pipe` failure does further down —
## descriptor exhaustion is not a state to fork in, and neither is this.
proc lockStart*(l: Lifecycle, be: Backend): tuple[fd: cint, status: StartLock] =
  result = (cint(-1), slUnavailable)
  try:
    let fd = posix.open(lockFileFor(l, be).cstring,
                        O_WRONLY or O_CREAT, 0o644.Mode)
    if fd < 0: return (cint(-1), slUnavailable)
    # Action purpose: POSIX record locks are not inherited across `fork`, but
    # the descriptor is and nothing closes it before `execve` — so it is marked
    # close-on-exec rather than left open in the backend for its lifetime.
    discard fcntl(fd, FdSetFd, FdCloexec)
    for _ in 0 ..< LockTries:
      if lockf(fd, LockTry, 0) == 0:
        return (fd, slHeld)
      os.sleep(LockRetryMs)
    discard posix.close(fd)
    result = (cint(-1), slContended)
  except CatchableError:
    result = (cint(-1), slUnavailable)

## Function purpose: released explicitly rather than left to process exit,
## because the caller is a long-lived worker and not a short command.
proc unlockStart*(fd: cint) =
  if fd < 0: return
  discard lockf(fd, LockRelease, 0)
  discard posix.close(fd)

## Function purpose: answers the new pid, zero if it was already running, or a
## negative number if something else holds the port — three outcomes the caller
## has to tell apart before reporting a restart.
proc start*(l: Lifecycle, be: Backend): int =
  if l.state(be).running:
    return l.state(be).pid

  createDir(l.paths.state)
  let (lock, lockStatus) = lockStart(l, be)
  defer: unlockStart(lock)

  # Asked again with the lock held: another process may have started this
  # backend while this one waited, making the earlier answer stale.
  let existing = l.state(be)
  if existing.running:
    return existing.pid
  if lockStatus != slHeld:
    # `slContended`: lost the wait, and the holder has not published a pid yet
    # or the check above would have found it. `slUnavailable`: there is no
    # mutual exclusion to rely on at all. Forking under either is the second
    # backend the lock exists to prevent, so both stop here. The watchdog
    # reports this as a failed restart and points at the log.
    return 0

  # An orphan holding the port: the pid file says nothing is running but
  # something is. A second copy would produce a bind failure and a confusing
  # log rather than an honest refusal.
  let port = if be == beLlama: l.llamaPort else: l.embedPort
  if portInUse(port):
    return -1

  let binary = l.paths.llamaServer
  if not fileExists(binary):
    return 0

  # Action purpose: refuse rather than hand the backend an empty `-m` and let it
  # fail with its own message. An unresolved model path is a configuration
  # problem, and the process that owns the configuration should say so.
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
  rotateLog(logPath)

  # Action purpose: fork/dup2/exec rather than `startProcess`, because
  # `startProcess` hands the child a pipe and a pipe nobody reads fills at
  # roughly 64 KB and then blocks the writer. Loading a model prints device
  # enumeration and per-layer offload progress well past that, so the backend
  # stalls mid-load and never finishes — and nothing is captured to say why.
  # Redirecting straight to a file removes the pipe: no buffer to fill, no
  # reader needed.
  var argv: seq[string] = @[binary]
  argv.add args

  # Action purpose: every allocation happens here in the parent, before the
  # fork, and the child calls nothing that allocates.
  #
  # POSIX permits only async-signal-safe calls between `fork` and `exec` in a
  # multithreaded process, and this one always is — `start` is reached from the
  # window's control worker while the GTK and stream threads run, and from the
  # watchdog while fourteen handler threads do. `getenv` and `setenv` allocate
  # through the process-wide libc malloc, so a fork taken while another thread
  # holds that lock leaves the child deadlocked before `execve`, presenting as a
  # backend that never starts with nothing in the log to say why.
  #
  # The environment is therefore materialised as an explicit `envp` here. The
  # child is left with `setsid`, `open`, `dup2`, `close` and `execve`, all of
  # which are async-signal-safe.
  var envSeq: seq[string] = @[]
  block:
    let libDir = l.paths.llamaLibDir
    var ldPath = ""
    if dirExists(libDir):
      let existingPath = getEnv("LD_LIBRARY_PATH")
      ldPath = if existingPath.len > 0: libDir & ":" & existingPath else: libDir
    for key, val in envPairs():
      # Dropped here so the child cannot inherit a stale copy alongside the new
      # one: `execve` takes the array verbatim and would keep both.
      if ldPath.len > 0 and key == "LD_LIBRARY_PATH": continue
      if be == beEmbed and key == "GGML_VULKAN_DISABLE": continue
      envSeq.add key & "=" & val
    if ldPath.len > 0:
      envSeq.add "LD_LIBRARY_PATH=" & ldPath
    if be == beEmbed:
      # CPU-only by design: the embedding model must not compete for VRAM with
      # the agent model.
      envSeq.add "GGML_VULKAN_DISABLE=1"

  var cargs = allocCStringArray(argv)
  var cenv = allocCStringArray(envSeq)

  # Action purpose: `fork` succeeding says a process exists, not that it became
  # the backend. A binary present but not executable, or built for another
  # architecture, fails in `execve` — after the pid is known — so without this
  # the parent publishes a pid file for a process already exiting.
  #
  # The write end is close-on-exec, so a successful `execve` closes it and the
  # parent's read returns 0; a failed one writes `errno` first, which is the
  # only thing distinguishing the two from here. `write` and `_exit` are both
  # async-signal-safe, so the child stays inside what POSIX permits.
  # Without the pipe there is no way to tell a successful `execve` from a child
  # that exited 127, which is the whole point of it. Refusing is the honest
  # answer: `pipe` fails on descriptor exhaustion, which is not a state to fork
  # in either.
  var efd: array[0..1, cint] = [cint(-1), cint(-1)]
  if pipe(efd) != 0:
    deallocCStringArray(cargs)
    deallocCStringArray(cenv)
    return 0
  discard fcntl(efd[1], FdSetFd, FdCloexec)

  let pid = fork()
  if pid < 0:
    discard posix.close(efd[0])
    discard posix.close(efd[1])
    deallocCStringArray(cargs)
    deallocCStringArray(cenv)
    return 0
  if pid == 0:
    # Child. Nothing below allocates. Detached from the controlling terminal so
    # the backend survives this process exiting, then stdout and stderr are
    # pointed at the log before exec.
    discard posix.close(efd[0])
    discard setsid()
    let fd = posix.open(logPath.cstring,
                        O_WRONLY or O_CREAT or O_APPEND, 0o644.Mode)
    if fd >= 0:
      discard dup2(fd, 1)
      discard dup2(fd, 2)
      if fd > 2: discard posix.close(fd)
    discard posix.close(0)

    discard execve(binary.cstring, cargs, cenv)
    # Only reached if `execve` failed; the parent already has the pid, so
    # exiting non-zero is what makes the failure visible to the next check.
    #
    # Action purpose: `exitnow` rather than `quit`, for the same reason the
    # block above exists. `quit` runs the registered exit procedures and flushes
    # the C streams, and in a forked child of a multithreaded process those run
    # against state inherited mid-mutation from threads that do not exist here —
    # a deadlock on the one path that is already a failure. `exitnow` is
    # `_exit(2)`: immediate, no handlers, no flush.
    var why = errno
    discard posix.write(efd[1], addr why, sizeof(cint))
    posix.exitnow(127)

  # Parent only: the child either replaced its image or exited, so neither array
  # is reachable from it.
  deallocCStringArray(cargs)
  deallocCStringArray(cenv)

  var
    execErr: cint = 0
    handshakeLost = false
  discard posix.close(efd[1])
  # Only three answers are meaningful: a whole `errno` means `execve` failed, an
  # end of file means the close-on-exec descriptor went with a successful one,
  # and `EINTR` means neither yet. Anything else — a short read, a real error —
  # says the handshake itself broke, and a broken handshake is not evidence the
  # backend started. Treating it as success is the defect this exists to close,
  # pointed the other way.
  while true:
    let n = posix.read(efd[0], addr execErr, sizeof(cint))
    if n == sizeof(cint): break
    if n == 0:
      execErr = 0
      break
    if n < 0 and errno == EINTR: continue
    execErr = 0
    handshakeLost = true
    break
  discard posix.close(efd[0])

  if execErr != 0 or handshakeLost:
    # No pid file: the process is gone, or is one this call cannot vouch for,
    # and a file naming it would send `stop` and the watchdog after a pid the
    # system is free to reissue.
    #
    # The kill is for the lost-handshake case only. A child that reported its
    # `errno` has already called `_exit`, so the wait returns at once; one whose
    # handshake broke may be running perfectly well, and waiting on it without
    # ending it would block this worker for the life of the backend.
    if handshakeLost:
      discard kill(Pid(pid), SIGKILL)
    var status: cint = 0
    discard waitpid(Pid(pid), status, 0)
    try:
      let f = open(logPath, fmAppend)
      f.write(&"[{now()}] jenova-core could not exec {binary}: " &
              (if handshakeLost: "start handshake failed"
               else: $strerror(execErr)) & "\n")
      f.close()
    except IOError, OSError:
      discard
    return 0

  try:
    writeFile(pidFileFor(l, be), $pid)
    let f = open(logPath, fmAppend)
    f.write(&"[{now()}] jenova-core started {binary} {args.join(\" \")}\n")
    f.close()
  except IOError, OSError:
    discard
  pid

## Function purpose: SIGTERM, a grace period, then SIGKILL. The grace matters
## because a backend needs a moment to release GPU memory, and killing it
## outright leaves the device in a state the next start has to recover from.
proc stop*(l: Lifecycle, be: Backend, graceMs = 2000): bool =
  let st = l.state(be)
  # Action purpose: `removeFile` raises on an unlinkable pid file, and that
  # exception would escape here and turn a cleanup failure into a failed
  # shutdown. The process has already been signalled by this point.
  if not st.running:
    discard tryRemoveFile(pidFileFor(l, be))
    return true

  discard kill(st.pid.Pid, SIGTERM)
  let deadline = epochTime() + graceMs.float / 1000.0
  while epochTime() < deadline:
    if not isAlive(st.pid):
      discard tryRemoveFile(pidFileFor(l, be))
      return true
    sleep(50)

  discard kill(st.pid.Pid, SIGKILL)
  sleep(100)
  discard tryRemoveFile(pidFileFor(l, be))
  not isAlive(st.pid)

## Function purpose: both backends together, reporting each separately, because
## the agent model starting while the embedder fails is a normal state.
proc startAll*(l: Lifecycle): tuple[llama, embed: int] =
  (l.start(beLlama), l.start(beEmbed))

## Function purpose: answering HTTP, not merely holding a pid — which is the
## whole point of the watchdog. A backend that has wedged, out of VRAM mid-load
## or stuck on a request, keeps its pid and stops serving, and a pid check alone
## reports that as healthy.
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

## Function purpose: stops both before answering, so one failing to stop does
## not leave the other running.
proc stopAll*(l: Lifecycle): bool =
  let a = l.stop(beLlama)
  let b = l.stop(beEmbed)
  a and b

## Function purpose: the supervision loop, on its own thread inside `serve`, so
## the harness supervises its own engine rather than depending on a separate
## process that can disagree with it. It checks health rather than liveness: a
## wedged backend keeps its pid and only the port tells the truth.
##
## Action purpose: each of the three constants prevents a distinct failure. The
## interval is long enough that a model still loading is not mistaken for a dead
## one; the failure count means a single missed probe during a long prompt
## ingestion is not a fault; and the cooldown stops a backend that cannot start
## at all from being restarted every interval for ever.
type WatchConfig* = object
  intervalMs*: int
  cooldownMs*: int
  maxFailures*: int

## Function purpose: the constants in one value, so a test can shorten the
## interval without editing the module.
proc defaultWatch*(): WatchConfig =
  WatchConfig(intervalMs: 30_000, cooldownMs: 60_000, maxFailures: 3)

## Function purpose: one tick, separated from the loop so it can be asserted
## without waiting out an interval. An empty line means nothing happened.
proc watchOnce*(l: Lifecycle, be: Backend, failures: var int,
                lastRestart: var float, wc: WatchConfig): string =
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
  discard l.stop(be)
  let pid = l.start(be)
  # Action purpose: a negative answer means the port is held by something this
  # harness did not start, which is a failure and not a pid. Testing only for
  # zero would clear the failure counter and report a restart that never
  # happened, so failures reset only on a restart that produced a process.
  let port = if be == beLlama: l.llamaPort else: l.embedPort
  if pid < 0:
    return &"{be}: restart FAILED — port {port} is held by another process"
  if pid == 0:
    return &"{be}: restart FAILED — check {l.logFileFor(be)}"
  failures = 0
  &"{be}: restarted (pid {pid})"

## Function purpose: reports each backend separately rather than collapsing to
## one word, because the agent model being up while embeddings are not is a real
## and common state, and retrieval degrades quietly when it happens.
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
