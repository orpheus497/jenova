# Performance & Tuning

Jenova is designed to squeeze every bit of performance out of laptop hardware.

## GPU Offload Strategy
- **Full Offload**: If your model fits entirely in VRAM, Jenova offloads all layers (`NGL=all`). This is the fastest mode.
- **Partial Offload**: If VRAM is tight, some layers stay on the CPU.
- **Dual-GPU**: Jenova uses the `-fitt` flag to automatically distribute layers across multiple Vulkan devices (e.g., dGPU + iGPU).

## Memory Management
- **ZFS ARC**: On FreeBSD/ZFS, limit the ARC to prevent it from competing with the LLM for memory.
- **Swap**: For UMA (integrated GPU) systems, ensure you have fast NVMe swap. Jenova is tuned to handle paging gracefully.
- **Optane**: If you have Intel Optane, Jenova can use it as a high-speed swap layer, allowing for larger models or context windows than would otherwise fit in RAM.

## Speculative Decoding
Speculative decoding uses a tiny "drafter" model (0.5B) to predict the next few tokens. The main model (e.g., 7B) then verifies them.
- **Benefit**: Can increase generation speed by 1.5x - 2x.
- **Requirement**: Requires additional VRAM (~0.5GB). Enabled by default if headroom is available.

## KV Cache Quantization
To save memory, the Key-Value (KV) cache is quantized.
- `q8_0`: High quality, medium memory.
- `q4_0`: Lower memory, slight quality impact.
- `f16`: Maximum quality, highest memory.
