-- jenova/agent/init.lua
-- Bootstrap the embedded agent inside jvim.
--
-- Key responsibilities:
--   1. Install package.path shim so require("utils.http") etc. resolve to the
--      shared/ subtree at ~/.config/jvim/lua/jenova/agent/shared/.
--   2. Inject our vim.system HTTP provider into package.loaded["utils.http"]
--      BEFORE any shared module is loaded, so jenova_backend.lua picks it up.
--   3. Inject a vim.json wrapper for require("utils.json_fallback").
--   4. Inject a context.manager shim so engine uses vim.system for git queries
--      instead of io.popen, keeping the event loop free.
--   5. Call tools.setup() (loads shared tools + jvim overrides) BEFORE
--      QueryEngine.new() so the engine captures the complete tool set.
--   6. Provide an async M.query(prompt, opts) running QueryEngine in a
--      coroutine so vim.system HTTP calls can yield without blocking jvim.

local M = {}

-- Exposed so chat.lua can read agent activity state for UI indicators.
M._running  = false   -- true while a query coroutine is active
M._turn     = 0       -- increments each query
M._tool_use = nil     -- name of currently executing tool (or nil)

-- ── Path shim ────────────────────────────────────────────────────────────────

local function install_path_shim()
  local shared = vim.fn.stdpath("config") .. "/lua/jenova/agent/shared"

  if vim.fn.isdirectory(shared) == 0 then
    -- Fallback: try the runtime source tree (in-tree jvim build / dev mode)
    local src = debug.getinfo(1, "S").source:sub(2)
    local agent_dir = vim.fn.fnamemodify(src, ":h")
    shared = agent_dir .. "/shared"
  end

  local p = ";" .. shared .. "/?.lua;" .. shared .. "/?/init.lua"
  if not package.path:find(shared, 1, true) then
    package.path = package.path .. p
  end

  return shared
end

-- ── Shim injections ───────────────────────────────────────────────────────────

local function inject_shims()
  -- utils.http → vim.system provider (non-blocking inside coroutines)
  if not package.loaded["utils.http"] then
    local ok, prov = pcall(require, "jenova.agent.provider")
    if ok then
      package.loaded["utils.http"] = prov
    end
  end

  -- utils.json_fallback → thin wrapper around vim.json
  if not package.loaded["utils.json_fallback"] then
    package.loaded["utils.json_fallback"] = {
      stringify = function(v) return vim.json.encode(v) end,
      stringify_pretty = function(v) return vim.json.encode(v) end,
      parse = function(s)
        if type(s) ~= "string" or #s == 0 then return nil end
        local ok2, v = pcall(vim.json.decode, s)
        return ok2 and v or nil
      end,
    }
  end

  -- context.manager → vim-native shim (avoids io.popen git calls inside engine)
  -- The shared context.manager uses io.popen for git queries; here we replace
  -- the relevant fields with vim.system so they yield in our coroutine.
  if not package.loaded["context.manager"] then
    local function run_git(args)
      local result = vim.system(
        vim.list_extend({ "git" }, args),
        { text = true, cwd = vim.fn.getcwd() }
      ):wait()
      if result.code == 0 then
        return vim.trim(result.stdout or "")
      end
      return nil
    end

    local function is_git_repo()
      local r = vim.system({ "git", "rev-parse", "--is-inside-work-tree" },
        { text = true }):wait()
      return r.code == 0
    end

    package.loaded["context.manager"] = {
      get_system_context = function()
        return {
          platform     = "freebsd",
          os_version   = "",
          is_git_repo  = is_git_repo(),
          git_branch   = run_git({ "branch", "--show-current" }),
          git_status   = run_git({ "status", "--porcelain" }) or "(clean)",
        }
      end,
      get_user_context = function()
        return {
          shell    = vim.env.SHELL or "sh",
          username = vim.env.USER or vim.env.LOGNAME or "user",
        }
      end,
      get_directory_snapshot = function(cwd, max_lines)
        local result = vim.system({ "find", cwd, "-maxdepth", "3",
          "-not", "-path", "*/.git/*", "-not", "-name", "*.o",
          "-not", "-name", "*.a" }, { text = true }):wait()
        if result.code ~= 0 then return nil end
        local lines = vim.split(result.stdout or "", "\n", { plain = true })
        max_lines = max_lines or 200
        if #lines > max_lines then
          local kept = {}
          for i = 1, max_lines do kept[i] = lines[i] end
          table.insert(kept, string.format("... (%d more)", #lines - max_lines))
          return table.concat(kept, "\n")
        end
        return table.concat(lines, "\n")
      end,
      get_git_diff_stat = function()
        return run_git({ "diff", "--stat", "HEAD" })
      end,
      is_git_repository = is_git_repo,
      get_git_branch = function() return run_git({ "branch", "--show-current" }) end,
      get_git_status = function()
        return run_git({ "status", "--porcelain" }) or "(clean)"
      end,
      get_platform = function() return "freebsd" end,
      get_toolchain = function()
        local tools = {}
        for _, t in ipairs({ "cc", "make", "cmake", "cargo", "go", "node", "python3" }) do
          if vim.fn.executable(t) == 1 then table.insert(tools, t) end
        end
        return #tools > 0 and table.concat(tools, ", ") or nil
      end,
    }
  end

  -- utils.shell → simple POSIX quote helper (no io.popen needed)
  if not package.loaded["utils.shell"] then
    package.loaded["utils.shell"] = {
      quote = function(s)
        s = tostring(s)
        return "'" .. s:gsub("'", "'\\''") .. "'"
      end,
    }
  end
end

-- ── Permission UI shim ────────────────────────────────────────────────────────
-- The shared permissions manager prompts via io.write/io.read with ANSI colour.
-- That works in a real terminal, but inside jvim's chat buffer it is invisible
-- and io.read blocks the editor. We monkey-patch request_permission to use a
-- vim.ui.select picker instead, yielding the agent coroutine until the user
-- picks Yes/No/Always/Session. The rest of the manager (mode lookup, caches,
-- read-only tool whitelist) is reused unchanged.
local function patch_permissions()
  local ok, perms = pcall(require, "permissions.manager")
  if not ok or type(perms) ~= "table" then return end
  if perms._jvim_patched then return end
  perms._jvim_patched = true

  local function describe(tool_name, input)
    if type(input) ~= "table" then return tool_name end
    if tool_name == "Shell" or tool_name == "Bash" then
      return input.command and ("$ " .. tostring(input.command):sub(1, 200)) or tool_name
    elseif tool_name == "Write" then
      local size = input.content and (#input.content .. " bytes ") or ""
      return "write " .. size .. "→ " .. tostring(input.file_path or "?")
    elseif tool_name == "Edit" then
      return "edit " .. tostring(input.file_path or "?")
    elseif tool_name == "MultiEdit" then
      local n = type(input.edits) == "table" and tostring(#input.edits) or "?"
      return "multiedit (" .. n .. ") " .. tostring(input.file_path or "?")
    end
    for _, k in ipairs({ "file_path", "path", "command", "query", "url" }) do
      if type(input[k]) == "string" and #input[k] > 0 then
        return k .. ": " .. input[k]:sub(1, 120)
      end
    end
    return tool_name
  end

  perms.request_permission = function(tool_name, input, _context)
    perms._cache = perms._cache or {}

    -- Session-wide grant check (matches original semantics: a "session"
    -- decision allows every subsequent call of the same tool name).
    if perms._cache[tool_name .. ":*"] then
      return true, nil
    end

    local cache_key = perms.get_cache_key(tool_name, input)
    if perms._cache[cache_key] ~= nil then
      local cached = perms._cache[cache_key]
      if not cached then return false, "Permission denied (cached)" end
      return true, nil
    end

    local co = coroutine.running()
    if not co then
      -- Outside coroutine: fall back to a non-interactive deny so jvim never
      -- blocks on stdin. Action tools called from headless contexts must use
      -- /permissions auto.
      return false, "Permission required (no UI available)"
    end

    local detail = describe(tool_name, input)
    local title  = string.format("Allow %s?", tool_name)
    local prompt = title .. "\n" .. detail

    local choices = {
      "Yes — once",
      "No — deny",
      "Always — remember this exact call",
      "Session — allow " .. tool_name .. " for the rest of this session",
    }

    vim.schedule(function()
      vim.ui.select(choices, {
        prompt  = prompt,
        format_item = function(item) return item end,
      }, function(choice)
        local allowed, sticky_session, sticky_call
        if not choice or choice == choices[2] then
          allowed = false
        elseif choice == choices[1] then
          allowed = true
        elseif choice == choices[3] then
          allowed = true; sticky_call = true
        elseif choice == choices[4] then
          allowed = true; sticky_session = true
        else
          allowed = false
        end

        if sticky_call then
          perms._cache = perms._cache or {}
          perms._cache[cache_key] = true
        elseif sticky_session then
          perms._cache = perms._cache or {}
          perms._cache[tool_name .. ":*"] = true
        end

        pcall(perms.record_permission, tool_name, input, allowed)

        local ok_resume, err = coroutine.resume(co, allowed)
        if not ok_resume then
          vim.notify("permission resume failed: " .. tostring(err),
            vim.log.levels.ERROR, { title = "Jenova Agent" })
        end
      end)
    end)

    local allowed = coroutine.yield()
    if not allowed then
      return false, "Permission denied by user"
    end
    return true, nil
  end
end

-- ── Lazy singleton ────────────────────────────────────────────────────────────

local _engine = nil

local function get_engine()
  if _engine then return _engine end

  local shared = install_path_shim()
  inject_shims()

  if vim.fn.isdirectory(shared) == 0 then
    vim.notify(
      "jenova.agent: shared modules not found at " .. shared ..
      "\n  Run: make sync-modules && make install",
      vim.log.levels.ERROR, { title = "Jenova Agent" })
    return nil
  end

  -- Bootstrap the LLM provider registry. providers/base.lua is only the
  -- registry/manager — providers/init.lua is what actually loads and
  -- registers jenova_backend + llamacpp. Without this call, the registry
  -- stays empty and the manager fails with "All providers failed to
  -- initialize" the first time query_engine asks for a completion.
  local pok, providers = pcall(require, "providers.init")
  if pok and type(providers.init) == "function" then
    local iok, ierr = pcall(providers.init)
    if not iok then
      vim.notify("jenova.agent: provider init failed: " .. tostring(ierr),
        vim.log.levels.ERROR, { title = "Jenova Agent" })
    end
  else
    vim.notify("jenova.agent: failed to load providers.init: " .. tostring(providers),
      vim.log.levels.ERROR, { title = "Jenova Agent" })
  end

  -- Replace permissions.manager.request_permission with a vim.ui.select
  -- driven prompt that yields the agent coroutine instead of blocking on
  -- io.read. Must run AFTER the path shim is in place.
  patch_permissions()

  -- Load all shared CLI tools AND register jvim-native overrides FIRST.
  -- QueryEngine.new() calls tool_registry.build_api_tools() internally so the
  -- registry must be fully populated before the engine is constructed.
  local tools = require("jenova.agent.tools")
  tools.setup()

  local ok, QueryEngine = pcall(require, "engine.query_engine")
  if not ok then
    vim.notify(
      "jenova.agent: failed to load QueryEngine: " .. tostring(QueryEngine) ..
      "\n  Run: make sync-modules && make install",
      vim.log.levels.ERROR, { title = "Jenova Agent" })
    return nil
  end

  local context = require("jenova.agent.context")

  _engine = QueryEngine.new({
    system_prompt = context.build_system_prompt(),
    tools = {}, -- Suppress formal API tool block to save context for 3B model

    on_text = function(text)
      vim.schedule(function()
        M._emit_text(text)
      end)
    end,

    on_thinking = function(_text)
      vim.schedule(function()
        if M._thinking_cb then M._thinking_cb() end
      end)
    end,

    on_tool_use = function(tool_name, input)
      vim.schedule(function()
        M._tool_use = tool_name
        if M._tool_use_cb then M._tool_use_cb(tool_name, input) end
      end)
    end,

    on_tool_result = function(tool_name, result)
      vim.schedule(function()
        M._tool_use = nil
        if M._tool_result_cb then M._tool_result_cb(tool_name, result) end
      end)
    end,

    on_error = function(err)
      vim.schedule(function()
        M._tool_use = nil
        if M._error_cb then
          M._error_cb(tostring(err))
        else
          vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Jenova Agent" })
        end
      end)
    end,
  })

  return _engine
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Sinks set by chat.lua for each query call
M._text_sink     = nil   -- function(text)
M._done_sink     = nil   -- function(usage)
M._thinking_cb   = nil   -- function()         called each thinking token
M._tool_use_cb   = nil   -- function(name, input)
M._tool_result_cb = nil  -- function(name, result)
M._error_cb      = nil   -- function(msg)

function M._emit_text(text)
  if M._text_sink then M._text_sink(text) end
end

-- query(prompt, opts)
--   opts.on_text        function(text)
--   opts.on_done        function(usage)   usage = { input, output, cost }
--   opts.on_thinking    function()
--   opts.on_tool_use    function(name, input)
--   opts.on_tool_result function(name, result)
--   opts.on_error       function(msg)
function M.query(prompt, opts)
  opts = opts or {}
  if M._running then
    vim.notify("Agent is already running", vim.log.levels.WARN, { title = "Jenova Agent" })
    return
  end

  local engine = get_engine()
  if not engine then return end

  -- Refresh editor context each call
  local ctx_ok, context = pcall(require, "jenova.agent.context")
  if ctx_ok then engine.system_prompt = context.build_system_prompt() end

  -- Seed the shared app_state with jvim's actual working directory so the
  -- file/glob/grep tools resolve relative paths against the workspace
  -- instead of "." (which would be wherever jvim was launched from, or the
  -- empty string when AppState.get_cwd() falls through to its defaults).
  -- If the user is editing a file outside the launch cwd (very common with
  -- `jvim somefile.c`), fall back to the current buffer's directory so
  -- relative paths in the user's prompt resolve to the project they're
  -- actually working on.
  local as_ok, app_state = pcall(require, "state.app_state")
  if as_ok and app_state and app_state.set_cwd then
    local cwd = vim.fn.getcwd()

    -- Pick the most recent *real* source buffer to anchor the workspace
    -- on. The active buffer is often the jvim chat markdown (in
    -- ~/.local/state/jvim/jenova/chats/) which would mis-anchor cwd to
    -- the chat-state directory. Skip those, plus scratch/help/quickfix.
    local function is_workspace_buffer(b)
      if not vim.api.nvim_buf_is_loaded(b) then return false end
      local bt = vim.bo[b].buftype
      if bt ~= "" then return false end -- nofile/help/quickfix/terminal/etc.
      local n = vim.api.nvim_buf_get_name(b)
      if not n or n == "" then return false end
      
      -- Use the shared paths helper for robust restriction checks (.jenova, .claude, etc.)
      local paths_mod = require("utils.paths")
      if paths_mod.is_restricted(n) then return false end
      
      -- Also exclude standard nvim state/runtime paths that are not project source
      if n:match("/%.local/state/") or n:match("/%.local/share/") then return false end
      
      return vim.fn.filereadable(n) == 1
    end

    local cur = nil
    -- Try active buffer first.
    local active = vim.api.nvim_get_current_buf()
    if is_workspace_buffer(active) then
      cur = vim.api.nvim_buf_get_name(active)
    else
      -- Fall back to the most recently used loaded buffer.
      local best, best_ts = nil, -1
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if is_workspace_buffer(b) then
          local info = vim.fn.getbufinfo(b)[1]
          local lu = info and info.lastused or 0
          if lu > best_ts then best_ts = lu; best = b end
        end
      end
      if best then cur = vim.api.nvim_buf_get_name(best) end
    end

    if cur and cur ~= "" then
      local cur_dir = vim.fn.fnamemodify(cur, ":p:h")
      if cur_dir and not cur_dir:find(cwd, 1, true) then
        local markers = {
          ".git", "Makefile", "makefile", "CMakeLists.txt",
          "package.json", "pyproject.toml", "Cargo.toml", "go.mod",
          ".jenova",
        }
        local function find_root(start)
          local dir = start
          while dir and dir ~= "" and dir ~= "/" do
            for _, m in ipairs(markers) do
              if vim.fn.filereadable(dir .. "/" .. m) == 1
                or vim.fn.isdirectory(dir .. "/" .. m) == 1 then
                return dir
              end
            end
            local parent = vim.fn.fnamemodify(dir, ":h")
            if parent == dir then break end
            dir = parent
          end
          return nil
        end
        cwd = find_root(cur_dir) or cur_dir
      end
    end
    app_state.set_cwd(cwd)
  end

  M._text_sink      = opts.on_text
  M._done_sink      = opts.on_done
  M._thinking_cb    = opts.on_thinking
  M._tool_use_cb    = opts.on_tool_use
  M._tool_result_cb = opts.on_tool_result
  M._error_cb       = opts.on_error
  M._running        = true
  M._turn           = M._turn + 1
  M._tool_use       = nil

  local co = coroutine.create(function()
    local ok, err = pcall(function()
      engine:query(prompt)
    end)
    vim.schedule(function()
      M._running   = false
      M._tool_use  = nil
      M._text_sink = nil
      if not ok then
        local msg = tostring(err)
        if M._error_cb then M._error_cb(msg)
        else vim.notify(msg, vim.log.levels.ERROR, { title = "Jenova Agent" }) end
      end
      local usage = nil
      if engine.get_usage then
        local u = engine:get_usage()
        usage = {
          input  = u.input_tokens or 0,
          output = u.output_tokens or 0,
          cost   = u.total_cost_usd or 0,
        }
      end
      if M._done_sink then M._done_sink(usage) end
      M._done_sink      = nil
      M._thinking_cb    = nil
      M._tool_use_cb    = nil
      M._tool_result_cb = nil
      M._error_cb       = nil
    end)
  end)

  vim.defer_fn(function()
    coroutine.resume(co)
  end, 0)
end

-- Stop any in-flight generation.
function M.stop()
  if _engine then
    _engine.abort_controller = true
  end
  M._running  = false
  M._tool_use = nil
end

-- Reset session (clears message history, file cache, verifier state).
function M.clear()
  if _engine then
    _engine.messages    = {}
    _engine._file_cache = {}
    -- Reset file tracker
    local ft_ok, ft = pcall(require, "context.file_tracker")
    if ft_ok and ft and ft.reset then ft.reset() end
    -- Reset verifier attempt counters
    local tv_ok, tv = pcall(require, "services.tool_verifier")
    if tv_ok and tv and tv.reset then tv.reset() end
  end
  M._turn = 0
end

-- Destroy the engine so the next query rebuilds it.
function M.reset()
  _engine     = nil
  M._turn     = 0
  M._running  = false
  M._tool_use = nil
end

-- Return current message history for /history display
function M.get_messages()
  return _engine and _engine.messages or {}
end

-- Return last usage stats
function M.get_usage()
  if _engine and _engine.get_usage then
    return _engine:get_usage()
  end
  return { input_tokens = 0, output_tokens = 0, total_cost_usd = 0 }
end

return M
