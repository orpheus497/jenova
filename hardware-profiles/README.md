# Jenova Hardware Profiles

Hardware-specific configuration for Jenova, measured on FreeBSD and matching FreeBSD and Linux.
Each profile sets the GPU offload strategy, context size and thread counts for a given hardware
combination — not the model (see below). Detection runs when you ask for it — `jenova-core
hardware detect`, `list` or `apply --best`, or the desktop application's Hardware screen, which
ranks every profile and applies the one you choose — and nothing applies a profile at install.
Profiles can also be deployed by name.

## Directory Structure

Profiles are organised by **inference backend**, then by **hardware configuration**, at a
uniform depth of two:

```
hardware-profiles/
├── Vulkan/                       # Vulkan backend — built by `nimble llama` on FreeBSD and Linux
│   ├── apu-ryzen7-5700u/         # Ryzen 7 5700U, Vega 8 UMA, partial offload
│   ├── dgpu-i5-1135g7/           # i5-1135G7 + GTX 1650 Ti, dGPU only
│   ├── dgpu-igpu-i5-1135g7/      # i5-1135G7 + GTX 1650 Ti + Iris Xe, dual GPU
│   └── dgpu-generic-12gb/        # Any Vulkan GPU with 12GB+ VRAM (fallback)
├── CUDA/
│   └── dgpu-generic/             # Opt-in only — never auto-selected
├── CPU/
│   └── generic/                  # CPU-only fallback
└── README.md
```

The depth is uniform for readability. An earlier layout mixed vendor (`AMD`), backend (`Vulkan`)
and GPU class (`dgpu`) at the same level and varied between three and four levels deep, which broke
the fixed-depth glob that then listed profiles. Listing no longer depends on depth:
`hardware.listProfiles` walks `hardware-profiles/` recursively and takes every directory holding a
`profile.conf`.

**Profiles do not select a model.** No profile's `jenova.conf` sets `MODEL_PATH`, `MODEL_DRAFT` or
`MODEL_EMBED`. A profile sets devices, layer offload and fit target, tensor split, context size and
slots, threads, KV cache type, drafting (`JENOVA_DRAFT`, and `DRAFT_DEVICE` in all but
`CPU/generic`), and — in the Vulkan profiles — batch sizes; every profile also sets `JCA_HOME`,
`LLAMA_SERVER` and the ports, and some set URLs, paths, agent limits, a health timeout and (in
`CPU/generic`) the flash-attention, mlock and mmap switches. Which model runs is decided by
`src/jenova/models.nim`: `config.load` calls `models.discover` for `MODEL_PATH`, `MODEL_DRAFT` or
`MODEL_EMBED` only when the evaluated conf files leave that key empty. For the agent model it checks
`JENOVA_MODEL` first, then `models/agent/active.gguf` when that link resolves, then the first
non-backup `.gguf` that resolves in `models/agent/` in sorted order, then the same in the flat
`$JCA_HOME/models/`. Draft and embed take the first such file in `models/draft/` and `models/embed/`,
with no fallback; `JENOVA_DRAFT_MODEL` and `JENOVA_EMBED_MODEL` come first for them.

Model names in profile comments are the models each profile was sized against, not settings, and
nothing reads them. Model names also appear in `profile.conf` values: `PROFILE_DESC` is read and
shown on the window's Hardware screen; `STRATEGY_DESC` is read into a field nothing displays; the
`RECOMMENDED_*` keys are read by nothing. These have drifted too — `apu-ryzen7-5700u`'s
`PROFILE_DESC` names Qwen3.5-4B Q6_K while its `STRATEGY_DESC` names Qwen2.5-Coder-3B Q8_0.

## Dual-GPU Strategy: The Laptop Advantage

Many consumer laptops carry both an integrated GPU (iGPU) and a discrete GPU (dGPU) and can use
both for inference simultaneously.

**The main advantage is running a larger model, or a significantly larger context, than a single
low-VRAM discrete GPU allows** — splitting layers across both devices pools their VRAM.

Trade-offs:

* **Speed** — slightly lower than a smaller model on a single stronger GPU, due to coordination
  overhead between devices.
* **Thermals and battery** — distributing the workload can keep both GPUs out of their highest
  power states. *Not a guarantee; it depends on the machine, but it has been consistent on our
  test hardware.*

These profiles target the balance found in consumer and prosumer laptops, not high-VRAM desktop
GPUs.

## Available Profiles

**GPUs are named, not numbered, wherever a machine can have more than one.** `Vulkan0` and
`Vulkan1` are the driver's numbering, and it is not the same everywhere: FreeBSD numbers the
i5-1135G7 laptop's GTX 1650 Ti `Vulkan0`, Linux its Iris Xe. So the i5-1135G7 profiles and
`dgpu-generic-12gb` set `DEVICES` to names, which Jenova turns into numbers when it starts the
backend (see [`jenova.conf`](#jenovaconf)); `apu-ryzen7-5700u` has one GPU and keeps `Vulkan0`.

On Linux, when `nimble llama` built CUDA, `llama-server` lists the CUDA devices first, so an NVIDIA
GPU appears as `CUDA0` ahead of its own Vulkan number. A name such as `NVIDIA` then resolves to
`CUDA0` and that GPU runs through CUDA: the dual-GPU profile passes `-dev CUDA0,Vulkan0` there.

### `Vulkan/dgpu-i5-1135g7` — single dGPU, Optane swap

**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB (sole GPU) | 16GB RAM | Intel Optane NVMe
**Strategy:** Partial offload — a 9B Q4_K_M does not fit in 4 GiB, so ~16 of 36 layers go to the
dGPU and the rest to the CPU. One slot at 8K keeps the KV cache small enough to leave VRAM for
those layers, and there is no budget for a drafter beside them. The machine it was sized on has
its swap on an Optane NVMe; Jenova neither requires nor configures that.

| Setting | Value |
|---|---|
| `DEVICES` | `NVIDIA` |
| `NGL_AGENT` | `16` |
| `CTX_SIZE` | `8192` |
| `NUM_SLOTS` | `1` |
| Drafter | No |

### `Vulkan/dgpu-igpu-i5-1135g7` — dual GPU

**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe (~7GB UMA) | 16GB RAM
**Strategy:** Full offload split across both Vulkan devices.

| Setting | Value |
|---|---|
| `DEVICES` | `NVIDIA,Intel.*(Iris\|Xe)` |
| `NGL_AGENT` | `all` |
| `CTX_SIZE` | `32768` |
| `NUM_SLOTS` | `2` |
| Drafter | Yes, pinned to the Iris Xe (`DRAFT_DEVICE=Intel.*(Iris\|Xe)`) |

### `Vulkan/apu-ryzen7-5700u` — AMD UMA partial offload

**Hardware:** AMD Ryzen 7 5700U 8C/16T | Radeon Vega 8 (Lucienne) UMA ~2–4GB | 15.28GB RAM
**Strategy:** Partial offload — 24 layers on the Vega 8, the rest on CPU. Raise `NGL_AGENT` if
the BIOS allocates 4+ GiB of UMA.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL_AGENT` | `24` |
| `CTX_SIZE` | `16384` |
| `NUM_SLOTS` | `2` |
| Drafter | Yes |

### `Vulkan/dgpu-generic-12gb` — allowlisted 12GB+ Vulkan GPUs

**Hardware:** RTX 3080/3090/4070/4080/4090/5070 Ti/5080/5090, RX 6800/6900/6950/7800/7900/9070,
Arc A770
**Strategy:** Full single-GPU offload. This is the **GPU fallback** for hardware with no specific
profile — it scores 25 on a listed card, above `CPU/generic` (20). A hardware-specific profile
needs its CPU to match, or it is disqualified; with the CPU matched, the single-GPU ones score 35
with their GPU and 30 without, and the dual-GPU one 40 with both GPUs, 35 with only the second, 27
with only the first and 22 with neither — so a matching hardware-specific profile does not always
score above this one.

**`MATCH_GPU_0` is an explicit allowlist, not a catch-all.** It offloads every layer and opens a
32K context, which only a card with 12 GiB or more survives; detection reads no VRAM
figure and can only validate by device name, so the pattern names the models that qualify. A card
that is not listed falls to `CPU/generic` — the safe direction — and this profile stays deployable
by name with `jenova-core hardware apply`. A newer card with enough VRAM belongs in that list.

| Setting | Value |
|---|---|
| `DEVICES` | the same allowlist as `MATCH_GPU_0` |
| `NGL_AGENT` | `all` |
| `CTX_SIZE` | `32768` |
| `NUM_SLOTS` | `2` |
| Drafter | Yes |

### `CPU/generic` — CPU-only fallback

**Hardware:** Any multi-core CPU, no usable Vulkan device
**Strategy:** CPU-only inference. It scores 20 on any FreeBSD or Linux host, which every profile's
`MATCH_OS` matches. With no listed GPU, `Vulkan/dgpu-generic-12gb` scores 20 as well — a GPU mismatch adds
nothing rather than disqualifying — and `CPU/generic` wins that tie only because profiles are listed
in sorted path order (`CPU/` before `Vulkan/`) and the ranking sort is stable. Without it, a
GPU-less host would get `dgpu-generic-12gb`, with full offload and a 32K context.

| Setting | Value |
|---|---|
| `DEVICES` | `none` — `llama-server`'s word for no GPU; it refuses `CPU` |
| `NGL_AGENT` | `0` |
| `CTX_SIZE` | `16384` |
| `NUM_SLOTS` | `2` |
| Drafter | No |

### `CUDA/dgpu-generic` — opt-in only

**Hardware:** NVIDIA GPU, CUDA backend
**Strategy:** Full offload via CUDA.

**This profile is never auto-selected.** Its `DEVICES=CUDA0` needs a `llama-server` built with
CUDA, which `nimble llama` produces only on Linux with `nvcc` found, and its `profile.conf` sets
`PROFILE_OPT_IN=1`, which excludes it from detection. Without that, its broad NVIDIA pattern would
score 25 on any NVIDIA host: a tie with `Vulkan/dgpu-generic-12gb` on a listed card, which `CUDA/`
would win by sorting first, and a win over `CPU/generic` on an unlisted one — on hardware the
`Vulkan/` profiles are written for. It would not beat the i5-1135G7 profiles.

Deploy it deliberately:

```sh
jenova-core hardware apply CUDA/dgpu-generic
```

| Setting | Value |
|---|---|
| `DEVICES` | `CUDA0` |
| `NGL_AGENT` | `all` |
| `CTX_SIZE` | `16384` |
| `NUM_SLOTS` | `2` |
| Drafter | Yes |

---

## Profile Summary

| Profile | Backend | `DEVICES` | `NGL_AGENT` | GPU memory | Context | Drafter | Auto-selected |
|---|---|---|---|---|---|---|---|
| `Vulkan/dgpu-i5-1135g7` | Vulkan | `NVIDIA` | `16` | 4 GiB dGPU | 8K | No | Yes |
| `Vulkan/dgpu-igpu-i5-1135g7` | Vulkan | `NVIDIA,Intel.*(Iris\|Xe)` | `all` | ~11 GiB dual | 32K | Yes | Yes |
| `Vulkan/apu-ryzen7-5700u` | Vulkan | `Vulkan0` | `24` | ~2–4 GiB UMA | 16K | Yes | Yes |
| `Vulkan/dgpu-generic-12gb` | Vulkan | the allowlist | `all` | 12GB+ | 32K | Yes | Fallback, allowlisted |
| `CPU/generic` | CPU | `none` | `0` | none | 16K | No | Fallback |
| `CUDA/dgpu-generic` | CUDA | `CUDA0` | `all` | VRAM-dependent | 16K | Yes | **No — opt-in** |

There is no model column because no profile sets a model. Five of the six `profile.conf` files name
the model they were sized against under `RECOMMENDED_AGENT_MODEL` (and `RECOMMENDED_EMBED_MODEL`,
with download URLs); `Vulkan/dgpu-igpu-i5-1135g7` has none. It is documentation rather than a
setting — nothing reads it.

## Profile Detection

```sh
jenova-core hardware detect    # Hardware detection report
jenova-core hardware apply --best   # Score every profile and deploy the winner
jenova-core hardware list    # Every profile, ranked by score, with the reasons (-- when disqualified)
```

The OS is the one the binary was built for, `FreeBSD` or `Linux`, with the running kernel's
release. On FreeBSD the CPU, memory, swap and storage come from `sysctl`, `swapinfo`, `zpool` and
`nvmecontrol`; on Linux from `/proc/cpuinfo`, `/proc/meminfo`, `/proc/swaps`, the filesystem
`$JCA_HOME` is on, and `/sys/class/nvme`. The GPU list comes from `llama-server --list-devices` on
both.

### Detection Scoring

| Signal | Points |
|---|---|
| `MATCH_OS` matches | +20 (a mismatch disqualifies the profile outright) |
| `MATCH_CPU` matches | +10 (a mismatch disqualifies) |
| `MATCH_GPU_0` matches | +5 (a mismatch adds nothing) |
| `MATCH_GPU_1` matches | +5 |
| `MATCH_GPU_1` declared but absent | −8 |
| `MATCH_SWAP` matches | +10 (a mismatch disqualifies) |
| No `MATCH_OS` set (generic profile) | −5 |
| `PROFILE_OPT_IN=1` | excluded from detection entirely |

The highest scorer wins, and a score must be **strictly greater than zero** to be selected at
all. A tie goes to the profile listed first, in sorted path order. Multi-GPU profiles score above
their single-GPU equivalents on dual-GPU hardware because of the `MATCH_GPU_1` bonus.

The resulting priority ladder:

| Score | Profile kind |
|---|---|
| 22–40 | Hardware-specific, CPU matched (40 with both GPUs of the dual profile; 35 or 30 for the single-GPU ones, with or without their GPU; 27 or 22 for the dual profile missing its second GPU) |
| 25 or 20 | `Vulkan/dgpu-generic-12gb` — GPU fallback, 25 on a listed card |
| 20 | `CPU/generic` — CPU-only fallback |
| — | `CUDA/dgpu-generic` — excluded, opt-in only |

**Set `MATCH_OS` on any profile you want selectable** — `"FreeBSD|Linux"` for both. Leaving it
empty takes the −5 generic penalty, and a profile whose only other signal is a GPU match then
totals 0 — which fails the strictly-greater-than-zero test and can never be chosen.

---

## Profile Structure

```
<backend>/<config>/
├── profile.conf        # Detection rules and metadata
└── jenova.conf         # Runtime configuration
```

### `profile.conf`

```sh
PROFILE_NAME="Vulkan/dgpu-i5-1135g7"
PROFILE_DESC="Hardware description"
MATCH_CPU="i5-1135G7"        # CPU model substring (fixed string, case-insensitive)
MATCH_GPU_0="NVIDIA"         # Primary GPU pattern (Nim std/re, i.e. PCRE; case-insensitive)
MATCH_GPU_1="Intel.*(Iris|Xe)"  # Secondary GPU pattern (optional; same syntax)
MATCH_OS="FreeBSD|Linux"     # Omit only for deliberate last-resort fallbacks
PROFILE_OPT_IN=1             # Optional: exclude from auto-detection entirely
```

### `jenova.conf`

Runtime configuration, evaluated by `src/jenova/config.nim`. **Use the unprefixed names** —
`DEVICES`, `CTX_SIZE`, `NUM_SLOTS`, `THREADS`, `THREADS_BATCH`, `NGL_AGENT`, `FIT_TARGET`,
`KV_CACHE_TYPE`. The key list `config.nim` reads is exactly `Keys` in that file; a name not in it
is invisible to the core. Setting `JENOVA_CTX_SIZE` and friends instead is silently ignored, and
`llama-server` then launches on the built-in defaults. For those tuning keys the `JENOVA_*` names
belong on the right-hand side, as environment overrides:

```sh
CTX_SIZE="${JENOVA_CTX:-16384}"
```

A few keys are themselves `JENOVA_*` names and are assigned under them on the left:
`JENOVA_STATE`, `JENOVA_DRAFT`, `JENOVA_FLASH_ATTN`, `JENOVA_MLOCK`, `JENOVA_MMAP`,
`JENOVA_REASONING` and `JENOVA_HEALTH_TIMEOUT`. `JENOVA_MLOCK` and `JENOVA_MMAP` become llama.cpp's
single `-lm` load mode. `JENOVA_REASONING` (`on`, `off`, `auto`) is passed as `--reasoning`; left
empty, a model in `models/instruct/` runs without thinking and any other keeps the automatic default.

GPU patterns are matched against the `llama-server --list-devices` lines; a pattern that is not a
valid regex counts as no match.

`DEVICES` and `DRAFT_DEVICE` take a comma-separated list. `none` on its own means no GPU. An entry
that is a device number (`Vulkan0`, `CUDA0`) is passed to `llama-server` as it is; any other entry
is a pattern, matched the same way against each device's name (not its memory figures), and
becomes the number of the first device it matches that is not already taken.
`jenova-core backends args` shows the result. A name that matches nothing is left out and noted in
the backend's log, on a line beginning `jenova:`, just before that start's output. If nothing is
left, or `llama-server --list-devices` does not answer,
no `-dev` is passed and `llama-server` uses every GPU it finds.

### Kernel tuning — not here, and not Jenova's job

Each profile once carried a `jenova-setup` script that set sysctls and capped the ZFS ARC.
**Those scripts are gone and nothing replaces them: Jenova never applies a kernel tunable and
never writes `/etc/sysctl.conf`.** It reads `sysctl` (FreeBSD) or `/proc` (Linux) to detect the
machine and sets nothing.
Tuning the kernel is yours to do. The old scripts' values are not kept in this tree; the ZFS ARC
cap is in [../docs/install.md](../docs/install.md#zfs).

---

## Manual Profile Selection

```sh
# Deploy a specific profile
jenova-core hardware apply Vulkan/dgpu-i5-1135g7

# Or copy manually. config.nim prefers $JCA_HOME/etc over the source tree's etc/
cp hardware-profiles/Vulkan/dgpu-i5-1135g7/jenova.conf "${JCA_HOME:-$HOME/Jenova}/etc/jenova.conf"
```

The desktop application's Hardware screen does the same thing, and is the intended route.

---

## Environment Overrides

Every profile respects these, set in the environment of the `jenova` or `jenova-core` process:

```sh
export JENOVA_MODEL=/path/to/my-model.gguf
export JENOVA_DEVICES="Vulkan0"
export JENOVA_NGL_AGENT=24
export JENOVA_CTX=8192
export JENOVA_SLOTS=1
export JENOVA_DRAFT=0
export JENOVA_HOST=0.0.0.0    # LAN mode — affects the server on :8080 only
```

`JENOVA_HOST` moves the **server**, Jenova's own listener on `:8080`. The inference and embedding
servers always bind loopback; they are internal backends reached through it. `JENOVA_MODEL` is read
by model discovery, not by the conf files, so it does not work from inside `jenova.local.conf` —
set `MODEL_PATH` there instead.

---

## Creating a New Profile

1. Choose the backend directory: `Vulkan/`, `CUDA/` or `CPU/`.
2. Create `hardware-profiles/<backend>/<config>/` — keep the depth at two.
3. Add `profile.conf` with detection patterns and metadata.
4. Add `jenova.conf` by copying an existing profile — **check the variable names against the
   list above.**
5. That is all a profile is — two data files. There is no setup script.
6. Test: `jenova-core hardware detect`

Name profiles for the hardware, not the model. The agent model is chosen by `MODEL_PATH` if a conf
file (such as `jenova.local.conf`) sets it, else by the `JENOVA_MODEL` environment variable, else by
discovery: `models/agent/active.gguf` (written by a model switch), then a scan of `models/agent/`,
then of `$JCA_HOME/models/`.
