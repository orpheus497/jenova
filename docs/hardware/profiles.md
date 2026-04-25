# Hardware Profiles

Jenova is hardware-aware. At install time, it detects your GPU(s) and CPU and recommends a profile that balances model quality with inference speed.

## Profile Logic
Profiles are organized by vendor and GPU configuration:
- `Intel/dgpu_igpu/`: Dual-GPU setups (e.g., GTX 1650 Ti + Iris Xe).
- `AMD/apu/`: Integrated graphics only (e.g., Ryzen 5700U / Vega 8).
- `Vulkan/dgpu/`: Generic high-performance GPU profile.
- `Optane/`: Specialized profiles for systems with Intel Optane NVMe swap.

## Key Profiles

| Profile | Hardware | Model | Context |
|---|---|---|---|
| `Vulkan/dgpu/full-offload-14b` | 8GB+ VRAM GPU | 14B Q4_K_M | 32K |
| `Intel/dgpu_igpu/i5-1135g7-3b` | i5 + Dual GPU | 3B Q8_0 | 32K |
| `AMD/apu/ryzen7-5700u-3b` | Ryzen 7 APU | 3B Q8_0 | 16K |

## Deployment
Profiles are deployed using the `detect-hardware.sh` script:

```sh
# Show hardware report
./hardware-profiles/detect-hardware.sh --info

# Apply recommended profile
./hardware-profiles/detect-hardware.sh --apply
```

## Manual Overrides
You can manually tune your profile in `etc/jenova.conf`. Key variables include:
- `DEVICES`: The Vulkan devices to use (e.g., `Vulkan0,Vulkan1`).
- `NGL`: Number of layers to offload to the GPU (`all` for full offload).
- `CTX_SIZE`: The size of the context window.
- `JENOVA_DRAFT`: Enable/disable speculative decoding.
