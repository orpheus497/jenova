# Native Tooling Overhaul & Token Compression

## Objective
Aggressively condense tool definitions and re-architect the agent tools to be fully "jvim-native" and "buffer-first," eliminating any remaining "CLI/REPL" characteristics. This maximizes the context window for the 3B model and ensures consistent behavior between the agent and jvim's native rewrite functions.

## Key Changes

### 1. Token Compression (All Tools)
*   Surgically condense `description` and `parameters` descriptions for every tool in `jvim-config/lua/jenova/agent/tools/`.
*   Reduce the cumulative tool schema size by ~50% to save tokens on every single turn.

### 2. Native Buffer-First Logic
*   **`Read`**: Already updated to use `vim.fn.bufadd`. Ensure it consistently provides `Line | Content` format.
*   **`Edit` / `MultiEdit`**: Already updated to use line-range replacements via `vim.api.nvim_buf_set_lines`. 
*   **`Grep`**: Enhance to search unsaved content in open jvim buffers *before* searching the disk. This ensures the Agent "sees" what the user is currently editing.
*   **`LS` / `Glob`**: Ensure they prioritize workspace-relative paths and emphasize project traversal within the editor.
*   **`Write`**: Refactor to use `bufadd` and `nvim_buf_set_lines` for a unified experience, rather than falling back to `io.open` for closed files.

### 3. Identity Alignment
*   Update tool descriptions to explicitly mention they operate on "jvim buffers" and "workspace paths."
*   Remove any language suggesting these are "commands to run" or "terminal functions."

## Implementation Steps

### Phase 1: Compression Pass
*   Update `LS`, `Glob`, `Grep`, `Buffers`, `Shell`, `Write`, `AskUserQuestion` with ultra-terse schemas.

### Phase 2: Grep Buffer Awareness
*   Modify `buffer_grep.lua` to iterate through `vim.api.nvim_list_bufs()`.
*   Match the pattern against loaded buffer lines using `vim.api.nvim_buf_get_lines`.
*   Deduplicate results when a file is both in a buffer and on disk.

### Phase 3: Unified Write
*   Update `buffer_write.lua` to follow the `Read/Edit` pattern: `bufadd` -> `set_lines` -> `write`.

## Verification & Testing
*   Verify that `LS` and `Glob` still return correct paths.
*   Verify `Grep` finds strings in unsaved buffers.
*   Confirm total character count of the tool schema via the diagnostic script.
*   Verify the Agent (3B model) correctly uses the new line-range parameters without confusion.
