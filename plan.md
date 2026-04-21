# Jenova — Hardware Detection & Portable Installation Plan

**Branch:** `dev/cli`
**Date:** 2026-03-30
**Status:** Implemented (Phases 1–3 complete; Phase 4 partial; Phases 5–7 ongoing)

---

## Goal

Create a hardware detection script (`detect-hardware.sh`) that probes the host machine and generates a platform-appropriate configuration, build strategy, and dependency list. This enables Jenova to run portably across different Linux distributions, FreeBSD, and varied GPU hardware — without manual tuning of `etc/jenova.conf` or `install.sh` flags.

---

## Problem Statement

Today, Jenova is hardcoded for a single machine:

| Item | Current Hardcoded Value | What Varies |
|---|---|---|
| GPU devices | `Vulkan0,Vulkan1` (GTX 1650 Ti + Intel Iris Xe) | NVIDIA CUDA, AMD ROCm, Intel oneAPI, Apple Metal, CPU-only, single GPU, multi-GPU |
| Tensor split | `1.0,1.8` (4 GiB NVIDIA : 7 GiB Intel UMA) | Depends on VRAM per device |
| GPU layers | `all` (28 layers fit dual-GPU ~11 GiB) | Depends on total VRAM vs model size |
| Threads | `4` / `6` (i5-1135G7, 4P cores) | Depends on physical/logical core count |
| Context size | `16384` (fits with Optane swap) | Depends on RAM + VRAM budget |
| Slots | `2` | Depends on available memory |
| KV cache type | `q8_0` | `q8_0` for constrained, `f16` for high-VRAM |
| Build flags | `-DGGML_VULKAN=ON` | CUDA, HIP, Metal, SYCL, or CPU-only |
| Package manager | `pkg install` (FreeBSD) | `apt`, `dnf`, `pacman`, `apk`, `brew` |
| FFI constants | FreeBSD `errno` values (EAGAIN=35) | Linux uses EAGAIN=11, different FIONBIO |
| Model selection | 7B Q5_K_M (needs ~5 GiB + KV) | Smaller models for low-RAM/no-GPU machines |
| Speculative decoding | Enabled (draft model) | Disable on CPU-only or low-memory |
| Fit target | `768` MiB | Depends on actual VRAM headroom |

---

## Architecture

```
detect-hardware.sh
        │
        ├── Probe: OS & distro
        ├── Probe: CPU (cores, arch, features)
        ├── Probe: RAM (total, available)
        ├── Probe: GPU (vendor, VRAM, driver, count)
        ├── Probe: Swap (size, type)
        ├── Probe: Package manager
        │
        ▼
  Hardware Profile (JSON or shell vars)
        │
        ├──► etc/jenova.conf.generated   (runtime config)
        ├──► build-llama.sh              (cmake flags for this hardware)
        └──► deps.txt / install hint     (platform-specific packages)
```

The detection script does **not** replace `install.sh` — it generates inputs that `install.sh` consumes. The existing env-var overrides (`JENOVA_DEVICES`, `JENOVA_TS`, etc.) remain as manual escape hatches.

---

## Phase 1: Hardware Detection Script (`detect-hardware.sh`)

### 1.1 OS & Distribution Detection

```
Detect:
  - uname -s              → FreeBSD | Linux | Darwin
  - /etc/os-release       → PRETTY_NAME, ID (ubuntu, debian, fedora, arch, alpine)
  - FreeBSD: uname -r     → version
  - macOS: sw_vers         → version

Output:
  OS=linux
  DISTRO=ubuntu
  DISTRO_VERSION=24.04
  PKG_MANAGER=apt
```

**Package Manager Mapping:**

| Distro ID | Package Manager | Install Syntax |
|---|---|---|
| `freebsd` | `pkg` | `pkg install <pkg>` |
| `ubuntu`, `debian` | `apt` | `apt install -y <pkg>` |
| `fedora`, `rhel`, `centos` | `dnf` | `dnf install -y <pkg>` |
| `arch`, `manjaro` | `pacman` | `pacman -S --noconfirm <pkg>` |
| `alpine` | `apk` | `apk add <pkg>` |
| `opensuse*` | `zypper` | `zypper install -y <pkg>` |
| `darwin` | `brew` | `brew install <pkg>` |

### 1.2 CPU Detection

```
Detect:
  - Physical cores:   nproc / sysctl hw.ncpu / sysctl -n hw.physicalcpu
  - Logical cores:    nproc / lscpu
  - Architecture:     uname -m (x86_64, aarch64, arm64)
  - CPU model:        /proc/cpuinfo or sysctl hw.model
  - AVX/AVX2/AVX512:  lscpu flags or /proc/cpuinfo (affects llama.cpp CPU perf)

Output:
  CPU_ARCH=x86_64
  CPU_CORES_PHYSICAL=4
  CPU_CORES_LOGICAL=8
  CPU_MODEL="Intel i5-1135G7"
  CPU_HAS_AVX2=1
  CPU_HAS_AVX512=0
```

**Thread Heuristic:**
- `THREADS` = physical cores (avoid hyperthreading contention for inference)
- `THREADS_BATCH` = physical cores × 1.5, capped at logical cores

### 1.3 Memory Detection

```
Detect:
  - Total RAM:     /proc/meminfo (Linux) / sysctl hw.physmem (FreeBSD) / sysctl hw.memsize (macOS)
  - Available RAM:  MemAvailable from /proc/meminfo / vm_stat (macOS)
  - Swap size:      /proc/swaps or swapon --show (Linux) / swapinfo (FreeBSD)
  - Swap type hint: Check if swap device is on NVMe (rotational=0 in /sys/block)

Output:
  RAM_TOTAL_GB=16
  RAM_AVAILABLE_GB=12
  SWAP_TOTAL_GB=27
  SWAP_IS_FAST=1   (NVMe/Optane vs spinning disk)
```

### 1.4 GPU Detection

This is the most critical and complex probe.

```
Detection Priority:
  1. nvidia-smi           → NVIDIA GPU (CUDA/Vulkan)
  2. rocm-smi / rocminfo  → AMD GPU (ROCm/HIP)
  3. vulkaninfo            → Any Vulkan-capable GPU (fallback enumeration)
  4. lspci / lshw          → PCI device identification
  5. system_profiler       → macOS (Apple Silicon / Metal)
  6. None found            → CPU-only profile

Output per GPU:
  GPU_COUNT=2
  GPU_0_VENDOR=nvidia
  GPU_0_MODEL="GTX 1650 Ti"
  GPU_0_VRAM_MB=4096
  GPU_0_DRIVER=vulkan
  GPU_1_VENDOR=intel
  GPU_1_MODEL="Iris Xe"
  GPU_1_VRAM_MB=7168
  GPU_1_DRIVER=vulkan
  GPU_TOTAL_VRAM_MB=11264
  GPU_BACKEND=vulkan          (vulkan | cuda | hip | metal | cpu)
```

**GPU Backend Decision Tree:**

```
if NVIDIA GPU detected:
    if nvidia-smi works AND CUDA toolkit available:
        GPU_BACKEND=cuda       (best NVIDIA perf)
    else:
        GPU_BACKEND=vulkan     (universal fallback)

elif AMD GPU detected:
    if rocm-smi works:
        GPU_BACKEND=hip        (best AMD perf)
    else:
        GPU_BACKEND=vulkan     (fallback)

elif Apple Silicon:
    GPU_BACKEND=metal

elif Intel GPU only:
    if oneAPI/SYCL available:
        GPU_BACKEND=sycl
    elif vulkaninfo shows Intel device:
        GPU_BACKEND=vulkan
    else:
        GPU_BACKEND=cpu

else:
    GPU_BACKEND=cpu
```

### 1.5 Dependency Resolution

Based on detected OS/distro, output the correct package names:

```
Dependencies map (per distro):

luajit:
  freebsd  → luajit-openresty
  ubuntu   → luajit
  fedora   → luajit
  arch     → luajit
  alpine   → lua-jit
  brew     → luajit

cmake:
  freebsd  → cmake
  ubuntu   → cmake
  fedora   → cmake
  arch     → cmake
  alpine   → cmake
  brew     → cmake

curl:
  freebsd  → (not needed, has fetch)
  ubuntu   → curl
  fedora   → curl
  arch     → curl
  alpine   → curl
  brew     → curl  (usually preinstalled)

neovim:
  freebsd  → neovim
  ubuntu   → neovim  (or AppImage/snap for newer versions)
  fedora   → neovim
  arch     → neovim
  alpine   → neovim
  brew     → neovim

GPU-specific:
  vulkan (ubuntu)  → libvulkan-dev vulkan-tools mesa-vulkan-drivers
  vulkan (fedora)  → vulkan-loader-devel vulkan-tools mesa-vulkan-drivers
  cuda (ubuntu)    → nvidia-cuda-toolkit
  cuda (fedora)    → cuda
  rocm (ubuntu)    → rocm-dev
  rocm (fedora)    → rocm-dev
```

---

## Phase 2: Configuration Generation

### 2.1 Generate `etc/jenova.conf.detected`

The detection script outputs a config file that `jenova.conf` can source:

```sh
# Auto-generated by detect-hardware.sh — do not edit manually
# Re-run detect-hardware.sh to regenerate

# --- GPU ---
JENOVA_DEVICES="Vulkan0"
JENOVA_TS=""
JENOVA_FITT="512"
JENOVA_NGL_7B="all"

# --- CPU ---
JENOVA_THREADS="6"
JENOVA_THREADS_BATCH="9"

# --- Memory ---
JENOVA_CTX="8192"
JENOVA_SLOTS="1"
JENOVA_KV_TYPE="q8_0"

# --- Model recommendation ---
# VRAM: 8192 MB, RAM: 32 GB
# Recommended: 7B Q5_K_M (fits in GPU)
# Speculative decoding: enabled (sufficient VRAM headroom)
JENOVA_DRAFT="1"
```

### 2.2 Generate Build Flags

Output a `build-profile.sh` that `install.sh` sources:

```sh
# Auto-generated by detect-hardware.sh
LLAMA_CMAKE_FLAGS="-DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release"
LLAMA_BUILD_JOBS=8
```

### 2.3 Model Recommendation Matrix

| Total VRAM | RAM | Recommended Model | Context | Slots | Draft |
|---|---|---|---|---|---|
| ≥ 10 GiB | ≥ 16 GB | 7B Q5_K_M | 16384 | 2 | Yes |
| 6–10 GiB | ≥ 16 GB | 7B Q4_K_M | 8192 | 2 | Yes |
| 4–6 GiB | ≥ 16 GB | 7B Q4_K_M | 8192 | 1 | No |
| 2–4 GiB | ≥ 8 GB | 3B Q5_K_M | 4096 | 1 | No |
| 0 (CPU) | ≥ 32 GB | 7B Q4_K_M | 8192 | 1 | No |
| 0 (CPU) | 16 GB | 3B Q5_K_M | 4096 | 1 | No |
| 0 (CPU) | 8 GB | 1.5B Q8_0 | 2048 | 1 | No |

---

## Phase 3: Integration with `install.sh`

### 3.1 Modified Install Flow

```
install.sh
  │
  ├── 1. Run detect-hardware.sh (if no manual config exists)
  │       → Generates etc/jenova.conf.detected
  │       → Generates build-profile.sh
  │       → Outputs dependency list
  │
  ├── 2. Install dependencies (using detected pkg manager)
  │       → Auto-select correct package names per distro
  │
  ├── 3. Build llama.cpp (using detected build flags)
  │       → cmake flags from build-profile.sh
  │       → -DGGML_CUDA=ON or -DGGML_VULKAN=ON etc.
  │
  ├── 4. Download models (using detected recommendation)
  │       → Model size based on VRAM/RAM budget
  │
  ├── 5. Source detected config into jenova.conf
  │       → etc/jenova.conf sources etc/jenova.conf.detected if present
  │
  └── 6. Deploy Neovim config + symlinks (unchanged)
```

### 3.2 Config Sourcing Chain

```sh
# In etc/jenova.conf, add at the top:
# Source auto-detected hardware config (overridden by JENOVA_* env vars)
if [ -f "$JENOVA_ROOT/etc/jenova.conf.detected" ]; then
    . "$JENOVA_ROOT/etc/jenova.conf.detected"
fi

# Then existing defaults still work as fallbacks:
DEVICES="${JENOVA_DEVICES:-Vulkan0,Vulkan1}"   # env > detected > hardcoded
```

This preserves the existing override chain: **env vars > detected config > hardcoded defaults**.

---

## Phase 4: FFI Constants Portability (`lib/ffi_defs.lua`)

The current `lib/ffi_defs.lua` has FreeBSD-specific constants:

| Constant | FreeBSD | Linux | Action |
|---|---|---|---|
| `EAGAIN` | 35 | 11 | Runtime detection |
| `EWOULDBLOCK` | 35 | 11 | Runtime detection |
| `EINPROGRESS` | 36 | 115 | Runtime detection |
| `FIONBIO` | `0x8004667e` | `0x5421` | Runtime detection |
| `O_NONBLOCK` | `0x0004` | `0x0800` | Runtime detection |
| `F_GETFL` / `F_SETFL` | 3 / 4 | 3 / 4 | Same (no change needed) |
| `SIG*` | Standard POSIX | Standard POSIX | Same (no change needed) |

**Approach:** Detect OS at LuaJIT startup via `ffi.os` and select the correct constant set:

```lua
local os_name = ffi.os  -- "Linux", "BSD", "OSX"
if os_name == "Linux" then
    defs.EAGAIN = 11
    defs.EINPROGRESS = 115
    defs.FIONBIO = 0x5421
    -- ...
else  -- BSD (FreeBSD, current default)
    defs.EAGAIN = 35
    defs.EINPROGRESS = 36
    defs.FIONBIO = 0x8004667e
    -- ...
end
```

---

## Phase 5: Testing Strategy

### 5.1 Detection Script Tests

- **Mock environments:** Create test fixtures simulating different `/proc/cpuinfo`, `nvidia-smi` outputs, `/etc/os-release` files
- **Validate outputs:** Ensure generated config values are sane for each hardware profile
- **Edge cases:** No GPU, unknown distro, container/WSL environments, ARM architectures

### 5.2 Hardware Profiles to Test

| Profile | OS | GPU | RAM | Expected Backend |
|---|---|---|---|---|
| FreeBSD + Dual Vulkan | FreeBSD 15 | GTX 1650 Ti + Iris Xe | 16 GB | vulkan (dual) |
| Ubuntu + NVIDIA | Ubuntu 24.04 | RTX 3060 12 GB | 32 GB | cuda |
| Ubuntu + AMD | Ubuntu 24.04 | RX 7900 XT 20 GB | 32 GB | hip |
| Fedora + CPU-only | Fedora 40 | None | 64 GB | cpu |
| Alpine + CPU-only | Alpine 3.20 | None | 8 GB | cpu |
| macOS + Apple Silicon | macOS 15 | M2 Pro 16 GB unified | 16 GB | metal |
| Arch + Intel Arc | Arch Linux | Intel Arc A770 16 GB | 32 GB | sycl or vulkan |
| Debian + Old NVIDIA | Debian 12 | GTX 1060 6 GB | 16 GB | vulkan or cuda |
| WSL2 + NVIDIA | Ubuntu (WSL2) | RTX 4090 (passthrough) | 32 GB | cuda |

---

## File Inventory (Implemented)

### Implemented Files
| File | Purpose |
|---|---|
| `hardware-profiles/detect-hardware.sh` | Main hardware detection script (with `--info`, `--apply`, `--install`, `--list`) |
| `hardware-profiles/<Category>/<gpu_type>/<name>/` | Per-profile directories with `profile.conf`, `jenova.conf`, `install.sh`, `jenova-setup` |
| `scripts/jenova-setup` | Dispatcher that auto-detects hardware and runs the matched profile's setup script |
| `lib/jenova-model.sh` | Model auto-discovery helper (scans `models/{agent,embed,draft}/`) |
| `bin/build-llama-jenova` | Vulkan llama.cpp build with Jenova runtime tuning |
| `bin/jenova-swap-mount` | FreeBSD swap-backed memory filesystem for model mmap |

### Modified Files
| File | Change |
|---|---|
| `scripts/install.sh` | Calls `detect-hardware.sh --apply`, sources build profile, downloads models |
| `etc/jenova.conf` | Per-profile configs deployed by detection; sources `lib/jenova-model.sh` for auto-discovery |
| `lib/ffi_defs.lua` | OS-conditional errno/ioctl constants (FreeBSD vs Linux) |
| `.gitignore` | Runtime artifacts ignored |

---

## Implementation Order

1. **`detect-hardware.sh`** — Core detection logic (OS, CPU, RAM, GPU, swap, packages) ✅
2. **Config generation** — Per-profile `jenova.conf` files (not `jenova.conf.detected`) ✅
3. **`lib/ffi_defs.lua`** — OS-conditional constants for Linux portability ✅
4. **`install.sh` integration** — Wire detection into install flow ✅
5. **`etc/jenova.conf`** — Profile-based config with env var override chain ✅
6. **Testing** — Validate across profiles (mock + real where possible) 🚧
7. **Documentation** — Update README with portability instructions 🚧

---

## Design Principles

- **Detection is advisory, not mandatory** — Everything still works with manual env vars
- **No breaking changes** — Existing FreeBSD setup works identically
- **Layered overrides** — `env vars > detected config > jenova.conf defaults`
- **Single script, no dependencies** — `detect-hardware.sh` uses only POSIX sh + standard tools
- **Idempotent** — Re-running detection regenerates config safely
- **Transparent** — Generated config is human-readable with comments explaining each choice
