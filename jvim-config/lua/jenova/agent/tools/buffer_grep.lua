-- jenova/agent/tools/buffer_grep.lua
-- jvim-native override for the shared "Grep" tool.
-- Uses vim.system to call ripgrep or grep directly without blocking the event loop.

local paths = require("utils.paths")

local M = {
  name        = "Grep",
  description = "Search for a pattern in file contents. Supports regex patterns. Returns matching lines with file paths and line numbers.",
  parameters  = {
    type = "object",
    properties = {
      pattern     = { type = "string", description = "The regular expression pattern to search for" },
      path        = { type = "string", description = "File or directory to search in (default: current directory)" },
      glob        = { type = "string", description = "Glob pattern to filter files (e.g., '*.lua', '*.rs')" },
      output_mode = { type = "string", description = "Output mode: 'content' (matching lines), 'files_with_matches' (file paths only), 'count'" },
      ["-i"]      = { type = "boolean", description = "Case insensitive search" },
    },
    required = { "pattern" },
  },
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
  return input and input.pattern and ("Grep: " .. input.pattern) or "Grep"
end

function M.check_permissions(_input, _ctx) return { allowed = true } end

function M.call(args, context)
  local pattern = args.pattern
  if not pattern then return { type = "error", error = "pattern is required" } end
  
  local cwd = context and context.cwd or vim.fn.getcwd()
  local target_path = cwd
  if args.path then
    target_path = paths.resolve(args.path, cwd)
    if paths.is_restricted(target_path) then return paths.restricted_error(target_path) end
  end

  local output_mode = args.output_mode or "content"
  
  -- Try ripgrep first
  local rg_cmd = { "rg" }
  if output_mode == "content" then
    table.insert(rg_cmd, "-n")
    table.insert(rg_cmd, "--no-heading")
  elseif output_mode == "files_with_matches" then
    table.insert(rg_cmd, "--files-with-matches")
  elseif output_mode == "count" then
    table.insert(rg_cmd, "--count")
  end
  if args["-i"] then table.insert(rg_cmd, "-i") end
  if args.glob then
    table.insert(rg_cmd, "-g")
    table.insert(rg_cmd, args.glob)
  end
  table.insert(rg_cmd, pattern)
  table.insert(rg_cmd, target_path)

  local result = vim.system(rg_cmd, { text = true, cwd = cwd }):wait()
  
  -- 127 is command not found, or if result.code is non-zero and stderr mentions rg not found.
  if result.code == 127 or (result.code ~= 0 and result.stderr and result.stderr:match("not found")) then
    -- Fallback to grep
    local grep_cmd = { "grep", "-E" }
    if output_mode == "content" then
      table.insert(grep_cmd, "-rn")
    elseif output_mode == "files_with_matches" then
      table.insert(grep_cmd, "-r")
      table.insert(grep_cmd, "-l")
    elseif output_mode == "count" then
      table.insert(grep_cmd, "-r")
      table.insert(grep_cmd, "-c")
    end
    if args["-i"] then table.insert(grep_cmd, "-i") end
    if args.glob then
      table.insert(grep_cmd, "--include=" .. args.glob)
    end
    table.insert(grep_cmd, pattern)
    table.insert(grep_cmd, target_path)

    result = vim.system(grep_cmd, { text = true, cwd = cwd }):wait()
  end

  local output = result.stdout or ""
  if result.code ~= 0 and output == "" then
    if result.stderr and result.stderr ~= "" then
      return { type = "error", error = "Grep failed: " .. result.stderr }
    else
      return { type = "text", text = "No matches found." }
    end
  end
  
  -- Cap output
  local lines = vim.split(output, "\n", { plain = true })
  if #lines > 500 then
    local capped = {}
    for i = 1, 500 do table.insert(capped, lines[i]) end
    table.insert(capped, "... [truncated " .. (#lines - 500) .. " more lines]")
    output = table.concat(capped, "\n")
  end
  if #output > 50000 then
    output = output:sub(1, 50000) .. "\n... [truncated by byte limit]"
  end

  return { type = "text", text = output }
end

return M
