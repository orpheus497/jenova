-- jvim.messages — capture :messages history into the native notify queue.
-- This is the small piece of noice we still need: it lets the builtin
-- echo/echom flow be visible in jvim.notify popups (so the cmdline
-- doesn't clobber long messages and we can review them later).
--
-- Strategy: leave Vim's own cmdline-as-printer alone (we don't replace
-- the cmdline UI), but proxy `vim.notify` through jvim.notify. Provide
-- :JvimMessages to scroll back through captured notifications.

local M = {}

function M.setup()
  local notify = require("jvim.notify")
  -- Switch the default notifier so plugins / LSP / diagnostics use us.
  vim.notify = function(msg, level, opts) notify.notify(msg, level, opts) end
  -- :messages mirror — captures any echom output via VimEnter + a once-per-second
  -- diff against the cached history. Cheap because messages don't change often.
  local last_seen = ""
  local function poll()
    local ok, hist = pcall(vim.api.nvim_exec2, "messages", { output = true })
    if not ok or not hist or not hist.output then return end
    local out = hist.output
    if out == last_seen or out == "" then return end
    -- Compute new tail since last poll (everything after the last_seen prefix).
    local tail
    if last_seen ~= "" and out:sub(1, #last_seen) == last_seen then
      tail = out:sub(#last_seen + 1)
    else
      -- History truncated or rolled — show the last 5 lines.
      local lines = vim.split(out, "\n", { plain = true })
      tail = table.concat({ unpack(lines, math.max(1, #lines - 4)) }, "\n")
    end
    last_seen = out
    tail = tail:gsub("^[\n\r]+", ""):gsub("[\n\r]+$", "")
    if tail ~= "" then
      -- Heuristic: classify by keyword.
      local lvl = vim.log.levels.INFO
      if tail:lower():match("error") then lvl = vim.log.levels.ERROR
      elseif tail:lower():match("warning") then lvl = vim.log.levels.WARN end
      notify.notify(tail, lvl, { title = "messages" })
    end
  end
  local timer = (vim.uv or vim.loop).new_timer()
  if timer then
    timer:start(2000, 2000, vim.schedule_wrap(poll))
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function() pcall(function() timer:close() end) end,
      once = true,
    })
  end
end

return M
