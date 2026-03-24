# coder — Autonomous Local Coding Agent

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Platform: FreeBSD](https://img.shields.io/badge/Platform-FreeBSD-red.svg)](#)

**coder** is a high-performance, autonomous coding assistant designed to run entirely on your local machine. Built with a focus on privacy, reliability, and deep system integration, it leverages the power of **LuaJIT**, **Vulkan**, and **GGUF-based LLMs** to provide a seamless agentic experience without the need for cloud dependencies.

---

## 🌟 The "Local-First" Philosophy

In an era of increasing cloud centralization, **coder** stands for digital sovereignty. Every line of code, every architectural thought, and every project secret stays on your disk.

### Why Local AI?
*   **Absolute Privacy:** Your intellectual property never leaves your machine. No data is used for training external models, and no telemetry is sent to third parties.
*   **Offline Resilience:** Work through long flights, remote cabins, or network outages. **coder** is your companion for deep, overnight sessions where focus is paramount and connectivity is optional.
*   **Zero Latency & No Limits:** No API rate limits, no subscription fees, and no "down for maintenance" windows. If your computer is on, your agent is ready.
*   **Hardware Ownership:** Why pay for GPUs in the cloud when you have them on your desk? **coder** is optimized to squeeze every bit of performance out of your local silicon.

---

## 🧠 Cognitive Architecture: The Jenova Influence

**coder**'s internal logic is heavily inspired by the **Jenova Cognitive Architecture**, specifically adapted for the constraints and opportunities of local, single-agent execution.

### Plan → Execute → Reflect
Unlike simpler agents that react to prompts in isolation, **coder** operates on a continuous cognitive loop:
1.  **Thinking (Plan):** Before acting, the agent uses a specialized `think` tool to decompose complex requests into a structured plan. It identifies what it needs to learn, verify, and modify.
2.  **Acting (Execute):** The agent interacts with your system through a suite of tools (shell, file I/O, search). It doesn't just suggest code; it applies it, compiles it, and tests it.
3.  **Reflecting (Reflect):** After every action, the agent analyzes the result. If a shell command fails or a file edit doesn't match, it detects the error, records the failure, and adapts its strategy rather than repeating the same mistake.

### Just-in-Time Context & Memory
Following Jenova's focus on efficient context management:
*   **Episodic Memory:** Each session is isolated, preventing "context pollution" from past unrelated tasks while maintaining a sharp focus on the current objective.
*   **Semantic RAG:** A hybrid BM25 and vector-based search engine (powered by `nomic-embed-text`) injects relevant code snippets into the agent's context window only when needed.
*   **Action Deduplication:** The agent tracks every attempted action, preventing the "looping" behavior common in lesser LLM implementations.

---

## 🛠 Features

*   **Hybrid Search:** Combines keyword-based BM25 with semantic vector embeddings for pinpoint accuracy in large codebases.
*   **Vulkan Optimization:** Native support for the Vulkan backend via `llama.cpp`, allowing high-speed inference on FreeBSD where CUDA is unavailable.
*   **Agentic Tooling:**
    *   `shell`: Full access to the FreeBSD userland (pkg, cc, make, etc.).
    *   `read_file` / `write_file` / `edit_file`: Precise file manipulations with automatic backups.
    *   `search_files`: Deep semantic indexing of your project.
*   **FFI-Powered HTTP:** A zero-dependency, high-performance HTTP client written in Lua using FFI for direct socket communication.
*   **speculative decoding:** Support for speculative decoding to accelerate inference on supported hardware.

---

## 🚀 Quick Start (FreeBSD)

### 1. Prerequisites
Ensure you have the necessary system-level dependencies:
```sh
# Install dependencies via pkg
pkg install luajit-openresty vulkan-loader vulkan-headers nvidia-driver pkgconf
```

### 2. Configure System
For userspace `mlock` (required by `llama.cpp` for performance):
```sh
sysctl security.bsd.unprivileged_mlock=1
# Add to /etc/sysctl.conf for persistence
```

### 3. Launch
```sh
./bin/coder-agent
```
*This will start the local llama-server and enter the agent REPL.*

---

## 📦 Project Structure

```text
bin/                 # Executable scripts (Server, Agent, Neovim server)
lib/                 # Core logic (Agent loop, HTTP, Search, Memory, UI)
etc/                 # Configuration (coder.conf)
models/              # GGUF models (place your .gguf files here)
var/                 # Runtime logs, cache, and session data
llama.cpp/           # Submodule for the high-performance inference engine
```

---

## 🐧 Roadmap: Linux Compatibility

While **coder** is currently optimized for **FreeBSD**, we have active plans to bring it to **Linux** out of the box. The architecture is modular, and work is underway to:
*   Abstract package management (`pkg` vs `apt`/`dnf`).
*   Standardize GPU access (Vulkan is cross-platform, but driver paths vary).
*   Provide pre-built binaries for common Linux distributions.

---

## ⚙️ Hardware Recommendations

Optimized for mid-range hardware with a focus on heterogeneous compute:
*   **Primary Model:** Qwen2.5-Coder-14B (Q4_K_M)
*   **Embedding Model:** nomic-embed-text-v1.5
*   **Example Setup:** i5-1135G7 / GTX 1650 Ti / 16GB RAM.
*   **Tensor Split:** Supports splitting workloads between NVIDIA GPUs and Intel Integrated Graphics (via Vulkan).

---

## 📜 License

This project is licensed under the **GNU Affero General Public License v3 (AGPL-3.0)**. 

The AGPL is chosen to ensure that the spirit of local, open-source AI is preserved. If you modify this software and run it over a network, you must make your source code available to your users. See the [LICENSE](LICENSE) file for details.

---

## 🤝 Respect & Attributions

**coder** is built on the shoulders of giants. We give our deepest respect and thanks to the following creators and projects:

*   **[llama.cpp](https://github.com/ggerganov/llama.cpp):** By Georgi Gerganov and the incredible community of contributors. The foundation of local LLM inference.
*   **[Qwen2.5-Coder](https://github.com/QwenLM/Qwen2.5-Coder):** By Alibaba Cloud. The state-of-the-art open coding model that makes this agent possible.
*   **[Nomic AI](https://vibe.nomic.ai/):** For `nomic-embed-text`, providing the semantic bridge for our RAG system.
*   **[LuaJIT](https://luajit.org/):** By Mike Pall. The fastest JIT compiler, giving our agent its snappy response times.
*   **Jenova Cognitive Architecture:** For the conceptual framework of autonomous, tool-augmented AI agents.

---
*Generated by the agent, for the user. Happy hacking.*
