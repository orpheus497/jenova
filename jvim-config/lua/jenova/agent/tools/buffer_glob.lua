-- jenova/agent/tools/buffer_glob.lua
-- jvim-native Glob override.
--
-- The shared shared/tools/glob.lua targets the Rust jenova.fs FFI which
-- isn't present in jvim. Its `find` fallback uses `-path '*.lua'`, which
-- matches a single segment and silently returns 0 hits for the recursive
-- patterns the model usually emits ("**/*.lua"). This native version uses
-- vim.fn.glob with the magic-** suffix, then sorts newest-first to match
-- upstream cli-agent behaviour the model expects.

local paths = require("jenova.agent.utils.paths")

local M = {
  name = "Glob",
  description = "Find files by pattern (e.g. **/*.lua). Returns newest first.",
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Glob pattern" },
      path    = { type = "string", description = "Search root (default: .)" },
    },
    required = { "pattern" },
  },
}

function M.is_enabled()    return true end
function M.is_read_only()  return true end
function M.user_facing_name(input)
  return input and input.pattern and ("Glob: " .. input.pattern) or "Glob"
end
function M.check_permissions(_i, _c) return { allowed = true } end

local function expand(pattern, root)
  -- vim.fn.globpath understands `**` natively when called with the third
  -- "nosuf" arg = true and the fourth "list" arg = true.
  local list = vim.fn.globpath(root, pattern, true, true)
  if type(list) ~= "table" then return {} end
  return list
end

function M.call(args, context)
  local pattern = args.pattern
  if not pattern or pattern == "" then
    return { type = "error", error = "No pattern provided" }
  end

  local root = args.path
  if root and #root > 0 then
    root = paths.resolve(root, context and context.cwd)
  else
    root = (context and context.cwd) or vim.fn.getcwd()
  end
  if paths.is_restricted(root) then return paths.restricted_error(root) end

  local files = expand(pattern, root)

  -- Filter: drop directories, .jenova/.claude/.git noise, cap at 500.
  local filtered = {}
  for _, p in ipairs(files) do
    if vim.fn.isdirectory(p) == 0
       and not paths.is_restricted(p)
       and not p:find("/%.git/")
    then
      table.insert(filtered, p)
    end
  end

  -- Sort by mtime descending (newest first), like cli-agent.
  table.sort(filtered, function(a, b)
    local sa = vim.uv.fs_stat(a)
    local sb = vim.uv.fs_stat(b)
    local ma = sa and sa.mtime and sa.mtime.sec or 0
    local mb = sb and sb.mtime and sb.mtime.sec or 0
    return ma > mb
  end)

  if #filtered > 500 then
    local trimmed = {}
    for i = 1, 500 do trimmed[i] = filtered[i] end
    filtered = trimmed
  end

  if #filtered == 0 then
    return {
      type = "text",
      text = "No files matched: " .. pattern .. " (under " .. root .. ")",
      num_files = 0,
    }
  end

  return {
    type      = "text",
    text      = table.concat(filtered, "\n"),
    num_files = #filtered,
  }
end

return M
