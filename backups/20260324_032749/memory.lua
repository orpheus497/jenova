-- memory.lua: Session memory, error tracking, project context for coder-agent
-- All file-based, no external dependencies

local json = require("json")

local memory = {}

local CODER_DIR = ".coder"
local SESSION_LOG = CODER_DIR .. "/session.jsonl"
local NOTES_FILE = CODER_DIR .. "/notes.md"
local ERROR_FILE = CODER_DIR .. "/errors.jsonl"

-------------------------------------------------------------------------------
-- Ensure .coder directory exists
-------------------------------------------------------------------------------
function memory.init()
  os.execute("mkdir -p " .. CODER_DIR)
end

-------------------------------------------------------------------------------
-- Append a structured entry to the session log
-------------------------------------------------------------------------------
function memory.log(entry_type, content)
  local entry = {
    ts = os.time(),
    type = entry_type,
    data = content,
  }
  local f = io.open(SESSION_LOG, "a")
  if f then
    f:write(json.encode(entry) .. "\n")
    f:close()
  end
end

-------------------------------------------------------------------------------
-- Log an error with context
-------------------------------------------------------------------------------
function memory.log_error(tool_name, args_summary, error_msg)
  local entry = {
    ts = os.time(),
    tool = tool_name,
    args = args_summary,
    error = error_msg,
  }
  local f = io.open(ERROR_FILE, "a")
  if f then
    f:write(json.encode(entry) .. "\n")
    f:close()
  end
end

-------------------------------------------------------------------------------
-- Get the last N errors
-------------------------------------------------------------------------------
function memory.get_errors(n)
  n = n or 5
  local lines = {}
  local f = io.open(ERROR_FILE, "r")
  if not f then return {} end
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  local result = {}
  local start = math.max(1, #lines - n + 1)
  for i = start, #lines do
    local ok, entry = pcall(json.decode, lines[i])
    if ok then
      result[#result + 1] = entry
    end
  end
  return result
end

-------------------------------------------------------------------------------
-- Format recent errors for injection into system prompt
-------------------------------------------------------------------------------
function memory.format_errors_for_prompt(n)
  local errors = memory.get_errors(n or 3)
  if #errors == 0 then return "" end
  local parts = { "\n## Recent Errors (learn from these)" }
  for _, e in ipairs(errors) do
    parts[#parts + 1] = string.format(
      "- Tool `%s` with args `%s`: %s",
      e.tool or "?", e.args or "?", e.error or "?"
    )
  end
  return table.concat(parts, "\n")
end

-------------------------------------------------------------------------------
-- Get project file tree (cached per session)
-------------------------------------------------------------------------------
local cached_tree = nil

function memory.get_project_tree(root, max_depth)
  if cached_tree then return cached_tree end
  root = root or "."
  max_depth = max_depth or 3
  local cmd = string.format(
    "find %s -maxdepth %d -type f -not -path '*/.git/*' -not -path '*/.coder/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -not -name '*.gguf' -not -name '*.bin' 2>/dev/null | head -200 | sort",
    root, max_depth
  )
  local p = io.popen(cmd)
  local output = p:read("*a")
  p:close()
  cached_tree = output
  return cached_tree
end

function memory.invalidate_tree_cache()
  cached_tree = nil
end

-------------------------------------------------------------------------------
-- Read persistent notes
-------------------------------------------------------------------------------
function memory.get_notes()
  local f = io.open(NOTES_FILE, "r")
  if not f then return "" end
  local content = f:read("*a")
  f:close()
  return content
end

-------------------------------------------------------------------------------
-- Write persistent notes
-------------------------------------------------------------------------------
function memory.save_notes(content)
  local f = io.open(NOTES_FILE, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

-------------------------------------------------------------------------------
-- Build context string for system prompt injection
-------------------------------------------------------------------------------
function memory.format_for_prompt()
  local parts = {}

  local tree = memory.get_project_tree()
  if tree and tree ~= "" then
    parts[#parts + 1] = "\n## Project Files\n```\n" .. tree .. "```"
  end

  local errors_str = memory.format_errors_for_prompt(3)
  if errors_str ~= "" then
    parts[#parts + 1] = errors_str
  end

  local notes = memory.get_notes()
  if notes ~= "" then
    parts[#parts + 1] = "\n## Your Notes\n" .. notes
  end

  return table.concat(parts, "\n")
end

return memory
