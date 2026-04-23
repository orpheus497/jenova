-- jenova/agent/tools/init.lua
-- Loads the full cli-agent tool set from shared/ into the registry, then
-- registers jvim-native overrides so buffer-aware tools shadow the disk-based
-- CLI equivalents.
--
-- Call order (enforced here):
--   1. load_shared_tools()   — populates registry with all synced CLI tools
--   2. register_overrides()  — replaces Read/Edit/LSP with jvim-native versions
--
-- This module is called by agent/init.lua BEFORE QueryEngine.new() so that
-- QueryEngine.tools captures the final resolved set.

local M = {}

-- Canonical list of shared CLI tools to load from shared/tools/.
-- Loaded via pcall so a broken individual tool does not block the rest.
local SHARED_TOOLS = {
  "tools.bash",
  "tools.brief",
  "tools.file_edit",
  "tools.file_read",
  "tools.file_write",
  "tools.git",
  "tools.glob",
  "tools.grep",
  "tools.local_search",
  "tools.multiedit",
  "tools.web_fetch",
  "tools.web_search",
  -- Ported from cli-agent (priority set: agentic loop, planning, search)
  "tools.todo_write",
  "tools.ask_user",
  "tools.agent",
  "tools.tool_search",
  "tools.snip",
  "tools.enter_plan_mode",
  "tools.exit_plan_mode",
  "tools.sleep",
  "tools.config_tool",
  "tools.send_message",
  -- NOTE: tools.verify_plan and tools.synthetic_output are intentionally
  -- omitted. The local jenova.gguf model treats them as cheap "I'm working"
  -- placeholders and emits them in place of real Read/Edit calls, which
  -- breaks file-traversal flows. Re-add only when running larger models.
}

function M.load_shared_tools()
  local ok, registry = pcall(require, "tools.registry")
  if not ok then
    vim.notify("jenova.agent.tools: tools.registry not found — run make sync-modules",
      vim.log.levels.ERROR, { title = "Jenova Agent" })
    return false
  end

  local loaded, failed = 0, 0
  for _, mod_name in ipairs(SHARED_TOOLS) do
    local mok, tool = pcall(require, mod_name)
    if mok and tool and tool.name and tool.call then
      registry.register(tool)
      loaded = loaded + 1
    else
      failed = failed + 1
      vim.notify(
        string.format("jenova.agent.tools: failed to load %s: %s", mod_name, tostring(tool)),
        vim.log.levels.WARN, { title = "Jenova Agent" })
    end
  end

  return loaded > 0
end

function M.register_overrides()
  local ok, registry = pcall(require, "tools.registry")
  if not ok then
    -- Fallback to absolute dotted path
    ok, registry = pcall(require, "jenova.agent.shared.tools.registry")
  end
  if not ok then
    vim.notify("jenova.agent.tools: registry not found — skipping overrides",
      vim.log.levels.WARN, { title = "Jenova Agent" })
    return
  end

  -- Read → buffer_read: returns live buffer content, falls back to disk.
  -- Schema must match shared/tools/file_read (file_path/offset/limit) or the
  -- model will silently send the wrong parameters.
  local r_ok, buffer_read = pcall(require, "jenova.agent.tools.buffer_read")
  if r_ok and buffer_read then registry.register(buffer_read) end

  -- Edit → buffer_edit: applies edits via vim.api, preserves undo history
  local e_ok, buffer_edit = pcall(require, "jenova.agent.tools.buffer_edit")
  if e_ok and buffer_edit then registry.register(buffer_edit) end

  -- Glob → buffer_glob: vim.fn.globpath-based recursive matcher. The shared
  -- tool's `find -path '*.lua'` fallback can't handle the ** patterns the
  -- model emits, so it always returned 0 matches in jvim.
  local g_ok, buffer_glob = pcall(require, "jenova.agent.tools.buffer_glob")
  if g_ok and buffer_glob then registry.register(buffer_glob) end

  -- LS → buffer_ls: tree-style directory listing. Without this the agent
  -- has no way to enumerate folder contents — only Glob, which requires
  -- the model to guess a pattern.
  local ls_ok, buffer_ls = pcall(require, "jenova.agent.tools.buffer_ls")
  if ls_ok and buffer_ls then registry.register(buffer_ls) end

  -- Buffers → list of currently open jvim buffers/tabs. Lets the agent
  -- answer questions like "the other files I have open" without guessing.
  local b_ok, buffer_list = pcall(require, "jenova.agent.tools.buffer_list")
  if b_ok and buffer_list then registry.register(buffer_list) end

  -- LSP → jvim-native: uses vim.lsp + vim.diagnostic instead of grep fallback
  local l_ok, lsp_tool = pcall(require, "jenova.agent.tools.lsp")
  if l_ok and lsp_tool then registry.register(lsp_tool) end

  -- AskUser → jvim-native: uses vim.ui.input (the cli-agent original calls
  -- io.read which would block jvim's event loop indefinitely).
  local a_ok, ask_user = pcall(require, "jenova.agent.tools.ask_user")
  if a_ok and ask_user then registry.register(ask_user) end
end

-- Convenience: load everything in the correct order.
function M.setup()
  M.load_shared_tools()
  M.register_overrides()
end

return M
