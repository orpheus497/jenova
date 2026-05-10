# Jenova Hardware Profiles

Hardware-specific configuration profiles for Jenova Cognitive Architecture. Each profile sets the model, GPU offload strategy, context size, and thread counts for a given hardware combination. Auto-detection selects the best match at install time; profiles can also be deployed manually.

For more details on hardware optimization and detection scoring, see **[docs/hardware/profiles.md](../docs/hardware/profiles.md)**.

## Directory Structure

Profiles are organised by operating system, then by hardware configuration:

```
hardware-profiles/
├── FreeBSD/                         # FreeBSD-specific profiles
│   ├── dgpu/                        # Discrete GPU only
│   │   ├── i5-1135g7-3b/            # 3B Q8_0, GTX 1650 Ti only
│   │   └── i5-1135g7-7b/            # 9B Q4_K_M, partial offload + Optane
│   ├── dgpu_igpu/                   # Discrete + integrated GPU
│   │   └── i5-1135g7-3b/            # 3B Q8_0, GTX 1650 Ti + Iris Xe
│   └── dgpu_igpu/                   # Discrete + integrated GPU (Optane)
│       └── i5-1135g7-7b/            # 7B, dual GPU + Optane swap
├── Linux/                           # Linux-specific profiles
│   ├── AMD/                         # AMD CPU systems
│   │   └── apu/
│   │       └── ryzen7-5700u-3b/     # 3B Q8_0, Vega 8 partial offload
│   ├── CPU/                         # CPU-only systems
│   │   └── generic/                 # Qwen2.5-3B Q8, Ryzen optimization
│   ├── CUDA/                        # NVIDIA CUDA systems
│   │   └── dgpu/
│   │       └── nvidia-generic/      # CUDA acceleration
│   └── Vulkan/                      # Generic Vulkan systems
│       ├── dgpu/
│       │   ├── full-offload-14b/    # 9B Q8, 12GB+ VRAM
│       │   └── gtx-1650ti/          # 4B Q8_0, GTX 1650 Ti
│       └── apu/
├── macOS/                           # macOS-specific profiles
│   ├── CPU/                         # CPU-only systems
│   │   └── generic/                 # Qwen3.5-0.8B Q8, Neural Engine
│   └── Metal/                       # Apple Silicon GPU
│       └── generic/                 # Qwen2.5-3B Q8_K_M, Metal
└── detect-hardware.sh
```

**Note:** Model names in the configuration files act as intelligent defaults and aren't hard-coded. If users wish to change models from what the downloader provides, they can easily override them via environment variables (e.g., `JENOVA_MODEL`).

## Dual-GPU Strategy: The Laptop Advantage

Many modern consumer laptops, particularly those with both an integrated GPU (iGPU) and a discrete GPU (dGPU), can leverage both simultaneously for inference. Jenova's dual-GPU profiles are designed specifically for this common hardware configuration.

**The primary advantage of a dual-GPU setup is the ability to run larger models or use a significantly larger context size** than would be possible with a single, lower-VRAM discrete GPU. By splitting the model layers across both the iGPU and dGPU, the total available VRAM is effectively pooled.

However, there are trade-offs:
*   **Speed**: Inference speed may be slightly lower compared to running a smaller model on a single, more powerful GPU due to the overhead of coordinating between two devices.
*   **Thermals and Battery**: On some laptops, using a dual-GPU configuration can result in lower overall thermal load and reduced battery drain compared to maxing out a single dGPU. This is because the workload is distributed, potentially keeping both GPUs out of their highest power states. *This is not a guarantee and depends on many variables, but has been a consistent observation on our test machines.*

These profiles are optimized for the balance of performance and resource availability found in consumer and prosumer laptops, not necessarily high-end gaming rigs with single, high-VRAM GPUs.


## Available Profiles

### FreeBSD Profiles

#### 1. `FreeBSD/Optane/dgpu/i5-1135g7-9b` — 9B Q4_K_M, dGPU only + Optane swap
**Model:** Qwen3.5-9B-Instruct-Q4_K_M (~5.5 GiB)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB (sole GPU) | 16GB RAM | Intel Optane NVMe
**OS:** FreeBSD 15
**Strategy:** Partial offload to single dGPU. High-speed Optane NVMe swap handles the remainder of the context and layers.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL` | `16` (partial offload) |
| `CTX` | `8192` |
| `DRAFT` | `0` |

#### 2. `FreeBSD/Optane/dgpu_igpu/i5-1135g7-9b` — 9B Q4_K_M, dual GPU + Optane swap
**Model:** Qwen3.5-9B-Instruct-Q4_K_M (~5.5 GiB)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe ~7GB UMA | 16GB RAM | Intel Optane NVMe
**OS:** FreeBSD 15
**Strategy:** Dual GPU partial offload. Intel Optane NVMe provides high-bandwidth swap for CPU-bound layers.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0,Vulkan1` |
| `NGL` | `24` (partial offload) |
| `CTX` | `8192` |
| `DRAFT` | `0` |

### Linux Profiles

#### 3. `Linux/CPU/generic` — CPU-only, multi-core optimization
**Model:** Qwen2.5-3B-Instruct-Q8 (~3.1 GiB)
**Hardware:** Multi-core CPU (Ryzen, Intel) | No GPU
**OS:** Linux
**Strategy:** CPU-only inference with optimized threading for modern multi-core processors.

| Setting | Value |
|---|---|
| `DEVICES` | `CPU` |
| `NGL` | `0` |
| `CTX` | `16384` |
| `DRAFT` | `0` |

#### 4. `Linux/AMD/apu/ryzen7-5700u-3b` — 3B Q8, AMD UMA
**Model:** Qwen2.5-3B-Instruct-Q8 (~3.1 GiB)
**Hardware:** AMD Ryzen 7 5700U 8C/16T | AMD Vega 8 UMA ~2-4GB | 15.28GB RAM
**OS:** Linux
**Strategy:** Partial GPU offload — 24 of 36 layers on Vega 8, remainder on CPU

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` (AMD RADV) |
| `NGL` | `24` (partial offload) |
| `CTX` | `16384` |
| `DRAFT` | `1` |

#### 5. `Linux/Vulkan/dgpu/full-offload-12gb` — 9B Q8, 12GB+ VRAM
**Model:** Qwen3.5-9B-Instruct-Q8 (~9.5 GiB)
**Hardware:** Any Vulkan-capable GPU with 12GB+ VRAM
**OS:** Linux
**Strategy:** Full single-GPU offload — all layers fit in VRAM.

| Setting | Value |
|---|---|
| `DEVICES` | `Vulkan0` |
| `NGL` | `all` (full offload) |
| `CTX` | `32768` |
| `DRAFT` | `1` |

#### 6. `Linux/CUDA/dgpu/nvidia-generic` — CUDA acceleration
**Model:** Qwen2.5-3B-Instruct-Q8 (default)
**Hardware:** NVIDIA CUDA-capable GPU
**OS:** Linux
**Strategy:** Hardware-accelerated inference utilizing CUDA cores.

| Setting | Value |
|---|---|
| `DEVICES` | `CUDA0` |
| `NGL` | `all` |
| `CTX` | `16384` |
| `DRAFT` | `1` |

### macOS Profiles

#### 7. `macOS/Metal/generic` — 2.5B Q8_K_M, Apple Silicon Metal
**Model:** Qwen2.5-3B-Instruct-Q8_K_M (~3.2 GiB)
**Hardware:** Apple Silicon (M1/M2/M3/M4) | Integrated GPU
**OS:** macOS
**Strategy:** Full Metal GPU offload using unified memory

| Setting | Value |
|---|---|
| `DEVICES` | `Metal0` |
| `NGL` | `all` (full offload) |
| `CTX` | `16384` |
| `DRAFT` | `1` |

#### 8. `macOS/CPU/generic` — 0.8B Q8, Apple Silicon CPU (half spec)
**Model:** Qwen3.5-0.8B-Instruct-Q8 (~0.8 GiB)
**Hardware:** Apple Silicon (M1/M2/M3/M4) | CPU-only
**OS:** macOS
**Strategy:** CPU-only inference. Context size and thread scaling are set to exactly half the footprint of the standard Ryzen configurations to maintain extreme power efficiency on battery.

| Setting | Value |
|---|---|
| `DEVICES` | `CPU` |
| `NGL` | `0` |
| `CTX` | `8192` |
| `DRAFT` | `0` |

---

## Profile Summary

| Profile | OS | Model | Quant | GPU Memory | Context | Drafter |
|---|---|---|---|---|---|---|
| `FreeBSD/Optane/dgpu_igpu/i5-1135g7-9b` | FreeBSD | Qwen3.5-9B | Q4_K_M | ~11 GiB dual | 8K | No |
| `FreeBSD/Optane/dgpu/i5-1135g7-9b` | FreeBSD | Qwen3.5-9B | Q4_K_M | 4 GiB dGPU | 8K | No |
| `Linux/CPU/generic` | Linux | Qwen2.5-3B | Q8 | CPU-only | 16K | No |
| `Linux/AMD/apu/ryzen7-5700u-3b` | Linux | Qwen2.5-3B | Q8 | ~2-4 GiB UMA | 16K | Yes |
| `Linux/Vulkan/dgpu/full-offload-12gb` | Linux | Qwen3.5-9B | Q8 | 12GB+ | 32K | Yes |
| `Linux/CUDA/dgpu/nvidia-generic` | Linux | Qwen2.5-3B | Q8 | VRAM-dependent | 16K | Yes |
| `macOS/Metal/generic` | macOS | Qwen2.5-3B | Q8_K_M | Unified | 16K | Yes |
| `macOS/CPU/generic` | macOS | Qwen3.5-0.8B | Q8 | CPU-only | 8K | No |


## Profile Detection

Jenova automatically detects hardware and selects the best-matching profile at install time:

```bash
./hardware-profiles/detect-hardware.sh --info    # Hardware detection report
./hardware-profiles/detect-hardware.sh --apply   # Auto-detect and deploy
./hardware-profiles/detect-hardware.sh --list    # List all profiles
```

### Detection Scoring

Profiles are scored on hardware matches:
- **OS match:** +20 points (required for OS-specific profiles)
- **CPU match:** +10 points (required for specific CPU profiles)
- **GPU match:** +5 points per matching device
- **Generic profiles** get lower priority (-5 points)

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
export JENOVA_NGL_AGENT=24
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
