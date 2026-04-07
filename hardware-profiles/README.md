# Jenova Hardware Profiles

This directory contains hardware-specific configuration profiles for Jenova Cognitive Architecture. Each profile is optimized for specific hardware combinations (CPU, GPU, RAM, storage).

## Available Profiles

### 1. `freebsd-i5-1135g7-dual-gpu/`
**Hardware:** Intel i5-1135G7 | GTX 1650 Ti 4GB + Intel Iris Xe ~7GB | 16GB RAM | Optane NVMe
**OS:** FreeBSD 15
**Strategy:** Dual-GPU full offload with tensor splitting (Vulkan0=NVIDIA, Vulkan1=Intel)
**Performance:** All 28 layers on GPU, 16K context, 2 slots

**Key settings:**
- DEVICES: Vulkan0,Vulkan1
- TENSOR_SPLIT: 1.0,1.8 (4GB:7GB ratio)
- NGL_7B: all (full offload with auto-fit)
- CTX: 16384

### 2. `freebsd-ryzen7-5700u-amd/`
**Hardware:** AMD Ryzen 7 5700U 8C/16T | AMD Vega 8 (UMA ~2-4GB) | 15GB RAM | ZFS swap
**OS:** FreeBSD 15
**Strategy:** Hybrid CPU+GPU inference with partial offload
**Performance:** 18/28 layers on GPU, 10 layers on CPU, 8K context

**Key settings:**
- DEVICES: Vulkan0 (AMD RADV)
- NGL_7B: 18 (partial offload)
- CTX: 8192 (conservative for UMA)
- THREADS: 8 (Zen 2 handles CPU layers well)

### 3. `vulkan-full-offload/`
**Hardware:** Generic Vulkan GPU with 8GB+ VRAM (NVIDIA/AMD/Intel)
**OS:** Any (Linux, FreeBSD, Windows with Vulkan)
**Strategy:** Full GPU offload for maximum performance
**Performance:** All 28 layers on GPU, 16K context, 2 slots

**Key settings:**
- DEVICES: Vulkan0
- NGL_7B: all (full offload)
- CTX: 16384
- FIT_TARGET: 1024 (larger safety margin)

**Suitable for:**
- NVIDIA RTX 3060/4060 (12GB/8GB), RTX 3070+ (8GB+)
- AMD RX 6800/7800 (16GB/8GB+)
- Intel Arc A770 (16GB)

## Profile Detection

Jenova automatically detects your hardware and selects the best-matching profile:

```bash
# View hardware detection report
./hardware-profiles/detect-hardware.sh --info

# Auto-detect and deploy the matching profile
./hardware-profiles/detect-hardware.sh --apply

# List all available profiles
./hardware-profiles/detect-hardware.sh --list
```

### Detection Scoring

Profiles are scored based on hardware matches:
- **CPU match:** +10 points (required for specific profiles)
- **GPU match:** +5 points per device
- **OS match:** +3 points

The profile with the highest score is selected. Generic profiles (like `vulkan-full-offload`) have lower scores and serve as fallbacks.

## Profile Structure

Each profile directory contains:

```
profile-name/
├── profile.conf        # Detection rules (MATCH_CPU, MATCH_GPU_0, MATCH_GPU_1, MATCH_OS)
├── jenova.conf         # Runtime configuration (DEVICES, NGL, CTX, etc.)
├── install.sh          # Profile-specific installer (optional)
└── jenova-setup        # Quick profile deployment script (optional)
```

### `profile.conf`
Defines hardware detection patterns:
```sh
PROFILE_NAME="my-profile"
PROFILE_DESC="Hardware description"
MATCH_CPU="i5-1135G7"        # CPU model substring (case-insensitive)
MATCH_GPU_0="NVIDIA"         # Primary GPU pattern (regex)
MATCH_GPU_1="Intel.*Iris"    # Secondary GPU pattern (regex, optional)
MATCH_OS="FreeBSD"           # OS name (optional)
```

### `jenova.conf`
Runtime configuration sourced by `bin/jenova-ca`. Contains:
- Model paths (auto-detected from `models/agent/`, `models/embed/`, `models/draft/`)
- Hardware settings (DEVICES, TENSOR_SPLIT, NGL_7B, CTX_SIZE, etc.)
- Network configuration (HOST, ports)
- Thread settings (THREADS, THREADS_BATCH)

### `install.sh`
Profile-specific installation script that:
1. Validates hardware compatibility
2. Deploys profile configuration
3. Builds llama.cpp with correct backend
4. Downloads models (if needed)

### `jenova-setup`
Quick profile deployment script. Copies or symlinks `jenova.conf` to `etc/jenova.conf`.

## Creating a New Profile

1. **Create profile directory:**
   ```bash
   mkdir hardware-profiles/my-new-profile
   ```

2. **Create `profile.conf`:**
   ```sh
   PROFILE_NAME="my-new-profile"
   PROFILE_DESC="My Custom Hardware"
   MATCH_CPU="CPU-Model-String"
   MATCH_GPU_0="GPU-Pattern"
   MATCH_OS="Linux"  # Optional
   ```

3. **Create `jenova.conf`:**
   - Copy an existing profile's `jenova.conf` as a template
   - Adjust DEVICES, NGL_7B, TENSOR_SPLIT, CTX_SIZE for your hardware
   - Include model auto-discovery code (see `vulkan-full-offload/jenova.conf`)

4. **Create `install.sh` (optional):**
   - Hardware validation
   - Profile deployment
   - Build instructions

5. **Test detection:**
   ```bash
   ./hardware-profiles/detect-hardware.sh --info
   ```

## Manual Profile Selection

If auto-detection doesn't work or you want to use a specific profile:

```bash
# Deploy a specific profile
cp hardware-profiles/vulkan-full-offload/jenova.conf etc/jenova.conf

# Or use the profile's setup script
./hardware-profiles/vulkan-full-offload/jenova-setup

# Or run the profile installer
./hardware-profiles/vulkan-full-offload/install.sh
```

## Profile Priority

When multiple profiles match:
1. Higher-scored profiles win (more specific matches)
2. CPU matches are required for non-generic profiles
3. Multi-GPU profiles require all specified GPUs
4. Generic profiles (like `vulkan-full-offload`) have the lowest priority

## Environment Overrides

All profiles respect environment variables:
```bash
# Override model selection
export JENOVA_MODEL=/path/to/my-model.gguf
export JENOVA_EMBED_MODEL=/path/to/my-embed.gguf
export JENOVA_DRAFT_MODEL=/path/to/my-draft.gguf

# Override hardware settings
export JENOVA_DEVICES="Vulkan0"
export JENOVA_NGL_7B=24
export JENOVA_CTX=8192

# Override network
export JENOVA_HOST=0.0.0.0  # Listen on all interfaces (LAN mode)
export JENOVA_PORT=8080
```

## Backend Support

All profiles use Vulkan by default. To build with CUDA or CPU:

```bash
# Build with CUDA
JENOVA_BACKEND=cuda ./bin/build-llama-jenova

# Build with CUDA + Vulkan
JENOVA_BACKEND=cuda JENOVA_CUDA_WITH_VULKAN=1 ./bin/build-llama-jenova

# Build CPU-only
JENOVA_BACKEND=cpu ./bin/build-llama-jenova
```

Then adjust your profile's `DEVICES` setting or set `JENOVA_DEVICES=CUDA0`.

## Troubleshooting

### No matching profile found
- Run `./hardware-profiles/detect-hardware.sh --info` to see detection results
- Use the generic `vulkan-full-offload` profile as a starting point
- Create a custom profile for your hardware

### Profile deployed but Jenova fails to start
- Check `var/log/jenova-ca.log` and `var/log/llama-*.log`
- Verify Vulkan drivers: `vulkaninfo --summary`
- Verify models exist: `ls -lh models/agent/ models/embed/ models/draft/`
- Check GPU memory: `nvidia-smi` or `vulkaninfo`

### Wrong profile selected
- Manually deploy the correct profile: `cp hardware-profiles/PROFILE/jenova.conf etc/jenova.conf`
- Or adjust profile.conf detection patterns for better matching

## Contributing

When contributing new hardware profiles:
1. Use descriptive profile names (e.g., `linux-rtx4090-fulloffload`)
2. Document hardware requirements in `profile.conf` comments
3. Test auto-detection with `detect-hardware.sh --info`
4. Validate with: `bin/jenova-ca start && bin/jenova-ca status`
