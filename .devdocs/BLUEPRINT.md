# BLUEPRINT

System architecture, dependency requirements, and the implementation registry.

**Last updated:** 2026-08-28 14:03 (deep audit)

---

## 1. Scope Boundary

| In scope | Out of scope |
|---|---|
| `bin/`, `lib/`, `scripts/`, `hardware-profiles/`, `etc/`, `tests/`, `jenova-ui/`, `docs/`, `Makefile`, `install-jenova.sh` | `external/llama.cpp` — **Git submodule, a dependency, not project code. Never modified.** |
| | `external/ext_bin/` — build output |
| | `jca_web/` — audited, **zero OS coupling found**; no `process.platform`, no `os.platform`, no platform strings in `src/`, `vite.config.ts`, `playwright.config.ts` or `package.json`. Nothing to migrate. |

`external/llama.cpp` is consumed through `bin/build-llama-jenova`, which passes CMake flags to
it. FreeBSD concerns are expressed by *how we invoke the submodule's build*, never by editing
the submodule.

## 2. Runtime Topology — **one port**

> Corrected 2026-08-28 per USER ruling D-E. An earlier revision of this document tabulated
> three ports as peer services, implying three front doors. That was wrong.

**:8080 is the port.** :8081 and :8082 are internal backends reached only by the proxy.

```
client / WebUI / LAN
        │
        ▼
   :8080  lib/proxy.lua ──── forwards unmatched ───▶ :8081  llama-server (inference)
        │  (the only listener   requests
        │   a client uses)
        └── in-process call ─────────────────────▶ :8082  llama-server (embed, CPU)
             lib/embed.lua
```

| Port | Reached by | Evidence |
|---|---|---|
| **8080** | clients, WebUI, LAN | binds `HOST:PORT` at `lib/proxy.lua:53-54,1523,1529` |
| 8081 | **the proxy only** | forwarded at `lib/proxy.lua:1428`; Host header rewritten to the internal target at `:1204` |
| 8082 | **the proxy only, in-process** | `lib/embed.lua` is `require`d by the proxy (`proxy.lua:15,63-72`) and POSTs to `127.0.0.1:8082` itself (`embed.lua:26,107`) — it never traverses the proxy's HTTP surface |

Corroborated from the client side: `jca_web/src` contains **zero** references to 8081 or 8082,
and the vite dev proxy targets only `localhost:8080` (`jca_web/vite.config.ts:91-99`).

### 2.1 Two places contradict this and expose the internals

1. **Bind address.** `bin/jenova-ca` launches llama-server and the embed server with
   `--host "$HOST"` (`:239`, `:708`, `:804`, `:823`). Under `--lan`, `HOST="0.0.0.0"`
   (`:331`) — so **:8081 and :8082 are published to the LAN with no authentication.** The code
   already encodes the intent: `:332` sets `_INT_HOST="127.0.0.1"` and `:556-557` build the
   proxy's upstream URLs from it. The bind simply does not follow.
2. **Firewall guidance.** `scripts/install.sh:562` instructs LAN-client users to open "ports
   8080, 8081, and 8082".

**Scoped fix:** bind :8081 and :8082 to loopback unconditionally; correct the text to :8080
only. This is *smaller* than remediation-plan WP-8, whose first half proposed an upstream
routing table so `/v1/embeddings` could reach :8082 — unnecessary, because embeddings are an
in-process call. Only WP-8's binding half applies.

Supervisor `bin/jenova-ca`; desktop manager `bin/jenova-ui` (GTK3 tray + ncurses TUI, C with
embedded LuaJIT); web workspace `jca_web/` → `public/`, served by the proxy.

State: `$JCA_HOME/.system/`, `var/log/`, `var/cache/`, `Workspaces/`, `var/jenova.db`.

### 2.2 Configuration hierarchy — **inverted in the implementation**

> Corrected 2026-08-28 by full-tree audit. An earlier revision of this document stated the
> hierarchy as *"`etc/jenova.conf` (profile-generated) → `etc/jenova.local.conf` (user overrides)"*.
> That is the intended design and it is **not what the code does.**

`bin/jenova-ca` sources in this order:

```
:44  lib/detect-env.sh
:45  lib/jenova-conf.sh    ── sources etc/jenova.local.conf  (:53-74)
:46  lib/jenova-model.sh
:48  etc/jenova.conf       ── the deployed hardware profile
```

The profile conf runs **last**, and every tuning variable in it is assigned unconditionally:

```sh
DEVICES="${JENOVA_DEVICES:-Vulkan0,Vulkan1}"   # etc/jenova.conf:56
THREADS="${JENOVA_THREADS:-4}"                 # etc/jenova.conf:70
```

The right-hand side reads the **environment**, not the current shell value. So any bare
assignment made in `jenova.local.conf` is overwritten before `llama-server` is launched.

| Set in `etc/jenova.local.conf` | Effect |
|---|---|
| `DEVICES=`, `THREADS=`, `CTX_SIZE=`, `NUM_SLOTS=`, `NGL_AGENT=`, `FIT_TARGET=`, `KV_CACHE_TYPE=`, `TENSOR_SPLIT=` | **None** — clobbered by `etc/jenova.conf` |
| `JENOVA_DEVICES=`, `JENOVA_THREADS=`, `JENOVA_CTX=`, … (exported) | Honoured |
| `LLAMA_SERVER=` | Honoured — both files use `${LLAMA_SERVER:-…}` |

**Two consequences worth stating plainly:**

1. `scripts/build-llama.sh:264-275` generates `jenova.local.conf` using the **unprefixed** names.
   The build script's own hardware-derived tuning is therefore discarded on every run.
2. `hardware-profiles/README.md` correctly instructs profile authors to *"use the unprefixed
   names"*. That is right for a **profile** conf and exactly wrong for a **local** conf. Nothing
   documents the distinction.

Tracked as `TODOS.md` **B-12**; the fix direction is an open USER decision, `DECISIONS_LOG.md` **Q-9**.

### 2.3 Profile system-tuning dispatch — three of six profiles do not tune

`scripts/jenova-setup` presents itself as a hardware-aware dispatcher for "profile-specific kernel
tuning" and `exec sh "$PROFILE_DIR/jenova-setup"`. The six targets are not the same kind of script:

| Profile | `jenova-setup` does |
|---|---|
| `Vulkan/dgpu-igpu-i5-1135g7` | FreeBSD sysctls, ZFS ARC cap, NVMe coalescing ✅ |
| `Vulkan/apu-ryzen7-5700u` | FreeBSD sysctls, amdgpu/RADV checks, ARC cap ✅ |
| `Vulkan/dgpu-i5-1135g7` | FreeBSD sysctls ✅ — but `:94` resolves `../../../..`, one level too deep since the S-6 restructure, so `bin/jenova-swap-mount` is never found and it silently takes the inline `mdmfs` fallback |
| `CPU/generic` | **Linux only.** No FreeBSD tunable is applied (B-10) |
| `Vulkan/dgpu-generic-12gb` | **Not a tuning script.** Symlinks a config; `:8` uses five `dirname` calls from a three-deep directory → root resolves to `$HOME` → `ln -s` fails under `set -e` (B-09) |
| `CUDA/dgpu-generic` | Identical to the above (B-09) |

`Vulkan/dgpu-generic-12gb` is the GPU fallback (score 25), so this is the path most unrecognised
hardware takes.

### 2.1 Supervisor gap confirmed in source (affects Q-5)

`bin/jenova-ca:13` declares `PROXY_PID=""`. **It is never assigned anywhere in the file.**
`--daemon` launches `llama-server` (`:695`) and the embed server (`:699`) only. Consequences,
all verified by reading the source:

| Symptom | Evidence |
|---|---|
| Headless start has no :8080 at all | no proxy launch in the `--daemon` block, `:596-779` |
| `status` cannot report the proxy | `:382-408` reads only two PIDs from `$PID_FILE` |
| `stop` cannot stop the proxy | `:355-380`, same |
| Watchdog cannot detect a wedged proxy | `_probe_health` (`:254-279`) targets `$LLAMA_PORT` = 8081 |
| Stale variable reference | `:670` prints `$OLD_PROXY_PID`, never set |

The proxy is instead `io.popen`'d as a child of the tray (`lib/ui.lua:67,137,156`). This
matches `docs/architecture/remediation-plan.md` WP-9. It matters here because **an `rc.d`
script is a headless start path and would inherit the gap** — see Q-5.

## 3. Target Dependency Set — FreeBSD Only

### Required (`pkg install`)

| Package | Consumed by |
|---|---|
| `luajit-openresty` | `lib/proxy.lua`, `lib/ui.lua`, all Lua runtime |
| `lua54` | `jenova-ui` embedded interpreter |
| `sqlite3` | `lib/db.lua:39` — `ffi.load("sqlite3")`. **Hard runtime dependency, missing from `docs/installation/dependencies.md`** |
| `git` | submodule fetch, `lib/git.lua` |
| `cmake`, `gmake` | llama.cpp and `jenova-ui` builds |
| `vulkan-loader` | GPU offload |
| `pkgconf` | `jenova-ui` build |
| `gtk3`, appindicator | `jenova-ui` tray (see licence note) |
| `ncurses` | `jenova-ui` TUI |
| `gettext-tools` | build tooling |

### Base system — must NOT be packaged

| Tool | Where it is wrongly treated as a package |
|---|---|
| `realpath(1)` | `scripts/install-dependencies.sh:104` maps it to `coreutils`; `scripts/preflight-check.sh:148` prints `install: coreutils`. It is in FreeBSD base. |
| `fetch(1)` | correctly detected in places, but ranked below `curl` in three probes |
| `swapinfo`, `sysctl`, `pciconf`, `zpool`, `nvmecontrol`, `mdmfs`, `ifconfig`, `lockf` | base |

### Optional

`shaderc` (glslc) · `drm-kmod` + `gpu-firmware-amd-kmod` · `node`/`npm` (Web UI build only —
but see Q-8) · `llvm` (clangd) · `curl` (fallback HTTPS client)

### 3.1 Licence posture (AGENTS.md rule 2)

| Dependency | Licence | Status |
|---|---|---|
| LuaJIT, Lua 5.4, llama.cpp/ggml | MIT | ✅ |
| SQLite | Public domain | ✅ |
| ncurses | MIT-style | ✅ |
| `pango`, `cairo` | LGPL-2.1 / MPL-1.1 | ✅ explicit AGENTS.md exception |
| **GTK3** | **LGPL-2.1** | ⚠️ beyond the stated exception — Q-4 |
| **libappindicator / ayatana** | **LGPL-2.1 / LGPL-3.0** | ⚠️ beyond the stated exception — Q-4 |
| **GNU coreutils** | **GPL-3.0** | ❌ **rule-2 violation.** Pulled in only to supply `realpath`, which FreeBSD has in base. Pure removal. |
| **GNU bash** | **GPL-3.0** | ❌ **rule-2 violation.** Required by `bin/jenova-model-switch:1` (`#!/usr/bin/env bash`) — the only non-`/bin/sh` script in the repo, and not in FreeBSD base. Q-7. |

Project licence is AGPL-3.0 (`LICENSE`); that governs Jenova's own distribution and is
independent of the dependency rule.

## 4. Platform Abstraction — Current vs Target

### 4.1 The FFI ABI switch — the highest-value removal

`lib/ffi_defs.lua:8` sets `is_linux = jit.os == "Linux"` and branches twice.

**Branch 1 (`:11-104`) — ~50 lines of duplicated struct definitions.** Not cosmetic. The two
arms differ structurally:

| Struct | Linux arm | FreeBSD arm |
|---|---|---|
| `sa_family_t` | `unsigned short` (2 bytes) | `uint8_t` (1 byte) |
| `sockaddr_in` | no length byte | leading `uint8_t sin_len` |
| `sockaddr_in6` | no length byte | leading `uint8_t sin6_len` |
| `sockaddr` | no length byte | leading `uint8_t sa_len` |
| **`addrinfo`** | `… ai_addr; ai_canonname; ai_next;` | `… ai_canonname; ai_addr; ai_next;` — **fields in the opposite order** |

That last row is a live ABI trap: reading the wrong arm silently swaps a `struct sockaddr *`
with a `char *`.

**Branch 2 (`:215-263`) — 24 constants per arm**, including `O_NONBLOCK` (0x0800 vs 0x0004),
`SOL_SOCKET` (1 vs 0xffff), `SO_REUSEADDR` (2 vs 4), the whole `SO_*`/`TCP_KEEP*` block,
`EAGAIN` (11 vs 35), `EINPROGRESS` (115 vs 36), `ETIMEDOUT` (110 vs 60), `MSG_DONTWAIT`
(0x40 vs 0x80). Plus `AF_INET6` at `:198` (10 vs 28).

`IS_LINUX` is exported at `:195` and consumed at exactly five sites:

| Site | Guarded behaviour |
|---|---|
| `lib/proxy.lua:553` | `h_addr.sin_len = ffi.sizeof(h_addr)` — BSD length byte |
| `lib/proxy.lua:1424` | BSD-only arm |
| `lib/proxy.lua:1516` | BSD-only arm |
| `lib/http.lua:189` | BSD-only arm |
| `lib/http.lua:277` | BSD-only arm |

**Target:** one arm. `docs/architecture/remediation-plan.md:324-340` (WP-15) already concluded
that LuaJIT's C ABI surface is genuinely implicated — three of four Phase 1 defects traced to a
single variadic mismatch, the fourth to an undefined ctype that failed invisibly inside a
`pcall`. Deleting Linux halves that surface. **This stage makes the code more correct, not just
narrower.**

Note the file already hard-codes FreeBSD values unconditionally elsewhere — `:265-268` is
commented "FreeBSD signal numbers" with no branch (correct only because SIGINT/SIGTERM/SIGPIPE
happen to agree). The file's header (`:3`) already claims "FreeBSD 15 / amd64 compatible."

### 4.2 Environment detection

`lib/detect-env.sh` (259 lines), the largest single concentration — 39 non-FreeBSD references:

| Lines | Content |
|---|---|
| `:37-42` | `JENOVA_OS` tri-state (freebsd / linux / macos / unknown) |
| `:51-54` | WSL probe via `/proc/version` |
| `:60-130` | seven-way distro map, six-way package-manager probe, macOS brew/macports |
| `:143-152` | `/proc/cpuinfo` + `lscpu` CPU detection |
| `:155-160` | macOS `sysctl machdep.cpu.brand_string` / `hw.logicalcpu` |
| `:173-176` | `/proc/meminfo` memory |
| `:177-185` | macOS `hw.memsize` / `vm.swapusage` |
| `:196-203` | Linux `ldconfig -p` + multilib Vulkan paths; macOS `.dylib` under `/usr/local` and `/opt/homebrew` |

**Target:** FreeBSD `sysctl` (`hw.model`, `hw.ncpu`, `hw.physmem`), `swapinfo`, and
`ldconfig -r` only. Hard-fail on any other `uname -s` rather than degrading to `unknown`.

### 4.3 Linux kernel tuning — dead code today

`lib/linux-tune.sh` (128 lines) is wholly Linux-specific: `/etc/sysctl.d/99-jenova.conf`,
`vm.swappiness`, `vm.max_map_count`, `net.core.*`, transparent hugepages via `/sys/kernel/mm/`,
`nvidia-smi -pm 1`, Debian `limits.d`.

**It is already unreachable.** Its only caller is `scripts/jenova-setup:125`, guarded by
`[ "$JENOVA_OS" = "linux" ]` — but `scripts/jenova-setup` **never sources
`lib/detect-env.sh`**, so `$JENOVA_OS` is empty there and the branch cannot fire. Deleting the
file, its caller branch, and `tests/test_linux_tune_regex.sh` removes 128 + ~12 + 66 lines of
code that has never executed.

FreeBSD tuning is unaffected: it lives in the per-profile `jenova-setup` scripts and
`hardware-profiles/common-setup.sh`, which writes `/etc/sysctl.conf` — the location FreeBSD
actually reads. `lib/linux-tune.sh` wrote `/etc/sysctl.d/`, which FreeBSD does not read at all.

### 4.4 Build backend selection

`bin/build-llama-jenova` carries a full Metal path that cannot apply:

| Lines | Content |
|---|---|
| `:72, :81-83, :133, :152-153, :218-220` | `ENABLE_METAL`, `metal` backend argument, `-DGGML_METAL=ON` |
| `:91-99` | `auto` branch: `[ "$JENOVA_OS" = "macos" ]` → Metal on aarch64, Vulkan on Intel Mac |
| `:286-289` | `append_devices "Metal" 1` |
| `:234` | copies `"$BUILD_DIR/bin/"*.dylib*` |
| `:118-126` | glslc hints for pacman / apt / dnf / zypper / brew |

**CUDA is a separate question.** `:104` enables CUDA when `nvcc` is present and `:278-283`
counts GPUs with `nvidia-smi`. NVIDIA ships no CUDA toolkit for FreeBSD — its FreeBSD driver
provides OpenGL/Vulkan only. So on FreeBSD the CUDA path is unreachable in practice. See Q-6.

### 4.5 Executable-path resolution

`jenova-ui/src/main.c:56-74` — three arms: `__FreeBSD__` → `sysctl KERN_PROC_PATHNAME`;
`__APPLE__` → `_NSGetExecutablePath` (with `mach-o/dyld.h` at `:20-22`); `#else` →
`readlink("/proc/self/exe")`. **Target:** the FreeBSD arm alone, plus `#error` on anything else.

### 4.6 Shell-out flavour probes

| Site | Probe | Target |
|---|---|---|
| `lib/search.lua:143-164` | Runs `stat -c '%Y' /dev/null` at module load to test for GNU stat, falls back to BSD `stat -f '%m'` | BSD form unconditionally. Removes one wasted fork on every proxy start. |
| `bin/jenova-ca:68` | `stat -c '%U'` then `stat -f '%Su'` | BSD form only |
| `bin/jenova-ca:624` | `stat -c %Y` then `stat -f %m` | BSD form only |
| `lib/ui.lua:93-97` | `xdg-open` test, falls back to `open(1)` "macOS / FreeBSD with xdg-utils missing" | `xdg-open`, with `xdg-utils` documented |
| `lib/ui.lua:186-195` | `ifconfig` fallback "for FreeBSD/macOS" | unconditional; `ifconfig` is base |
| `lib/ui.lua:48-52` | health client order: `curl` → `nc` → `fetch` | `fetch` first — it is base, curl is not |
| `bin/jenova-ca:256` | `_probe_health` prefers `curl` over the bundled `healthcheck.lua` | prefer base/bundled |
| `bin/jenova:15` | GUI detect includes `[ "$(uname -s)" = "Darwin" ]` | drop |
| `bin/jenova-term:6-8` | Darwin arm execs `osascript` for Terminal.app | drop |
| `bin/jenova-ca:204-207` | Vulkan backend probe checks `.dylib` | drop |

### 4.7 Locking — `flock(1)` is not FreeBSD base

`bin/jenova-ca:604-656`. The comment at `:609` reads "flock available (Linux, FreeBSD with
flock installed)". FreeBSD's base equivalent is **`lockf(1)`**, not `flock(1)`. On a stock
FreeBSD host the `command -v flock` test fails and the code takes the mkdir-based fallback
(`:620-655`), which works but carries stale-lock timeout logic that the kernel would handle for
free. A FreeBSD-native supervisor should use `lockf`.

### 4.8 Verified portable — no action needed

Checked and confirmed working on FreeBSD; listed so they are not "fixed" by mistake:
`cp -a` (FreeBSD `cp` supports `-a` as `-pPR`) · `readlink -f` · `realpath` · `find` with
`-maxdepth` / `-mindepth` / `-print0` / `-quit` · `head -c` · `pkill -f` · `df -kP` ·
`install -m` · no `sed -i` outside the file being deleted · no `grep -P` · no `xargs -r/-d` ·
no `date -d` · no GNU-only Makefile syntax in `Makefile`, `jenova-ui/Makefile` or
`tests/Makefile` · `bin/jenova-swap-mount` is **already** FreeBSD-native (`mdmfs`, swap-backed,
`/etc/fstab` guidance) and needs no change.

## 5. `fetch` vs `curl` — deliberate retention

`lib/proxy.lua:257-285` prefers `fetch -T <n> -qo -` and falls back to `curl -sL --max-time`.
Under a FreeBSD-only target the fallback *looks* like Linux residue but is not — it is a runtime
capability check, and `fetch` is already the first choice. Recommendation: keep the fallback,
reword the comment, and fix the three places that rank `curl` *above* `fetch`
(`lib/ui.lua:48-52`, `bin/jenova-ca:256`, `scripts/preflight-check.sh:183`). Tabled as Q-2.

## 6. Hardware Profile Registry — deduplication analysis

### 6.1 Measured settings across all ten profiles

| Profile | DEVICES | NGL | CTX | Slots | Thr | TB | KV | Draft |
|---|---|---|---|---|---|---|---|---|
| `FreeBSD/AMD/apu/ryzen7-5700u-3b` | Vulkan0 | 24 | 16384 | 2 | 8 | 12 | q8_0 | 1 |
| `FreeBSD/dgpu/i5-1135g7-9b` | Vulkan0 | all | 16384 | 2 | 4 | 6 | q8_0 | 1 |
| `FreeBSD/dgpu_igpu/i5-1135g7-9b` | Vulkan0,Vulkan1 | all | 32768 | 2 | 4 | 6 | q8_0 | 0 |
| `Linux/AMD/apu/ryzen7-5700u-3b` | Vulkan0 | 24 | 16384 | 2 | 8 | 12 | q8_0 | 1 |
| `Linux/CPU/generic` | CPU | — | 16384 | 2 | 4 | 6 | — | 0 |
| `Linux/CUDA/dgpu/nvidia-generic` | CUDA0 | all | 16384 | 2 | 4 | 8 | q8_0 | 1 |
| `Linux/Vulkan/dgpu/full-offload-9b` | Vulkan0 | all | 32768 | 2 | 4 | 6 | q8_0 | 1 |
| `Linux/Vulkan/dgpu/gtx-1650ti` | Vulkan0 | all | 8192 | 1 | 4 | 6 | q8_0 | 0 |
| `macOS/CPU/generic` | CPU | — | 8192 | 1 | 4 | 4 | — | 0 |
| `macOS/Metal/generic` | Metal0 | — | 16384 | 2 | 4 | 8 | — | 1 |

### 6.2 Duplicates — proven

**Duplicate 1 — exact.** `Linux/AMD/apu/ryzen7-5700u-3b` ≡ `FreeBSD/AMD/apu/ryzen7-5700u-3b`:

- `jenova.conf` — **byte-identical** (`diff` empty)
- `jenova-setup` — **byte-identical**
- `profile.conf` — differs only in a header comment, `PROFILE_NAME`, `PROFILE_DESC`
  ("15.28 GiB" vs "16 GiB") and `MATCH_OS`

Same hardware, same tuning, two OS labels. Delete the Linux copy — zero loss.

**Duplicate 2 — same hardware, drifted settings.** `Linux/Vulkan/dgpu/gtx-1650ti` ≈
`FreeBSD/dgpu/i5-1135g7-9b`. Both declare `MATCH_CPU="i5-1135G7"` with a single NVIDIA dGPU;
this is one physical laptop described twice.

| | FreeBSD/dgpu | Linux/gtx-1650ti |
|---|---|---|
| `MATCH_GPU_0` | `NVIDIA` (broad) | `GeForce GTX 1650 Ti` (specific) |
| CTX / slots / draft | 16384 / 2 / on | 8192 / 1 / off |

Delete the Linux copy. Worth adopting its tighter `MATCH_GPU_0` — the FreeBSD profile's broad
`NVIDIA` also matches the dual-GPU machine, and is separated from `dgpu_igpu` only by the
`MATCH_GPU_1` scoring bonus.

### 6.3 Not duplicates — unique coverage

| Profile | Why it must survive |
|---|---|
| `Linux/CPU/generic` | The **only** CPU-only profile anywhere. Without it a FreeBSD host with no working Vulkan ICD matches nothing and `detect-hardware.sh` exits non-zero. |
| `Linux/Vulkan/dgpu/full-offload-9b` | The **only** generic 12GB+ single-GPU fallback. `MATCH_OS=""` — it already matches FreeBSD. |
| `Linux/CUDA/dgpu/nvidia-generic` | Retained under D-B as **opt-in only** — must be excluded from auto-detection. |
| `FreeBSD/dgpu_igpu/i5-1135g7-9b` | Dual-GPU split; distinct from every single-GPU profile. |

`macOS/CPU/generic` and `macOS/Metal/generic` are deleted outright.

**Result: 10 → 6 profiles.**

### 6.4 The tree is taxonomically incoherent

The middle level is sometimes a **vendor** (`AMD`), sometimes a **backend** (`Vulkan`, `CUDA`,
`CPU`), sometimes a **GPU class** (`dgpu`, `dgpu_igpu`). Depth varies between 3 and 4:

```
FreeBSD/AMD/apu/ryzen7-5700u-3b      ← 4 levels, vendor
FreeBSD/dgpu/i5-1135g7-9b            ← 3 levels, GPU class
Linux/Vulkan/dgpu/gtx-1650ti         ← 4 levels, backend
Linux/CPU/generic                    ← 3 levels, backend
```

That inconsistency is the **root cause of D-9**: `scripts/jenova-setup:107` globs
`*/*/*/profile.conf` at fixed depth 3, so every 4-deep profile is silently missing from its
"available profiles" listing. `detect-hardware.sh` escapes this only because it uses
`find -name`. See Q-1 for the layout options; a uniform-depth tree fixes the bug structurally
rather than patching the glob.

### 6.5 Profile documentation is stale

`hardware-profiles/README.md` disagrees with the files it documents:

| Claim | Reality |
|---|---|
| `:70-74` — `FreeBSD/dgpu/i5-1135g7-9b` is NGL 16 partial, CTX 8192, DRAFT 0 | conf says NGL `all`, CTX 16384, slots 2, DRAFT 1 |
| `:82-87` — `FreeBSD/dgpu_igpu/i5-1135g7-9b` is DRAFT 1 | conf says DRAFT 0 |

Both rows must be rewritten in S-5 regardless of the Q-1 outcome.

> **Status 2026-08-28 — half done.** S-7 rewrote `hardware-profiles/README.md`, and the audit
> removed its model/quantisation columns entirely (they were never read by anything). But the
> drift itself lives in **`profile.conf`**, which no stage touched. Each `profile.conf` carries a
> `PROFILE_*` block commented *"should match jenova.conf in this directory"*; for
> `Vulkan/dgpu-i5-1135g7` **all five values differ** — CTX 8192 vs 16384, slots 1 vs 2, NGL 16 vs
> `all`, DRAFT 0 vs 1, FIT 256 vs 128 — and `dgpu-igpu` disagrees on DRAFT. These blocks are
> informational (nothing reads them), so the correct fix is to sync or delete them, not to trust
> them. `TODOS.md` **B-20**.

### 6.6 Detection mechanics

Scoring (`hardware-profiles/detect-hardware.sh:184-232`): OS match +20 and a mismatch is
disqualifying (`:190`); CPU +10, disqualifying; GPU +5 per device; `MATCH_GPU_1` absent −8;
generic (no `MATCH_OS`) −5. Linux-only detection to delete: `lspci` (`:117-120`),
`/proc/mounts` (`:143-146`), `/proc/swaps` + `lsblk` (`:157-159`). FreeBSD equivalents —
`pciconf -lv`, `zpool list`, `swapinfo`, `nvmecontrol devlist` — are already present.

**Under D-B, the CUDA profile must be made unreachable by auto-detection.** Today its
`MATCH_OS="Linux|FreeBSD"` makes it FreeBSD-eligible and its broad
`MATCH_GPU_0="NVIDIA|GeForce|Quadro|RTX|GTX"` scores +5 on any NVIDIA host — so it can win
against a Vulkan profile on the very hardware D-B says should default to Vulkan.

### 6.7 Variable-name correctness

| Profiles | Names used | `bin/jenova-ca:228-233` reads |
|---|---|---|
| all three `FreeBSD/*` | `CTX_SIZE`, `NUM_SLOTS`, `THREADS`, `THREADS_BATCH` | ✅ match |
| `Linux/CPU/generic`, `macOS/CPU/generic`, `macOS/Metal/generic` | `JENOVA_CTX_SIZE`, `JENOVA_NUM_SLOTS`, `JENOVA_THREADS` | ❌ **`llama-server` launches with `-c "" -np "" -t ""`** |

This is the Q-1 hazard: `CPU/generic` is a survivor, and promoting it unfixed makes a broken
profile FreeBSD's only CPU fallback (remediation-plan WP-13).

**Variable drift verified.** All three FreeBSD profiles correctly set `CTX_SIZE`, `NUM_SLOTS`,
`THREADS`, `THREADS_BATCH` — the names `bin/jenova-ca:228-233` actually reads. The WP-13 drift
(`JENOVA_CTX_SIZE` etc.) is confined to `Linux/CPU/generic`, `macOS/CPU/generic` and
`macOS/Metal/generic`. **This is the hazard in Q-1 option A:** relocating `Linux/CPU/generic`
without fixing it would make a known-broken profile FreeBSD's only CPU fallback, launching
`llama-server` with `-c "" -np "" -t ""`.

Scoring (`hardware-profiles/detect-hardware.sh:184-232`): OS match +20 and a mismatch is
disqualifying (`:190`); CPU +10, disqualifying; GPU +5 per device; `MATCH_GPU_1` absent −8;
generic (no `MATCH_OS`) −5. Linux-only detection to delete: `lspci` (`:117-120`),
`/proc/mounts` (`:143-146`), `/proc/swaps` + `lsblk` (`:157-159`). FreeBSD equivalents —
`pciconf -lv`, `zpool list`, `swapinfo`, `nvmecontrol devlist` — are already present.

**Latent glob bug.** `scripts/jenova-setup:107` lists available profiles with
`"$SCRIPT_DIR/hardware-profiles"/*/*/*/profile.conf` — exactly three levels. The tree is mixed
depth: `FreeBSD/dgpu/i5-1135g7-9b` is three, `FreeBSD/AMD/apu/ryzen7-5700u-3b` is **four**, so
the APU profile never appears in that error listing. `detect-hardware.sh` uses `find -name`
and is unaffected. Whatever Q-1 decides, this glob must be replaced with `find`.

## 7. Missing FreeBSD-Native Surface

`docs/README.md:187-188`: *"There is no FreeBSD `rc.d` script and no systemd unit anywhere in
the repository."* Confirmed — nothing matches. A FreeBSD-native system is managed by
`service(8)` with `rcvar` and `sysrc jenova_enable=YES`. This is **additive** work, and it
inherits the §2.1 supervisor gap. See Q-5.

## 8. Test Surface

| Test | Guards | Migration impact |
|---|---|---|
| `tests/test_linux_tune_regex.sh` | `lib/linux-tune.sh` sed regexes | **Delete with its subject** (both are dead code) |
| `tests/test_validate_arg.sh:54,62` | path traversal in `detect-hardware.sh` | Fixtures use `Linux/Vulkan/dgpu/gtx-1650ti` — repoint |
| `tests/test_bin_jenova.sh` | `bin/jenova` dispatch | Update — Darwin arm removed |
| `tests/test-launcher.sh`, `test_gpu.sh`, `test_gpu_single.sh`, `test-health.sh` | launcher, GPU regexes, health | Review |
| `tests/proxy-concurrency/` | WP-1/2/3 regressions | **Must stay green** — the acceptance gate for S-1 |

`tests/proxy-concurrency/` is the only harness that exercises the proxy at all
(`REMEDIATION_PLAN.md`, Test strategy).

### 8.1 Audit findings, 2026-08-28

| Finding | Detail |
|---|---|
| **The fd-leak assertion cannot fail on FreeBSD** | `run.sh:58,96` count descriptors with `find /proc/$PX/fd`. `/proc` is not mounted on stock FreeBSD, so both counts are 0 and `[ 0 -le 2 ]` passes whether or not fds leak. The check was written under the Linuxulator, where `/proc` **is** mounted. **V-4 is therefore only a partial gate on the target platform.** FreeBSD equivalent: `procstat -f <pid>` (B-23) |
| **`python3` is undeclared** | `test-health.sh` and the whole `proxy-concurrency` harness require it; it is not in `install-dependencies.sh`'s `DEPS`, so `make deps` does not install it (B-24) |
| **`tests/Makefile` runs 3 of 8 scripts** | `test_bin_jenova.sh`, `test_validate_arg.sh`, `test_gpu.sh`, `test_gpu_single.sh` are orphaned (B-25) |
| **Both GPU tests fail unconditionally** | They require `external/ext_bin/bin/llama-cli`; `build-llama.sh:205-210` copies `llama-server` and `*.so*` only (B-25) |
| **`test_validate_arg.sh` mutates the repository** | Its `assert_pass` genuinely applies a profile, and `apply_profile` mirrors into `$JENOVA_ROOT/etc/jenova.conf`. The mktemp `JCA_HOME` does not cover the mirror. This is the real origin of commit `eee557e` (B-22) |
| **`test-health.sh` cannot pass on a headless start** | It probes `:8080`, which `--daemon` never brings up (B-13 / WP-9) |

The one test that does exactly its job is `test_ffi_flags.lua` — five assertions on real
descriptors, and it would have caught the entire Phase 1 defect class. It is the model to copy.

## 9. Cross-Cutting Defects Found During the Audit

Not platform bugs, but inside the blast radius. Listed so they are fixed deliberately or
deferred deliberately — not stepped over.

| # | Defect | Evidence |
|---|---|---|
| D-1 | `sqlite3` absent from the dependency doc though it is a hard runtime requirement | `lib/db.lua:39`; `docs/README.md:138` |
| D-2 | WP-13 variable drift in `CPU/generic` profiles | §6 above |
| D-3 | `realpath` mapped to GPL-3.0 `coreutils`; it is FreeBSD base | `install-dependencies.sh:104`, `preflight-check.sh:148` |
| D-4 | bash required in **two** places, not one — the shebang *and* an explicit `bash …` invocation from Lua. GPL-3.0, not in FreeBSD base. Closed by ruling D-A. | `bin/jenova-model-switch:1`; **`lib/ui.lua:121`** |
| D-5 | `scripts/install.sh:264` calls `make`; `install-jenova.sh:177-178` and every doc use `gmake` | inconsistent build entry |
| D-6 | `node`/`npm` checked as **required** in preflight though documented optional. **Resolved by ruling D-C: the code is right, the docs are stale.** | `preflight-check.sh:176-177` vs `docs/installation/dependencies.md:29-30` |
| D-7 | Preflight network check is curl-only | `preflight-check.sh:183` |
| D-8 | `jenova-setup` reads `$JENOVA_OS` without sourcing `detect-env.sh` | `scripts/jenova-setup:125` |
| D-9 | Profile-listing glob misses 4-deep profiles | `scripts/jenova-setup:107` |
| D-10 | `$OLD_PROXY_PID` referenced, never assigned | `bin/jenova-ca:670` |
| D-11 | Documented installer flags `--skip-jenova-ui`, `--skip-lsp` are not parsed | `docs/installation/freebsd.md:49-53` vs `install.sh:50-66` |
| D-12 | **:8081 and :8082 bind to `0.0.0.0` under `--lan`** though no external client uses them; firewall text tells users to open them | `bin/jenova-ca:239,708,804,823` + `:331`; `scripts/install.sh:562`. See §2.1 and ruling D-E. |
| D-13 | `/api/fs` is missing from the vite dev proxy while `/api/storage`, `/api/db`, `/api/workspaces` are present | `jca_web/vite.config.ts:91-99` (already noted in remediation-plan WP-13) |

## 10. Active Workstream — Nim native desktop application (rulings D-D, **D-L**)

> **Promoted 2026-08-28 20:29 by ruling D-L.** This section previously described a long-term
> trajectory. It is now the active workstream, and its target changed: **Jenova becomes a native
> FreeBSD graphical desktop application** — compiled, drawing its own interface, explicitly not a
> web wrapper or a WebUI in a window. `jca_web/` is retained during the transition and
> **deprecated**.
>
> **The spec below is superseded in one respect.** `jenova_refactor_analysis.md` describes a Nim
> *server and CLI* that keeps the WebUI as its client — it lists WebUI static-file serving as a
> core responsibility and "WebUI clients never experience lag" as an acceptance criterion, and its
> six-component roadmap has **no GUI component**. Under D-L that roadmap gains a seventh component
> and loses its client. Its server, RAG, database and `llama.cpp`-linkage analysis stands.
>
> **Q-4 is no longer deferrable.** The row below de-prioritises the LGPL GTK3/appindicator
> exposure on the reasoning that it "likely disappears" in the rewrite. It does not disappear —
> under D-L the GUI *is* the product, and Directive 2 rules out GTK, Qt, FLTK and every wrapper
> over them. The toolkit choice is the first architectural decision of the rewrite: **Q-20**.
>
> Two further open questions gate this work: **Q-21** (re-triage the backlog — most open defects
> live in files the rewrite deletes) and **Q-22** (single binary vs core daemon + GUI client,
> which also settles static vs dynamic `llama.cpp` linkage).

The USER's stated direction, corroborated by `jenova_refactor_analysis.md` on `develop/nim`:
replace `proxy.lua`, `db.lua`, `search.lua`, `embed.lua` and the shell orchestrators with a
compiled Nim backend — `asyncdispatch` (kqueue on FreeBSD), isolated thread pools for
inference / network / workers, direct `libllama` linkage, and the three ports unified behind
one router. The GTK3/C tray becomes a Nim native desktop app.

**Note `develop/nim` holds the design document and no Nim source, and is behind `main`** — it
lacks `tests/proxy-concurrency/` entirely, which `d2afac0` added. It is a specification to
honour, not a base to merge (C-7).

### What this changes about the FreeBSD migration

| Component | Fate under Nim | Therefore, now |
|---|---|---|
| `lib/ffi_defs.lua` | deleted — Nim binds C directly | **Delete the Linux arm aggressively.** Pure subtraction; less to port, and it removes the exact FFI class the Nim analysis cites as motivation. |
| `lib/proxy.lua`, `db.lua`, `search.lua`, `embed.lua` | rewritten in Nim | Touch only to remove `IS_LINUX` and GNU-first probes. **No restructuring.** |
| `bin/jenova-ca`, `scripts/*` | replaced by Nim orchestration | **Excise foreign branches; do not redesign.** |
| `jenova-ui/src/main.c` | replaced by a Nim desktop app | Minimum viable: collapse the `#ifdef`s, fix the pkg-config name. **De-prioritises Q-4** — the LGPL exposure likely disappears. |
| `hardware-profiles/` | survives — data, not code | Worth getting the taxonomy right now (Q-1). |
| `rc.d/jenova` | survives — calls verbs, not internals | Additive work that outlives the rewrite. |

**Governing principle: subtract, do not rewrite.** Deletion is banked as less to port;
restructuring is thrown away.

It also settles WP-15 (`docs/architecture/remediation-plan.md:324-340`), which framed Lua vs
Nim as open and recommended a C shim as a middle path. The USER has decided. WP-15's
recommendation is moot; its *diagnosis* — that the LuaJIT C ABI surface is the defect source —
is exactly what S-1 acts on.

## 11. Implementation Registry

Completed work. **Note:** sections 4 and 6 above describe the *pre-migration* state and are
retained as the audit record; the tree they describe no longer exists.

| ID | Item | Completed | Verified |
|---|---|---|---|
| S-0 | :8081/:8082 bind loopback unconditionally; firewall text :8080 only | 2026-08-28 | `sh -n`; `sockstat` check pending |
| S-1 | `ffi_defs.lua` Linux ABI arms deleted (304→236 lines); `IS_LINUX` + 5 consumers removed; FreeBSD load guard | 2026-08-28 | **Live:** loads on FreeBSD 15.1, `AF_INET6=28`, `SOL_SOCKET=0xffff`, `EAGAIN=35`, `sizeof(sockaddr_in)=16`; `test_ffi_flags.lua` 5/5 |
| S-2 | bash eliminated — `jenova-model-switch` POSIX rewrite + `lib/ui.lua:121` | 2026-08-28 | **Live:** 6/6 functional cases incl. filenames with spaces |
| S-3 | `detect-env.sh` rewritten on `kern.ostype`; `linux-tune.sh` + test deleted | 2026-08-28 | **Live:** `freebsd`/`15.1-RELEASE`/`pkg` (was `linux`/`fedora`/`none`) |
| S-4 | 12 shell files excised; `install-dependencies.sh` 498→210; Metal, CUDA auto-detect, `flock`, GNU-`stat` removed | 2026-08-28 | `sh -n` all 53 scripts |
| S-5 | `jenova-ui` FreeBSD-only C; Makefile probes both indicator libraries | 2026-08-28 | ⏸ needs a compile |
| S-6 | Profiles 10→6, uniform depth 2; WP-13 drift fixed; CUDA `PROFILE_OPT_IN` | 2026-08-28 | **Live:** selects `Vulkan/dgpu-i5-1135g7` (35); CUDA `[no match]`; ladder 35/27 > 25 > 20 |
| S-7 | Dropped-platform docs deleted; port topology corrected; profile reference rewritten | 2026-08-28 | Reviewed |
| X-1 | Vulkan GPU fallback was unselectable (scored 0, selection requires >0) → `MATCH_OS="FreeBSD"` = 25 | 2026-08-28 | **Live:** now scores 25 |
| X-2 | `scripts/jenova-setup` never sourced `detect-env.sh`, so its OS guard could not fire | 2026-08-28 | `sh -n` |

**Cancelled by ruling D-H:** S-8 (`rc.d/jenova`) and WP-9 (proxy supervision) — service
integration will be written once, against the Nim backend.

### Outstanding verification

A full `make` build, `make install`, the complete `tests/proxy-concurrency/all.sh` harness, and a
live daemon start have **not** been run. See `TODOS.md` → Active (V-1 … V-6). *(The `gmake` naming
in those steps is stale — the build uses base `make(1)`; `TODOS.md` B-06.)*

### 11.1 Registry corrections — full-tree audit, 2026-08-28

Three rows above claimed more than was done. Corrected here; the rows are left in place so the
failure mode stays visible.

| Row | Claimed | Actual |
|---|---|---|
| **S-6** "Profiles 10→6, uniform depth 2; WP-13 drift fixed" | drift fixed | Fixed in `jenova.conf` only. `profile.conf` was never touched and still contradicts it (§6.5 status note, B-20). The relocation also broke three `jenova-setup` scripts (§2.3, B-09/B-10) |
| **S-4** "GNU-first `stat` removed … Metal, CUDA auto-detect, `flock` removed" | shell excision complete | True for the files that were rewritten. `hardware-profiles/CPU/generic/jenova-setup` was **moved, not rewritten**, and is still pure Linux (B-10) |
| **S-7** "Documentation … profile reference rewritten" | docs corrected | The README was corrected; `verify-install.sh`, `uninstall.sh` and `update.sh` still document and verify a bundled Neovim distribution that does not exist (B-08, B-27, B-28) |

**Root cause, for future stages:** every one of these is a file that was *relocated* rather than
*edited*. Verification was `sh -n` plus review of the diff — and a moved file has no diff. Static
syntax checking cannot detect a syntactically valid script that does nothing on this kernel.
**A stage that moves files must re-read them at the destination.**
