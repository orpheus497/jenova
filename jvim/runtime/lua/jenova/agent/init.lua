-- jenova/agent/init.lua
-- Bootstrap the embedded agent inside jvim.
--
-- Installs a package.path shim so that cli-agent shared modules load under
-- the jenova.agent.shared.* namespace, then wires QueryEngine with jvim-native
-- callbacks (vim.schedule streaming, notify errors, tool badge in statusline).

local M = {}

-- ── Path shim ────────────────────────────────────────────────────────────────
-- Maps   require("utils.json_fallback")   →  jenova.agent.shared.utils.json_fallback
-- Maps   require("providers.base")        →  jenova.agent.shared.providers.base
-- etc.
--
-- The shared/ subtree is populated at build time by `make sync-modules` from
-- cli-agent/lua/.  jvim-native overrides live directly in jenova/agent/ and
-- take priority because this directory comes first in the searcher list.

local function install_path_shim()
  local runtime = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h")
  -- runtime = jvim/runtime/lua
  local shared = runtime .. "/jenova/agent/shared"
  local agent_root = runtime .. "/jenova/agent"

  -- Prepend agent root (for overrides) and shared (for cli-agent modules)
  local sep = package.config:sub(1, 1) == "\\" and "\\" or "/"
  local suffix = sep .. "?.lua;" .. sep .. "?" .. sep .. "init.lua;"

  package.path = agent_root .. suffix
    .. shared .. suffix
    .. package.path
end

-- ── Lazy singleton ────────────────────────────────────────────────────────────

local _engine = nil

local function get_engine()
  if _engine then return _engine end

  install_path_shim()

  local ok, QueryEngine = pcall(require, "jenova.agent.shared.engine.query_engine")
  if not ok then
    -- Fallback: try bare require after shim (shim already added shared/ to path)
    ok, QueryEngine = pcall(require, "engine.query_engine")
  end
  if not ok then
    vim.notify("jenova.agent: QueryEngine not found — run `make sync-modules`",
      vim.log.levels.ERROR, { title = "Jenova Agent" })
    return nil
  end

  local context = require("jenova.agent.context")
  local tools   = require("jenova.agent.tools")

  _engine = QueryEngine.new({
    system_prompt = context.build_system_prompt(),

    on_text = function(text)
      vim.schedule(function()
        M._emit_text(text)
      end)
    end,

    on_thinking = function(_text)
      vim.schedule(function()
        vim.api.nvim_echo({ { "⟳ thinking…", "Comment" } }, false, {})
      end)
    end,

    on_tool_use = function(tool_name, _input)
      vim.schedule(function()
        vim.api.nvim_echo({ { "⚙ " .. tool_name .. "…", "DiagnosticInfo" } }, false, {})
      end)
    end,

    on_tool_result = function(tool_name, _result)
      vim.schedule(function()
        vim.api.nvim_echo({ { "✓ " .. tool_name, "DiagnosticOk" } }, false, {})
      end)
    end,

    on_error = function(err)
      vim.schedule(function()
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Jenova Agent" })
      end)
    end,
  })

  -- Register jvim-native tool overrides (buffer read/edit/lsp) on top of the
  -- shared registry so they shadow the file-based CLI tools.
  tools.register_overrides()

  return _engine
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Callbacks set by the chat panel to receive streaming tokens and completion.
M._text_sink    = nil   -- function(text)  called per streamed token
M._done_sink    = nil   -- function()      called when query completes

function M._emit_text(text)
  if M._text_sink then M._text_sink(text) end
end

-- query(prompt, opts)
--   prompt  : string
--   opts    : { on_text=fn, on_done=fn, context_lines=table }
function M.query(prompt, opts)
  opts = opts or {}

  local engine = get_engine()
  if not engine then return end

  -- Refresh editor context on each call so the system prompt is always current.
  local context = require("jenova.agent.context")
  engine.system_prompt = context.build_system_prompt()

  M._text_sink = opts.on_text
  M._done_sink = opts.on_done

  -- Run in a vim.loop async handle so we don't block the event loop.
  vim.defer_fn(function()
    local ok, err = pcall(function()
      engine:query(prompt)
    end)
    vim.schedule(function()
      M._text_sink = nil
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Jenova Agent" })
      end
      if M._done_sink then M._done_sink() end
      M._done_sink = nil
    end)
  end, 0)
end

-- Stop any in-flight generation.
function M.stop()
  if _engine and _engine.abort_controller then
    _engine.abort_controller = true
  end
end

-- Destroy the engine so the next query rebuilds it (picks up new system prompt).
function M.reset()
  _engine = nil
end

return M
