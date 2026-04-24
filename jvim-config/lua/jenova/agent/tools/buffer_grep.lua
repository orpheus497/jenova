-- jenova/agent/tools/buffer_grep.lua
-- jvim-native Grep tool. 
-- Searches live buffer content first (unsaved changes), then falls back to disk.

local paths = require("utils.paths")

local M = {
  name = "Grep",
  description = "Regex search in workspace. Searches live buffers first, then disk. Returns paths and line numbers.",
  parameters = {
    type = "object",
    properties = {
      pattern     = { type = "string", description = "Regex pattern" },
      path        = { type = "string", description = "Target directory/file (default: .)" },
      glob        = { type = "string", description = "File filter (e.g. *.lua)" },
      output_mode = { enum = {"content", "files_with_matches", "count"}, default = "content" },
      ["-i"]      = { type = "boolean", description = "Case-insensitive" },
    },
    required = { "pattern" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name(input) return "Grep: " .. (input and input.pattern or "?") end
function M.check_permissions() return { allowed = true } end

local function match_buffer(buf, pattern, insensitive)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local matches = {}
  local p = pattern
  if insensitive then p = pattern:lower() end

  for i, line in ipairs(lines) do
    local l = insensitive and line:lower() or line
    if l:find(p) then
      table.insert(matches, { lnum = i, text = line })
    end
  end
  return matches
end

function M.call(args, context)
  local pattern = args.pattern
  local cwd = context and context.cwd or vim.fn.getcwd()
  local target = args.path and paths.resolve(args.path, cwd) or cwd
  local mode = args.output_mode or "content"
  local insensitive = args["-i"] or false

  local results = {}
  local seen_files = {}

  -- 1. Search live buffers first
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name:find(target, 1, true) then
        local matches = match_buffer(b, pattern, insensitive)
        if #matches > 0 then
          seen_files[name] = true
          local rel = vim.fn.fnamemodify(name, ":~:.")
          if mode == "files_with_matches" then
            table.insert(results, rel)
          elseif mode == "count" then
            table.insert(results, rel .. ": " .. #matches)
          else
            for _, m in ipairs(matches) do
              table.insert(results, string.format("%s:%d:%s", rel, m.lnum, m.text))
            end
          end
        end
      end
    end
  end

  local rg_cmd = { "rg", "-n", "--no-heading" }
  if mode == "files_with_matches" then rg_cmd = { "rg", "-l" }
  elseif mode == "count" then rg_cmd = { "rg", "-c" } end
  if insensitive then table.insert(rg_cmd, "-i") end
  if args.glob then table.insert(rg_cmd, "-g"); table.insert(rg_cmd, args.glob) end
  table.insert(rg_cmd, pattern)
  table.insert(rg_cmd, target)

  -- Wait with a 5-second timeout to prevent editor stalls
  local obj = vim.system(rg_cmd, { text = true, cwd = cwd })
  local res = obj:wait(5000)

  if res.code == 0 and res.stdout then
    for _, line in ipairs(vim.split(res.stdout, "\n", { plain = true })) do
      if line ~= "" then
        local fname = line:match("^([^:]+)")
        local abs = vim.fn.fnamemodify(fname, ":p")
        if not seen_files[abs] then
          table.insert(results, line)
        end
      end
    end
  elseif res.signal ~= 0 or res.code ~= 0 then
    if res.signal == 15 or res.signal == 9 then
      return { type = "error", error = "Grep timed out after 5 seconds." }
    end
  end

  if #results == 0 then return { type = "text", text = "No matches found." } end
  
  -- Cap output
  if #results > 500 then
    local total = #results
    results = { unpack(results, 1, 500) }
    table.insert(results, string.format("... [truncated %d more matches]", total - 500))
  end

  return { type = "text", text = table.concat(results, "\n") }
end

return M
