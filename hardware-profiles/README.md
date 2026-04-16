# Jenova Hardware Profiles

Hardware-specific configuration profiles for Jenova Cognitive Architecture. Each profile sets the model, GPU offload strategy, context size, and thread counts for a given hardware combination. Auto-detection selects the best match at install time; profiles can also be deployed manually.

## Available Profiles

### 1. `vulkan-full-offload/` — 14B Q4_K_M, single GPU
**Model:** Qwen2.5-Coder-14B-Instruct-Q4_K_M (~8.7 GiB)
**Hardware:** Any Vulkan-capable GPU with 8GB+ VRAM
**OS:** Any (Linux, FreeBSD, Windows with Vulkan)
**Strategy:** Full single-GPU offload — all 48 layers on GPU via `-fitt` auto-fit
**Performance:** 16K context, 2 slots, 0.5B speculative drafter

Best-quality Jenova agent for systems with a capable GPU. 10+ GiB VRAM recommended for 16k context with KV cache and drafter. For strict 8 GiB GPUs, set `JENOVA_CTX=8192 JENOVA_SLOTS=1`.

**Suitable for:** NVIDIA RTX 3080/4070/4080/4090, AMD RX 6900/7900, Intel Arc A770 (16GB)

**Key settings:**
- `DEVICES: Vulkan0`
- `NGL: all` (full offload)
- `FIT_TARGET: 1024`
- `CTX: 16384`

---

### 2. `freebsd-i5-1135g7-dual-gpu/` — 3B Q8_0, dual GPU
**Model:** Qwen2.5-Coder-3B-Instruct-Q8_0 (~3.1 GiB)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe ~7GB UMA | 16GB RAM
**OS:** FreeBSD 15
**Strategy:** Full dual-GPU offload; compact model leaves large GPU headroom for wide context
**Performance:** All 36 layers on GPU, 32K context, 2 slots, 0.5B drafter

The compact 3B model at Q8_0 (~3.1 GiB) fits easily on either GPU alone. Running across both devices leaves ~8 GiB free for a 32K context window, KV cache, and the 0.5B drafter. No swap-backed filesystem required.

**Key settings:**
- `DEVICES: Vulkan0,Vulkan1`
- `NGL: all` (full offload)
- `FIT_TARGET: 512`
- `CTX: 32768`
- `DRAFT_DEVICE: Vulkan1`

---

### 3. `freebsd-i5-1135g7-dual-gpu-7b/` — 7B Q5_K_M, dual GPU + Optane swap
**Model:** Qwen2.5-Coder-7B-Instruct-Q5_K_M (~4.8 GiB)
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe ~7GB UMA | 16GB RAM | Intel Optane NVMe
**OS:** FreeBSD 15
**Strategy:** Full dual-GPU offload with speculative decoding; Optane swap-backed mdmfs for fast model loading and KV overflow
**Performance:** All 28 layers on GPU, 16K context, 2 slots, 0.5B drafter on Iris Xe

Same hardware as profile 2, running the 7B model at Q5_K_M. Intel Optane NVMe (~7 μs swap latency) provides a fast swap-backed mdmfs mount at `/mnt/jenova-models` for cold-start model loading and KV cache overflow during long sessions.

**Manual deploy only** (auto-detection selects the 3B profile for this hardware):
```bash
cp hardware-profiles/freebsd-i5-1135g7-dual-gpu-7b/jenova.conf etc/jenova.conf
sudo hardware-profiles/freebsd-i5-1135g7-dual-gpu-7b/jenova-setup
```

**Key settings:**
- `DEVICES: Vulkan0,Vulkan1`
- `NGL: all` (full offload)
- `FIT_TARGET: 512`
- `CTX: 16384`
- `DRAFT_DEVICE: Vulkan1`

---

### 4. `freebsd-ryzen7-5700u-amd/` — 3B Q8_0, AMD UMA
**Model:** Qwen2.5-Coder-3B-Instruct-Q8_0 (~3.1 GiB)
**Hardware:** AMD Ryzen 7 5700U 8C/16T | AMD Vega 8 UMA ~2-4GB | 15.28GB RAM | ZFS swap
**OS:** FreeBSD 15
**Strategy:** Partial GPU offload — 24 of 36 layers on Vega 8, remainder on CPU
**Performance:** 8K context, 2 slots, 0.5B drafter

Compact 3B model suited to limited UMA VRAM. The Zen 2 CPU handles CPU-resident layers efficiently. Increase `NGL` to 36 if BIOS allocates 4+ GiB to Vega 8. Keep context conservative to avoid swap pressure (standard NVMe at ~100 μs latency).

**AMD GPU requirements:** Install `drm-kmod` + `gpu-firmware-amd-kmod`; add `amdgpu` to `kld_list`.

**Key settings:**
- `DEVICES: Vulkan0` (AMD RADV)
- `NGL: 24` (partial offload)
- `FIT_TARGET: 256`
- `CTX: 8192`
- `THREADS: 8` (Zen 2 8C/16T)

---

## Profile Summary

| Profile | Model | Quant | GPU Memory | Context |
|---|---|---|---|---|
| `vulkan-full-offload` | Qwen2.5-Coder-14B-Instruct | Q4_K_M | 8+ GiB (10+ GiB recommended) | 16K |
| `freebsd-i5-1135g7-dual-gpu` | Qwen2.5-Coder-3B-Instruct | Q8_0 | ~11 GiB dual GPU | 32K |
| `freebsd-i5-1135g7-dual-gpu-7b` | Qwen2.5-Coder-7B-Instruct | Q5_K_M | ~11 GiB dual GPU | 16K |
| `freebsd-ryzen7-5700u-amd` | Qwen2.5-Coder-3B-Instruct | Q8_0 | ~2-4 GiB UMA (partial) | 8K |

All profiles use the 0.5B Qwen2.5-Coder drafter for speculative decoding (disable with `JENOVA_DRAFT=0` if needed). The embedding server always runs on CPU using `nomic-embed-text-v1.5.Q8_0.gguf`.

---

## Profile Detection

Jenova automatically detects hardware and selects the best-matching profile at install time:

```bash
# View hardware detection report
./hardware-profiles/detect-hardware.sh --info

# Auto-detect and deploy the matching profile
./hardware-profiles/detect-hardware.sh --apply

# List all available profiles
./hardware-profiles/detect-hardware.sh --list
```

### Detection Scoring

Profiles are scored on hardware matches:
- **CPU match:** +10 points (required for specific profiles)
- **GPU match:** +5 points per device
- **OS match:** +3 points

The highest-scoring profile is selected. Generic profiles (like `vulkan-full-offload`) have lower scores and serve as fallbacks.

---

## Profile Structure

Each profile directory contains:

```
profile-name/
├── profile.conf        # Detection rules (MATCH_CPU, MATCH_GPU_0, MATCH_GPU_1, MATCH_OS)
├── jenova.conf         # Runtime configuration (DEVICES, NGL, CTX, model, etc.)
├── install.sh          # Profile-specific installer (optional)
└── jenova-setup        # One-time system tuning script (run as root, optional)
```

### `profile.conf`
Hardware detection patterns and metadata:
```sh
PROFILE_NAME="my-profile"
PROFILE_DESC="Hardware description"
MATCH_CPU="i5-1135G7"        # CPU model substring (case-insensitive)
MATCH_GPU_0="NVIDIA"         # Primary GPU pattern (regex)
MATCH_GPU_1="Intel.*Iris"    # Secondary GPU pattern (regex, optional)
MATCH_OS="FreeBSD"           # OS name (optional)
```

### `jenova.conf`
Runtime configuration sourced by `jenova-ca`. Contains:
- Model paths (auto-detected from `models/agent/`, `models/embed/`, `models/draft/`)
- Hardware settings (`DEVICES`, `NGL_7B`, `CTX_SIZE`, `FIT_TARGET`, etc.)
- Network configuration (`HOST`, ports)
- Thread settings (`THREADS`, `THREADS_BATCH`)

### `jenova-setup`
One-time system tuning script. Configures kernel parameters, ZFS ARC cap, and hardware-specific settings. Run once as root after deploying a profile.

---

## Manual Profile Selection

```bash
# Deploy a specific profile
cp hardware-profiles/vulkan-full-offload/jenova.conf etc/jenova.conf

# Or use the profile's setup script
./hardware-profiles/vulkan-full-offload/jenova-setup

# Or run the profile installer
./hardware-profiles/vulkan-full-offload/install.sh
```

---

## Environment Overrides

All profiles respect environment variable overrides:
```bash
# Override model
export JENOVA_MODEL=/path/to/my-model.gguf
export JENOVA_EMBED_MODEL=/path/to/my-embed.gguf
export JENOVA_DRAFT_MODEL=/path/to/my-draft.gguf

# Override hardware settings
export JENOVA_DEVICES="Vulkan0"
export JENOVA_NGL_7B=24
export JENOVA_CTX=8192
export JENOVA_SLOTS=1

# Override network
export JENOVA_HOST=0.0.0.0  # Listen on all interfaces (LAN mode)
export JENOVA_PORT=8080
```

---

## Creating a New Profile

1. Create a profile directory under `hardware-profiles/`
2. Add `profile.conf` with detection patterns and metadata
3. Add `jenova.conf` by copying an existing profile and adjusting `DEVICES`, `NGL_7B`, `CTX_SIZE`, and model comments
4. Test auto-detection: `./hardware-profiles/detect-hardware.sh --info`
5. Validate: `jenova-ca start && jenova-ca status`

Profile names should describe the hardware (e.g., `linux-rtx4090-fulloffload`), not the model — model selection can always be overridden via environment variables.

---

## Troubleshooting

- **No matching profile:** Use `detect-hardware.sh --info` to see scores; fall back to `vulkan-full-offload`.
- **Jenova fails to start:** Check `var/log/jenova-ca.log` and `var/log/llama-*.log`. Verify Vulkan drivers (`vulkaninfo --summary`) and that models exist in `models/agent/`, `models/embed/`, `models/draft/`.
- **GPU OOM:** Reduce `JENOVA_CTX`, `JENOVA_SLOTS`, or disable the drafter (`JENOVA_DRAFT=0`). Consider a lower-quant model.
- **Wrong profile selected:** Deploy manually: `cp hardware-profiles/PROFILE/jenova.conf etc/jenova.conf`
