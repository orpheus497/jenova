# Jenova Tool Development Guide

This document outlines the **logical process and comprehensive method** for building tools for the Jenova system. 

With the decommissioning of the CLI REPL, all tools must be designed with the **jvim-native** philosophy in mind, prioritizing buffer context and non-blocking asynchronous execution.

## 1. Tool Structure
Every tool is a Lua module returning a table with the following fields:

- `name`: (string) The identifier used by the model (e.g., "Read").
- `description`: (string) Clear, concise instructions for the model.
- `parameters`: (table) JSON Schema defining the input arguments.
- `is_enabled()`: (function) Returns true if the tool should be available in the current context.
- `is_read_only()`: (function) Returns true if the tool doesn't modify the filesystem.
- `check_permissions(input, context)`: (function) Validates if the call is allowed.
- `call(args, context)`: (function) The implementation logic.

## 2. The "Buffer-First" Philosophy
Jenova tools should interact with the **editor state** whenever possible:
- **Read**: If a file is already open in a jvim buffer, return the buffer content (which may contain unsaved changes) instead of the disk version.
- **Write/Edit**: Apply changes to the buffer if it exists. This allows the user to see the change instantly and use `u` (undo) within the editor.
- **Context**: Use the `context` argument to get the current working directory (`context.cwd`) or other session-specific state.

## 3. Path Resolution & Security
All tools MUST use the `utils.paths` module:
- `paths.resolve(path, base)`: Always resolve relative paths against the session's CWD.
- `paths.is_restricted(path)`: Always check if a path is inside `.jenova` or other restricted areas.
- **Never** allow a tool to modify the `.jenova` directory.

## 4. Async & Non-Blocking Execution
Inside `jvim`, the agent runs in a coroutine.
- **Avoid `io.popen`**: It blocks the editor's main thread.
- **Use `vim.system`**: For shell commands or HTTP calls, use `vim.system`. In `jvim-config`, the `utils.http` module is shimmed to use `vim.system` and yields the coroutine automatically.
- **FFI**: Use `jenova.fs` (C FFI) for fast, low-level file operations when buffer interaction isn't required.

## 5. Permission Handling
Always delegate to `permissions.manager`. 
- In `jvim`, this is shimmed to use a `vim.ui.select` picker that yields the agent's execution until the user responds.
- Tools should provide a `user_facing_name(input)` helper to make the permission prompt descriptive (e.g., "Write: src/main.c").

## 6. Implementation Checklist
1. [ ] Define precise JSON schema parameters.
2. [ ] Add `check_permissions` call.
3. [ ] Resolve and validate `file_path` using `utils.paths`.
4. [ ] Check if the file is open in a `jvim` buffer (`vim.fn.bufadd` / `vim.api.nvim_buf_get_lines`).
5. [ ] Return a structured table with `type = "text"` or `type = "error"`.
6. [ ] Provide enough context in the output for the model to understand the result (e.g., line numbers for Read).
