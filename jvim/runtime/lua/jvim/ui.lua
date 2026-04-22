-- jvim.ui — first-party `vim.ui.input` and `vim.ui.select` overrides.
-- Replaces dressing.nvim / telescope-ui-select. Floating prompt for input,
-- floating list for select, both routed through jvim's standard UI palette.

local M = {}

local function close_floating(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

local function input(opts, on_confirm)
  opts = opts or {}
  local prompt = opts.prompt or "Input: "
  local default = opts.default or ""
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].bufhidden = "wipe"
  vim.fn.prompt_setprompt(buf, prompt)
  local W = math.min(80, math.max(40, math.floor(vim.o.columns * 0.5)))
  local row = math.floor((vim.o.lines - 3) / 2)
  local col = math.floor((vim.o.columns - W) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = W, height = 1,
    style = "minimal", border = "rounded",
    title = " " .. prompt:gsub(":%s*$", "") .. " ", title_pos = "left",
  })
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:JvimFinderPrompt"
  vim.fn.prompt_setcallback(buf, function(text)
    close_floating(win, buf)
    if on_confirm then on_confirm(text ~= "" and text or nil) end
  end)
  vim.fn.prompt_setinterrupt(buf, function()
    close_floating(win, buf)
    if on_confirm then on_confirm(nil) end
  end)
  if default ~= "" then
    vim.api.nvim_feedkeys(default, "n", false)
  end
  vim.cmd("startinsert!")
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    close_floating(win, buf)
    if on_confirm then on_confirm(nil) end
  end, { buffer = buf, nowait = true, silent = true })
end

local function select(items, opts, on_choice)
  opts = opts or {}
  local prompt = opts.prompt or "Select"
  local format = opts.format_item or tostring
  local lines = {}
  for i, it in ipairs(items) do
    lines[i] = string.format("%2d. %s", i, format(it))
  end
  local W = 0
  for _, l in ipairs(lines) do if #l > W then W = #l end end
  W = math.min(math.max(W + 4, 30), math.floor(vim.o.columns * 0.8))
  local H = math.min(#lines, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - H) / 2)
  local col = math.floor((vim.o.columns - W) / 2)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = W, height = H,
    style = "minimal", border = "rounded",
    title = " " .. prompt .. " ", title_pos = "left",
  })
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:JvimFinderPrompt,CursorLine:JvimFinderSelection"
  vim.wo[win].cursorline = true
  local function pick()
    local idx = vim.api.nvim_win_get_cursor(win)[1]
    close_floating(win, buf)
    if on_choice then on_choice(items[idx], idx) end
  end
  local function cancel()
    close_floating(win, buf)
    if on_choice then on_choice(nil, nil) end
  end
  vim.keymap.set("n", "<CR>", pick,   { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "o",    pick,   { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>",cancel, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q",    cancel, { buffer = buf, nowait = true, silent = true })
  for i = 1, math.min(#items, 9) do
    vim.keymap.set("n", tostring(i), function()
      close_floating(win, buf)
      if on_choice then on_choice(items[i], i) end
    end, { buffer = buf, nowait = true, silent = true })
  end
end

function M.setup()
  vim.ui.input = input
  vim.ui.select = select
end

return M
