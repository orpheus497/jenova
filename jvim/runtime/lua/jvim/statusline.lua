-- jvim.statusline — native global statusline.
-- Replaces nvim-lualine/lualine.nvim with no third-party dependency.
--
-- Sections (mirrors the prior lualine layout):
--   [mode] [branch · diff · diagnostics] [filename]                          [services][AI][encoding][filetype] [progress] [position]
--
-- Wired by `runtime/plugin/jvim_ui.lua`, which sets:
--   vim.o.laststatus = 3
--   vim.o.statusline = "%!v:lua.require('jvim.statusline').render()"

local M = {}

-- ##Section: branch cache. We avoid spawning `git` on every redraw by
-- caching one branch name per buffer file path, with a soft TTL refreshed on
-- BufEnter / FocusGained / DirChanged. `vim.b.gitsigns_head` is also honoured
-- as a free upgrade if/when the user later installs the gitsigns shim.
local _branch_by_root = {}      -- map: root -> { name = string, mtime = uv hr time }
local _branch_root_for_file = {} -- map: bufname -> root (cached)
local BRANCH_TTL_NS = 30 * 1e9   -- 30s

local function _git_root(bufname)
  if not bufname or bufname == "" then return nil end
  local cached = _branch_root_for_file[bufname]
  if cached ~= nil then return cached ~= "" and cached or nil end
  local dir = vim.fs and vim.fs.dirname and vim.fs.dirname(bufname)
              or vim.fn.fnamemodify(bufname, ":h")
  local found
  if vim.fs and vim.fs.find then
    local hits = vim.fs.find(".git", { upward = true, path = dir })
    found = hits and hits[1] or nil
  end
  local root = found and vim.fn.fnamemodify(found, ":h") or ""
  _branch_root_for_file[bufname] = root
  return root ~= "" and root or nil
end

local function _resolve_gitdir(root)
  -- In a normal repo `${root}/.git` is a directory; in worktrees and
  -- submodules it is a file containing `gitdir: <path>` (path may be
  -- relative to root). Return the absolute gitdir path, or nil.
  local dotgit = root .. "/.git"
  local stat = (vim.uv or vim.loop).fs_stat(dotgit)
  if not stat then return nil end
  if stat.type == "directory" then return dotgit end
  if stat.type ~= "file" then return nil end
  local ok, lines = pcall(vim.fn.readfile, dotgit, "", 1)
  if not ok or not lines or not lines[1] then return nil end
  local rel = lines[1]:match("^gitdir:%s*(.+)$")
  if not rel or rel == "" then return nil end
  if rel:sub(1, 1) == "/" then return rel end
  return root .. "/" .. rel
end

local function _read_branch(root)
  local gitdir = _resolve_gitdir(root)
  if not gitdir then return nil end
  local head_path = gitdir .. "/HEAD"
  local ok, lines = pcall(vim.fn.readfile, head_path)
  if not ok or not lines or not lines[1] then return nil end
  local ref = lines[1]:match("^ref:%s+refs/heads/(.+)$")
  if ref then return ref end
  -- detached HEAD: short SHA (only return if it actually looks like a SHA).
  local sha = lines[1]:match("^([0-9a-f]+)$")
  if sha then return sha:sub(1, 7) end
  return nil
end

local function branch()
  local head_var = vim.b.gitsigns_head
  if head_var and head_var ~= "" then return head_var end
  local bufname = vim.api.nvim_buf_get_name(0)
  local root = _git_root(bufname)
  if not root then return "" end
  local now = (vim.uv or vim.loop).hrtime()
  local entry = _branch_by_root[root]
  if entry and (now - entry.mtime) < BRANCH_TTL_NS then return entry.name end
  local name = _read_branch(root) or ""
  _branch_by_root[root] = { name = name, mtime = now }
  return name
end

-- ##Section: diagnostics counts (LSP).
local function diag_counts()
  local d = vim.diagnostic
  if not (d and d.get) then return 0, 0, 0, 0 end
  local sev = d.severity
  local function n(s) return #d.get(0, { severity = s }) end
  return n(sev.ERROR), n(sev.WARN), n(sev.INFO), n(sev.HINT)
end

-- ##Section: LSP attached client names.
local function lsp_clients()
  local fn = vim.lsp.get_clients or vim.lsp.get_active_clients
  if not fn then return "" end
  local clients = fn({ bufnr = 0 })
  if not clients or #clients == 0 then return "" end
  local names = {}
  for _, c in ipairs(clients) do names[#names + 1] = c.name end
  return table.concat(names, "/")
end

-- ##Section: mode → label + highlight group.
local MODE_MAP = {
  n      = { "NORMAL",   "JvimStatusMode"  },
  no     = { "O-PEND",   "JvimStatusMode"  },
  v      = { "VISUAL",   "JvimStatusModeV" },
  V      = { "V-LINE",   "JvimStatusModeV" },
  ["\22"] = { "V-BLOCK", "JvimStatusModeV" },
  s      = { "SELECT",   "JvimStatusModeV" },
  S      = { "S-LINE",   "JvimStatusModeV" },
  ["\19"] = { "S-BLOCK", "JvimStatusModeV" },
  i      = { "INSERT",   "JvimStatusModeI" },
  ic     = { "I-COMP",   "JvimStatusModeI" },
  R      = { "REPLACE",  "JvimStatusModeR" },
  Rv     = { "V-REPL",   "JvimStatusModeR" },
  c      = { "COMMAND",  "JvimStatusModeC" },
  cv     = { "EX",       "JvimStatusModeC" },
  r      = { "PROMPT",   "JvimStatusModeC" },
  rm     = { "MORE",     "JvimStatusModeC" },
  ["r?"] = { "CONFIRM",  "JvimStatusModeC" },
  ["!"]  = { "SHELL",    "JvimStatusModeT" },
  t      = { "TERM",     "JvimStatusModeT" },
}

local function mode_part()
  local m = vim.api.nvim_get_mode().mode
  local entry = MODE_MAP[m] or MODE_MAP[m:sub(1, 1)] or { m:upper(), "JvimStatusMode" }
  return string.format("%%#%s# %s %%*", entry[2], entry[1])
end

-- ##Section: jenova backend integration (best-effort, no hard dependency).
local function jenova_part()
  local mon_ok, monitor = pcall(require, "jenova.monitor")
  if mon_ok and monitor and monitor.service_icons and monitor.lualine_status then
    local icons = monitor.service_icons() or ""
    local status = monitor.lualine_status() or ""
    if icons ~= "" or status ~= "" then
      return string.format(" %s  %s ", icons, status)
    end
  end
  if vim.g.jenova_connected then return " AI:on " end
  return ""
end

-- ##Function: Render a single statusline line. Called by Neovim every redraw.
function M.render()
  local parts = {}
  parts[#parts + 1] = mode_part()

  local b = branch()
  if b ~= "" then
    parts[#parts + 1] = string.format("%%#JvimStatusBranch#  %s ", b)
  end

  local e, w, i, h = diag_counts()
  if e + w + i + h > 0 then
    local segs = { "%#JvimStatusInfo# " }
    if e > 0 then segs[#segs + 1] = string.format("%%#JvimStatusErr# %d ", e) end
    if w > 0 then segs[#segs + 1] = string.format("%%#JvimStatusWarn# %d ", w) end
    if h > 0 then segs[#segs + 1] = string.format("%%#JvimStatusHint# %d ", h) end
    parts[#parts + 1] = table.concat(segs)
  end

  -- Filename with modified marker. Use %f so :registers etc. report the same.
  parts[#parts + 1] = " %#JvimStatusFile#%f%#JvimStatusFileMod#%m%r%* "

  parts[#parts + 1] = "%="

  local jen = jenova_part()
  if jen ~= "" then
    parts[#parts + 1] = "%#JvimStatusInfo#" .. jen
  end

  local lsp = lsp_clients()
  if lsp ~= "" then
    parts[#parts + 1] = string.format("%%#JvimStatusInfo# %s ", lsp)
  end

  parts[#parts + 1] = "%#JvimStatusInfo# %{&fileencoding!=''?&fileencoding:&encoding} "
  parts[#parts + 1] = "%#JvimStatusInfo# %{&filetype} "
  parts[#parts + 1] = "%#JvimStatusInfo# %p%% "
  parts[#parts + 1] = "%#JvimStatusMode# %l:%c "

  return table.concat(parts)
end

-- ##Function: Cache invalidation hooks. Called from runtime/plugin/jvim_ui.lua.
function M.setup()
  vim.o.laststatus = 3
  vim.o.statusline = "%!v:lua.require('jvim.statusline').render()"

  local group = vim.api.nvim_create_augroup("JvimStatusline", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "DirChanged" }, {
    group = group,
    callback = function(ev)
      local name = ev.file or vim.api.nvim_buf_get_name(0)
      _branch_root_for_file[name] = nil
      -- Force a redraw of the global statusline.
      vim.cmd("redrawstatus")
    end,
  })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function() vim.cmd("redrawstatus") end,
  })
end

return M
