-- jenova/agent/tools/lsp_diag.lua
-- jvim-native tool for LSP/compiler diagnostics.

local M = {}

M.name = "LSP_Diag"
M.description = "Get diagnostics/errors for a file. Falls back to compiler linting for C files if no LSP."

M.parameters = {
  type = "object",
  properties = {
    file_path = { type = "string", description = "Target file (omit for all loaded buffers)" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name(input) return "LSP:Diagnostics" end
function M.check_permissions() return { allowed = true } end

local function resolve_buf(file_path)
  if not file_path or file_path == "" then return nil end
  local abs = vim.fn.fnamemodify(file_path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == abs or bname == file_path then
        return b
      end
    end
  end
  local ok, bn = pcall(vim.fn.bufadd, abs)
  if ok and bn > 0 then
    vim.fn.bufload(bn)
    return bn
  end
  return nil
end

function M.call(args)
  local diags = {}
  local buf = resolve_buf(args.file_path)
  
  if buf then
    diags = vim.diagnostic.get(buf)
  else
    diags = vim.diagnostic.get()
  end

  -- Fallback for C files
  if (#diags == 0) and args.file_path and args.file_path ~= "" and vim.fn.executable("cc") == 1 then
    local ext = args.file_path:match("%.([^.]+)$")
    if ext == "c" or ext == "h" then
      local abs = vim.fn.fnamemodify(args.file_path, ":p")
      local res = vim.system({ "cc", "-fsyntax-only", "-I.", "-Iinclude", abs }, { text = true }):wait()
      if res.code ~= 0 and res.stderr and res.stderr ~= "" then
        return { type = "text", text = "Compiler Diagnostics:\n" .. res.stderr }
      end
    end
  end

  if not diags or #diags == 0 then
    return { type = "text", text = "No diagnostics." }
  end

  local sev_name = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }
  local lines = {}
  table.sort(diags, function(a, b)
    if a.severity ~= b.severity then return a.severity < b.severity end
    return a.lnum < b.lnum
  end)

  for _, d in ipairs(diags) do
    local path = vim.api.nvim_buf_get_name(d.bufnr or 0)
    path = vim.fn.fnamemodify(path, ":~:.")
    local sev = sev_name[d.severity] or "?"
    table.insert(lines, string.format("%s:%d:%d  %s  %s",
      path, d.lnum + 1, d.col + 1, sev, d.message))
  end

  return { type = "text", text = table.concat(lines, "\n"), num_lines = #lines }
end

return M
