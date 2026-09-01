# Jenova Hardware Profiles

Hardware-specific configuration for Jenova on FreeBSD. Each profile sets the model, GPU offload
strategy, context size, and thread counts for a given hardware combination. Auto-detection
selects the best match at install time; profiles can also be deployed by name.

## Directory Structure

Profiles are organised by **inference backend**, then by **hardware configuration**, at a
uniform depth of two:

```
hardware-profiles/
├── Vulkan/                       # Vulkan backend — the default on FreeBSD
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

The depth is uniform on purpose. An earlier layout mixed vendor (`AMD`), backend (`Vulkan`) and
GPU class (`dgpu`) at the same level and varied between three and four levels deep, which broke a
fixed-depth glob used to list profiles — every four-level profile was silently omitted.

**Profiles do not select a model.** They set devices, layer offload, context size, batch sizes,
threads and KV cache type — nothing more. Which model runs is decided by `src/jenova/models.nim`:
`models.discover`, called from `config.load`, takes the alphabetically first `.gguf` in
`$JCA_HOME/models/agent`, `draft` and `embed`, and fills only the paths the configuration left
empty. A `JENOVA_MODEL`, `JENOVA_DRAFT_MODEL` or `JENOVA_EMBED_MODEL` override wins over
discovery. Model names appearing in profile comments are the hardware each profile was sized
against, not a setting; several of those comments have drifted from each other and none of them
is read by anything.

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

### `Vulkan/dgpu-i5-1135g7` — single dGPU, Optane swap

**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB (sole GPU) | 16GB RAM | Intel Optane NVMe
**Strategy:** Partial offload — a 9B Q4_K_M does not fit in 4 GiB, so ~16 of 36 layers go to the
dGPU and the rest to the CPU. One slot at 8K keeps the KV cache small enough to leave VRAM for
those layers, and there is no budget for a drafter beside them. Optane NVMe swap backs the
overflow at ~7 μs.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL_AGENT` | `16` |
| `CTX_SIZE` | `8192` |
| `NUM_SLOTS` | `1` |
| Drafter | No |

### `Vulkan/dgpu-igpu-i5-1135g7` — dual GPU

**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe (~7GB UMA) | 16GB RAM
**Strategy:** Full offload split across both Vulkan devices.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0,Vulkan1` |
| `NGL_AGENT` | `all` |
| `CTX_SIZE` | `32768` |
| `NUM_SLOTS` | `2` |
| Drafter | Yes, pinned to `Vulkan1` |

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
profile — it scores 25, above `CPU/generic` (20) and below every hardware-specific profile (30+).

**`MATCH_GPU_0` is an explicit allowlist, not a catch-all.** It offloads every layer and opens a
32K context, which only a card with 12 GiB or more survives; detection reads no VRAM
figure and can only validate by device name, so the pattern names the models that qualify. A card
that is not listed falls to `CPU/generic` — the safe direction — and this profile stays deployable
by name with `jenova-core hardware apply`. A newer card with enough VRAM belongs in that list.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL_AGENT` | `all` |
| `CTX_SIZE` | `32768` |
| `NUM_SLOTS` | `2` |
| Drafter | Yes |

### `CPU/generic` — CPU-only fallback

**Hardware:** Any multi-core CPU, no usable Vulkan device
**Strategy:** CPU-only inference. Matches when no GPU profile does — without it, a host with no
working Vulkan ICD matches nothing at all.

| Setting | Value |
|---|---|
| `DEVICES` | `CPU` |
| `NGL_AGENT` | `0` |
| `CTX_SIZE` | `16384` |
| `NUM_SLOTS` | `2` |
| Drafter | No |

### `CUDA/dgpu-generic` — opt-in only

**Hardware:** NVIDIA GPU, CUDA backend
**Strategy:** Full offload via CUDA.

**This profile is never auto-selected.** NVIDIA hardware is driven through Vulkan by default;
its `profile.conf` sets `PROFILE_OPT_IN=1`, which excludes it from detection. Without that, its
broad NVIDIA GPU pattern would out-score the Vulkan profile on exactly the hardware that should
default to Vulkan.

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
| `Vulkan/dgpu-i5-1135g7` | Vulkan | `Vulkan0` | `16` | 4 GiB dGPU | 8K | No | Yes |
| `Vulkan/dgpu-igpu-i5-1135g7` | Vulkan | `Vulkan0,Vulkan1` | `all` | ~11 GiB dual | 32K | Yes | Yes |
| `Vulkan/apu-ryzen7-5700u` | Vulkan | `Vulkan0` | `24` | ~2–4 GiB UMA | 16K | Yes | Yes |
| `Vulkan/dgpu-generic-12gb` | Vulkan | `Vulkan0` | `all` | 12GB+ | 32K | Yes | Fallback, allowlisted |
| `CPU/generic` | CPU | `CPU` | `0` | none | 16K | No | Fallback |
| `CUDA/dgpu-generic` | CUDA | `CUDA0` | `all` | VRAM-dependent | 16K | Yes | **No — opt-in** |

There is no model column because no profile sets a model. Each `profile.conf` names the model it
was sized against under `RECOMMENDED_AGENT_MODEL`, which is documentation rather than a setting —
nothing reads it.

## Profile Detection

```sh
jenova-core hardware detect    # Hardware detection report
jenova-core hardware apply --best   # Auto-detect and deploy
jenova-core hardware list    # List all profiles
```

### Detection Scoring

| Signal | Points |
|---|---|
| `MATCH_OS` matches | +20 (a mismatch disqualifies the profile outright) |
| `MATCH_CPU` matches | +10 (a mismatch disqualifies) |
| `MATCH_GPU_0` matches | +5 |
| `MATCH_GPU_1` declared but absent | −8 |
| `MATCH_SWAP` matches | +10 (a mismatch disqualifies) |
| No `MATCH_OS` set (generic profile) | −5 |
| `PROFILE_OPT_IN=1` | excluded from detection entirely |

The highest scorer wins, and a score must be **strictly greater than zero** to be selected at
all. Multi-GPU profiles score above their single-GPU equivalents on dual-GPU hardware because of
the `MATCH_GPU_1` bonus.

The resulting priority ladder:

| Score | Profile kind |
|---|---|
| 30–40 | Hardware-specific (OS + CPU + GPU matched) |
| 25 | `Vulkan/dgpu-generic-12gb` — GPU fallback |
| 20 | `CPU/generic` — CPU-only fallback |
| — | `CUDA/dgpu-generic` — excluded, opt-in only |

**Set `MATCH_OS="FreeBSD"` on any profile you want selectable.** Leaving it empty takes the −5
generic penalty, and a profile whose only other signal is a GPU match then totals 0 — which
fails the strictly-greater-than-zero test and can never be chosen.

**The OS is read from `kern.ostype`, not `uname -s`.** Under the FreeBSD Linuxulator `uname -s`
answers `Linux`, which previously caused detection to select a Linux profile on a FreeBSD host.

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
MATCH_GPU_0="NVIDIA"         # Primary GPU pattern (extended regex)
MATCH_GPU_1="Intel.*(Iris|Xe)"  # Secondary GPU pattern (optional)
MATCH_OS="FreeBSD"           # Omit only for deliberate last-resort fallbacks
PROFILE_OPT_IN=1             # Optional: exclude from auto-detection entirely
```

### `jenova.conf`

Runtime configuration, evaluated by `src/jenova/config.nim`. **Use the unprefixed names** —
`DEVICES`, `CTX_SIZE`, `NUM_SLOTS`, `THREADS`, `THREADS_BATCH`, `NGL_AGENT`, `FIT_TARGET`,
`KV_CACHE_TYPE`. The key list `config.nim` reads is exactly `Keys` in that file; a name not in it
is invisible to the core. Setting `JENOVA_CTX_SIZE` and friends instead is silently ignored, and
`llama-server` then launches on the built-in defaults. The `JENOVA_*` names belong on the
right-hand side, as environment overrides:

```sh
CTX_SIZE="${JENOVA_CTX:-16384}"
```

### Kernel tuning — not here, and not Jenova's job

Each profile once carried a `jenova-setup` script that set sysctls and capped the ZFS ARC.
**Those are archived and nothing replaces them: Jenova never applies a kernel tunable and
never writes `/etc/sysctl.conf`.** It reads `sysctl` to detect the machine and sets nothing.
Tuning the kernel is yours to do; the values the old scripts used are preserved under
`.devdocs/ARCHIVE/hardware-profiles/`.

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

Every profile respects these:

```sh
export JENOVA_MODEL=/path/to/my-model.gguf
export JENOVA_DEVICES="Vulkan0"
export JENOVA_NGL_AGENT=24
export JENOVA_CTX=8192
export JENOVA_SLOTS=1
export JENOVA_DRAFT=0
export JENOVA_HOST=0.0.0.0    # LAN mode — affects the proxy on :8080 only
```

`JENOVA_HOST` moves the **proxy**. The inference and embedding servers always bind loopback;
they are internal backends reached through the proxy, and nothing outside the host addresses
them directly.

---

## Creating a New Profile

1. Choose the backend directory: `Vulkan/`, `CUDA/` or `CPU/`.
2. Create `hardware-profiles/<backend>/<config>/` — keep the depth at two.
3. Add `profile.conf` with detection patterns and metadata.
4. Add `jenova.conf` by copying an existing profile — **check the variable names against the
   list above.**
5. That is all a profile is — two data files. There is no setup script.
6. Test: `jenova-core hardware detect`

Name profiles for the hardware, not the model — model selection is an environment override.
