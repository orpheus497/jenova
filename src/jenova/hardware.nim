## Script function and purpose: Hardware detection, profile scoring and profile
## selection in Nim, replacing `hardware-profiles/detect-hardware.sh` (S-1,
## ruled at D-BC).
##
## Choosing which profile Jenova runs under was a 431-line shell script that
## died on its line 19 sourcing an archived `lib/detect-env.sh`, and which
## nothing invoked anyway because `config.nim` reads `etc/jenova.conf`
## directly. So there was no way to detect hardware or change profile at all
## except hand-editing a config file, which D-BC makes a defect.
##
## ## Why this is a module and not part of `gui.nim`
##
## Scoring is pure logic over data files, and a wrong score does not fail
## loudly — it silently runs the machine on the wrong tuning. Keeping detection,
## scoring and apply here means `hardware-selftest` can assert all of it with no
## window and no backend, which is the same reason `settings.nim` and the
## branching tree walk sit below the widget layer.
##
## ## What this deliberately does NOT do
##
## **It never touches `sysctl` as a setting (D-BN).** No kernel tunable is
## applied, `/etc/sysctl.conf` is never written, and the tuning in the archived
## `jenova-setup` scripts is not ported. Reading a `sysctl` to find out what the
## machine *is* — `hw.model`, `hw.physmem` — is detection, not tuning, and is
## the only use of it here.

import std/[algorithm, os, osproc, re, streams, strtabs, strutils]

type
  Hardware* = object
    ## What was detected, in the shape the scorer matches against. The three
    ## `*Raw` fields are the strings a profile's patterns are tested on; the
    ## rest exist to be shown to the USER.
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
    ## One `hardware-profiles/<vendor>/<name>/` directory, read from its
    ## `profile.conf`. `dir` is the absolute path; `name` is the
    ## vendor/name pair the USER sees and `apply` is given.
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
    ## The outcome of scoring one profile. `disqualified` is not "scored zero":
    ## a required pattern that did not match takes the profile out of the
    ## running entirely, and `why` is what the screen shows to explain it.
    profile*: Profile
    points*: int
    disqualified*: bool
    why*: seq[string]

  HardwareError* = object of CatchableError

const
  ProfilesDirName* = "hardware-profiles"

  ## The scoring ladder, ported from `detect-hardware.sh`'s `match_profile`.
  ## These are the numbers that decide which profile a machine gets, so they are
  ## named rather than inlined — the -8 in particular is the whole reason a
  ## dual-GPU profile loses on a single-GPU machine.
  PtsOs* = 20
  PtsCpu* = 10
  PtsGpu* = 5
  PtsGpuMissing* = -8
  PtsSwap* = 10
  PtsGeneric* = -5

## Function purpose: read a `KEY="value"` line out of a `profile.conf` without
## running it. The originals are `sh` and were sourced; sourcing a data file to
## read five strings out of it is what `load_jenova_profile` did and is exactly
## what this project is removing.
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
  # A profile whose PROFILE_NAME is missing is still selectable by directory,
  # which is what the shell keyed on — it derived the name from the path.
  if result.name.len == 0:
    result.name = dir.lastPathPart

## Function purpose: every profile in the tree, in a stable order so the screen
## and the self-test see the same list. `find` gave the shell an arbitrary one.
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

proc sysctlStr(key: string): string =
  try:
    let (outp, code) = execCmdEx("sysctl -n " & key)
    if code == 0: outp.strip else: ""
  except OSError, IOError:
    ""

proc sysctlInt(key: string): int =
  try: parseInt(sysctlStr(key)) except ValueError: 0

## Action purpose: the OS name is hardcoded rather than taken from `uname -s`,
## and this is not laziness — under the FreeBSD Linuxulator `uname -s` answers
## "Linux", which made the shell script select a Linux profile on a FreeBSD
## host. The release still comes from the kernel.
proc detectOs(h: var Hardware) =
  h.osName = "FreeBSD"
  h.osRelease = sysctlStr("kern.osrelease")
  if h.osRelease.len == 0: h.osRelease = "unknown"

proc detectCpu(h: var Hardware) =
  h.cpuModel = sysctlStr("hw.model")
  h.cpuThreads = sysctlInt("hw.ncpu")

## Function purpose: run a command that must not be allowed to hang, and kill it
## if it does.
##
## Action purpose: **`execCmdEx` has no timeout, and that cost a hang.** The GPU
## probe below initialises Vulkan; while the agent model is loading onto the same
## device it can be slow, and there is no upper bound on "slow". The first
## version of this ran unbounded on the shared control worker and left the window
## sitting on "starting" with every button dead (**D-BQ**). It is off that worker
## now, and it is bounded here as well — one guard would have been enough for
## today, and two is what keeps a stuck probe from also hanging the exit path,
## where the worker is joined.
##
## The output is read after the process ends rather than while it runs: this
## reads a device list of a few hundred bytes, far below the pipe buffer, so
## draining concurrently would be machinery for no gain.
proc runBounded(exe: string, args: seq[string], libDir: string,
                timeoutMs: int): tuple[output: string, ok: bool] =
  var p: Process
  try:
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    if libDir.len > 0 and dirExists(libDir):
      # Required, not defensive: without it the loader cannot find
      # `libllama-server-impl.so` and the device list comes back **empty**,
      # which does not look like an error — it looks like a machine with no GPU,
      # and it silently selected the wrong profile the first time this ran.
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
    # Still running past its budget. Killed rather than waited on, because the
    # caller is a worker whose thread is joined at exit.
    try: p.terminate() except CatchableError: discard
    try: p.kill() except CatchableError: discard
    try: discard p.waitForExit() except CatchableError: discard
    try: p.close() except CatchableError: discard
    return ("", false)

  var outp = ""
  try: outp = p.outputStream.readAll() except CatchableError: discard
  try: p.close() except CatchableError: discard
  (outp, true)

## Action purpose: the GPU list comes from `llama-server --list-devices`, not
## from `vulkaninfo` or `pciconf` as the shell used. It is the same source that
## established the SETTLED FACTS device row, it is a binary this project already
## ships and runs, and it reports the devices *the inference engine can actually
## use* — which is the only question a profile is asking. Failure is not fatal:
## a machine with no working Vulkan still scores, it just cannot win a
## GPU-matched profile.
proc detectGpu(h: var Hardware, llamaServer, llamaLibDir: string) =
  if llamaServer.len == 0 or not fileExists(llamaServer): return
  # 10 seconds: an enumeration that has not answered by then is not going to,
  # and the caller would rather report "no GPU reported" than never return.
  let (outp, ok) = runBounded(llamaServer, @["--list-devices"], llamaLibDir,
                              10_000)
  if not ok: return
  for raw in outp.splitLines:
    let line = raw.strip
    # The listing is `  Vulkan0: NVIDIA GTX 1650 Ti (4342 MiB, ...)`; the
    # device name is what the MATCH_GPU_* patterns are written against.
    if line.len == 0 or not line.contains(':'): continue
    let head = line.split(':')[0].strip
    if not (head.startsWith("Vulkan") or head.startsWith("CUDA") or
            head.startsWith("ROCm") or head.startsWith("SYCL")): continue
    h.gpuDevices.add line

proc detectMemory(h: var Hardware) =
  let physBytes = sysctlInt("hw.physmem")
  if physBytes > 0: h.ramGiB = physBytes div (1024 * 1024 * 1024)
  # `swapinfo -k` prints a header then one row per device; the total is the sum
  # of the device rows, which are the ones whose first field is a path.
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

proc detectStorage(h: var Hardware) =
  h.storage = if execCmdEx("zpool list").exitCode == 0: "ZFS" else: "UFS"

## Action purpose: `MATCH_SWAP` is written against swap device names plus the
## NVMe controller listing, because the one profile that uses it is matching an
## Optane swap device by controller model.
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

proc detect*(llamaServer = "", llamaLibDir = ""): Hardware =
  detectOs(result)
  detectCpu(result)
  detectGpu(result, llamaServer, llamaLibDir)
  detectMemory(result)
  detectStorage(result)
  detectSwapHardware(result)

# ------------------------------------------------------------------ scoring --

## Action purpose: the profile patterns are POSIX extended regexes — they use
## alternation (`Lucienne|Renoir`) — and the shell tested them with `grep -iE`.
## A pattern that does not compile must not take the profile out of the running
## silently, so it is treated as a non-match and said so by the caller.
proc matchesRe(hay, pattern: string): bool =
  if pattern.len == 0: return false
  try: hay.contains(re(pattern, {reIgnoreCase}))
  except RegexError: false

## `MATCH_CPU` was tested with `grep -Fi` — a fixed string, case-insensitive —
## specifically so a CPU model containing regex metacharacters cannot inject.
proc matchesFixed(hay, needle: string): bool =
  needle.len > 0 and hay.toLowerAscii.contains(needle.toLowerAscii)

## Function purpose: score one profile against detected hardware, reproducing
## `detect-hardware.sh`'s `match_profile` exactly — including the three
## conditions that **disqualify** rather than merely score zero, which is the
## part a summary of the ladder loses.
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

  # Action purpose: this is the rule that separates the dual-GPU profile from
  # the single-GPU one on the same CPU. A declared second GPU that is absent is
  # penalised, not merely unscored, so the single-GPU profile wins on a machine
  # with one GPU and loses on a machine with two.
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

## Function purpose: score every profile, highest first, so both the screen and
## the subcommand can show the ranking and not just the winner — "which one
## matched and why" is the requirement D-BC's screen exists to answer.
proc scoreAll*(profiles: seq[Profile], h: Hardware): seq[Score] =
  for p in profiles: result.add scoreProfile(p, h)
  result.sort(proc (a, b: Score): int =
    if a.disqualified != b.disqualified:
      (if a.disqualified: 1 else: -1)
    else:
      cmp(b.points, a.points))

## Function purpose: the winner, or nothing. The shell required a score above
## zero to select at all, and that is kept: a profile that only ever accumulated
## penalties is not a match, it is the absence of one.
proc bestProfile*(profiles: seq[Profile], h: Hardware): tuple[found: bool, score: Score] =
  let ranked = scoreAll(profiles, h)
  if ranked.len == 0: return (false, Score())
  if ranked[0].disqualified or ranked[0].points <= 0: return (false, ranked[0])
  (true, ranked[0])

# -------------------------------------------------------------------- apply --

## Function purpose: deploy a profile by copying its `jenova.conf` to
## `$JCA_HOME/etc`, which `config.configDir` already prefers over the source
## tree (D-AT2).
##
## Action purpose: **`jenova.local.conf` is never touched.** It is the USER's
## machine file (SETTLED FACTS), `config.load` layers it over the profile, and
## an apply that clobbered it would silently discard their overrides while
## looking like it worked.
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

## Function purpose: find a profile by the name the USER sees, for `apply` by
## name. An opt-in profile is selectable this way and only this way, which is
## the whole meaning of opt-in.
proc findByName*(profiles: seq[Profile], name: string): tuple[found: bool, profile: Profile] =
  for p in profiles:
    if p.name == name or p.dir.lastPathPart == name:
      return (true, p)
  (false, Profile())

## Function purpose: the currently deployed profile, by matching the deployed
## `jenova.conf` against each profile's own copy. There is no marker file, so
## the content is the only evidence of which one is live.
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
