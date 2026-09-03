## Script function and purpose: detect the machine, score every profile against
## it, and deploy the winner. Kept below the window because a wrong score does
## not fail loudly — it silently runs the machine on the wrong tuning — so all of
## it has to be assertable with no window and no backend.
##
## No kernel tunable is ever applied and `/etc/sysctl.conf` is never written.
## Reading a `sysctl` to learn what the machine *is* is detection; setting one
## would be tuning, and that is out of scope here.

import std/[algorithm, os, osproc, re, streams, strtabs, strutils]

type
  Hardware* = object
    ## The three `*Raw` fields are the strings a profile's patterns are tested
    ## against; the rest exist only to be shown.
    osName*: string        ## always "FreeBSD" — see `detectOs`
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

## Action purpose: the OS name is hardcoded rather than read from `uname -s`.
## Under the Linuxulator `uname -s` answers "Linux", which selects a Linux
## profile on a FreeBSD host. The release still comes from the kernel.
proc detectOs(h: var Hardware) =
  h.osName = "FreeBSD"
  h.osRelease = sysctlStr("kern.osrelease")
  if h.osRelease.len == 0: h.osRelease = "unknown"

## Function purpose: the model string is what the CPU patterns match against,
## so it is taken verbatim rather than normalised.
proc detectCpu(h: var Hardware) =
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

## Function purpose: the GPU list comes from `llama-server --list-devices`
## rather than `vulkaninfo` or `pciconf`, because it reports the devices the
## inference engine can actually use — which is the only question a profile
## asks. Failure is not fatal: a machine with no working Vulkan still scores, it
## just cannot win a GPU-matched profile.
proc detectGpu(h: var Hardware, llamaServer, llamaLibDir: string) =
  if llamaServer.len == 0 or not fileExists(llamaServer): return
  # An enumeration that has not answered by then is not going to, and the
  # caller would rather report no GPU than never return.
  let (outp, ok) = runBounded(llamaServer, @["--list-devices"], llamaLibDir,
                              10_000)
  if not ok: return
  for raw in outp.splitLines:
    let line = raw.strip
    # The device name between the colon and the parenthesis is what the
    # profiles' GPU patterns are written against.
    if line.len == 0 or not line.contains(':'): continue
    let head = line.split(':')[0].strip
    if not (head.startsWith("Vulkan") or head.startsWith("CUDA") or
            head.startsWith("ROCm") or head.startsWith("SYCL")): continue
    h.gpuDevices.add line

## Function purpose: swap is detected as well as RAM because one profile
## identifies itself by its swap device rather than by its memory size.
proc detectMemory(h: var Hardware) =
  let physBytes = sysctlInt("hw.physmem")
  if physBytes > 0: h.ramGiB = physBytes div (1024 * 1024 * 1024)
  # `swapinfo -k` prints a header then one row per device, so the rows to sum
  # are the ones whose first field is a path.
  var swapKiB = 0
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
proc detectStorage(h: var Hardware) =
  h.storage = if execCmdEx("zpool list").exitCode == 0: "ZFS" else: "UFS"

## Function purpose: the swap patterns are tested against device names plus the
## NVMe controller listing, because the profile that uses them is identifying a
## swap device by its controller model.
proc detectSwapHardware(h: var Hardware) =
  var parts: seq[string]
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

## Function purpose: the whole probe in one call, so a caller cannot run half
## of it and score against a partly-filled record.
proc detect*(llamaServer = "", llamaLibDir = ""): Hardware =
  detectOs(result)
  detectCpu(result)
  detectGpu(result, llamaServer, llamaLibDir)
  detectMemory(result)
  detectStorage(result)
  detectSwapHardware(result)

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
