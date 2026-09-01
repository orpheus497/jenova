-- jenova/agent/tools/buffer_grep.lua
-- jvim-native Grep tool. 
-- Searches live buffer content first (unsaved changes), then falls back to disk.

local paths = require("jenova.agent.utils.paths")

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
  local ok, regex = pcall(vim.regex, (insensitive and "\\c" or "") .. pattern)
  if not ok then return matches end

  for i, line in ipairs(lines) do
    if regex:match_str(line) then
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
      local in_target = (name == target or name:sub(1, #target + 1) == target .. "/")
      if in_target or target == "." or target == cwd then
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

  -- Short-circuit: if target is a specific file already covered by a loaded buffer, skip disk search
  local target_is_file = vim.fn.filereadable(target) == 1
  if target_is_file and seen_files[target] then
    if #results == 0 then return { type = "text", text = "No matches found." } end
    if #results > 500 then
      local total = #results
      results = { table.unpack(results, 1, 500) }
      table.insert(results, string.format("... [truncated %d more matches]", total - 500))
    end
    return { type = "text", text = table.concat(results, "\n") }
  end

  -- Native disk search via vim.fn.globpath + vim.fn.readfile — no subprocess.
  local ok_regex, regex = pcall(vim.regex, (insensitive and "\\c" or "") .. pattern)
  if not ok_regex then
    if #results > 0 then
      if #results > 500 then
        local total = #results
        results = { table.unpack(results, 1, 500) }
        table.insert(results, string.format("... [truncated %d more matches]", total - 500))
      end
      return { type = "text", text = table.concat(results, "\n") }
    end
    return { type = "error", error = "Invalid pattern: " .. pattern }
  end

  local glob_pat = args.glob and ("**/" .. args.glob) or "**/*"
  local disk_files = vim.fn.globpath(target, glob_pat, true, true)

  for _, fpath in ipairs(disk_files) do
    if #results >= 500 then break end
    local abs = vim.fn.fnamemodify(fpath, ":p")
    if vim.fn.isdirectory(abs) == 0 and not seen_files[abs] and not paths.is_restricted(abs) then
      local rel = vim.fn.fnamemodify(abs, ":~:.")
      local file_lines = vim.fn.readfile(abs, "", 10000)
      if type(file_lines) == "table" then
        local match_count = 0
        for lnum, line in ipairs(file_lines) do
          if regex:match_str(line) then
            match_count = match_count + 1
            if mode == "content" then
              table.insert(results, string.format("%s:%d:%s", rel, lnum, line))
            end
            if #results >= 500 then break end
          end
        end
        if match_count > 0 then
          if mode == "files_with_matches" then
            table.insert(results, rel)
          elseif mode == "count" then
            table.insert(results, rel .. ": " .. match_count)
          end
        end
      end
    end
  end

  if #results == 0 then return { type = "text", text = "No matches found." } end

  -- Cap output
  if #results > 500 then
    local total = #results
    results = { table.unpack(results, 1, 500) }
    table.insert(results, string.format("... [truncated %d more matches]", total - 500))
  end

  return { type = "text", text = table.concat(results, "\n") }
end

return M
