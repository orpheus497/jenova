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
├── common-setup.sh
├── detect-hardware.sh
└── README.md
```

The depth is uniform on purpose. An earlier layout mixed vendor (`AMD`), backend (`Vulkan`) and
GPU class (`dgpu`) at the same level and varied between three and four levels deep, which broke
the fixed-depth glob that `scripts/jenova-setup` used to list profiles — every four-level
profile was silently omitted.

**Profiles do not select a model.** They set devices, layer offload, context size, batch sizes,
threads and KV cache type — nothing more. Which model runs is decided by `lib/jenova-model.sh`,
which discovers whatever `.gguf` files are in `$JCA_HOME/models/`, or by a `JENOVA_MODEL`
override. Model names appearing in profile comments are the hardware each profile was sized
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
**Strategy:** Full offload to the single dGPU. Optane NVMe swap backs context overflow at ~7 μs.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL_AGENT` | `all` |
| `CTX_SIZE` | `16384` |
| `NUM_SLOTS` | `2` |
| Drafter | Yes |

### `Vulkan/dgpu-igpu-i5-1135g7` — dual GPU

**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe (~7GB UMA) | 16GB RAM
**Strategy:** Full offload split across both Vulkan devices.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0,Vulkan1` |
| `NGL_AGENT` | `all` |
| `CTX_SIZE` | `32768` |
| `NUM_SLOTS` | `2` |
| Drafter | No |

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

### `Vulkan/dgpu-generic-12gb` — any 12GB+ Vulkan GPU

**Hardware:** Any Vulkan-capable GPU with 12GB+ VRAM (RTX 3080/4070/4080/4090, RX 7900, Arc A770)
**Strategy:** Full single-GPU offload. This is the **GPU fallback** for hardware with no
specific profile — it scores 25, above `CPU/generic` (20) and below every hardware-specific
profile (30+).

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
JENOVA_BACKEND=cuda make llama
./hardware-profiles/detect-hardware.sh --apply-profile CUDA/dgpu-generic
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
| `Vulkan/dgpu-i5-1135g7` | Vulkan | `Vulkan0` | `all` | 4 GiB dGPU | 16K | Yes | Yes |
| `Vulkan/dgpu-igpu-i5-1135g7` | Vulkan | `Vulkan0,Vulkan1` | `all` | ~11 GiB dual | 32K | No | Yes |
| `Vulkan/apu-ryzen7-5700u` | Vulkan | `Vulkan0` | `24` | ~2–4 GiB UMA | 16K | Yes | Yes |
| `Vulkan/dgpu-generic-12gb` | Vulkan | `Vulkan0` | `all` | 12GB+ | 32K | Yes | Fallback |
| `CPU/generic` | CPU | `CPU` | `0` | none | 16K | No | Fallback |
| `CUDA/dgpu-generic` | CUDA | `CUDA0` | `all` | VRAM-dependent | 16K | Yes | **No — opt-in** |

There is no model column because no profile sets a model. The default set that
`scripts/model_dl.sh` downloads — Qwen3.5-4B-Q6_K, Qwen3-Embedding-0.6B-Q8_0 and
Qwen3.5-0.8B-Q8_0 — is the same on every profile.

## Profile Detection

```sh
./hardware-profiles/detect-hardware.sh --info    # Hardware detection report
./hardware-profiles/detect-hardware.sh --apply   # Auto-detect and deploy
./hardware-profiles/detect-hardware.sh --list    # List all profiles
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
├── jenova.conf         # Runtime configuration
└── jenova-setup        # One-time system tuning (run as root)
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

Runtime configuration sourced by `bin/jenova-ca`. **Use the unprefixed names** — `DEVICES`,
`CTX_SIZE`, `NUM_SLOTS`, `THREADS`, `THREADS_BATCH`, `NGL_AGENT`, `FIT_TARGET`,
`KV_CACHE_TYPE`. `jenova-ca` reads exactly these. Setting `JENOVA_CTX_SIZE` and friends instead
is silently ignored, and `llama-server` then launches with empty `-c`, `-np` and `-t` values.
The `JENOVA_*` names belong on the right-hand side, as environment overrides:

```sh
CTX_SIZE="${JENOVA_CTX:-16384}"
```

### `jenova-setup`

One-time system tuning: sysctls, ZFS ARC cap, hardware-specific settings. Run once as root
after deploying a profile.

---

## Manual Profile Selection

```sh
# Deploy a specific profile
./hardware-profiles/detect-hardware.sh --apply-profile Vulkan/dgpu-i5-1135g7

# Or copy manually
cp hardware-profiles/Vulkan/dgpu-i5-1135g7/jenova.conf etc/jenova.conf

# Run that profile's system tuning
sudo hardware-profiles/Vulkan/dgpu-i5-1135g7/jenova-setup

# Or force a profile through the dispatcher
sudo ./scripts/jenova-setup --profile Vulkan/dgpu-i5-1135g7
```

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
5. Add `jenova-setup` if the hardware needs system tuning.
6. Test: `./hardware-profiles/detect-hardware.sh --info`

Name profiles for the hardware, not the model — model selection is an environment override.
