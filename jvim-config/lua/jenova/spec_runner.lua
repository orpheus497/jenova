-- jenova/spec_runner.lua
-- Minimal native runner for lazy.nvim-style plugin spec tables.
--
-- All plugins live under jvim/runtime/pack/jenova/start/ and are auto-loaded
-- by Neovim's native package system, so we don't need a real plugin manager.
-- We just need to honour each spec's init/config/opts/keys/cmd/event entries.
--
-- Supported keys (subset of lazy.nvim spec):
--   init         function          run before plugin loads (we run it now)
--   config       function|true     run after plugin loads (we run it now)
--   opts         table             passed to require(name).setup(opts) when
--                                  config is missing or true
--   keys         { lhs, rhs, mode, desc } | { lhs, fn, desc }
--   cmd          string|table      user commands that lazily load the plugin
--                                  (we just register a thin wrapper)
--   event        string|table      lazy event triggers (autocmd-based)
--   ft           string|table      filetype triggers
--   dependencies (ignored — pack/start order handles load order)
--
-- Anything else is silently ignored.

local M = {}

local function plugin_main_module(name)
  -- Strip "user/" prefix and ".nvim"/.vim suffix to get a plausible
  -- require() module name.
  if not name then return nil end
  local short = name:match("[^/]+$") or name
  short = short:gsub("%.nvim$", ""):gsub("%.vim$", "")
  short = short:gsub("%-", "_"):lower()
  return short
end

local function call_setup(spec)
  local mod = plugin_main_module(spec[1] or spec.name)
  if not mod then return end
  local ok, m = pcall(require, mod)
  if not ok or type(m) ~= "table" or type(m.setup) ~= "function" then return end
  pcall(m.setup, spec.opts or {})
end

local function apply_keys(keys)
  if type(keys) ~= "table" then return end
  for _, k in ipairs(keys) do
    if type(k) == "table" and k[1] then
      local mode = k.mode or "n"
      local rhs  = k[2]
      local opts = { desc = k.desc, silent = true }
      if rhs then vim.keymap.set(mode, k[1], rhs, opts) end
    end
  end
end

local function apply_cmd(cmds, loader)
  if type(cmds) == "string" then cmds = { cmds } end
  if type(cmds) ~= "table" then return end
  for _, c in ipairs(cmds) do
    pcall(vim.api.nvim_create_user_command, c, function(args)
      if loader then loader() end
      vim.cmd(c .. " " .. (args.args or ""))
    end, { nargs = "*" })
  end
end

local function apply_event(events, loader)
  if not events or not loader then return end
  if type(events) == "string" then events = { events } end
  -- Translate lazy.nvim-only synthetic events to real autocmd events.
  local translated = {}
  for _, e in ipairs(events) do
    if e == "VeryLazy" or e == "User VeryLazy" then
      table.insert(translated, "VimEnter")
    else
      table.insert(translated, e)
    end
  end
  vim.api.nvim_create_autocmd(translated, { once = true, callback = loader })
end

local function apply_ft(fts, loader)
  if not fts or not loader then return end
  if type(fts) == "string" then fts = { fts } end
  vim.api.nvim_create_autocmd("FileType", {
    pattern = fts, once = true, callback = loader,
  })
end

local function run_spec(spec)
  if type(spec) ~= "table" then return end

  local loaded = false
  local function load_now()
    if loaded then return end
    loaded = true
    if type(spec.config) == "function" then
      pcall(spec.config, spec, spec.opts or {})
    elseif spec.config == true or (spec.opts and spec.config == nil) then
      call_setup(spec)
    end
  end

  if type(spec.init) == "function" then pcall(spec.init, spec) end

  apply_keys(spec.keys)
  apply_cmd(spec.cmd, load_now)
  apply_event(spec.event, load_now)
  apply_ft(spec.ft, load_now)

  -- No lazy trigger? Load eagerly.
  if not (spec.event or spec.cmd or spec.ft or spec.keys) then
    load_now()
  end
end

-- Run a spec module. The module typically returns a list of specs (lazy
-- syntax) but may also return a single spec table.
function M.run(mod_name)
  local ok, spec_or_list = pcall(require, mod_name)
  if not ok then
    vim.notify(("spec_runner: failed to load %s: %s"):format(mod_name,
      tostring(spec_or_list)), vim.log.levels.WARN)
    return
  end
  if type(spec_or_list) ~= "table" then return end
  -- List of specs?
  if spec_or_list[1] and (type(spec_or_list[1]) == "table"
      or type(spec_or_list[1]) == "string") then
    for _, s in ipairs(spec_or_list) do
      if type(s) == "table" then run_spec(s) end
    end
  else
    run_spec(spec_or_list)
  end
end

return M
