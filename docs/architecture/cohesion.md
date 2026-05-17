## 1. Unified Monorepo & Dependencies
Jenova is a monorepo that contains almost all its own code. The only external dependency repositories are:
- **llama.cpp**: The high-performance inference engine.
- **mcsh**: The modernised C-shell.

These are treated as sub-repositories with their own lifecycle, while everything else—including the **jvim** editor, **jenova-ui** desktop manager, and **jca_web**—is built-in and directly wired into the Jenova core.
All components (backend, TUI, proxy, and editor) respect the same configuration hierarchy:
1. `etc/jenova.conf`: The active system profile (auto-generated from `hardware-profiles/`).
2. `etc/jenova.local.conf`: User overrides (ignored by git, preserved across updates).

This ensures that when you change a model path or a port in one place, the entire system—from the Svelte WebUI to the C-based Tray Icon—updates its behavior accordingly.

## 2. Shared Runtime State (`~/Jenova/.system`)
Transient state, such as process PIDs, active model metadata, and session tokens, is stored in the hidden `.system` directory within your `JENOVA_HOME` (typically `~/Jenova`).
- `jenova-ca` (the daemon) writes PIDs here.
- `jenova-ui` (the TUI/Tray) reads these PIDs to monitor health.
- `jvim` (the editor) checks these files to auto-start the backend if it's not already running.

## 3. Communication Loop
Components interact via a multi-port bridge:
- **Port 8080 (Proxy)**: The "brain" of the system. It handles RAG, tool execution, and workspace management. It serves as the gateway for both the WebUI and the `jvim` agent.
- **Port 8081 (Inference)**: Raw LLM access via `llama-server`.
- **Port 8082 (Embeddings)**: Semantic search backend.

## 4. Seamless Installation & Update Path
The `install-jenova.sh` and `scripts/update.sh` scripts are "cohesion-aware":
- They don't just pull code; they verify that dependencies for *all* components are met.
- They handle the complex relationship between `llama.cpp` (inference) and the `jvim` (editor), ensuring they are built with matching hardware optimizations (e.g., Vulkan/CUDA).
- The TUI (`jenova-manager.sh`) provides a high-level orchestration layer for these scripts, allowing granular control without breaking system integrity.

## 5. Security & Privacy by Structure
Cohesion is also maintained in what we *don't* share. The `.gitignore` at the repository root acts as a master guard, ensuring that while the code is a monorepo, the data (models, chat history, secrets) is strictly localized and never intermingled with the source control.
