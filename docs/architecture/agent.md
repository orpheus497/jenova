# Unified Agent System

The Jenova Agent is an autonomous "coding partner" that lives inside your editor. It is designed to be "context-aware" by default.

## Unification
The agent is fully unified. It lives inside the `jvim` runtime but its engine and tools can be invoked by both the editor and headless launchers.

- **jvim Agent**: The canonical interactive experience. It has full access to Neovim buffers, LSP data, and the project tree.
- **Headless Agent**: Accessible via `bin/jenova` for scripted or CI workflows.

## Core Components

### 1. QueryEngine
The engine that runs the Plan → Execute → Reflect loop. It manages multi-turn tool calling and ensures the model stays on track.

### 2. Tool Registry
A modular system where tools are registered.
- **FS Tools**: `Read`, `Write`, `Edit`, `Glob`, `Grep`.
- **System Tools**: `Shell`, `AskUserQuestion`.
- **jvim Tools**: `LSP` (hover/definition), `BufferRead`, `BufferWrite`.

### 3. Context Management
The agent automatically builds a "snapshot" of the current environment:
- Active buffer content.
- Project file tree.
- LSP diagnostics (warnings/errors).
- Recent conversation history.

## Token Compression
To maximize the effectiveness of the 3B/7B models, all tool schemas and system prompts are aggressively condensed. This ensures more room for code and reasoning in the context window.

## Security & Permissions
- **Interactive Prompts**: Action tools (like `Shell` or `Write`) require user confirmation by default.
- **Plan Mode**: A read-only mode that prevents the agent from making any changes while it researches a solution.
- **Sandbox**: A C-based layer that validates paths and blocks dangerous shell patterns.
