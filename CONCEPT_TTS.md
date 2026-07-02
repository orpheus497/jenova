# Voice Model Architecture (Qwen3-TTS)

## 1. Overview

This document outlines the architectural strategy for integrating a Voice Model (specifically **Qwen3-TTS-1.7B-CustomVoice-GGUF**) into the Jenova platform. The design completely replaces any speculative decoding mechanisms with a highly optimized voice generation subsystem capable of running concurrently with the main reasoning agent.

## 2. Hardware Allocation Strategy (iGPU Offloading)

To ensure zero performance degradation to the core reasoning engine, the Voice model is strictly offloaded to the Integrated GPU (iGPU).

*   **VRAM Preservation**: The primary Agent model requires high-bandwidth, fast GDDR6 VRAM of the dedicated GPU (dGPU) for deep reasoning and fast token generation. 
*   **iGPU UMA Utilization**: The Qwen3-TTS 1.7B model is highly compact (~1.8GB). By binding its background process explicitly to the iGPU (e.g., `-dev Vulkan1`), it seamlessly utilizes shared system RAM (UMA). It does not compete for compute or memory bandwidth with the Agent model.
*   **Parallel Generation**: Because the Agent and Voice models sit on entirely separate hardware buses, they operate in perfect parallel. The Agent streams text out, and the Voice model instantly ingests and synthesizes it without causing GPU context-switching bottlenecks.

## 3. Subsystem Lifecycle & Isolation

The integration does not require an entirely new external server application, but rather leverages `jenova-ca` to orchestrate a separate companion process.

*   **Process Isolation (`llama.cpp`)**: The `-md` argument in `llama.cpp` shares the exact same vocabulary and thread loop as the main text model. Because Qwen3-TTS outputs audio tokens, it structurally cannot share a thread loop with the standard text Agent. Therefore, it is launched as a specialized companion background process (`PID`), allowing specific targeting of the iGPU.
*   **Daemon Orchestration (`jenova-ca`)**: The old speculative logic (`DRAFT_ARGS`) is removed. In its place, the Qwen3-TTS model is directly managed, started, and stopped by the Jenova daemon exactly like the embedding model.

## 4. Dual-Layer Toggle Architecture

The system supports strict resource-efficiency through a dual-layer toggle system:

1.  **Config Level (`jenova.conf`)**: 
    A `JENOVA_VOICE=1` flag and a `VOICE_DEVICE="Vulkan1"` setting dictate the initialization behavior. When the daemon boots, if the flag is disabled, it completely skips initializing the Voice process.
2.  **Web UI Level (Dynamic Lifecycle)**: 
    Using the lifecycle endpoints used by the UI contract, specifically the load/unload flow handled by `/models/load` and `/models/unload`, a UI toggle dynamically unloads the Voice model during "Silent Mode", and dynamically reloads it into the iGPU when voice is requested. This guarantees aggressive resource optimization when audio synthesis is not required, while keeping `/v1/models` reserved for listing models only.

## 5. Next Steps

* Update `jenova-ca` process orchestration logic to spawn the secondary iGPU process.
* Map the new routing logic in `proxy.lua` to properly bridge text streams to the Voice proxy port.
