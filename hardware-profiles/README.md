# Jenova Hardware Profiles

Hardware-specific configuration profiles for Jenova Cognitive Architecture. Each profile sets the model, GPU offload strategy, context size, and thread counts for a given hardware combination. Auto-detection selects the best match at install time; profiles can also be deployed manually.

## Directory Structure

Profiles are organised into a three-level hierarchy:

```
hardware-profiles/
├── Intel/                         # Intel CPU systems
│   ├── dgpu_igpu/                 # Discrete + integrated GPU
│   │   └── i5-1135g7-3b/         # 3B Q8_0, GTX 1650 Ti + Iris Xe
│   ├── dgpu/                      # Discrete GPU only
│   └── apu/                       # Integrated GPU only
├── AMD/                           # AMD CPU systems
│   ├── dgpu_igpu/
│   ├── dgpu/
│   └── apu/
│       └── ryzen7-5700u-3b/       # 3B Q8_0, Vega 8 partial offload
├── Vulkan/                        # Generic / vendor-agnostic
│   ├── dgpu_igpu/
│   ├── dgpu/
│   │   └── full-offload-14b/      # 14B Q4_K_M, any 8GB+ GPU
│   └── apu/
├── Optane/                        # Intel Optane NVMe swap-backed
│   ├── dgpu_igpu/
│   │   └── i5-1135g7-7b/         # 7B, dual GPU + Optane swap
│   ├── dgpu/
│   │   ├── i5-1135g7-3b/         # 3B Q8_0, GTX 1650 Ti only + Optane
│   │   └── i5-1135g7-7b/         # 7B Q5_K_M, partial offload + Optane
│   └── apu/
├── detect-hardware.sh
└── README.md
```

**Categories:** `Intel`, `AMD`, `Vulkan` (generic), `Optane` (swap-backed)
**GPU types:** `dgpu_igpu` (discrete + integrated), `dgpu` (discrete only), `apu` (integrated only)

---

## Available Profiles

### 1. `Intel/dgpu_igpu/i5-1135g7-3b` — 3B Q8_0, dual GPU
**Model:** Qwen2.5-Coder-3B-Instruct-Q8_0 (~3.1 GiB)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe ~7GB UMA | 16GB RAM
**OS:** FreeBSD 15
**Strategy:** Full dual-GPU offload; compact model leaves large GPU headroom for wide context

The 3B model at Q8_0 fits easily on either GPU alone. Running across both devices leaves ~8 GiB free for a 32K context window, KV cache, and the 0.5B drafter. No swap-backed filesystem required.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0,Vulkan1` |
| `NGL` | `all` (full offload) |
| `FIT_TARGET` | `512` |
| `CTX` | `32768` |
| `DRAFT_DEVICE` | `Vulkan1` |

---

### 2. `AMD/apu/ryzen7-5700u-3b` — 3B Q8_0, AMD UMA
**Model:** Qwen2.5-Coder-3B-Instruct-Q8_0 (~3.1 GiB)
**Hardware:** AMD Ryzen 7 5700U 8C/16T | AMD Vega 8 UMA ~2-4GB | 15.28GB RAM
**OS:** FreeBSD 15
**Strategy:** Partial GPU offload — 24 of 36 layers on Vega 8, remainder on CPU

**AMD GPU requirements:** Install `drm-kmod` + `gpu-firmware-amd-kmod`; add `amdgpu` to `kld_list`.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` (AMD RADV) |
| `NGL` | `24` (partial offload) |
| `FIT_TARGET` | `256` |
| `CTX` | `16384` |
| `THREADS` | `8` (Zen 2 8C/16T) |

---

### 3. `Vulkan/dgpu/full-offload-14b` — 14B Q4_K_M, single GPU
**Model:** Qwen2.5-Coder-14B-Instruct-Q4_K_M (~8.7 GiB)
**Hardware:** Any Vulkan-capable GPU with 8GB+ VRAM
**OS:** Any (Linux, FreeBSD, Windows with Vulkan)
**Strategy:** Full single-GPU offload — all 48 layers on GPU

Best-quality Jenova agent for systems with a capable GPU. 10+ GiB VRAM recommended. For strict 8 GiB GPUs, set `JENOVA_CTX=8192 JENOVA_SLOTS=1`.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL` | `all` (full offload) |
| `FIT_TARGET` | `1024` |
| `CTX` | `32768` |

---

### 4. `Optane/dgpu_igpu/i5-1135g7-7b` — 7B, dual GPU + Optane swap
**Model:** 7B Jenova agent model (resolved from `models/agent`)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe ~7GB UMA | 16GB RAM | Intel Optane NVMe
**OS:** FreeBSD 15
**Strategy:** Full dual-GPU offload with speculative decoding; Optane swap-backed mdmfs for fast model loading and KV overflow

**Manual deploy only** (auto-detection selects the 3B profile for this hardware):
```bash
cp hardware-profiles/Optane/dgpu_igpu/i5-1135g7-7b/jenova.conf etc/jenova.conf
sudo hardware-profiles/Optane/dgpu_igpu/i5-1135g7-7b/jenova-setup
```

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0,Vulkan1` |
| `NGL` | `all` (full offload) |
| `FIT_TARGET` | `512` |
| `CTX` | `32768` |
| `DRAFT_DEVICE` | `Vulkan1` |

---

### 5. `Optane/dgpu/i5-1135g7-3b` — 3B Q8_0, dGPU only + Optane swap
**Model:** Qwen2.5-Coder-3B-Instruct-Q8_0 (~3.1 GiB)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB (sole GPU, iGPU excluded) | 16GB RAM | Intel Optane NVMe
**OS:** FreeBSD 15
**Strategy:** Full offload to single dGPU with speculative decoding. iGPU deliberately excluded to avoid UMA contention with system RAM. Optane swap catches KV overflow at ~7 μs latency.

Tight fit: ~3.1 GiB model + ~644 MiB drafter + ~256 MiB KV = ~4.0 GiB in 4 GiB VRAM. Context reduced to 16K (vs 32K on dual-GPU) to stay within budget.

```bash
cp hardware-profiles/Optane/dgpu/i5-1135g7-3b/jenova.conf etc/jenova.conf
sudo hardware-profiles/Optane/dgpu/i5-1135g7-3b/jenova-setup
```

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL` | `all` (full offload) |
| `FIT_TARGET` | `128` |
| `CTX` | `16384` |
| `DRAFT_DEVICE` | `Vulkan0` (shared) |
| `DRAFT` | `1` (enabled) |

---

### 6. `Optane/dgpu/i5-1135g7-7b` — 7B Q5_K_M, dGPU only + Optane swap (partial offload)
**Model:** Qwen2.5-Coder-7B-Instruct-Q5_K_M (~4.8 GiB)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB (sole GPU, iGPU excluded) | 16GB RAM | Intel Optane NVMe
**OS:** FreeBSD 15
**Strategy:** Partial GPU offload — ~16 of 28 layers on GPU, rest on CPU. No drafter (no VRAM budget). Higher model quality than 3B but significantly slower due to CPU layers and no speculative decoding.

The 7B model exceeds 4 GiB VRAM, requiring partial offload. CPU handles ~12 layers; Optane NVMe swap (~7 μs) keeps CPU-resident layer access fast. Single slot, 8K context to minimize KV footprint.

```bash
cp hardware-profiles/Optane/dgpu/i5-1135g7-7b/jenova.conf etc/jenova.conf
sudo hardware-profiles/Optane/dgpu/i5-1135g7-7b/jenova-setup
```

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL` | `16` (partial offload) |
| `FIT_TARGET` | `256` |
| `CTX` | `8192` |
| `SLOTS` | `1` |
| `DRAFT` | `0` (disabled) |

---

## Profile Summary

| Profile | Model | Quant | GPU Memory | Context | Drafter |
|---|---|---|---|---|---|
| `Intel/dgpu_igpu/i5-1135g7-3b` | Qwen2.5-Coder-3B | Q8_0 | ~11 GiB dual GPU | 32K | Yes (Vulkan1) |
| `AMD/apu/ryzen7-5700u-3b` | Qwen2.5-Coder-3B | Q8_0 | ~2-4 GiB UMA (partial) | 16K | Yes |
| `Vulkan/dgpu/full-offload-14b` | Qwen2.5-Coder-14B | Q4_K_M | 8+ GiB (10+ rec.) | 32K | Yes |
| `Optane/dgpu_igpu/i5-1135g7-7b` | Qwen2.5-Coder-7B | auto | ~11 GiB dual GPU | 32K | Yes (Vulkan1) |
| `Optane/dgpu/i5-1135g7-3b` | Qwen2.5-Coder-3B | Q8_0 | 4 GiB dGPU only | 16K | Yes (shared) |
| `Optane/dgpu/i5-1135g7-7b` | Qwen2.5-Coder-7B | Q5_K_M | 4 GiB dGPU (partial) | 8K | No |

All profiles (except `Optane/dgpu/i5-1135g7-7b`) use the 0.5B Qwen2.5-Coder drafter for speculative decoding. The embedding server always runs on CPU using `nomic-embed-text-v1.5.Q8_0.gguf`.

---

## Profile Detection

Jenova automatically detects hardware and selects the best-matching profile at install time:

```bash
./hardware-profiles/detect-hardware.sh --info      # Hardware detection report
./hardware-profiles/detect-hardware.sh --apply      # Auto-detect and deploy
./hardware-profiles/detect-hardware.sh --list       # List all profiles
```

### Detection Scoring

Profiles are scored on hardware matches:
- **CPU match:** +10 points (required for specific profiles)
- **GPU match:** +5 points per device
- **OS match:** +3 points

The highest-scoring profile is selected. Generic profiles (like `Vulkan/dgpu/full-offload-14b`) have lower scores and serve as fallbacks. Multi-GPU profiles (`MATCH_GPU_1`) score higher than single-GPU variants.

---

## Profile Structure

Each profile directory contains:

```
Category/gpu_type/profile-name/
├── profile.conf        # Detection rules (MATCH_CPU, MATCH_GPU_0, MATCH_GPU_1, MATCH_OS)
├── jenova.conf         # Runtime configuration (DEVICES, NGL, CTX, model, etc.)
├── install.sh          # Profile-specific installer
└── jenova-setup        # One-time system tuning script (run as root)
```

### `profile.conf`
Hardware detection patterns and metadata:
```sh
PROFILE_NAME="Category/gpu_type/profile-name"
PROFILE_DESC="Hardware description"
MATCH_CPU="i5-1135G7"        # CPU model substring (case-insensitive)
MATCH_GPU_0="NVIDIA"         # Primary GPU pattern (regex)
MATCH_GPU_1="Intel.*Iris"    # Secondary GPU pattern (regex, optional)
MATCH_OS="FreeBSD"           # OS name (optional)
```

### `jenova.conf`
Runtime configuration sourced by `jenova-ca`. Contains model paths (auto-detected), hardware settings, network configuration, and thread settings.

### `jenova-setup`
One-time system tuning script. Configures kernel parameters, ZFS ARC cap, and hardware-specific settings. Run once as root after deploying a profile.

---

## Manual Profile Selection

```bash
# Deploy a specific profile
cp hardware-profiles/Optane/dgpu/i5-1135g7-3b/jenova.conf etc/jenova.conf

# Run the profile's system tuning
sudo hardware-profiles/Optane/dgpu/i5-1135g7-3b/jenova-setup

# Or run the full profile installer
./hardware-profiles/Optane/dgpu/i5-1135g7-3b/install.sh

# Force a profile via jenova-setup dispatcher
sudo ./jenova-setup --profile Optane/dgpu/i5-1135g7-3b
```

---

## Environment Overrides

All profiles respect environment variable overrides:
```bash
export JENOVA_MODEL=/path/to/my-model.gguf
export JENOVA_DEVICES="Vulkan0"
export JENOVA_NGL_7B=24
export JENOVA_CTX=8192
export JENOVA_SLOTS=1
export JENOVA_DRAFT=0
export JENOVA_HOST=0.0.0.0    # LAN mode
```

---

## Creating a New Profile

1. Choose the appropriate category and GPU type directory
2. Create a profile directory: `hardware-profiles/<Category>/<gpu_type>/<name>/`
3. Add `profile.conf` with detection patterns and metadata
4. Add `jenova.conf` by copying an existing profile and adjusting settings
5. Add `install.sh` and `jenova-setup` as needed
6. Test: `./hardware-profiles/detect-hardware.sh --info`

Profile names should describe the hardware, not the model — model selection can be overridden via environment variables.
