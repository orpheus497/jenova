# Plan: Restore Agent and Chat Features

The objective is to fix the critical failures introduced during the native tooling overhaul that caused the Jenova Chat and Agent features to disappear from `jvim`.

## Key Files & Context

- **`jvim-config/lua/plugins/chat.lua`**: The plugin specification that failed to load due to invalid `dir` and `name` fields.
- **`jvim-config/lua/jenova/agent/provider.lua`**: Missing the `generate_request` method required by the new engine.
- **`jvim-config/lua/jenova/agent/init.lua`**: Contains `setup()` but it is never called.
- **`jvim-config/lua/jenova/agent/tools/init.lua`**: Contains a broken require path for the registry.
- **`jvim-config/lua/jenova/chat.lua`**: Needs to trigger the agent initialization.

## Implementation Steps

### 1. Fix Plugin Specification
- **File**: `jvim-config/lua/plugins/chat.lua`
- **Action**: Remove the `dir` and `name` fields. Change the first element to `"jenova.chat"` to ensure proper module resolution by `spec_runner`.

### 2. Implement Missing Provider Method
- **File**: `jvim-config/lua/jenova/agent/provider.lua`
- **Action**: Implement `M.generate_request(request)`. This method will wrap `post_json` (or `post_stream` if streaming is handled) and return a structured table `{ content = ... }` as expected by `engine.lua`.

### 3. Repair Tool Initialization
- **File**: `jvim-config/lua/jenova/agent/tools/init.lua`
- **Action**: Change `require("tools.registry")` to `require("jenova.agent.registry")`.
- **File**: `jvim-config/lua/jenova/agent/init.lua`
- **Action**: Ensure `M.setup()` correctly registers all tools.

### 4. Wire the Bootstrap Chain
- **File**: `jvim-config/lua/jenova/chat.lua`
- **Action**: In `M.setup()`, add a call to `require("jenova.agent").setup()`. This ensures that whenever the chat is initialized (on `VeryLazy`/`VimEnter`), the agent and its tools are also ready.

## Verification & Testing

1.  **Command Presence**: Verify that `:JenovaChat` and `:JenovaAgentReset` commands are available in `jvim`.
2.  **Plugin Load**: Check `:messages` for any `spec_runner` warnings related to `plugins.chat`.
3.  **Agent Functionality**: Open a chat and ask a question that requires tool use (e.g., "What's in the current file?"). Verify that the agent autonomously calls `Read` or `LSP`.
4.  **Diagnostics**: Verify that the "Option B" prompt correctly includes the file context and tool definitions as intended.
