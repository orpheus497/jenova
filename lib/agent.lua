#!/usr/bin/env luajit
-- coder-agent: Agentic coding assistant with shell/file access
-- Uses llama-server's OpenAI-compatible API with tool calling
--
-- Architecture notes (do not remove):
-- * Qwen2.5-Coder-14B returns tool calls as text in msg.content.
--   Extracted via fallback parser (Stage 2) or code-block interceptor (Stage 3).
--   The 14B model outputs {"arguments":{...},"name":"..."} (reversed key order).
-- * edit_file exists because write_file requires the model to regenerate
--   the entire file as JSON content, which can exceed generation timeout.
--   edit_file only needs the old/new snippet.

local script_dir = arg[0]:match("^(.*)/") or "."
local coder_root = os.getenv("CODER_ROOT") or script_dir:match("^(.*)/lib$") or script_dir .. "/.."
package.path = script_dir .. "/?.lua;" .. package.path

local json = require("json")
local http = require("http")
local memory = require("memory")
local search = require("search")
local embed = require("embed")

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------
local API_URL   = os.getenv("CODER_API_URL") or "http://127.0.0.1:8080"
local ENDPOINT  = API_URL .. "/v1/chat/completions"
local MODEL     = "qwen2.5-coder"
local MAX_TURNS = tonumber(os.getenv("CODER_MAX_TURNS")) or 25
local DEBUG     = os.getenv("CODER_DEBUG") == "1"
local HOME      = os.getenv("HOME") or "/home/orpheus497"
local CWD       = nil  -- set in main()
local HTTP_TIMEOUT = tonumber(os.getenv("CODER_TIMEOUT")) or 300
local MAX_ACTIONS  = 20

-- Per-turn state
local files_written_this_turn = {}
local files_read_this_turn    = {}   -- path -> content (cache for edit_file)
local last_read_path          = nil
local last_read_content       = nil
local consecutive_same_tool   = { name = nil, path = nil, count = 0 }
local edit_fails_this_turn    = {}  -- path -> count of failed edits

-------------------------------------------------------------------------------
-- Colors + visual symbols
-------------------------------------------------------------------------------
local C = {
  reset   = "\27[0m",  bold    = "\27[1m",  dim     = "\27[2m",
  red     = "\27[31m", green   = "\27[32m", yellow  = "\27[33m",
  blue    = "\27[34m", cyan    = "\27[36m", magenta = "\27[35m",
  white   = "\27[37m",
}

local ICON = {
  think = "◐", read = "◉", write = "◈", edit = "◇", shell = "⚡",
  search = "◎", list = "◇", ok = "✓", err = "✗", warn = "⚠",
  turn = "→", nudge = "↻", backup = "◆",
}

-------------------------------------------------------------------------------
-- Spinner
-------------------------------------------------------------------------------
local SPINNER_FRAMES = { "◐", "◓", "◑", "◒" }
local spinner_active = false

local function spinner_start(label)
  spinner_active = true
  io.write(C.cyan .. "  " .. SPINNER_FRAMES[1] .. " " .. (label or "thinking") .. C.reset)
  io.flush()
end

local function spinner_stop()
  if spinner_active then
    io.write("\r\27[K")
    io.flush()
    spinner_active = false
  end
end

-------------------------------------------------------------------------------
-- Status helpers
-------------------------------------------------------------------------------
local function status(icon, color, msg)
  io.write(color .. "  " .. icon .. " " .. C.reset .. msg .. "\n")
  io.flush()
end

local function status_turn(turn_num, name)
  local ic = ({ read_file=ICON.read, write_file=ICON.write, shell=ICON.shell,
    search_files=ICON.search, list_dir=ICON.list, edit_file=ICON.edit })[name] or ICON.turn
  io.write(C.yellow.."  "..ICON.turn.." "..C.reset..C.dim.."["..turn_num.."/"..MAX_TURNS.."] "..C.reset..C.cyan..C.bold..ic.." "..name..C.reset.."\n")
  io.flush()
end

-------------------------------------------------------------------------------
-- Path resolution
-- Handles: relative, ~/, absolute (with auto-fix for missing project subdir)
-------------------------------------------------------------------------------
local function resolve_path(p)
  if not p then return p end
  -- Strip surrounding quotes the model sometimes adds
  p = p:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
  if p:sub(1, 2) == "~/" then
    return HOME .. p:sub(2)
  elseif p == "~" then
    return HOME
  elseif p:sub(1, 1) ~= "/" then
    return ((CWD or ".") .. "/" .. p):gsub("/%./", "/")
  end
  -- Absolute path: verify it exists
  local f = io.open(p, "r")
  if f then f:close(); return p end
  -- Auto-fix: model may drop project subdir
  local basename = p:match("([^/]+)$")
  if basename and CWD then
    local try = CWD .. "/" .. basename
    local tf = io.open(try, "r")
    if tf then
      tf:close()
      status(ICON.warn, C.yellow, C.yellow.."path fixed "..C.reset..C.dim..p.." → "..try..C.reset)
      return try
    end
  end
  return p
end

-------------------------------------------------------------------------------
-- Shell safety
-------------------------------------------------------------------------------
local DESTRUCTIVE_PATTERNS = {
  "^rm%s", "^rm$", "^mv%s", "^chmod%s", "^chown%s", "^dd%s", "^mkfs",
  "^rmdir%s", "^truncate%s", "^sed%s.*%-i", "^perl%s.*%-[ip]",
  "^git%s+reset%s+%-%-hard", "^git%s+clean%s+%-[fd]",
  "^pkill%s", "^kill%s", "^killall%s",
}

local function is_destructive_shell(cmd)
  local trimmed = cmd:match("^%s*(.-)%s*$")
  for _, pat in ipairs(DESTRUCTIVE_PATTERNS) do
    if trimmed:find(pat) then return true end
  end
  for segment in trimmed:gmatch("|%s*(%S+)") do
    for _, pat in ipairs(DESTRUCTIVE_PATTERNS) do
      if segment:find(pat) then return true end
    end
  end
  return false
end

local function confirm_action(action_type, detail)
  io.write("\n"..C.yellow..C.bold.."  "..ICON.warn.." [confirm] "..C.reset..action_type.."\n")
  io.write(C.dim.."  "..detail..C.reset.."\n")
  io.write(C.bold.."  1"..C.reset.."=yes  "..C.bold.."2"..C.reset.."=no  "..C.bold.."3"..C.reset.."=suggest\n")
  io.write(C.bold.."  > "..C.reset); io.flush()
  local choice = io.read("*l")
  if not choice then return "no", nil end
  choice = choice:match("^%s*(.-)%s*$")
  if choice == "1" or choice:lower() == "y" or choice:lower() == "yes" then return "yes", nil
  elseif choice == "3" then
    io.write(C.bold.."  suggestion> "..C.reset); io.flush()
    return "suggest", io.read("*l")
  else return "no", nil end
end

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------
local function dbg(label, data)
  if not DEBUG then return end
  io.write(C.magenta.."[DBG "..label.."] "..C.reset)
  if type(data) == "string" then io.write(data:sub(1,2000).."\n")
  else io.write(json.encode(data):sub(1,2000).."\n") end
end

-------------------------------------------------------------------------------
-- System prompt
-- DESIGN: Keep compact — every token costs model reasoning capacity.
-- Show-by-example > explain-by-rules.
-------------------------------------------------------------------------------
local rag_context = ""

local function build_system_prompt()
  local parts = {}
  parts[#parts+1] = "You are coder, an autonomous coding agent on FreeBSD. CWD: " .. (CWD or ".")
  parts[#parts+1] = [[
You have these tools — call ONE per response:

shell(command)       — Run a shell command. Use for compiling, checking headers, tests.
read_file(path)      — Read a file.
edit_file(path, old, new) — Replace exact text in a file.
write_file(path, content) — Create/overwrite a file (use edit_file for changes).
list_dir(path)       — List directory contents.
search_files(query, top_k) — Search project files by keyword.
think(thought)       — Reason about a problem (not shown to user).

To call a tool, respond ONLY with:
```json
{"name": "tool_name", "arguments": {"arg": "value"}}
```

WORKFLOW: read_file first, shell to diagnose/compile, edit_file to fix ALL issues at once, shell to verify. Repeat until clean, then report in 1-2 sentences.

RULES:
- NEVER narrate or explain — just call tools.
- NEVER use headers/types/APIs you haven't verified exist. CHECK FIRST with shell.
- Fix ALL errors in one edit, not one at a time.
- Use edit_file for changes, write_file ONLY for new files.
- Use relative paths. This is FreeBSD (no apt, use pkg).
- If edit fails, read_file to see current content, then retry.]]

  -- Inject recent errors so model learns from past mistakes
  local errors_str = memory.format_errors_for_prompt(5)
  if errors_str ~= "" then parts[#parts+1] = errors_str end

  if rag_context ~= "" then parts[#parts+1] = rag_context end
  local tree = memory.get_project_tree()
  if tree and tree ~= "" then parts[#parts+1] = "\nFiles:\n" .. tree end
  return table.concat(parts, "\n")
end

-------------------------------------------------------------------------------
-- Tool definitions (OpenAI format)
-------------------------------------------------------------------------------
local TOOLS = {
  { type = "function", ["function"] = {
    name = "shell", description = "Run a shell command. Use for: compiling (cc -fsyntax-only), checking installed headers (ls /usr/include/), running tests, pkg-config queries.",
    parameters = { type = "object",
      properties = { command = { type = "string", description = "Shell command" } },
      required = { "command" } } } },
  { type = "function", ["function"] = {
    name = "read_file", description = "Read file contents. Use relative paths.",
    parameters = { type = "object",
      properties = { path = { type = "string", description = "File path" } },
      required = { "path" } } } },
  { type = "function", ["function"] = {
    name = "edit_file",
    description = "Replace text in a file. Provide exact old text and new text. Creates backup.",
    parameters = { type = "object",
      properties = {
        path = { type = "string", description = "File path" },
        old  = { type = "string", description = "Exact text to replace" },
        new  = { type = "string", description = "Replacement text" } },
      required = { "path", "old", "new" } } } },
  { type = "function", ["function"] = {
    name = "write_file",
    description = "Create or overwrite a file with complete content. Creates backup. Prefer edit_file for changes.",
    parameters = { type = "object",
      properties = {
        path    = { type = "string", description = "File path" },
        content = { type = "string", description = "Complete file content" } },
      required = { "path", "content" } } } },
  { type = "function", ["function"] = {
    name = "list_dir", description = "List directory contents",
    parameters = { type = "object",
      properties = { path = { type = "string", description = "Directory (default: .)" } },
      required = {} } } },
  { type = "function", ["function"] = {
    name = "search_files", description = "Search project files by keyword. Use code terms, not descriptions.",
    parameters = { type = "object",
      properties = {
        query = { type = "string", description = "Search query — use code identifiers, function names, types" },
        top_k = { type = "number", description = "Results (default: 5)" } },
      required = { "query" } } } },
  { type = "function", ["function"] = {
    name = "think",
    description = "Reason about a problem before acting. Use when you need to plan. Output is NOT shown to user.",
    parameters = { type = "object",
      properties = {
        thought = { type = "string", description = "Your analysis and plan" } },
      required = { "thought" } } } },
}

-------------------------------------------------------------------------------
-- Tool execution
-------------------------------------------------------------------------------
local function exec_shell(args)
  local cmd = args.command
  if not cmd or cmd == "" then return "error: empty command" end
  cmd = cmd:gsub("^~", HOME):gsub(" ~/", " "..HOME.."/")


  if is_destructive_shell(cmd) then
    local choice, sug = confirm_action("destructive command", cmd)
    if choice == "no" then return "BLOCKED: user denied" end
    if choice == "suggest" and sug then return "BLOCKED: user suggests: "..sug end
  end

  status(ICON.shell, C.dim, C.dim.."$ "..cmd..C.reset)
  local tmpfile = os.tmpname()
  local full = string.format("cd %q && %s", CWD or ".", cmd)
  local exit_code = os.execute(full .. " >" .. tmpfile .. " 2>&1")
  local f = io.open(tmpfile, "r")
  local output = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(tmpfile)

  local code = 0
  if type(exit_code) == "number" then code = exit_code
  elseif type(exit_code) == "boolean" then code = exit_code and 0 or 1 end

  if code ~= 0 then
    output = output .. "\n[exit code: " .. code .. "]"
    memory.log_error("shell", cmd:sub(1,100), output:sub(1,200))
    status(ICON.err, C.red, C.red.."exit "..code..C.reset)
  else
    local n = 0; for _ in output:gmatch("\n") do n = n+1 end
    status(ICON.ok, C.green, C.dim..n.." lines"..C.reset)
  end
  -- Aggressively cap shell output to save context
  if #output > 8000 then
    output = output:sub(1,4000) .. "\n...[truncated]...\n" .. output:sub(-2000)
  end
  memory.log("shell", { command = cmd:sub(1,200), exit_code = code })
  return output
end

local function exec_read_file(args)
  local path = resolve_path(args.path)
  if not path or path == "" then return "error: no path" end

  -- Avoid redundant re-reads — but allow re-reading files that were written this turn
  if files_read_this_turn[path] and not files_written_this_turn[path] then
    status(ICON.read, C.dim, C.dim.."already read "..path..C.reset)
    local content = files_read_this_turn[path]
    if #content > 16000 then
      content = content:sub(1,8000) .. "\n...[truncated "..#content.." bytes]...\n" .. content:sub(-4000)
    end
    return content .. "\n(already read this turn — proceed to edit)"
  end

  status(ICON.read, C.blue, C.blue.."reading "..C.reset..path)

  local f = io.open(path, "r")
  if not f then
    -- Fallback: search CWD for the basename
    local bn = path:match("([^/]+)$")
    if bn and CWD then
      local p = io.popen(string.format("find %q -name %q -type f 2>/dev/null | head -1", CWD, bn))
      local found = p:read("*l"); p:close()
      if found and found ~= "" then
        status(ICON.warn, C.yellow, C.yellow.."found "..C.reset..found)
        f = io.open(found, "r")
        if f then path = found end
      end
    end
    if not f then
      memory.log_error("read_file", path, "not found")
      status(ICON.err, C.red, C.red.."not found"..C.reset)
      return "error: file not found: "..path..". Use list_dir or search_files."
    end
  end

  local content = f:read("*a"); f:close()
  files_read_this_turn[path] = content
  last_read_path = path
  last_read_content = content
  local bn = path:match("([^/]+)$")
  if bn then files_read_this_turn[bn] = path end

  local kb = string.format("%.1fkb", #content/1024)
  status(ICON.ok, C.green, C.dim..kb.." read"..C.reset)

  -- Cap what we return to the model to save context
  if #content > 16000 then
    content = content:sub(1,8000) .. "\n...[truncated "..#content.." bytes]...\n" .. content:sub(-4000)
  end
  memory.log("read_file", { path = path, size = #content })
  return content
end

local function exec_edit_file(args)
  local path = resolve_path(args.path)
  local old_text = args.old
  local new_text = args.new
  if not path or path == "" then return "error: no path" end
  if not old_text or old_text == "" then return "error: no 'old' text" end
  if new_text == nil then return "error: no 'new' text" end
  -- Get file content (from cache or disk)
  local content = files_read_this_turn[path]
  if not content then
    local f = io.open(path, "r")
    if not f then return "error: not found: "..path end
    content = f:read("*a"); f:close()
  end

  -- Exact match first
  local s, e = content:find(old_text, 1, true)
  if not s then
    -- Fuzzy: normalize whitespace and search
    local norm_old = old_text:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
    if #norm_old < 3 then
      return "error: old text too short to match safely"
    end
    -- Build a line-based search instead of byte-by-byte
    local lines = {}
    for line in (content.."\n"):gmatch("([^\n]*)\n") do lines[#lines+1] = line end
    local norm_lines = {}
    for i, l in ipairs(lines) do norm_lines[i] = l:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","") end

    -- Find first line of old_text in file
    local first_line_old = norm_old:match("^([^\n]*)")
    if not first_line_old then first_line_old = norm_old end
    first_line_old = first_line_old:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")

    local found_start = nil
    for i, nl in ipairs(norm_lines) do
      if nl:find(first_line_old, 1, true) then
        found_start = i
        break
      end
    end

    if not found_start then
      return "error: text not found in "..path..". Use read_file to check current content."
    end

    -- Count lines in old_text to determine range
    local old_line_count = 1
    for _ in old_text:gmatch("\n") do old_line_count = old_line_count + 1 end
    local found_end = math.min(found_start + old_line_count - 1, #lines)

    -- Reconstruct the actual text from the file at those lines
    local actual_lines = {}
    for i = found_start, found_end do actual_lines[#actual_lines+1] = lines[i] end
    local actual_old = table.concat(actual_lines, "\n")

    s, e = content:find(actual_old, 1, true)
    if not s then
      return "error: fuzzy match failed in "..path..". Use read_file to check content."
    end
  end

  -- Backup original to .coder/backups/ before editing
  local bk_f = io.open(path, "r")
  if bk_f then
    local bk_data = bk_f:read("*a"); bk_f:close()
    local bk_dir = (CWD or ".") .. "/.coder/backups"
    os.execute("mkdir -p " .. bk_dir)
    local bn = path:match("([^/]+)$") or path
    local ts = os.date("%H%M%S")
    local bk_path = bk_dir .. "/" .. bn .. "." .. ts
    local bk_out = io.open(bk_path, "w")
    if bk_out then bk_out:write(bk_data); bk_out:close()
      status(ICON.backup, C.yellow, C.yellow.."backup "..C.reset..C.dim..bk_path..C.reset)
    end
  end

  -- Apply
  local new_content = content:sub(1, s-1) .. new_text .. content:sub(e+1)
  status(ICON.edit, C.green, C.green.."editing "..C.reset..path..C.dim.." (-"..#old_text.."b +"..#new_text.."b)"..C.reset)

  local dir = path:match("^(.+)/[^/]+$")
  if dir then os.execute("mkdir -p "..dir) end
  local wf = io.open(path, "w")
  if not wf then
    memory.log_error("edit_file", path, "cannot write")
    return "error: cannot write "..path
  end
  wf:write(new_content); wf:close()

  files_read_this_turn[path] = new_content
  files_written_this_turn[path] = true
  last_read_path = path
  last_read_content = new_content
  memory.log("edit_file", { path = path, old_len = #old_text, new_len = #new_text })
  search.reindex_file(path)
  memory.invalidate_tree_cache()

  status(ICON.ok, C.green, C.green.."done"..C.reset)

  -- Auto-compile check for C/C++ files
  local ext = path:match("%.([^.]+)$")
  if ext == "c" or ext == "h" or ext == "cpp" or ext == "cc" or ext == "cxx" then
    local compile_cmd = string.format("cd %q && cc -fsyntax-only -Wall %q 2>&1", CWD or ".", path)
    status(ICON.shell, C.dim, C.dim.."auto-checking: cc -fsyntax-only "..path..C.reset)
    local tmpf = os.tmpname()
    os.execute(compile_cmd .. " > " .. tmpf .. " 2>&1")
    local cf = io.open(tmpf, "r")
    local compile_out = cf and cf:read("*a") or ""
    if cf then cf:close() end
    os.remove(tmpf)
    if compile_out ~= "" and #compile_out > 5 then
      status(ICON.warn, C.yellow, C.yellow.."compile issues remain"..C.reset)
      return "ok: edited "..path.."\n\nCompile check:\n"..compile_out:sub(1, 2000).."\nFix the remaining errors."
    else
      status(ICON.ok, C.green, C.dim.."compiles clean"..C.reset)
    end
  end

  return "ok: edited "..path
end

local function exec_write_file(args)
  local path = resolve_path(args.path)
  local content = args.content
  if not path or path == "" then return "error: no path" end
  if not content then return "error: no content" end
  if files_written_this_turn[path] then
    return "Already wrote "..path.." this turn. Use edit_file for more changes."
  end

  -- Backup existing to .coder/backups/ before writing
  local ef = io.open(path, "r")
  if ef then
    local old_data = ef:read("*a"); ef:close()
    local bk_dir = (CWD or ".") .. "/.coder/backups"
    os.execute("mkdir -p " .. bk_dir)
    local bn = path:match("([^/]+)$") or path
    local ts = os.date("%H%M%S")
    local bk_path = bk_dir .. "/" .. bn .. "." .. ts
    local bk_out = io.open(bk_path, "w")
    if bk_out then bk_out:write(old_data); bk_out:close()
      status(ICON.backup, C.yellow, C.yellow.."backup "..C.reset..C.dim..bk_path..C.reset)
    end
  end

  status(ICON.write, C.green, C.green.."writing "..C.reset..path..C.dim.." ("..#content.."b)"..C.reset)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then os.execute("mkdir -p "..dir) end
  local f = io.open(path, "w")
  if not f then
    memory.log_error("write_file", path, "cannot write")
    return "error: cannot write "..path
  end
  f:write(content); f:close()

  files_written_this_turn[path] = true
  files_read_this_turn[path] = content
  last_read_path = path
  last_read_content = content
  memory.log("write_file", { path = path, size = #content })
  search.reindex_file(path)
  memory.invalidate_tree_cache()

  status(ICON.ok, C.green, C.green.."wrote "..#content.."b"..C.reset)

  -- Auto-compile check for C/C++ files
  local ext = path:match("%.([^.]+)$")
  if ext == "c" or ext == "h" or ext == "cpp" or ext == "cc" or ext == "cxx" then
    local compile_cmd = string.format("cd %q && cc -fsyntax-only -Wall %q 2>&1", CWD or ".", path)
    status(ICON.shell, C.dim, C.dim.."auto-checking: cc -fsyntax-only "..path..C.reset)
    local tmpf = os.tmpname()
    os.execute(compile_cmd .. " > " .. tmpf .. " 2>&1")
    local cf = io.open(tmpf, "r")
    local compile_out = cf and cf:read("*a") or ""
    if cf then cf:close() end
    os.remove(tmpf)
    if compile_out ~= "" and #compile_out > 5 then
      status(ICON.warn, C.yellow, C.yellow.."compile issues remain"..C.reset)
      return "ok: wrote "..#content.." bytes to "..path.."\n\nCompile check:\n"..compile_out:sub(1, 2000).."\nFix the remaining errors."
    else
      status(ICON.ok, C.green, C.dim.."compiles clean"..C.reset)
    end
  end

  return "ok: wrote "..#content.." bytes to "..path
end

local function exec_list_dir(args)
  local path = resolve_path(args.path or ".")
  status(ICON.list, C.dim, C.dim.."listing "..path..C.reset)
  return exec_shell({ command = "ls -la "..path })
end

local function exec_search_files(args)
  local query = args.query
  if not query or query == "" then return "error: no query" end
  status(ICON.search, C.magenta, C.magenta.."search "..C.reset..C.dim..query..C.reset)
  local results = search.query(query, args.top_k or 5, true)
  memory.log("search_files", { query = query, hits = #results })
  return search.format_results(results)
end

local function exec_think(args)
  local thought = args.thought or ""
  status(ICON.think, C.cyan, C.cyan.."thinking"..C.reset..C.dim.." ("..#thought.." chars)"..C.reset)
  memory.log("think", { thought = thought:sub(1, 300) })
  return "ok — now act on your analysis. Call a tool."
end

local TOOL_HANDLERS = {
  shell = exec_shell, read_file = exec_read_file, edit_file = exec_edit_file,
  write_file = exec_write_file, list_dir = exec_list_dir, search_files = exec_search_files,
  think = exec_think,
}

local function execute_tool(name, arguments)
  local handler = TOOL_HANDLERS[name]
  if not handler then return "error: unknown tool '"..tostring(name).."'" end
  local args
  if type(arguments) == "string" then
    local ok, parsed = pcall(json.decode, arguments)
    if not ok then return "error: invalid JSON arguments" end
    args = parsed
  elseif type(arguments) == "table" then args = arguments
  else args = {} end
  local ok, result = pcall(handler, args)
  if not ok then
    local err = "error: "..tostring(result)
    memory.log_error(name, json.encode(args):sub(1,100), err)
    return err
  end
  -- Track repeated edit failures on same path
  if name == "edit_file" and result and result:match("^error:") then
    local ep = args.path or ""
    edit_fails_this_turn[ep] = (edit_fails_this_turn[ep] or 0) + 1
    if edit_fails_this_turn[ep] >= 3 then
      return result .. "\nSTOP: edit failed 3 times on "..ep..". Use read_file to see current content, or use write_file to replace the whole file."
    elseif edit_fails_this_turn[ep] >= 2 then
      return result .. "\nHINT: edit failed twice. Use read_file to see current content before retrying."
    end
  end
  return result or ""
end

-------------------------------------------------------------------------------
-- Fallback tool-call parser
-- Extracts tool calls from model content text when the API doesn't
-- parse them structurally (which is always with Qwen 7B).
-- Returns up to MAX_ACTIONS calls.
-------------------------------------------------------------------------------
local function parse_tool_calls_from_content(content)
  if not content or content == "" then return nil end
  local calls = {}

  -- 1) <tool_call> tags
  for block in content:gmatch("<tool_call>(.-)<%s*/tool_call>") do
    local ok, tc = pcall(json.decode, block)
    if ok and tc and tc.name and TOOL_HANDLERS[tc.name] then
      calls[#calls+1] = { id = "fb_"..#calls, ["function"] = { name = tc.name, arguments = tc.arguments or {} } }
    end
    if #calls >= MAX_ACTIONS then break end
  end
  if #calls > 0 then dbg("fb", #calls.." <tool_call>"); return calls end

  -- 2) Bare JSON: {"name":"tool","arguments":{...}} or {"arguments":{...},"name":"tool"}
  local json_patterns = {
    '%{%s*"name"%s*:%s*"[^"]+"%s*,%s*"arguments"%s*:%s*%b{}%s*%}',
    '%{%s*"arguments"%s*:%s*%b{}%s*,%s*"name"%s*:%s*"[^"]+"%s*%}',
  }
  for _, pat in ipairs(json_patterns) do
    for block in content:gmatch(pat) do
      local ok, tc = pcall(json.decode, block)
      if ok and tc and tc.name and TOOL_HANDLERS[tc.name] then
        calls[#calls+1] = { id = "fb_"..#calls, ["function"] = { name = tc.name, arguments = tc.arguments or {} } }
      end
      if #calls >= MAX_ACTIONS then break end
    end
    if #calls > 0 then dbg("fb", #calls.." bare JSON"); return calls end
  end

  -- 3) ```json blocks
  for block in content:gmatch("```json%s*(.-)%s*```") do
    local ok, tc = pcall(json.decode, block)
    if ok and tc and tc.name and TOOL_HANDLERS[tc.name] then
      calls[#calls+1] = { id = "fb_"..#calls, ["function"] = { name = tc.name, arguments = tc.arguments or {} } }
    end
    if #calls >= MAX_ACTIONS then break end
  end
  if #calls > 0 then dbg("fb", #calls.." ```json"); return calls end

  return nil
end

-------------------------------------------------------------------------------
-- Code block interceptor
-- DISABLED: Auto-converting code blocks to write_file is dangerous.
-- The model often dumps incomplete or incorrect code. Instead, we nudge
-- the model to use edit_file/write_file properly via tool calls.
-- Only intercept if the model explicitly says "write this to <filename>".
-------------------------------------------------------------------------------
local function intercept_code_block(content)
  if not content or content == "" or not last_read_path then return nil end

  -- Only intercept if the model explicitly references writing to a file
  local lo = content:lower()
  local has_write_intent = lo:match("writ[ei]%s+this%s+to") or lo:match("sav[ei]%s+this%s+to")
    or lo:match("updat[ei]%s+the%s+file") or lo:match("replac[ei]%s+the%s+file")
  if not has_write_intent then return nil end

  local code = content:match("```%w+%s*\n(.-)\n%s*```") or content:match("```%s*\n(.-)\n%s*```")
  if not code or #code < 100 then return nil end
  local lc = 1; for _ in code:gmatch("\n") do lc = lc+1 end
  if lc < 8 then return nil end

  -- Determine target
  local target = nil
  local before = content:match("^(.-)```") or ""
  for name, val in pairs(files_read_this_turn) do
    if type(val) == "string" and val:sub(1,1) == "/" then
      local bn = val:match("([^/]+)$")
      if bn and (before:find(bn,1,true) or content:find(bn,1,true)) then target = val; break end
    end
  end
  target = target or last_read_path
  if not target then return nil end

  status(ICON.nudge, C.yellow, C.yellow.."intercepted code → write_file "..C.reset..C.dim..target..C.reset)
  return {{ id = "intercept_1", ["function"] = { name = "write_file", arguments = { path = target, content = code } } }}
end

-------------------------------------------------------------------------------
-- Strip tool-call artifacts from content for clean message storage
-------------------------------------------------------------------------------
local function strip_tool_json(content)
  if not content or content == "" then return "" end
  local s = content
  s = s:gsub("<tool_call>.-<%s*/tool_call>", "")
  s = s:gsub("```json%s*%b{}%s*```", "")
  s = s:gsub('%{%s*"name"%s*:%s*"[^"]+"%s*,%s*"arguments"%s*:%s*%b{}%s*%}', "")
  s = s:gsub('%{%s*"arguments"%s*:%s*%b{}%s*,%s*"name"%s*:%s*"[^"]+"%s*%}', "")
  s = s:gsub("```%w*%s*\n.-\n%s*```", "")
  s = s:gsub("\n%s*\n%s*\n", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-------------------------------------------------------------------------------
-- Narration detection
-- Structural patterns only — catches categories, not individual phrases.
-- This keeps the list short and maintenance-free.
-------------------------------------------------------------------------------
local function is_narrating(text)
  if not text or text == "" then return false, nil end
  local lo = text:lower()

  -- Category 1: "Let's X" or "Let me X" — always narration
  if lo:match("let'?s%s+%w") then return true, "lets" end
  if lo:match("let%s+me%s+%w") then return true, "lets" end

  -- Category 2: "I'll X" / "I will X" / "I need to X" — future tense = not acting
  if lo:match("i'?ll%s+%w") then return true, "future" end
  if lo:match("i%s+will%s+%w") then return true, "future" end
  if lo:match("i%s+need%s+to%s") then return true, "future" end

  -- Category 3: "We should/need/can" — collaborative narration
  if lo:match("we%s+[snc]") then return true, "we" end

  -- Category 4: numbered plan (1. ... 2. ...)
  if lo:match("^%s*1%.%s") and lo:match("2%.%s") then return true, "plan" end

  -- Category 5: presentation phrases
  if lo:match("here%s+is") or lo:match("here'?s%s+the") or lo:match("below%s+is") or lo:match("as%s+follows") then return true, "present" end
  if lo:match("the%s+updated%s") or lo:match("the%s+fixed%s") or lo:match("the%s+complete%s") or lo:match("the%s+modified%s") then return true, "present" end

  -- Category 6: code dump (fenced block with >100 chars)
  if text:match("```%w*%s*\n.-\n%s*```") then
    local code = text:match("```%w*%s*\n(.-)\n%s*```")
    if code and #code > 100 then return true, "code" end
  end

  return false, nil
end

-------------------------------------------------------------------------------
-- Nudge: short, direct correction injected as user message.
-- DESIGN: Nudges must be TINY. Each one costs ~50 tokens of context.
-- Don't repeat the system prompt rules — just give a command.
-------------------------------------------------------------------------------
local function nudge_message(reason)
  local hint = ""
  if last_read_path then hint = " File: "..last_read_path end
  if reason == "code" then
    return 'Do NOT show code. Use {"name":"write_file","arguments":{"path":"FILE","content":"..."}}'..hint
  elseif reason == "plan" or reason == "present" then
    return 'STOP explaining. Respond ONLY with a tool call JSON. Example: {"name":"shell","arguments":{"command":"cc -fsyntax-only '..
      (last_read_path or "file.c")..' 2>&1"}}'
  else
    return 'Respond with ONLY tool call JSON. No text. Example: {"name":"read_file","arguments":{"path":"'..
      (last_read_path or "file.c")..'"}}'
  end
end

-------------------------------------------------------------------------------
-- HTTP via LuaJIT FFI (zero-dependency, no python3/curl subprocess)
-------------------------------------------------------------------------------
local function http_post(url, body)
  return http.post(url, body, HTTP_TIMEOUT)
end

-------------------------------------------------------------------------------
-- Chat API
-------------------------------------------------------------------------------
local messages = {}
local current_user_query = nil

local function trim_messages(max)
  max = max or 40
  if #messages <= max then return end
  -- Smart trimming: keep system, recent messages, and truncate large tool results
  local trimmed = {}
  if messages[1] then trimmed[1] = messages[1] end
  local start = math.max(2, #messages - max + 2)
  for i = start, #messages do
    local m = messages[i]
    -- Truncate large tool results in older messages to save context
    if m.role == "tool" and m.content and #m.content > 2000 and i < #messages - 6 then
      m = { role = m.role, content = m.content:sub(1, 1000) .. "\n...[truncated]", tool_call_id = m.tool_call_id }
    end
    trimmed[#trimmed+1] = m
  end
  messages = trimmed
end

local function chat(user_msg)
  if user_msg then
    messages[#messages+1] = { role = "user", content = user_msg }
    current_user_query = user_msg
  end
  trim_messages(30)

  local send = {{ role = "system", content = build_system_prompt() }}
  for _, m in ipairs(messages) do send[#send+1] = m end

  local body = json.encode({
    model = MODEL,
    messages = send,
    tools = TOOLS,
    tool_choice = "auto",
    temperature = 0.6,
    max_tokens = 4096,
  })
  dbg("req", body)

  spinner_start("thinking")
  local code, resp = http_post(ENDPOINT, body)
  spinner_stop()
  dbg("resp-code", tostring(code))
  dbg("resp-body", resp)

  if code == 0 then
    status(ICON.err, C.red, C.red.."timeout ("..HTTP_TIMEOUT.."s)"..C.reset)
    return nil
  end
  if code ~= 200 then
    status(ICON.err, C.red, C.red.."HTTP "..code..C.reset)
    dbg("http-err", resp:sub(1,500))
    return nil
  end

  local ok, data = pcall(json.decode, resp)
  if not ok or not data or not data.choices or #data.choices == 0 then
    status(ICON.err, C.red, C.red.."bad response"..C.reset)
    dbg("bad-resp", resp:sub(1, 500))
    return nil
  end

  local msg = data.choices[1].message
  if not msg then
    status(ICON.err, C.red, C.red.."no message"..C.reset)
    return nil
  end

  -- Detect empty response (model produced nothing useful)
  local has_content = msg.content and msg.content:match("%S")
  local has_tools = msg.tool_calls and #msg.tool_calls > 0
  if not has_content and not has_tools then
    status(ICON.warn, C.yellow, C.yellow.."empty response from model"..C.reset)
    -- Log finish_reason for diagnostics
    local fr = data.choices[1].finish_reason or "unknown"
    dbg("empty-finish", fr)
    -- Always log empty responses regardless of DEBUG
    io.write(C.dim.."  [diag] finish_reason="..fr
      ..", prompt_tokens="..tostring((data.usage or {}).prompt_tokens or "?")
      ..", completion_tokens="..tostring((data.usage or {}).completion_tokens or "?")
      ..C.reset.."\n")

    -- Retry with higher temperature
    local retry_body = json.encode({
      model = MODEL,
      messages = send,
      tools = TOOLS,
      tool_choice = "auto",
      temperature = 0.8,
      max_tokens = 4096,
    })
    spinner_start("retrying with higher temperature")
    local rcode, rresp = http_post(ENDPOINT, retry_body)
    spinner_stop()
    if rcode == 200 then
      local rok, rdata = pcall(json.decode, rresp)
      if rok and rdata and rdata.choices and #rdata.choices > 0 then
        local rmsg = rdata.choices[1].message
        local r_has_content = rmsg and rmsg.content and rmsg.content:match("%S")
        local r_has_tools = rmsg and rmsg.tool_calls and #rmsg.tool_calls > 0
        if r_has_content or r_has_tools then
          status(ICON.ok, C.green, C.dim.."retry succeeded (higher temp)"..C.reset)
          messages[#messages+1] = rmsg
          memory.log("assistant", { content = (rmsg.content or ""):sub(1,200), has_tc = r_has_tools, retry = true })
          return rmsg, rdata.choices[1].finish_reason
        end
      end
    end
    status(ICON.err, C.red, C.red.."model unable to generate — check server config"..C.reset)
    return nil
  end

  messages[#messages+1] = msg
  memory.log("assistant", { content = (msg.content or ""):sub(1,200), has_tc = msg.tool_calls ~= nil })
  return msg, data.choices[1].finish_reason
end

-------------------------------------------------------------------------------
-- Agent turn
-- Flow:
--   user message → chat → extract tools → execute → chat → ...
--   If model narrates instead of acting → nudge (max 2) → chat
--   If model dumps code block → intercept → write_file
--   Up to MAX_ACTIONS tool executions per user turn
-------------------------------------------------------------------------------
local function agent_turn(user_msg)
  memory.log("user", { content = user_msg:sub(1,200) })

  -- Reset per-turn state
  files_written_this_turn = {}
  files_read_this_turn = {}
  last_read_path = nil
  last_read_content = nil
  consecutive_same_tool = { name = nil, path = nil, count = 0 }
  edit_fails_this_turn = {}

  -- RAG once per turn — include file snippets, not just paths
  rag_context = ""
  local rag = search.query(user_msg, 3, true)
  if #rag > 0 then
    local parts = { "\nRelevant files:" }
    for _, r in ipairs(rag) do
      parts[#parts+1] = string.format("--- %s (score:%.1f, %db) ---", r.path, r.score, r.size or 0)
      if r.snippet then
        parts[#parts+1] = r.snippet:sub(1, 500)
      end
    end
    rag_context = table.concat(parts, "\n")
    -- Cap total RAG context to save token budget
    if #rag_context > 3000 then
      rag_context = rag_context:sub(1, 3000) .. "\n...[truncated]"
    end
  end

  local msg = chat(user_msg)
  if not msg then return end

  local turn = 0
  local nudge_count = 0
  local total_actions = 0

  while turn < MAX_TURNS do
    -- === Extract tool calls (3 stages) ===
    local tool_calls = msg.tool_calls
    local used_fallback = false

    if (not tool_calls or #tool_calls == 0) and msg.content then
      tool_calls = parse_tool_calls_from_content(msg.content)
      if tool_calls then used_fallback = true end
    end
    if (not tool_calls or #tool_calls == 0) and msg.content then
      tool_calls = intercept_code_block(msg.content)
      if tool_calls then used_fallback = true end
    end

    -- === Tool calls found: execute them ===
    if tool_calls and #tool_calls > 0 then
      nudge_count = 0
      local n_calls = math.min(#tool_calls, MAX_ACTIONS - total_actions)
      if n_calls <= 0 then n_calls = 1 end

      for ci = 1, n_calls do
        turn = turn + 1
        total_actions = total_actions + 1

        local tc = tool_calls[ci]
        local fn = tc["function"] or tc
        local name = fn.name or tc.name
        local arguments = fn.arguments or tc.arguments
        local call_id = tc.id or ("c_"..turn)

        if not TOOL_HANDLERS[name] then
          status(ICON.err, C.red, C.red.."unknown: "..tostring(name)..C.reset)
          break
        end

        -- Fix message history when using fallback (only once per batch)
        if used_fallback and ci == 1 then
          local last_idx = #messages
          local clean = strip_tool_json(messages[last_idx].content or "")
          local tc_list = {}
          for ti = 1, n_calls do
            local ttc = tool_calls[ti]
            local tfn = ttc["function"] or ttc
            tc_list[#tc_list+1] = {
              id = ttc.id or ("c_"..(turn - n_calls + ti)),
              type = "function",
              ["function"] = {
                name = tfn.name or ttc.name,
                arguments = type(tfn.arguments or ttc.arguments) == "table"
                  and json.encode(tfn.arguments or ttc.arguments)
                  or (tfn.arguments or ttc.arguments or "{}"),
              }
            }
          end
          messages[last_idx] = {
            role = "assistant",
            content = clean ~= "" and clean or nil,
            tool_calls = tc_list,
          }
        end

        -- Loop detection — only trigger on exact same tool+args combination
        -- read_file on same path is OK if the file was written in between
        -- shell with different commands is OK
        local at
        if type(arguments) == "string" then
          local dok, dp = pcall(json.decode, arguments)
          at = dok and dp or {}
        else
          at = arguments or {}
        end
        local tp = at.path or at.command or ""
        local is_same = (name == consecutive_same_tool.name and tp == consecutive_same_tool.path)
        -- Allow re-reading a file that was just written
        if is_same and name == "read_file" and files_written_this_turn[resolve_path(tp)] then
          is_same = false
        end
        if is_same then
          consecutive_same_tool.count = consecutive_same_tool.count + 1
        else
          consecutive_same_tool = { name = name, path = tp, count = 1 }
        end
        if consecutive_same_tool.count >= 4 then
          status(ICON.err, C.red, C.red.."loop: "..name.." x"..consecutive_same_tool.count..C.reset)
          return
        end

        status_turn(turn, name)
        local result = execute_tool(name, arguments)
        messages[#messages+1] = { role = "tool", content = result, tool_call_id = call_id }
      end

      -- Get next response
      if total_actions >= MAX_ACTIONS then
        msg = chat(nil)
        if not msg then return end
        break
      end
      msg = chat(nil)
      if not msg then return end

    -- === No tool calls: check for narration ===
    elseif msg.content then
      local narrating, reason = is_narrating(msg.content)

      if narrating and nudge_count < 3 then
        nudge_count = nudge_count + 1
        status(ICON.nudge, C.yellow, C.yellow.."nudge "..nudge_count.."/3"..C.reset..C.dim.." ("..reason..")"..C.reset)

        -- Keep the assistant message but add a correction.
        -- Do NOT set content=nil (causes template errors).
        -- Just add a short user correction and continue.
        messages[#messages+1] = { role = "user", content = nudge_message(reason) }
        msg = chat(nil)
        if not msg then return end
      else
        break
      end
    else
      break
    end
  end

  rag_context = ""

  -- Display final response (strip artifacts)
  if msg and msg.content and msg.content ~= "" then
    local display = strip_tool_json(msg.content)
    if display ~= "" then
      io.write("\n"..C.green..C.bold.."  coder"..C.reset..": "..display.."\n\n")
    end
  end
end

-------------------------------------------------------------------------------
-- Server health check (native FFI HTTP)
-------------------------------------------------------------------------------
local function check_server()
  for _ = 1, 3 do
    local code = http.get(API_URL .. "/health", 5)
    if code == 200 then return true end
    os.execute("sleep 0.5")
  end
  return false
end

-------------------------------------------------------------------------------
-- Main REPL
-------------------------------------------------------------------------------
local function main()
  local p = io.popen("pwd"); CWD = p:read("*l"); p:close()
  memory.init()

  local embed_ok = embed.init({ script_dir = coder_root })
  if embed_ok then search.init_embeddings(embed) end

  local indexed = search.index_dir(".", {
    "lua","sh","c","h","cpp","py","js","ts","go","rs",
    "md","txt","json","yaml","yml","toml","conf","cfg",
    "html","css","Makefile","zig",
  })

  if not check_server() then
    io.write(C.red..ICON.err.." llama-server not running at "..API_URL..C.reset.."\n")
    io.write(C.dim.."  Start with: ./coder-server"..C.reset.."\n")
    os.exit(1)
  end

  local emb = embed_ok and (C.green..ICON.ok.." embed:"..search.vec_count()..C.reset) or (C.dim.."no embed"..C.reset)
  io.write("\n"..C.bold..C.blue.."  ╔══════════════════════════════════════╗"..C.reset.."\n")
  io.write(C.bold..C.blue.."  ║"..C.reset..C.bold.."     coder "..C.dim.."— autonomous coding agent"..C.reset..C.bold..C.blue.."  ║"..C.reset.."\n")
  io.write(C.bold..C.blue.."  ╚══════════════════════════════════════╝"..C.reset.."\n")
  io.write(C.dim.."  CWD: "..CWD..C.reset.."\n")
  io.write(C.dim.."  "..API_URL.." | turns:"..MAX_TURNS.." actions:"..MAX_ACTIONS.." timeout:"..HTTP_TIMEOUT.."s | BM25:"..indexed.." "..emb..C.reset.."\n")
  io.write(C.dim.."  /clear /history /debug /context /reindex /files /search /errors /bench /stats /quit"..C.reset.."\n\n")

  while true do
    io.write(C.bold.."you"..C.reset..": "); io.flush()
    local ok_read, line = pcall(io.read, "*l")
    if not ok_read or not line then break end
    line = line:match("^%s*(.-)%s*$")
    if line == "" then goto continue end

    if line == "/quit" or line == "/exit" or line == "/q" then break
    elseif line == "/clear" then
      messages = {}; current_user_query = nil
      status(ICON.ok, C.green, "cleared"); goto continue
    elseif line == "/history" then
      for i, m in ipairs(messages) do
        io.write(C.dim..string.format("  [%d] %s%s: %s\n", i, m.role,
          m.tool_calls and " [TC]" or "", (m.content or ""):sub(1,80))..C.reset)
      end; goto continue
    elseif line == "/debug" then
      DEBUG = not DEBUG
      status(ICON.ok, C.cyan, "debug "..(DEBUG and "ON" or "OFF")); goto continue
    elseif line == "/context" then
      io.write(C.dim.."=== System Prompt ===\n"..build_system_prompt().."\n=== End ===\n"..C.reset); goto continue
    elseif line == "/reindex" then
      memory.invalidate_tree_cache()
      indexed = search.index_dir(".")
      status(ICON.ok, C.green, "reindexed "..indexed); goto continue
    elseif line == "/files" then
      io.write(C.dim..(memory.get_project_tree() or "(none)")..C.reset.."\n"); goto continue
    elseif line == "/search" then
      io.write(C.bold.."  query> "..C.reset); io.flush()
      local q = io.read("*l")
      if q and q ~= "" then io.write(C.dim..search.format_results(search.query(q,10))..C.reset.."\n") end
      goto continue
    elseif line == "/errors" then
      local errs = memory.get_errors(10)
      if #errs == 0 then status(ICON.ok, C.green, "none")
      else for _, e in ipairs(errs) do
        io.write(C.red.."  "..ICON.err.." ["..( e.tool or "?").."] "..(e.args or ""):sub(1,60)..": "..(e.error or ""):sub(1,80)..C.reset.."\n")
      end end; goto continue
    elseif line == "/bench" then
      io.write(C.cyan.."  Running benchmark..."..C.reset.."\n")
      local bench_cmd = coder_root.."/llama.cpp/build/bin/llama-bench -m "..coder_root.."/models/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf -ngl 99 -fa 1 -pg 512,128 2>&1"
      local bp = io.popen(bench_cmd); local bout = bp:read("*a"); bp:close()
      io.write(C.dim..bout..C.reset.."\n"); goto continue
    elseif line == "/stats" then
      local scode, sout = http.get(API_URL .. "/health", 3)
      io.write(C.dim.."  Server: "..tostring(scode).." "..sout:sub(1,200)..C.reset.."\n")
      local mp = io.popen("nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null")
      local mout = mp:read("*a"); mp:close()
      if mout and mout ~= "" then io.write(C.dim.."  GPU: "..mout:gsub("\n","")..C.reset.."\n") end
      goto continue
    end

    while line:sub(-1) == "\\" do
      line = line:sub(1,-2).."\n"
      io.write(C.dim.."... "..C.reset); io.flush()
      local nl = io.read("*l"); if not nl then break end
      line = line .. nl
    end

    local tok, terr = pcall(agent_turn, line)
    if not tok then
      spinner_stop()
      if terr and terr:match("interrupted") then
        io.write("\n"); status(ICON.warn, C.yellow, C.yellow.."interrupted"..C.reset)
      else
        status(ICON.err, C.red, C.red.."error: "..tostring(terr):sub(1,100)..C.reset)
      end
    end
    ::continue::
  end
  io.write(C.dim.."\n  bye\n"..C.reset)
end

local ok, err = pcall(main)
if not ok then
  if err and err:match("interrupted") then
    io.write("\n"..C.dim.."  bye"..C.reset.."\n")
  else
    io.write("\n"..C.red.."fatal: "..tostring(err)..C.reset.."\n")
  end
end
