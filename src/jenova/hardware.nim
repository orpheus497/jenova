## Script function and purpose: detect the machine — through `sysctl` on FreeBSD,
## `/proc` and `/sys` on Linux — score every profile against it, and deploy the
## winner. Kept below the window because a wrong score does not fail loudly, so
## all of it is assertable with no window. It reads the kernel and never tunes it.

import std/[algorithm, os, osproc, re, sequtils, streams, strtabs, strutils]

type
  Hardware* = object
    ## `osName`, `cpuModel`, `gpuDevices` and `swapInfo` are what a profile's
    ## patterns are tested against; the rest exist only to be shown.
    osName*: string        ## the OS this binary was built for — see `detectOs`
    osRelease*: string
    cpuModel*: string
    cpuThreads*: int
    gpuDevices*: seq[string]
    ramGiB*: int
    swapGiB*: int
    storage*: string
    swapInfo*: string

  Profile* = object
    ## One profile directory, read from its `profile.conf`. `name` is the
    ## vendor/name pair shown on screen and accepted by `apply`.
    name*: string
    dir*: string
    desc*: string
    optIn*: bool
    matchCpu*: string
    matchGpu0*: string
    matchGpu1*: string
    matchOs*: string
    matchSwap*: string
    hwSummary*: seq[tuple[key, value: string]]

  Score* = object
    ## `disqualified` is not "scored zero" — a required pattern that did not
    ## match takes the profile out of the running entirely, and `why` is what
    ## the screen shows to explain it.
    profile*: Profile
    points*: int
    disqualified*: bool
    why*: seq[string]

  HardwareError* = object of CatchableError

const
  ProfilesDirName* = "hardware-profiles"

  ## The llama.cpp backends whose devices are GPUs, named `<backend><index>`.
  DeviceBackends = ["Vulkan", "CUDA", "ROCm", "SYCL"]

  ## The numbers that decide which profile a machine gets, named rather than
  ## inlined. The penalty in particular is the whole reason a dual-GPU profile
  ## loses on a single-GPU machine.
  PtsOs* = 20
  PtsCpu* = 10
  PtsGpu* = 5
  PtsGpuMissing* = -8
  PtsSwap* = 10
  PtsGeneric* = -5

## Function purpose: reads a `KEY="value"` line without running the file. These
## are shell and could be sourced, but sourcing a data file to read five strings
## out of it executes whatever else is in it.
proc confValue(lines: seq[string], key: string): string =
  for raw in lines:
    let line = raw.strip
    if line.len == 0 or line.startsWith("#"): continue
    if not line.startsWith(key & "="): continue
    var v = line[key.len + 1 .. ^1].strip
    if v.len >= 2 and v[0] == '"' and v[^1] == '"':
      v = v[1 ..< ^1]
    elif v.len >= 2 and v[0] == '\'' and v[^1] == '\'':
      v = v[1 ..< ^1]
    return v
  ""

## Function purpose: one profile directory read into a value, so scoring never
## touches the filesystem and can be asserted against fixtures.
proc readProfile*(dir: string): Profile =
  let conf = dir / "profile.conf"
  if not fileExists(conf):
    raise newException(HardwareError, "no profile.conf in " & dir)
  let lines = readFile(conf).splitLines
  result.dir = dir
  result.name = confValue(lines, "PROFILE_NAME")
  result.desc = confValue(lines, "PROFILE_DESC")
  let optIn = confValue(lines, "PROFILE_OPT_IN")
  result.optIn = optIn.len > 0 and optIn != "0"
  result.matchCpu = confValue(lines, "MATCH_CPU")
  result.matchGpu0 = confValue(lines, "MATCH_GPU_0")
  result.matchGpu1 = confValue(lines, "MATCH_GPU_1")
  result.matchOs = confValue(lines, "MATCH_OS")
  result.matchSwap = confValue(lines, "MATCH_SWAP")
  for k in ["HW_CPU", "HW_GPU_0", "HW_GPU_1", "HW_RAM", "HW_SWAP",
            "HW_STORAGE", "HW_GPU_TOTAL_VRAM", "STRATEGY_DESC"]:
    let v = confValue(lines, k)
    if v.len > 0: result.hwSummary.add (k, v)
  # A profile whose declared name is missing stays selectable by its directory,
  # so a malformed `profile.conf` costs its label and not its existence.
  if result.name.len == 0:
    result.name = dir.lastPathPart

## Function purpose: sorted, so the screen and the self-test see the same list —
## directory enumeration order is not defined.
proc listProfiles*(root: string): seq[Profile] =
  let base = root / ProfilesDirName
  if not dirExists(base):
    raise newException(HardwareError, "no " & ProfilesDirName & " under " & root)
  var dirs: seq[string]
  for path in walkDirRec(base, yieldFilter = {pcDir}):
    if fileExists(path / "profile.conf"): dirs.add path
  dirs.sort()
  for d in dirs: result.add readProfile(d)

# ---------------------------------------------------------------- detection --

## Function purpose: an unavailable key answers empty rather than raising,
## because detection has to work on a partially-reporting kernel.
proc sysctlStr(key: string): string =
  try:
    let (outp, code) = execCmdEx("sysctl -n " & key)
    if code == 0: outp.strip else: ""
  except OSError, IOError:
    ""

## Function purpose: an unparseable value answers zero, which every scoring
## rule already treats as "not detected".
proc sysctlInt(key: string): int =
  try: parseInt(sysctlStr(key)) except ValueError: 0

## Function purpose: a `/proc` or `/sys` file, empty when it cannot be read.
proc readKernelFile(path: string): string =
  try: readFile(path) except IOError, OSError: ""

## Function purpose: the first `model name` in `/proc/cpuinfo`.
proc cpuinfoModel*(cpuinfo: string): string =
  for raw in cpuinfo.splitLines:
    let colon = raw.find(':')
    if colon > 0 and raw[0 ..< colon].strip == "model name":
      return raw[colon + 1 .. ^1].strip
  ""

## Function purpose: one `/proc/meminfo` field, in KiB.
proc meminfoKiB*(meminfo, key: string): int =
  for raw in meminfo.splitLines:
    let f = raw.splitWhitespace
    if f.len >= 2 and f[0] == key & ":":
      try: return parseInt(f[1]) except ValueError: return 0
  0

## Function purpose: the device paths in `/proc/swaps` and their total size in KiB.
proc procSwaps*(swaps: string): tuple[devices: seq[string], totalKiB: int] =
  for raw in swaps.splitLines:
    let f = raw.splitWhitespace
    if f.len >= 3 and f[0].startsWith("/"):
      result.devices.add f[0]
      try: result.totalKiB += parseInt(f[2]) except ValueError: discard

## Function purpose: the filesystem type of the `/proc/self/mounts` entry holding
## `path`: the longest mount point over it, and of equal ones the last (on top).
proc mountFsType*(mounts, path: string): string =
  var longest = -1
  for raw in mounts.splitLines:
    let f = raw.splitWhitespace
    if f.len < 3: continue
    let mnt = f[1].replace("\\040", " ")
    if (mnt == "/" or path == mnt or path.startsWith(mnt & "/")) and
       mnt.len >= longest:
      longest = mnt.len
      result = f[2]

## Function purpose: the OS this binary was built for; the release is the running
## kernel's.
proc detectOs(h: var Hardware) =
  when defined(freebsd):
    h.osName = "FreeBSD"
    h.osRelease = sysctlStr("kern.osrelease")
  elif defined(linux):
    h.osName = "Linux"
    h.osRelease = readKernelFile("/proc/sys/kernel/osrelease").strip
  else:
    h.osName = hostOS
  if h.osRelease.len == 0: h.osRelease = "unknown"

## Function purpose: the model string is what the CPU patterns match against,
## so it is taken verbatim rather than normalised.
proc detectCpu(h: var Hardware) =
  when defined(linux):
    h.cpuModel = cpuinfoModel(readKernelFile("/proc/cpuinfo"))
    h.cpuThreads = countProcessors()
  else:
    h.cpuModel = sysctlStr("hw.model")
    h.cpuThreads = sysctlInt("hw.ncpu")

## Function purpose: `execCmdEx` has no timeout, and the GPU probe below
## initialises Vulkan — which can be arbitrarily slow while the agent model is
## loading onto the same device. An unbounded probe holds the worker it runs on,
## and that worker is joined at exit, so a stuck probe would hang shutdown too.
##
## Action purpose: the output is read after the process ends rather than while it
## runs. This reads a few hundred bytes, far below the pipe buffer, so draining
## concurrently would be machinery for no gain.
proc runBounded(exe: string, args: seq[string], libDir: string,
                timeoutMs: int): tuple[output: string, ok: bool] =
  var p: Process
  try:
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    if libDir.len > 0 and dirExists(libDir):
      # Action purpose: required, not defensive. Without it the loader cannot
      # find the server's own shared object and the device list comes back
      # empty — which reads as a machine with no GPU rather than as an error,
      # and silently selects the wrong profile.
      let prior = getEnv("LD_LIBRARY_PATH")
      env["LD_LIBRARY_PATH"] =
        if prior.len > 0: libDir & ":" & prior else: libDir
    p = startProcess(exe, args = args, env = env,
                     options = {poStdErrToStdOut})
  except OSError, Exception:
    return ("", false)

  var waited = 0
  const Step = 50
  while waited < timeoutMs:
    if p.peekExitCode() != -1: break
    sleep(Step)
    waited += Step

  if p.peekExitCode() == -1:
    # Killed rather than waited on: the caller is a worker whose thread is
    # joined at exit.
    try: p.terminate() except CatchableError: discard
    try: p.kill() except CatchableError: discard
    try: discard p.waitForExit() except CatchableError: discard
    try: p.close() except CatchableError: discard
    return ("", false)

  var outp = ""
  try: outp = p.outputStream.readAll() except CatchableError: discard
  try: p.close() except CatchableError: discard
  (outp, true)

## Function purpose: the GPUs `llama-server --list-devices` reports, one
## `Vulkan0: <name> (...)` line each, and whether it answered at all.
proc probeDevices*(llamaServer, llamaLibDir: string):
    tuple[devices: seq[string], ok: bool] =
  if llamaServer.len == 0 or not fileExists(llamaServer): return
  # An enumeration that has not answered by then is not going to, and the
  # caller would rather report no GPU than never return.
  let (outp, ok) = runBounded(llamaServer, @["--list-devices"], llamaLibDir,
                              10_000)
  if not ok: return
  result.ok = true
  for raw in outp.splitLines:
    let line = raw.strip
    if line.len == 0 or not line.contains(':'): continue
    let head = line.split(':')[0].strip
    if DeviceBackends.anyIt(head.startsWith(it)): result.devices.add line

## Function purpose: from the engine rather than `vulkaninfo`, because the
## devices it can use are the only question a profile asks.
proc detectGpu(h: var Hardware, llamaServer, llamaLibDir: string) =
  h.gpuDevices = probeDevices(llamaServer, llamaLibDir).devices

## Function purpose: swap is detected as well as RAM because one profile
## identifies itself by its swap device rather than by its memory size.
proc detectMemory(h: var Hardware) =
  var swapKiB = 0
  when defined(linux):
    let kib = meminfoKiB(readKernelFile("/proc/meminfo"), "MemTotal")
    if kib > 0: h.ramGiB = kib div (1024 * 1024)
    swapKiB = procSwaps(readKernelFile("/proc/swaps")).totalKiB
  else:
    let physBytes = sysctlInt("hw.physmem")
    if physBytes > 0: h.ramGiB = physBytes div (1024 * 1024 * 1024)
    # `swapinfo -k` prints a header then one row per device, so the rows to sum
    # are the ones whose first field is a path.
    try:
      let (outp, code) = execCmdEx("swapinfo -k")
      if code == 0:
        for raw in outp.splitLines:
          let parts = raw.splitWhitespace
          if parts.len >= 2 and parts[0].startsWith("/"):
            try: swapKiB += parseInt(parts[1]) except ValueError: discard
    except OSError, IOError:
      discard
  h.swapGiB = swapKiB div (1024 * 1024)

## Function purpose: reported rather than scored — no profile matches on
## storage, but the screen shows it beside the rest.
proc detectStorage(h: var Hardware, jcaHome: string) =
  when defined(linux):
    let dir = if jcaHome.len > 0: jcaHome else: getHomeDir()
    let home = try: expandFilename(dir) except OSError: absolutePath(dir)
    h.storage = mountFsType(readKernelFile("/proc/self/mounts"), home)
    if h.storage.len == 0: h.storage = "unknown"
  else:
    h.storage = if execCmdEx("zpool list").exitCode == 0: "ZFS" else: "UFS"

## Function purpose: the swap patterns are tested against device names plus the
## NVMe controller listing, because the profile that uses them is identifying a
## swap device by its controller model.
proc detectSwapHardware(h: var Hardware) =
  var parts: seq[string]
  when defined(linux):
    parts.add procSwaps(readKernelFile("/proc/swaps")).devices
    for dir in walkDirs("/sys/class/nvme/nvme*"):
      let model = readKernelFile(dir / "model").strip
      if model.len > 0: parts.add dir.lastPathPart & ": " & model
  else:
    try:
      let (outp, code) = execCmdEx("swapinfo")
      if code == 0:
        for raw in outp.splitLines:
          let f = raw.splitWhitespace
          if f.len >= 1 and f[0].startsWith("/"): parts.add f[0]
    except OSError, IOError: discard
    try:
      let (outp, code) = execCmdEx("nvmecontrol devlist")
      if code == 0:
        for raw in outp.splitLines:
          if raw.strip.len > 0: parts.add raw.strip
    except OSError, IOError: discard
  h.swapInfo = if parts.len == 0: "None" else: parts.join(" ")

## Function purpose: the whole probe in one call, so a caller cannot score a
## partly-filled record. On Linux the storage reported is `jcaHome`'s.
proc detect*(llamaServer = "", llamaLibDir = "", jcaHome = ""): Hardware =
  detectOs(result)
  detectCpu(result)
  detectGpu(result, llamaServer, llamaLibDir)
  detectMemory(result)
  detectStorage(result, jcaHome)
  detectSwapHardware(result)

## Function purpose: a llama.cpp GPU id such as `Vulkan1` or `CUDA0`, in any case.
proc isDeviceId(entry: string): bool =
  for b in DeviceBackends:
    if entry.len > b.len and entry.toLowerAscii.startsWith(b.toLowerAscii) and
       entry[b.len .. ^1].allCharsInSet(Digits):
      return true
  false

## Function purpose: whether a `DEVICES` value names a device by pattern and so
## needs `probeDevices` to resolve. `none` is llama.cpp's only when it stands alone.
proc needsDeviceList*(spec: string): bool =
  if spec.strip == "none": return false
  for raw in spec.split(','):
    let entry = raw.strip
    if entry.len > 0 and not isDeviceId(entry): return true
  false

## Function purpose: a `--list-devices` line's device name, without its id and
## the memory figures after it, so a pattern cannot match a number of MiB.
proc deviceName(line: string): string =
  let colon = line.find(':')
  result = line[colon + 1 .. ^1].strip
  let memory = result.rfind(" (")
  if memory > 0 and result.endsWith(")") and "MiB" in result[memory .. ^1]:
    result = result[0 ..< memory]

# ------------------------------------------------------------------ scoring --

## Function purpose: the profile patterns are POSIX extended regexes and use
## alternation, so they cannot be compared literally. A pattern that does not
## compile is treated as a non-match rather than silently removing the profile.
proc matchesRe(hay, pattern: string): bool =
  if pattern.len == 0: return false
  try: hay.contains(re(pattern, {reIgnoreCase}))
  except RegexError: false

## Function purpose: the CPU pattern is matched as a fixed string, not a regex,
## so a CPU model containing metacharacters cannot change what it means.
proc matchesFixed(hay, needle: string): bool =
  needle.len > 0 and hay.toLowerAscii.contains(needle.toLowerAscii)

## Function purpose: a `DEVICES` value as llama.cpp device ids — an id passes
## through, any other entry names a GPU by pattern, since its index varies by OS.
proc resolveDevices*(spec: string, listed: seq[string]):
    tuple[ids: string, unresolved: seq[string]] =
  if spec.strip == "none": return ("none", @[])
  var picked: seq[string]
  # Device ids compare case-insensitively in llama.cpp, and a device named twice
  # would have its memory counted twice by the layer split.
  proc taken(id: string): bool = picked.anyIt(cmpIgnoreCase(it, id) == 0)
  for raw in spec.split(','):
    let entry = raw.strip
    if entry.len == 0: continue
    if isDeviceId(entry):
      if not taken(entry): picked.add entry
      continue
    var found = ""
    for line in listed:
      let colon = line.find(':')
      if colon <= 0: continue
      let id = line[0 ..< colon].strip
      if not taken(id) and matchesRe(deviceName(line), entry):
        found = id
        break
    if found.len > 0: picked.add found
    else: result.unresolved.add entry
  result.ids = picked.join(",")

## Function purpose: three conditions disqualify rather than merely score zero,
## which is the part of the ladder that decides most outcomes — a profile out of
## the running cannot be beaten back into it by accumulating points elsewhere.
proc scoreProfile*(p: Profile, h: Hardware): Score =
  result.profile = p

  if p.optIn:
    result.disqualified = true
    result.why.add "opt-in only: never selected automatically"
    return

  let gpuHay = h.gpuDevices.join("\n")

  if p.matchOs.len > 0:
    if matchesRe(h.osName, p.matchOs):
      result.points += PtsOs
      result.why.add "OS matches " & p.matchOs & " (+" & $PtsOs & ")"
    else:
      result.disqualified = true
      result.why.add "OS is not " & p.matchOs & " — disqualified"
      return
  else:
    result.points += PtsGeneric
    result.why.add "no OS pattern: generic fallback (" & $PtsGeneric & ")"

  if p.matchCpu.len > 0:
    if matchesFixed(h.cpuModel, p.matchCpu):
      result.points += PtsCpu
      result.why.add "CPU matches " & p.matchCpu & " (+" & $PtsCpu & ")"
    else:
      result.disqualified = true
      result.why.add "CPU is not " & p.matchCpu & " — disqualified"
      return

  if p.matchGpu0.len > 0:
    if matchesRe(gpuHay, p.matchGpu0):
      result.points += PtsGpu
      result.why.add "GPU matches " & p.matchGpu0 & " (+" & $PtsGpu & ")"
    else:
      result.why.add "GPU does not match " & p.matchGpu0 & " (+0)"

  # Action purpose: the rule that separates the dual-GPU profile from the
  # single-GPU one on the same CPU. A declared second GPU that is absent is
  # penalised rather than merely unscored, so the single-GPU profile wins on one
  # GPU and loses on two.
  if p.matchGpu1.len > 0:
    if matchesRe(gpuHay, p.matchGpu1):
      result.points += PtsGpu
      result.why.add "second GPU matches " & p.matchGpu1 & " (+" & $PtsGpu & ")"
    else:
      result.points += PtsGpuMissing
      result.why.add "second GPU " & p.matchGpu1 & " absent (" &
                     $PtsGpuMissing & ")"

  if p.matchSwap.len > 0:
    if matchesRe(h.swapInfo, p.matchSwap):
      result.points += PtsSwap
      result.why.add "swap matches " & p.matchSwap & " (+" & $PtsSwap & ")"
    else:
      result.disqualified = true
      result.why.add "swap is not " & p.matchSwap & " — disqualified"
      return

## Function purpose: ranked rather than reduced to a winner, because the screen
## has to answer which profile matched and why, not only which one won.
proc scoreAll*(profiles: seq[Profile], h: Hardware): seq[Score] =
  for p in profiles: result.add scoreProfile(p, h)
  result.sort(proc (a, b: Score): int =
    if a.disqualified != b.disqualified:
      (if a.disqualified: 1 else: -1)
    else:
      cmp(b.points, a.points))

## Function purpose: a positive score is required to select at all. A profile
## that only ever accumulated penalties is not a match, it is the absence of one.
proc bestProfile*(profiles: seq[Profile], h: Hardware): tuple[found: bool, score: Score] =
  let ranked = scoreAll(profiles, h)
  if ranked.len == 0: return (false, Score())
  if ranked[0].disqualified or ranked[0].points <= 0: return (false, ranked[0])
  (true, ranked[0])

# -------------------------------------------------------------------- apply --

## Function purpose: copies the profile's `jenova.conf` into `$JCA_HOME/etc`,
## which configuration loading already prefers over the source tree.
##
## Action purpose: `jenova.local.conf` is never touched. It is the user's machine
## file and is layered over the profile, so an apply that clobbered it would
## discard their overrides while appearing to work.
proc applyProfile*(p: Profile, jcaHome: string): tuple[ok: bool, msg: string] =
  let src = p.dir / "jenova.conf"
  if not fileExists(src):
    return (false, "profile has no jenova.conf: " & p.dir)
  let destDir = jcaHome / "etc"
  try:
    createDir(destDir)
    copyFile(src, destDir / "jenova.conf")
  except OSError, IOError:
    return (false, "could not write " & (destDir / "jenova.conf") &
                   ": " & getCurrentExceptionMsg())
  (true, "applied " & p.name & " to " & (destDir / "jenova.conf") &
         " — restart the backend for it to take effect")

## Function purpose: an opt-in profile is selectable by name and only by name,
## which is what opt-in means — scoring will never choose one.
proc findByName*(profiles: seq[Profile], name: string): tuple[found: bool, profile: Profile] =
  for p in profiles:
    if p.name == name or p.dir.lastPathPart == name:
      return (true, p)
  (false, Profile())

## Function purpose: there is no marker file, so the deployed `jenova.conf`'s
## content compared against each profile's own copy is the only evidence of
## which one is live.
proc currentProfile*(profiles: seq[Profile], jcaHome: string): tuple[found: bool, name: string] =
  let deployed = jcaHome / "etc" / "jenova.conf"
  if not fileExists(deployed): return (false, "")
  var live = ""
  try: live = readFile(deployed) except IOError: return (false, "")
  for p in profiles:
    let candidate = p.dir / "jenova.conf"
    if not fileExists(candidate): continue
    try:
      if readFile(candidate) == live: return (true, p.name)
    except IOError: discard
  (false, "")
