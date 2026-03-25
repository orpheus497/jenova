 Jenova Cognitive Architecture (CA)
  Comprehensive Architectural Blueprint & System Overhaul Plan


  This document outlines the strategic transformation of the coder prototype into the Jenova Cognitive Architecture. This is not merely a rebranding but a deep architectural pivot optimized for FreeBSD 15, Hybrid GPU (NVIDIA + Intel
  Xe), and Optane-backed Virtual Memory.

  ---

  1. Technical Deep Dive & Core Research Findings


  1.1 The Optane "Fluid Memory" Strategy
   * Observation: The system currently struggles with 14B models when context exceeds 8k, despite having 16GB RAM + 27GB Optane Swap.
   * Root Cause: mlock usage in the current launcher forces physical RAM residency, causing the kernel to kill the process when the KV cache grows.
   * Solution: By disabling mlock and tuning FreeBSD's vm.swappiness (or equivalent vfs.zfs.arc_max balancing), we leverage the 10μs latency of Optane as a secondary L4 cache. This allows Jenova to handle context windows up to 32k by
     paging inactive LLM weights to the NVMe without significant compute stalls.


  1.2 The Vulkan Initialization Bottleneck
   * Observation: Indexing a medium-sized repo hangs the proxy for 10-30 seconds.
   * Root Cause: lib/embed.lua calls the llama-embedding CLI via os.execute for every batch. This forces a full Vulkan device re-init (~800ms per call).
   * Solution: Shift to a persistent background "Embedding Daemon" or a dedicated llama-server endpoint for embeddings.


  1.3 BSD Socket Integrity
   * Observation: Intermittent EINVAL on socket operations.
   * Root Cause: FreeBSD requires sin_len to be set in sockaddr_in. The current FFI code leaves it at 0.
   * Solution: Enforce addr.sin_len = ffi.sizeof(addr) across all network modules.

  ---

  2. The "Jenova" Quad-Agent Parallel Implementation Plan

  To execute this transition rapidly and safely, work is partitioned into four independent streams.


  Agent 1: Infrastructure & Hardware Optimization ("The Architect")
  Focus: Shell scripts, configuration, and process management.
   * Renaming: bin/coder → bin/jenova, bin/coder-server → bin/jenova-ca, etc/coder.conf → etc/jenova.conf.
   * Launcher (jenova-ca):
       * Implement background mode using nohup or daemon(8).
       * PID management in .jenova/jenova-ca.pid.
       * Removal of mlock and re-tuning of TENSOR_SPLIT to 1.0, 3.0 (favoring Iris Xe for Optane paging).
   * Files: bin/*, etc/*, README.md, .gitignore.


  Agent 2: Networking & Protocol Resilience ("The Signal")
  Focus: Non-blocking I/O and HTTP protocol compliance.
   * Async Proxy: Refactor lib/proxy.lua to use a select()-based non-blocking loop with Lua coroutines.
   * BSD Hardening: Update lib/ffi_defs.lua and lib/http.lua to ensure sin_len alignment.
   * Chunked Decoding: Implement a robust HTTP chunked-encoding decoder for incoming POST requests to support modern IDE clients.
   * Files: lib/proxy.lua (Network Core), lib/http.lua, lib/ffi_defs.lua.


  Agent 3: Intelligence & RAG Quality ("The Mind")
  Focus: Vector search, embedding persistence, and semantic context.
   * Persistent Embedder: Refactor lib/embed.lua to maintain a persistent connection to the embedding engine, eliminating Vulkan re-init overhead.
   * Background Indexing: Move search.index_dir into an asynchronous background task so the proxy can accept connections immediately.
   * Semantic Snippets: Replace the 500-char truncation with a line-aware parser that respects function/class boundaries.
   * Files: lib/search.lua, lib/embed.lua, lib/prompts.lua.


  Agent 4: UX & Interface Identity ("The Voice")
  Focus: CLI branding, status reporting, and user interaction.
   * Branding: Update lib/ui.lua with the "Jenova Cognitive Architecture" ASCII banner and color palette.
   * Agent Logic: Update lib/agent.lua to automatically detect and start the jenova-ca backend if missing.
   * Visual Feedback: Add progress indicators for background indexing and hardware utilization stats.
   * Files: lib/agent.lua, lib/ui.lua, lib/chat.lua, lib/memory.lua.

  ---

  3. Synchronization & Integration Protocol

  To prevent collision, agents must adhere to the following strict boundaries:


   1. Interface Integrity: Agent 3 (Intelligence) provides a non-blocking API for Agent 2 (Networking) to call within the proxy loop.
   2. State Directory: All agents migrate from .coder/ to .jenova/.
   3. Cross-File Safety: No agent shall modify a file outside their assigned scope without coordination from Agent 5.

  ---

  4. Final Consolidation & Validation (Agent 5)


  Once the four agents complete their tasks, a final Consolidator Agent will:
   1. Verify the end-to-end flow: jenova (Agent) → jenova-ca (Launcher) → proxy.lua (Networking) → search.lua (Intelligence).
   2. Run the BSD Protocol Suite to ensure no EINVAL regressions.
   3. Perform a Memory Stress Test to validate the Optane paging performance with a 14B model at 16k context.
   4. Finalize the documentation and provide the "Jenova Ready" report.


  ---
  Report Status: Research Complete. Plan Finalized.
