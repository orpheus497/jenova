-- ##Module purpose: Bottom-docked terminal workflow for the jvim IDE.
-- Provides toggle/new shell terminals and a Jenova agent terminal that all
-- open as a `botright split`. edgy.nvim in this runtime only manages the
-- left/right panel groups, so a bottom split does not collide with its panel
-- manager and no extra filter flag is required.
local M = {}

local DEFAULT_HEIGHT = 12

local state = {
  shell = { buf = nil },
  jenova = { buf = nil },
}

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function close_visible(buf)
  if not buf_valid(buf) then
    return false
  end

  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    return false
  end

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      -- pcall guards against `E444: Cannot close last window` when the
      -- terminal is the only remaining window in the tabpage.
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  return true
end

local function focus_visible(buf)
  if not buf_valid(buf) then
    return false
  end

  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    return false
  end

  local win = wins[1]
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.cmd("startinsert")
    return true
  end

  return false
end

local function set_terminal_keymaps(buf)
  local opts = { buffer = buf, silent = true }
  vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], opts)
  vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], opts)
  vim.keymap.set("t", "<C-j>", [[<C-\><C-n><C-w>j]], opts)
  vim.keymap.set("t", "<C-k>", [[<C-\><C-n><C-w>k]], opts)
  vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], opts)
  vim.keymap.set("n", "q", "<cmd>close<CR>", vim.tbl_extend("force", opts, { desc = "Close Terminal" }))
end

local function open_terminal(entry, opts)
  opts = opts or {}

  if not opts.new and focus_visible(entry.buf) then
    return entry.buf
  end

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.cmd("resize " .. tostring(opts.height or DEFAULT_HEIGHT))
  vim.wo[win].winfixheight = true

  if not opts.new and buf_valid(entry.buf) then
    vim.api.nvim_win_set_buf(win, entry.buf)
    vim.cmd("startinsert")
    return entry.buf
  end

  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  -- termopen() accepts either a string (parsed by the user's shell) or a list
  -- (executed without shell interpolation). We forward whichever form the
  -- caller provided so commands containing spaces or special characters in
  -- their path can be passed safely as a list, while interactive shells
  -- (vim.o.shell) continue to be invoked through the shell as a string.
  local cmd = opts.cmd or vim.o.shell
  local jobid = vim.fn.termopen(cmd, { cwd = opts.cwd or vim.fn.getcwd() })

  if jobid <= 0 then
    local cmd_display = type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
    vim.notify("Failed to start terminal: " .. cmd_display, vim.log.levels.ERROR, { title = "jvim" })
    -- Tear down the empty split + scratch buffer so a failed termopen does
    -- not leave a blank window for the user to clean up manually.
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    return nil
  end

  vim.bo[buf].bufhidden = "hide"
  -- Keep the docked terminal buffer out of `:bnext` / Telescope buffer pickers;
  -- it is managed exclusively through the toggle/new commands in this module.
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.b[buf].jvim_terminal_role = opts.role or "shell"
  set_terminal_keymaps(buf)

  entry.buf = buf
  vim.cmd("startinsert")
  return buf
end

local function jenova_root()
  local root = vim.fn.expand("$JENOVA_ROOT")
  if root ~= "" and root ~= "$JENOVA_ROOT" then
    return root
  end
  -- Preserve legacy behaviour for developers using the standard layout: prefer
  -- ~/Projects/jenova when it exists on disk so existing workflows continue
  -- without requiring $JENOVA_ROOT to be exported. Otherwise fall back to the
  -- user's current working directory rather than a hard-coded developer path
  -- so the command remains useful on every machine.
  local legacy = vim.fn.expand("~/Projects/jenova")
  if vim.fn.isdirectory(legacy) == 1 then
    return legacy
  end
  return vim.fn.getcwd()
end

function M.toggle_shell()
  if close_visible(state.shell.buf) then
    return
  end
  return open_terminal(state.shell, {
    cwd = vim.fn.getcwd(),
    role = "shell",
  })
end

function M.new_shell()
  -- Wipe the previous shell buffer if it's no longer visible so spawning a
  -- chain of "new" terminals does not leak orphaned, unlisted buffers that
  -- the user has no easy way to close.
  local prev = state.shell.buf
  if prev and vim.api.nvim_buf_is_valid(prev)
      and #vim.fn.win_findbuf(prev) == 0 then
    pcall(vim.api.nvim_buf_delete, prev, { force = true })
  end
  state.shell.buf = nil
  return open_terminal(state.shell, {
    cwd = vim.fn.getcwd(),
    role = "shell",
    new = true,
  })
end

function M.toggle_jenova()
  if close_visible(state.jenova.buf) then
    return
  end
  local root = jenova_root()
  -- Build an absolute path to the Jenova binary so the command does not rely
  -- on the terminal inheriting `root` as its working directory, and pass the
  -- argv as a list so any spaces in `root` are forwarded verbatim rather than
  -- being parsed by the shell.
  local sep = package.config:sub(1, 1)
  local bin = root .. sep .. "bin" .. sep .. "jenova"
  return open_terminal(state.jenova, {
    cwd = root,
    cmd = { bin },
    role = "jenova",
  })
end

return M
