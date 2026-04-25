# Cognitive Backend

Jenova runs three persistent daemon processes that manage inference, intelligence, and retrieval.

## 1. llama-server (Port 8081)
The main inference engine. 
- **Stack**: C++ (llama.cpp).
- **GPU Offload**: Uses Vulkan for single or dual-GPU offload.
- **Speculative Decoding**: Supports a small drafter model (0.5B) to speed up generation.

## 2. Intelligence Proxy (Port 8080)
A LuaJIT-based proxy that acts as the brain of the backend.
- **Role**: Handles non-blocking I/O, coroutine-based connection multiplexing, and RAG injection.
- **RAG Pipeline**: Automatically searches the local codebase (semantic + BM25) and injects relevant snippets into the prompt before sending it to `llama-server`.

## 3. Embedding Server (Port 8082)
A dedicated `llama-server` instance running in embedding mode.
- **Model**: `nomic-embed-text-v1.5`.
- **Strategy**: Runs on CPU to preserve VRAM for the main inference model.
- **Purpose**: Provides vector embeddings for semantic search and codebase indexing.

## Process Management
All three processes are managed as a unit by the `jenova-ca` supervisor.
- **Daemonize**: `jenova-ca --daemon` starts all three.
- **Lifecycle**: `jenova-ca stop` ensures all PIDs are cleaned up.
- **Health**: Provides a `/v1/health` endpoint for the editor and CLI clients.

## Networking
All internal communication uses HTTP/1.1 over localhost. The proxy handles chunked transfer-encoding and ensures low-latency streaming of responses.
