-- jenova/agent/init.lua
-- Bootstrap the embedded agent inside jvim.
--
-- Key responsibilities:
--   1. Install package.path shim so require("utils.http") etc. resolve to the
--      shared/ subtree at ~/.config/jvim/lua/jenova/agent/shared/.
--   2. Inject our vim.system HTTP provider into package.loaded["utils.http"]
--      BEFORE any shared module is loaded, so jenova_backend.lua picks it up.
--   3. Inject a vim.json wrapper for require("utils.json_fallback") — we prefer
--      vim.json over the pure-Lua fallback inside the editor.
--   4. Provide an async M.query(prompt, opts) that runs QueryEngine in a
--      coroutine, yielding during HTTP calls and resuming via vim.schedule so
--      the editor stays responsive throughout.

local M = {}

-- ── Path shim ────────────────────────────────────────────────────────────────
-- shared/ lives at  <config>/lua/jenova/agent/shared/
-- After this shim, require("engine.query_engine") resolves to that subtree.

local function install_path_shim()
  local shared = vim.fn.stdpath("config") .. "/lua/jenova/agent/shared"

  -- Double-check the directory actually exists (will silently fail if
  -- sync-modules hasn't run yet, which gives a better error later).
  if vim.fn.isdirectory(shared) == 0 then
    -- Also try the runtime path (in-tree jvim build)
    local src = debug.getinfo(1, "S").source:sub(2)
    local agent_dir = vim.fn.fnamemodify(src, ":h")
    shared = agent_dir .. "/shared"
  end

  local p = ";"  .. shared .. "/?.lua;" .. shared .. "/?/init.lua"
  if not package.path:find(shared, 1, true) then
    package.path = package.path .. p
  end

  return shared
end

-- ── Shim injections ───────────────────────────────────────────────────────────

local function inject_shims()
  -- utils.http → our vim.system provider (must happen before any shared module
  -- loads jenova_backend, which in turn calls require("utils.http"))
  if not package.loaded["utils.http"] then
    local ok, prov = pcall(require, "jenova.agent.provider")
    if ok then
      package.loaded["utils.http"] = prov
    end
  end

  -- utils.json_fallback → thin wrapper around vim.json (faster in-process)
  if not package.loaded["utils.json_fallback"] then
    package.loaded["utils.json_fallback"] = {
      stringify = function(v) return vim.json.encode(v) end,
      stringify_pretty = function(v) return vim.json.encode(v) end,
      parse = function(s)
        if type(s) ~= "string" or #s == 0 then return nil end
        local ok, v = pcall(vim.json.decode, s)
        return ok and v or nil
      end,
    }
  end
end

-- ── Lazy singleton ────────────────────────────────────────────────────────────

local _engine = nil

local function get_engine()
  if _engine then return _engine end

  local shared = install_path_shim()
  inject_shims()

  -- Verify shared modules are present
  if vim.fn.isdirectory(shared) == 0 then
    vim.notify(
      "jenova.agent: shared modules not found at " .. shared ..
      "\n  Run: make sync-modules && make install",
      vim.log.levels.ERROR, { title = "Jenova Agent" })
    return nil
  end

  local ok, QueryEngine = pcall(require, "engine.query_engine")
  if not ok then
    vim.notify(
      "jenova.agent: failed to load QueryEngine: " .. tostring(QueryEngine) ..
      "\n  Run: make sync-modules && make install",
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

  -- Register jvim-native tool overrides (BufferRead, BufferEdit) on top of
  -- the shared registry so they take priority over the file-based CLI tools.
  tools.register_overrides()

  return _engine
end

-- ── Public API ────────────────────────────────────────────────────────────────

M._text_sink = nil   -- function(text)  — called per streamed token
M._done_sink = nil   -- function()      — called when query completes

function M._emit_text(text)
  if M._text_sink then M._text_sink(text) end
end

-- query(prompt, opts)
--   prompt  : string
--   opts    : { on_text=fn, on_done=fn }
--
-- Runs in a Lua coroutine so the HTTP calls inside QueryEngine can yield
-- (via provider.lua's coroutine.yield()) and resume via vim.schedule without
-- blocking the editor event loop.
function M.query(prompt, opts)
  opts = opts or {}

  local engine = get_engine()
  if not engine then return end

  -- Refresh editor context on each call.
  local ctx_ok, context = pcall(require, "jenova.agent.context")
  if ctx_ok then
    engine.system_prompt = context.build_system_prompt()
  end

  M._text_sink = opts.on_text
  M._done_sink = opts.on_done

  -- Wrap in a coroutine so provider.lua's vim.system callbacks can yield.
  local co = coroutine.create(function()
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
  end)

  -- Kick off on the next tick so the caller's stack is clean.
  vim.defer_fn(function()
    coroutine.resume(co)
  end, 0)
end

-- Stop any in-flight generation.
function M.stop()
  if _engine then
    _engine.abort_controller = true
  end
end

-- Destroy the engine so the next query rebuilds it with the current context.
function M.reset()
  _engine = nil
end

return M
