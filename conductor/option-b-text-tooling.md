# Plan: Option B - Text-Based Tooling Migration (3B Model)

The objective is to eliminate the large JSON schema overhead (~1.5k tokens) that confuses the 3B model (Qwen2.5-Coder-3B-Instruct) and replaces it with a compact, text-based tool specification in the system prompt. This restores the agent's "intelligence" and autonomy while maximizing available context for code.

## Key Changes

### 1. Disable Formal API Tools
*   **File**: `jvim-config/lua/jenova/agent/init.lua`
*   **Change**: Modify the `get_engine()` constructor to pass `tools = {}` (or an empty list) to `QueryEngine.new()`. This prevents the backend from injecting the massive tool schema into every API call.

### 2. Compact Text-Based Tool Specification
*   **File**: `jvim-config/lua/jenova/agent/context.lua`
*   **Change**: Update `build_system_prompt()` to include a high-density Markdown table of available tools.
*   **Format**:
    ```markdown
    ## Tools (Call with: ```json {"name":..,"arguments":{..}} ```)
    - Read(file_path, start_line?, end_line?): View code with line numbers.
    - LSP(action, file_path?, line?, character?, query?): Get 'diagnostics', 'definition', 'references', 'hover', 'symbols'.
    - Edit(file_path, start_line, end_line, new_string): Replace line range.
    - MultiEdit(file_path, edits[{start_line, end_line, new_string}]): Batch edits.
    - Shell(command): Run tests/build. (Not for diagnostics).
    - Glob(pattern), Grep(pattern, path?), LS(path?): Search files.
    - AskUserQuestion(question): Prompt user for input.
    ```

### 3. Agentic Mandate (Rule 0)
*   **File**: `jvim-config/lua/jenova/agent/context.lua`
*   **Change**: Add a strict "Rule 0" to the system prompt:
    *   "0. NEVER ask the user to run commands, provide diagnostics, or read files for you. Use your tools to gather all information yourself. Act immediately."

### 4. LSP Diagnostic Fallback
*   **File**: `jvim-config/lua/jenova/agent/tools/lsp.lua`
*   **Change**: In `action_diagnostics`, if no LSP client is active and the file is `.c` or `.h`, run `cc -fsyntax-only -I. -Iinclude [file]` via `vim.system` to generate a list of errors. This ensures the model always has actionable diagnostics.

## Implementation Steps

### Phase 1: Tool specification & Mandate
1.  Update `jvim-config/lua/jenova/agent/context.lua` with the compact tool list and "Rule 0".
2.  Update `jvim-config/lua/jenova/agent/init.lua` to suppress the formal `tools` block.

### Phase 2: LSP Resilience
1.  Implement the `cc -fsyntax-only` fallback in `jvim-config/lua/jenova/agent/tools/lsp.lua`.

### Phase 3: Verification & Commit
1.  Verify the 3B model correctly uses the text-based tools in `jvim`.
2.  Commit all changes and push to the current branch.

## Verification Plan
1.  **Context Check**: Verify (via logs or debug output) that the tool schema is no longer sent to the backend.
2.  **Intelligence Check**: Ask the agent to "check for linting errors in xp_system.c and fix them" without providing any context. 
3.  **Success**: Agent should autonomously call `LSP`, then `Read`, then `Edit`.
