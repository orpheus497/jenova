#!/usr/bin/env luajit
-- jenova-agent: Agentic coding assistant with shell/file access
-- Uses llama-server's OpenAI-compatible API with tool calling
--
-- Architecture v2:
--   Plan → Execute → Reflect loop with action deduplication
--   Session-isolated memory prevents stale context pollution
--   Action history prevents repetitive failed attempts
--   Compact system prompt maximizes model reasoning capacity
--
-- Architecture notes (do not remove):
-- * Qwen2.5-Coder-14B returns tool calls as text in msg.content.
--   Extracted via fallback parser (Stage 2) or code-block interceptor (Stage 3).
--   The 14B model outputs {"arguments":{...},"name":"..."} (reversed key order).
-- * edit_file exists because write_file requires the model to regenerate
--   the entire file as JSON content, which can exceed generation timeout.
--   edit_file only needs the old/new snippet.

local script_dir = arg[0]:match("^(.*)/") or "."
local jenova_root = os.getenv("JENOVA_ROOT") or script_dir:match("^(.*)/lib$") or script_dir .. "/.."
package.path = script_dir .. "/?.lua;" .. package.path

local json = require("json")
local http = require("http")
local memory = require("memory")
local search = require("search")
local embed = require("embed")
local ui = require("ui")
local ffi = require("ffi")
local ffi_defs = require("ffi_defs")

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------
local API_URL   = os.getenv("JENOVA_API_URL") or "http://127.0.0.1:8080"
local ENDPOINT  = API_URL .. "/v1/chat/completions"
local MODEL     = "qwen2.5-coder"
local MAX_TURNS = tonumber(os.getenv("JENOVA_MAX_TURNS")) or 25
local DEBUG     = os.getenv("JENOVA_DEBUG") == "1"
local HOME      = os.getenv("HOME") or "/home/orpheus497"
local CWD       = nil  -- set in main()
local HTTP_TIMEOUT = tonumber(os.getenv("JENOVA_TIMEOUT")) or 600
local MAX_ACTIONS  = 20
local CONTEXT_WINDOW = tonumber(os.getenv("JENOVA_CTX")) or 8192

-- Per-turn state
local files_written_this_turn = {}
local files_read_this_turn    = {}
local last_read_path          = nil
local last_read_content       = nil
local edit_fails_this_turn    = {}

-------------------------------------------------------------------------------
-- UI shorthand aliases
-------------------------------------------------------------------------------
local P = ui.P
local ICON = ui.ICONS
local spinner_start = ui.spinner_start
local spinner_stop  = ui.spinner_stop

local function status_turn(turn_num, name)
  ui.status_turn(turn_num, MAX_TURNS, name)
end

-------------------------------------------------------------------------------
-- Path resolution
-------------------------------------------------------------------------------
local function resolve_path(p)
  if not p then return p end
  p = p:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
  if p:sub(1, 2) == "~/" then
    return HOME .. p:sub(2)
  elseif p == "~" then
    return HOME
  elseif p:sub(1, 1) ~= "/" then
    return ((CWD or ".") .. "/" .. p):gsub("/%./", "/")
  end
  local f = io.open(p, "r")
  if f then f:close(); return p end
  local basename = p:match("([^/]+)$")
  if basename and CWD then
    local try = CWD .. "/" .. basename
    local tf = io.open(try, "r")
    if tf then
      tf:close()
      ui.path_fixed(p, try)
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
  return ui.confirm(action_type, detail)
end

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------
local function dbg(label, data)
  if not DEBUG then return end
  if type(data) == "string" then ui.debug(label, data:sub(1,2000))
  else ui.debug(label, json.encode(data):sub(1,2000)) end
end

-------------------------------------------------------------------------------
-- System prompt — COMPACT. Every token costs reasoning capacity.
-- v2: Only injects session-relevant context, not historical noise.
-------------------------------------------------------------------------------
local rag_context = ""
local current_user_query = nil

local function assess_complexity(user_input)
  if not user_input then return "SIMPLE" end
  local words = 0
  for _ in user_input:gmatch("%S+") do words = words + 1 end

  local indicators = {
    "explain", "compare", "analyze", "describe in detail", "step by step",
    "how does", "why does", "what are the", "difference between", "relationship between",
    "implement", "refactor", "architect", "design", "rewrite", "port", "debug", "optimize"
  }

  local has_indicator = false
  local lower_input = user_input:lower()
  for _, ind in ipairs(indicators) do
    if lower_input:find(ind, 1, true) then
      has_indicator = true
      break
    end
  end

  local question_count = 0
  for _ in user_input:gmatch("%?") do question_count = question_count + 1 end

  if words > 40 and has_indicator and question_count > 1 then
    return "VERY_COMPLEX"
  elseif words > 20 and has_indicator then
    return "COMPLEX"
  elseif words > 10 or has_indicator then
    return "MODERATE"
  else
    return "SIMPLE"
  end
end

local function build_system_prompt()
  local parts = {}
  parts[#parts+1] = "You are Jenova, an expert autonomous cognitive agent on FreeBSD. CWD: " .. (CWD or ".")
  
  local complexity = assess_complexity(current_user_query)
  if complexity == "VERY_COMPLEX" or complexity == "COMPLEX" then
    parts[#parts+1] = "\nTASK COMPLEXITY: " .. complexity .. ". Plan carefully, but prioritize taking informative actions (read_file, list_dir) over excessive 'think' steps."
  else
    parts[#parts+1] = "\nTASK COMPLEXITY: " .. complexity .. ". Focus on direct actions (read, edit, test). Use 'think' only if you are truly stuck or need a complex plan."
  end

  parts[#parts+1] = [[

TOOLS (call ONE per response as JSON):
  shell(command)       — Run shell commands: compile, test, diagnose.
  read_file(path)      — Read a file's contents with line numbers.
  edit_file(path, start_line, end_line, new_content) — Replace lines.
  write_file(path, content) — Create/overwrite entire file. Use for NEW files only.
  list_dir(path)       — List directory contents.
  search_files(query, top_k) — Search project files by code identifiers/keywords.
  think(thought)       — Internal reasoning. Use ONLY for complex multi-step planning.

RESPONSE FORMAT:
You MUST think about your action first inside <think>...</think> tags.
Immediately after the closing tag, output exactly ONE JSON tool call.

Example:
<think>
I need to check if the header exists.
</think>
{"name": "shell", "arguments": {"command": "ls /usr/include/stdio.h"}}

WORKFLOW: Direct Action
1. READ before editing — identify what is real and what is not.
2. THINK natively — use the <think> block to reason through the step.
3. ACT decisively — use tools to make progress every turn.
4. VERIFY — check headers exist and code compiles.
5. VALIDATE — compile/test after changes.
6. REPORT — give 1-2 sentence summary when done.

CRITICAL:
- Respond with <think> followed by JSON.
- Respond ONLY with JSON after </think>. No other text.
- FreeBSD: use cc (not gcc), /usr/local/include for ports.
- Fix root causes, not symptoms.]]

  -- Session-aware context (errors, actions, plan — only from THIS session)
  local ctx = memory.build_context(current_user_query)
  if ctx ~= "" then parts[#parts+1] = ctx end

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
    description = "Replace a range of lines in a file. start_line and end_line are inclusive.",
    parameters = { type = "object",
      properties = {
        path = { type = "string", description = "File path" },
        start_line = { type = "number", description = "First line to replace" },
        end_line = { type = "number", description = "Last line to replace" },
        new_content = { type = "string", description = "Replacement text" } },
      required = { "path", "start_line", "end_line", "new_content" } } } },
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
    name = "grep_search", description = "Search for an exact string in the project using grep.",
    parameters = { type = "object",
      properties = {
        pattern = { type = "string", description = "Exact string or regex to find" },
        include = { type = "string", description = "Glob pattern for files to include (e.g. *.c)" } },
      required = { "pattern" } } } },
  { type = "function", ["function"] = {
    name = "think",
    description = "Reason about a problem before acting. Use when you need to plan. Output is NOT shown to user.",
    parameters = { type = "object",
      properties = {
        thought = { type = "string", description = "Your analysis and plan" } },
      required = { "thought" } } } },
}

local TOOL_HANDLERS = {}  -- forward declaration, populated below

-------------------------------------------------------------------------------
-- Tool execution
-------------------------------------------------------------------------------
local function exec_shell(args)
  local cmd = args.command
  if not cmd or cmd == "" then return "error: empty command", false end
  cmd = cmd:gsub("^~", HOME):gsub(" ~/", " "..HOME.."/")

  cmd = cmd:gsub("^apt%-get%s", "pkg "):gsub("^apt%s", "pkg "):gsub("^yum%s", "pkg ")
  cmd = cmd:gsub("^gcc%s", "cc ")

  -- Check if this exact command already failed this session
  local prior = memory.was_action_tried("shell", { command = cmd })
  if prior and prior.failures > 0 and prior.successes == 0 then
    return "BLOCKED: This command already failed ("..prior.failures.."x). Try a different approach.\nLast result: "..prior.last_result:sub(1, 100), false
  end

  if is_destructive_shell(cmd) then
    local choice, sug = confirm_action("destructive command", cmd)
    if choice == "no" then return "BLOCKED: user denied", false end
    if choice == "suggest" and sug then return "BLOCKED: user suggests: "..sug, false end
  end

  ui.shell_cmd(cmd)
  local tmpfile = os.tmpname()
  local full = string.format("cd %q && %s; echo \"\\n[EXIT:$?]\"", CWD or ".", cmd)
  os.execute(full .. " >" .. string.format("%q", tmpfile) .. " 2>&1")
  local f = io.open(tmpfile, "r")
  local output = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(tmpfile)

  local code = 0
  local exit_match = output:match("%[EXIT:(%d+)%]%s*$")
  if exit_match then
    code = tonumber(exit_match) or 0
    output = output:gsub("\n?%[EXIT:%d+%]%s*$", "")
  end

  local success = (code == 0)
  if not success then
    output = output .. "\n[exit code: " .. code .. "]"
    memory.log_error("shell", cmd:sub(1,100), output:sub(1,200))
    ui.shell_result(code, 0)
  else
    local n = 0; for _ in output:gmatch("\n") do n = n+1 end
    ui.shell_result(0, n)
  end

  if #output > 8000 then
    output = output:sub(1,4000) .. "\n...[truncated]...\n" .. output:sub(-2000)
  end
  memory.log("shell", { command = cmd:sub(1,200), exit_code = code })
  return output, success
end

local function exec_read_file(args)
  local path = resolve_path(args.path)
  if not path or path == "" then return "error: no path", false end

  ui.file_read(path)

  local f = io.open(path, "r")
  if not f then
    return "error: file not found: "..path, false
  end

  local content = f:read("*a"); f:close()
  files_read_this_turn[path] = content
  last_read_path = path
  last_read_content = content

  -- Format with line numbers for the model
  local formatted = {}
  local lnum = 1
  if content ~= "" then
    local clean_content = content:sub(-1) == "\n" and content:sub(1, -2) or content
    for line in (clean_content .. "\n"):gmatch("([^\n]*)\n") do
      formatted[#formatted+1] = string.format("%4d | %s", lnum, line)
      lnum = lnum + 1
    end
  end
  local result = table.concat(formatted, "\n")

  local kb = string.format("%.1fkb", #content/1024)
  ui.file_read_done(kb)

  if #result > 24000 then
    result = result:sub(1,12000) .. "\n...[truncated]...\n" .. result:sub(-8000)
  end
  memory.log("read_file", { path = path, size = #content })
  return result, true
end

local function exec_edit_file(args)
  local path = resolve_path(args.path)
  local start_line = tonumber(args.start_line)
  local end_line = tonumber(args.end_line)
  local new_text = args.new_content
  
  if not path or not start_line or not end_line or not new_text then
    return "error: missing arguments for edit_file", false
  end

  local content = files_read_this_turn[path]
  if not content then
    local f = io.open(path, "r")
    if not f then return "error: not found: "..path, false end
    content = f:read("*a"); f:close()
  end

  local lines = {}
  if content ~= "" then
    local clean_content = content:sub(-1) == "\n" and content:sub(1, -2) or content
    for line in (clean_content .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines+1] = line
    end
  end

  if #lines == 0 then
    if start_line ~= 1 or end_line ~= 1 then
      return "error: file is empty, range must be 1-1", false
    end
  elseif start_line < 1 or start_line > #lines + 1 or end_line < start_line or (end_line > #lines and not (start_line == #lines + 1 and end_line == #lines + 1)) then
    return string.format("error: invalid line range %d-%d (file has %d lines). To append, use %d-%d.", start_line, end_line, #lines, #lines + 1, #lines + 1), false
  end

  local new_lines = {}
  for i = 1, start_line - 1 do
    new_lines[#new_lines+1] = lines[i]
  end
  
  if new_text ~= "" then
    local clean_new = new_text:sub(-1) == "\n" and new_text:sub(1, -2) or new_text
    for line in (clean_new .. "\n"):gmatch("([^\n]*)\n") do
      new_lines[#new_lines+1] = line
    end
  end

  for i = end_line + 1, #lines do
    new_lines[#new_lines+1] = lines[i]
  end

  local new_content = table.concat(new_lines, "\n")
  -- Preserve UNIX newline convention if original file had it, or if it's a new file
  if #new_content > 0 and (content == "" or content:sub(-1) == "\n" or new_text:sub(-1) == "\n") then
    new_content = new_content .. "\n"
  end
  
  -- Backup
  local bk_dir = (CWD or ".") .. "/.jenova/backups"
  local ok_bkdir, err_bkdir = pcall(function() os.execute(string.format("mkdir -p %q", bk_dir)) end)
  if not ok_bkdir then ui.status_warn('failed to ensure backup dir: '..tostring(err_bkdir)) end
  local bn = path:match("([^/]+)$") or path
  local ts = os.date("%Y%m%d_%H%M%S")
  local bk_path = bk_dir .. "/" .. bn .. "." .. ts
  local bk_out = io.open(bk_path, "w")
  if bk_out then
    bk_out:write(content)
    bk_out:close()
    ui.file_backup(bk_path)
  end

  ui.file_edit(path, start_line, end_line)

  local wf = io.open(path, "w")
  if not wf then return "error: cannot write "..path, false end
  wf:write(new_content); wf:close()

  files_read_this_turn[path] = new_content
  files_written_this_turn[path] = true
  last_read_path = path
  last_read_content = new_content
  memory.log("edit_file", { path = path, range = start_line.."-"..end_line })
  search.reindex_file(path)
  memory.invalidate_tree_cache()

  ui.status_ok("done")
  return "ok: updated lines "..start_line.." to "..end_line.." in "..path, true
end

local function exec_write_file(args)
  local path = resolve_path(args.path)
  local content = args.content
  if not path or path == "" then return "error: no path", false end
  if not content then return "error: no content", false end
  if files_written_this_turn[path] then
    return "Already wrote "..path.." this turn. Use edit_file for more changes.", false
  end

  local ef = io.open(path, "r")
  if ef then
    local old_data = ef:read("*a"); ef:close()
    local bk_dir = (CWD or ".") .. "/.jenova/backups"
    local ok_bkdir2, err_bkdir2 = pcall(function() os.execute(string.format("mkdir -p %q", bk_dir)) end)
  if not ok_bkdir2 then ui.status_warn('failed to ensure backup dir: '..tostring(err_bkdir2)) end
    local bn = path:match("([^/]+)$") or path
    local ts = os.date("%H%M%S")
    local bk_path = bk_dir .. "/" .. bn .. "." .. ts
    local bk_out = io.open(bk_path, "w")
    if bk_out then bk_out:write(old_data); bk_out:close()
      ui.file_backup(bk_path)
    end
  end

  ui.file_write(path, #content)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then local ok,err = pcall(function() os.execute(string.format("mkdir -p %q", dir)) end) if not ok then ui.status_warn('failed to create dir '..tostring(dir)..': '..tostring(err)) end end
  local f = io.open(path, "w")
  if not f then
    memory.log_error("write_file", path, "cannot write")
    return "error: cannot write "..path, false
  end
  f:write(content); f:close()

  files_written_this_turn[path] = true
  files_read_this_turn[path] = content
  last_read_path = path
  last_read_content = content
  memory.log("write_file", { path = path, size = #content })
  search.reindex_file(path)
  memory.invalidate_tree_cache()

  ui.status_ok("wrote "..#content.."b")

  local ext = path:match("%.([^.]+)$")
  if ext == "c" or ext == "h" or ext == "cpp" or ext == "cc" or ext == "cxx" then
    local compile_cmd = string.format("cd %q && cc -fsyntax-only -Wall %q 2>&1", CWD or ".", path)
    ui.compile_check(path)
    local tmpf = os.tmpname()
    -- Run compile in subshell and capture output
    local ok_compile, err_compile = pcall(function() os.execute(compile_cmd .. " > " .. tmpf .. " 2>&1") end)
    if not ok_compile then ui.status_warn('compile command failed to run: '..tostring(err_compile)) end
    local cf = io.open(tmpf, "r")
    local compile_out = cf and cf:read("*a") or ""
    if cf then cf:close() end
    os.remove(tmpf)
    if compile_out ~= "" and #compile_out > 5 then
      ui.status_warn("compile issues remain")
      return "ok: wrote "..#content.." bytes to "..path.."\n\nCompile check:\n"..compile_out:sub(1, 2000).."\nFix the remaining errors.", true
    else
      ui.status_ok("compiles clean")
    end
  end

  return "ok: wrote "..#content.." bytes to "..path, true
end

local function exec_list_dir(args)
  local path = resolve_path(args.path or ".")
  ui.file_list(path)
  return exec_shell({ command = "ls -la "..path })
end

local function exec_search_files(args)
  local query = args.query
  if not query or query == "" then return "error: no query", false end
  ui.file_search(query)
  local results = search.query(query, args.top_k or 5, true)
  memory.log("search_files", { query = query, hits = #results })
  return search.format_results(results), true
end

local function exec_grep_search(args)
  local pattern = args.pattern
  if not pattern or pattern == "" then return "error: no pattern", false end
  local include = args.include or "*"
  ui.file_search("grep: " .. pattern)
  -- Use multiple --exclude-dir for /bin/sh compatibility (no brace expansion)
  local cmd = string.format("grep -rnE -e %q . --include=%q --exclude-dir=.git --exclude-dir=.jenova --exclude-dir=.crush --exclude-dir=node_modules --exclude-dir=build --exclude-dir=backups --exclude-dir=llama.cpp | head -20", pattern, include)
  local out, ok = exec_shell({ command = cmd })
  if not ok then return out, false end
  if out == "" then return "No matches found for '" .. pattern .. "'", true end
  return out, true
end

local function exec_think(args)
  local thought = args.thought or ""
  ui.think_status(#thought)
  memory.log("think", { thought = thought:sub(1, 300) })

  -- Extract plan from think output if it contains numbered steps
  local steps = {}
  for step in thought:gmatch("%d+[.%)%]]%s*([^\n]+)") do
    if #step > 5 and #step < 200 then
      steps[#steps + 1] = step:gsub("^%s+",""):gsub("%s+$","")
    end
  end
  if #steps >= 2 then
    memory.set_plan(steps)
    local plan_str = memory.format_plan()
    return "ok — plan recorded. Now execute step 1.\n" .. plan_str, true
  end

  return "ok — now act on your analysis. Call a tool.", true
end

TOOL_HANDLERS = {
  shell = exec_shell, read_file = exec_read_file, edit_file = exec_edit_file,
  write_file = exec_write_file, list_dir = exec_list_dir, search_files = exec_search_files,
  grep_search = exec_grep_search, think = exec_think,
}

-------------------------------------------------------------------------------
-- Tool execution with action tracking
-------------------------------------------------------------------------------
local function execute_tool(name, arguments)
  local handler = TOOL_HANDLERS[name]
  if not handler then return "error: unknown tool '"..tostring(name).."'", false end
  local args
  if type(arguments) == "string" then
    local ok, parsed = pcall(json.decode, arguments)
    if not ok then return "error: invalid JSON arguments", false end
    args = parsed
  elseif type(arguments) == "table" then args = arguments
  else args = {} end

  -- Pre-check: was this exact action already tried and failed?
  if name ~= "think" and name ~= "read_file" then
    local prior = memory.was_action_tried(name, args)
    if prior and prior.count >= 3 then
      return "BLOCKED: action tried "..prior.count.." times already. Try a completely different approach.", false
    end
    if prior and prior.failures >= 2 and prior.successes == 0 then
      return "BLOCKED: this already failed "..prior.failures.."x. Last: "..prior.last_result:sub(1, 80).."\nTry a DIFFERENT approach.", false
    end
  end

  local ok, result, success = pcall(handler, args)
  if not ok then
    local err = "error: "..tostring(result)
    memory.log_error(name, json.encode(args):sub(1,100), err)
    memory.record_action(name, args, err, false)
    return err, false
  end

  -- Default success to true if handler didn't return it
  if success == nil then success = not (result and result:match("^error:")) end

  -- Record this action for deduplication
  memory.record_action(name, args, result, success)

  -- Track edit failures
  if name == "edit_file" and not success then
    local ep = args.path or ""
    edit_fails_this_turn[ep] = (edit_fails_this_turn[ep] or 0) + 1
    if edit_fails_this_turn[ep] >= 3 then
      return result .. "\nSTOP: edit failed 3 times on "..ep..". Use read_file to see current content, or use write_file to replace the whole file.", false
    elseif edit_fails_this_turn[ep] >= 2 then
      return result .. "\nHINT: edit failed twice. Use read_file to see current content before retrying.", false
    end
  end

  -- Update plan progress
  local plan = memory.get_plan()
  if #plan > 0 and success and name ~= "think" then
    for i, step in ipairs(plan) do
      if step.status == "active" then
        memory.update_plan_step(i, "done", name .. " succeeded")
        memory.advance_plan()
        break
      end
    end
  end

  return result or "", success
end

-------------------------------------------------------------------------------
-- Fallback tool-call parser
-------------------------------------------------------------------------------
local function parse_tool_calls_from_content(content)
  if not content or content == "" then return nil end
  local calls = {}

  -- If it has <think> block, only look for tools AFTER </think>
  local actual_content = content
  local think_end = content:find("</think>", 1, true)
  if think_end then
    actual_content = content:sub(think_end + 8)
  end

  for block in actual_content:gmatch("<tool_call>(.-)<%s*/tool_call>") do
    local ok, tc = pcall(json.decode, block)
    if ok and tc and tc.name and TOOL_HANDLERS[tc.name] then
      calls[#calls+1] = { id = "fb_"..#calls, ["function"] = { name = tc.name, arguments = tc.arguments or {} } }
    end
    if #calls >= MAX_ACTIONS then break end
  end
  if #calls > 0 then dbg("fb", #calls.." <tool_call>"); return calls end

  local json_patterns = {
    '%{%s*"name"%s*:%s*"[^"]+"%s*,%s*"arguments"%s*:%s*%b{}%s*%}',
    '%{%s*"arguments"%s*:%s*%b{}%s*,%s*"name"%s*:%s*"[^"]+"%s*%}',
  }
  for _, pat in ipairs(json_patterns) do
    for block in actual_content:gmatch(pat) do
      local ok, tc = pcall(json.decode, block)
      if ok and tc and tc.name and TOOL_HANDLERS[tc.name] then
        calls[#calls+1] = { id = "fb_"..#calls, ["function"] = { name = tc.name, arguments = tc.arguments or {} } }
      end
      if #calls >= MAX_ACTIONS then break end
    end
    if #calls > 0 then dbg("fb", #calls.." bare JSON"); return calls end
  end

  for block in actual_content:gmatch("```json%s*(.-)%s*```") do
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
-------------------------------------------------------------------------------
local function intercept_code_block(content)
  if not content or content == "" or not last_read_path then return nil end

  local lo = content:lower()
  local has_write_intent = lo:match("writ[ei]%s+this%s+to") or lo:match("sav[ei]%s+this%s+to")
    or lo:match("updat[ei]%s+the%s+file") or lo:match("replac[ei]%s+the%s+file")
  if not has_write_intent then return nil end

  local code = content:match("```%w+%s*\n(.-)\n%s*```") or content:match("```%s*\n(.-)\n%s*```")
  if not code or #code < 100 then return nil end
  local lc = 1; for _ in code:gmatch("\n") do lc = lc+1 end
  if lc < 8 then return nil end

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

  ui.status_warn("intercepted code → write_file "..target)
  return {{ id = "intercept_1", ["function"] = { name = "write_file", arguments = { path = target, content = code } } }}
end

-------------------------------------------------------------------------------
-- Strip tool-call artifacts from content
-------------------------------------------------------------------------------
local function strip_tool_json(content)
  if not content or content == "" then return "" end
  local s = content
  s = s:gsub("<think>.-</think>", "")
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
-------------------------------------------------------------------------------
local function is_narrating(text)
  if not text or text == "" then return false, nil end
  local lo = text:lower()

  if lo:match("let'?s%s+%w") then return true, "lets" end
  if lo:match("let%s+me%s+%w") then return true, "lets" end
  if lo:match("i'?ll%s+%w") then return true, "future" end
  if lo:match("i%s+will%s+%w") then return true, "future" end
  if lo:match("i%s+need%s+to%s") then return true, "future" end
  if lo:match("we%s+[snc]") then return true, "we" end
  if lo:match("^%s*1%.%s") and lo:match("2%.%s") then return true, "plan" end
  if lo:match("here%s+is") or lo:match("here'?s%s+the") or lo:match("below%s+is") or lo:match("as%s+follows") then return true, "present" end
  if lo:match("the%s+updated%s") or lo:match("the%s+fixed%s") or lo:match("the%s+complete%s") or lo:match("the%s+modified%s") then return true, "present" end

  if text:match("```%w*%s*\n.-\n%s*```") then
    local code = text:match("```%w*%s*\n(.-)\n%s*```")
    if code and #code > 100 then return true, "code" end
  end

  return false, nil
end

-------------------------------------------------------------------------------
-- Nudge
-------------------------------------------------------------------------------
local function nudge_message(reason)
  local hint = ""
  if last_read_path then hint = " Target file: "..last_read_path end
  if reason == "code" then
    return 'Do NOT paste code. Write it to a file using a tool call. Respond ONLY with: {"name":"write_file","arguments":{"path":"FILE","content":"..."}}'..hint
  elseif reason == "plan" then
    return 'STOP planning. Execute the first step NOW. Respond ONLY with a tool call JSON.'..hint
  elseif reason == "present" then
    return 'Do not explain. Act. Respond with ONLY a tool call JSON.'..hint
  else
    return 'Respond with ONLY a tool call JSON — no text. Example: {"name":"read_file","arguments":{"path":"'..
      (last_read_path or "file.c")..'"}}'
  end
end

-------------------------------------------------------------------------------
-- HTTP
-------------------------------------------------------------------------------
local function http_post(url, body)
  return http.post(url, body, HTTP_TIMEOUT)
end

local function http_post_retry(url, body, label, max_retries)
  max_retries = max_retries or 2
  local code, resp
  for attempt = 1, max_retries do
    code, resp = http.post(url, body, HTTP_TIMEOUT)
    if code == 200 then return code, resp end
    if code == 0 then
      if attempt < max_retries then
        ui.status_warn(label.." timeout, retry "..attempt.."/"..max_retries)
        memory.log("retry", { label = label, attempt = attempt, code = code })
        ui.nonblocking_wait(2, "retrying ("..label..")")
      end
    elseif code >= 500 then
      if attempt < max_retries then
        ui.status_warn(label.." HTTP "..code..", retry "..attempt.."/"..max_retries)
        memory.log("retry", { label = label, attempt = attempt, code = code })
        ui.nonblocking_wait(1, "retrying ("..label..")")
      end
    else
      return code, resp
    end
  end
  return code, resp
end

-------------------------------------------------------------------------------
-- Chat API — v2: rebuilds system prompt each turn with fresh session context
-- v2.1: retry on timeout/5xx, higher max_tokens, truncation detection,
--        response diagnostics on every failure path
-------------------------------------------------------------------------------
local messages = {}

local function trim_messages(max)
  max = max or 24
  if #messages <= max then return end

  -- Identify the first message to keep
  local keep_from = #messages - max + 1
  if keep_from < 1 then keep_from = 1 end

  -- Symmetrical eviction: ensure we don't split an assistant tool call from its results
  -- If we land on a tool message, or an assistant message that has tool calls (which need responses), move back
  while keep_from > 1 and (messages[keep_from].role == "tool" or (messages[keep_from-1] and messages[keep_from-1].role == "assistant" and messages[keep_from-1].tool_calls)) do
    keep_from = keep_from - 1
  end

  local new_messages = {}
  for i = keep_from, #messages do
    local m = messages[i]
    -- Truncate old large tool results that we are still keeping
    if m.role == "tool" and m.content and #m.content > 2000 and i < #messages - 4 then
      m.content = m.content:sub(1, 1000) .. "\n...[truncated]"
    end
    new_messages[#new_messages+1] = m
  end

  messages = new_messages
end

local function estimate_token_count(msgs)
  local chars = 0
  if TOOLS then
    local ok, tools_json = pcall(json.encode, TOOLS)
    if ok then chars = chars + #tools_json end
  end
  for _, m in ipairs(msgs) do
    chars = chars + #(m.role or "")
    chars = chars + #(m.name or "")
    chars = chars + #(m.content or "")
    if m.tool_calls then
      for _, tc in ipairs(m.tool_calls) do
        chars = chars + #(tc["function"] and tc["function"].name or "")
        chars = chars + #(tc["function"] and tc["function"].arguments or "")
      end
    end
    chars = chars + 30 -- Structural overhead per message
  end
  return math.floor(chars / 2.8) + 100
end

local function chat(user_msg)
  if user_msg then
    messages[#messages+1] = { role = "user", content = user_msg }
    current_user_query = user_msg
  end
  trim_messages(24)

  local send = {{ role = "system", content = build_system_prompt() }}
  for _, m in ipairs(messages) do send[#send+1] = m end

  local prompt_est = estimate_token_count(send)
  local min_budget = math.min(2048, math.floor(CONTEXT_WINDOW * 0.25))
  
  while prompt_est > (CONTEXT_WINDOW - min_budget) and #messages > 1 do
    table.remove(messages, 1)
    send = {{ role = "system", content = build_system_prompt() }}
    for _, m in ipairs(messages) do send[#send+1] = m end
    prompt_est = estimate_token_count(send)
  end

  if prompt_est > (CONTEXT_WINDOW - min_budget) and #messages == 1 then
    local m = messages[1]
    if m.content and type(m.content) == "string" and #m.content > 1000 then
      m.content = m.content:sub(1, #m.content / 2) .. "\n...[force truncated to fit context]...\n"
      send = {{ role = "system", content = build_system_prompt() }, m}
      prompt_est = estimate_token_count(send)
    end
  end

  local budget = CONTEXT_WINDOW - prompt_est
  local max_tok = math.max(1, math.min(budget, 8192)) -- Cap at 8192 or budget, minimum 1

  local body = json.encode({
    model = MODEL,
    messages = send,
    tools = TOOLS,
    tool_choice = "auto",
    temperature = 0.6,
    max_tokens = max_tok,
  })
  dbg("req", "prompt_est="..prompt_est.." max_tokens="..max_tok.." body_len="..#body)

  spinner_start("cognizing")
  local code, resp = http_post_retry(ENDPOINT, body, "chat", 3)
  spinner_stop()
  dbg("resp-code", tostring(code))
  dbg("resp-body", resp)

  if code == 0 then
    local diag = string.format("timeout after %ds (prompt ~%d tok, max_tokens=%d, body=%db)",
      HTTP_TIMEOUT, prompt_est, max_tok, #body)
    ui.status_err(diag)
    memory.log_error("chat", "timeout", diag)
    ui.diagnostic("Tip: try /clear to reduce context, or check GPU utilization with /stats")
    return nil
  end
  if code ~= 200 then
    ui.status_err("HTTP "..code.." ("..#resp.."b)")
    ui.diagnostic(resp:sub(1, 300))
    memory.log_error("chat", "http_"..code, resp:sub(1, 200))
    return nil
  end

  local ok, data = pcall(json.decode, resp)
  if not ok or not data then
    ui.status_err("JSON decode failed ("..#resp.."b response)")
    ui.diagnostic("First 200 chars: "..resp:sub(1, 200))
    ui.diagnostic("Last 200 chars: "..resp:sub(-200))
    memory.log_error("chat", "json_fail", "len="..#resp.." start="..resp:sub(1,80))
    return nil
  end
  if not data.choices or #data.choices == 0 then
    ui.status_err("no choices in response")
    dbg("bad-resp", resp:sub(1, 500))
    return nil
  end

  local finish_reason = data.choices[1].finish_reason or "unknown"
  local usage = data.usage or {}
  local pt = usage.prompt_tokens or "?"
  local ct = usage.completion_tokens or "?"

  if finish_reason == "length" then
    ui.status_warn("response truncated (hit max_tokens="..max_tok..")")
    ui.diagnostic("prompt="..tostring(pt).." completion="..tostring(ct).." — model ran out of generation space")
    memory.log_error("chat", "truncated", "max_tokens="..max_tok.." pt="..tostring(pt).." ct="..tostring(ct))
  end

  local msg = data.choices[1].message
  if not msg then
    ui.status_err("no message in response (finish="..finish_reason..")")
    ui.diagnostic("prompt_tokens="..tostring(pt).." completion_tokens="..tostring(ct))
    return nil
  end

  local has_content = msg.content and msg.content:match("%S")
  local has_tools = msg.tool_calls and #msg.tool_calls > 0
  if not has_content and not has_tools then
    ui.status_warn("empty response from model")
    ui.diagnostic("finish_reason="..finish_reason..", prompt_tokens="..tostring(pt)..", completion_tokens="..tostring(ct))
    memory.log_error("chat", "empty_response", "finish="..finish_reason.." pt="..tostring(pt).." ct="..tostring(ct))

    local retry_msgs = {}
    for _, m in ipairs(send) do retry_msgs[#retry_msgs+1] = m end
    retry_msgs[#retry_msgs+1] = {
      role = "user",
      content = 'Respond with a tool call. Pick the most relevant tool. Respond ONLY with JSON: {"name":"tool_name","arguments":{...}}'
    }

    local retry_body = json.encode({
      model = MODEL,
      messages = retry_msgs,
      tools = TOOLS,
      tool_choice = "auto",
      temperature = 0.7,
      max_tokens = max_tok,
    })
    spinner_start("retrying")
    local rcode, rresp = http_post_retry(ENDPOINT, retry_body, "retry", 2)
    spinner_stop()
    if rcode == 200 then
      local rok, rdata = pcall(json.decode, rresp)
      if rok and rdata and rdata.choices and #rdata.choices > 0 then
        local rmsg = rdata.choices[1].message
        local r_has_content = rmsg and rmsg.content and rmsg.content:match("%S")
        local r_has_tools = rmsg and rmsg.tool_calls and #rmsg.tool_calls > 0
        if r_has_content or r_has_tools then
          ui.status_ok("retry succeeded")
          messages[#messages+1] = rmsg
          memory.log("assistant", { content = (rmsg.content or ""):sub(1,200), has_tc = r_has_tools, retry = true })
          return rmsg, rdata.choices[1].finish_reason
        end
      end
    end

    ui.status_err("model unable to generate — try /clear and rephrase")
    ui.diagnostic("Context may be too large ("..tostring(pt).." prompt tokens). Use /clear or simplify your request.")
    return nil
  end

  messages[#messages+1] = msg
  memory.log("assistant", {
    content = (msg.content or ""):sub(1,200),
    has_tc = msg.tool_calls ~= nil,
    finish = finish_reason,
    prompt_tok = pt,
    comp_tok = ct,
  })
  return msg, finish_reason
end

-------------------------------------------------------------------------------
-- Agent turn — v2: Plan → Execute → Reflect
-- Key changes:
--   1. Actions tracked and deduplicated via memory.record_action()
--   2. System prompt rebuilt each turn with fresh session context
--   3. Smarter loop detection: blocks actions that already failed
--   4. Plan tracking: multi-step tasks show progress
-------------------------------------------------------------------------------
local function agent_turn(user_msg)
  memory.log("user", { content = user_msg:sub(1,200) })

  -- Reset per-turn state
  files_written_this_turn = {}
  files_read_this_turn = {}
  last_read_path = nil
  last_read_content = nil
  edit_fails_this_turn = {}

  -- RAG: now handled automatically by the Intelligence Proxy Server
  local msg = chat(user_msg)
  if not msg then return end

  local turn = 0
  local nudge_count = 0
  local total_actions = 0

  while turn < MAX_TURNS do
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
          ui.status_err("unknown: "..tostring(name))
          break
        end

        -- Fix message history when using fallback
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

        status_turn(turn, name)
        local result, success = execute_tool(name, arguments)
        messages[#messages+1] = { role = "tool", content = result, tool_call_id = call_id }

        -- Reflect: if we got BLOCKED, add guidance
        if result:match("^BLOCKED:") then
          ui.status_warn("blocked — forcing different approach")
        end
      end

      if total_actions >= MAX_ACTIONS then
        msg = chat(nil)
        if not msg then return end
        break
      end
      msg = chat(nil)
      if not msg then return end

    elseif msg.content then
      local clean_content = strip_tool_json(msg.content)
      local narrating, reason = is_narrating(clean_content)

      if narrating and nudge_count < 3 then
        nudge_count = nudge_count + 1
        ui.nudge(nudge_count, 3, reason)
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

  if total_actions > 0 then
    memory.learn_from_turn(user_msg, total_actions, edit_fails_this_turn)
  end

  if msg and msg.content and msg.content ~= "" then
    local display = strip_tool_json(msg.content)
    if display ~= "" then
      ui.agent_response(display)
    end
  end
end

-------------------------------------------------------------------------------
-- Server health check
-------------------------------------------------------------------------------
local function check_server()
  local function try_health()
    local code = http.get(API_URL .. "/health", 3)
    return (code == 200 or code == 404 or code == 502 or code == 503)
  end

  if try_health() then return true end

  -- Backend not running. Try to launch it.
  spinner_start("starting jenova-ca backend")
  local root = jenova_root or "."
  local launcher = root .. "/bin/jenova-ca"
  local log_file = root .. "/.jenova/server_auto.log"
  local _ok,_err = pcall(function() os.execute("mkdir -p " .. root .. "/.jenova") end)
  if not _ok then ui.status_warn('failed to ensure .jenova: '..tostring(_err)) end
  
  -- Launch in background using daemon helper
  local daemon = require('daemon')
  local ok, pid_or_err = daemon.start_background({ launcher, '--daemon' }, log_file, root)
  if not ok then
    ui.status_err('failed to start backend: ' .. tostring(pid_or_err))
  end

  -- Wait for ready (up to 60s)
  for i = 1, 60 do
    if try_health() then
      spinner_stop()
      return true
    end
    local tv_sleep = ffi.new("struct timeval")
    tv_sleep.tv_sec = 1
    tv_sleep.tv_usec = 0
    ffi.C.select(0, nil, nil, nil, tv_sleep)
  end
  spinner_stop()
  return false
end

-------------------------------------------------------------------------------
-- Main REPL
-------------------------------------------------------------------------------
local function main()
  local p = io.popen("pwd")
  CWD = p and p:read("*l") or "."
  if p then p:close() end
  memory.init()

  local embed_ok = embed.init({ 
    script_dir = jenova_root,
  })
  if embed_ok then search.init_embeddings(embed) end

  local indexed = search.index_dir(".", {
    "lua","sh","c","h","cpp","py","js","ts","go","rs",
    "md","txt","json","yaml","yml","toml","conf","cfg",
    "html","css","Makefile","zig",
  })

  if not check_server() then
    ui.server_not_running(API_URL)
    os.exit(1)
  end

  local indexing = false
  local f = io.open(".jenova/index_queue.json", "r")
  if f then indexing = true; f:close() end

  io.write("\n")
  ui.draw_header()
  ui.draw_info({
    cwd = CWD,
    api_url = API_URL,
    indexed = tostring(indexed),
    indexing = indexing,
    embed = embed_ok and tostring(search.vec_count()) or nil,
    turns = tostring(MAX_TURNS),
    timeout = tostring(HTTP_TIMEOUT),
    session = memory.get_session_id(),
  })
  ui.separator("session")
  ui.draw_commands({
    "/clear", "/history", "/debug", "/context", "/reindex", "/files",
    "/search", "/errors", "/learn", "/plan", "/prefs", "/bench", "/stats", "/diag", "/quit",
  })

  while true do
    local idx_f = io.open(".jenova/index_queue.json", "r")
    if idx_f then
      idx_f:close()
      ui.dimtext("  (background indexing in progress...)\n")
    end

    ui.prompt()
    local ok_read, line = pcall(io.read, "*l")
    if not ok_read or not line then break end
    line = line:match("^%s*(.-)%s*$")
    if line == "" then goto continue end

    if line == "/quit" or line == "/exit" or line == "/q" then break
    elseif line == "/clear" then
      messages = {}; current_user_query = nil
      memory.clear_session()
      ui.status_ok("cleared (session + history)"); goto continue
    elseif line == "/history" then
      for i, m in ipairs(messages) do
        ui.dimtext(string.format("  [%d] %s%s: %s\n", i, m.role,
          m.tool_calls and " [TC]" or "", (m.content or ""):sub(1,80)))
      end; goto continue
    elseif line == "/debug" then
      DEBUG = not DEBUG
      ui.status_ok("debug "..(DEBUG and "ON" or "OFF")); goto continue
    elseif line == "/context" then
      ui.dimtext("=== System Prompt ===\n"..build_system_prompt().."\n=== End ===\n"); goto continue
    elseif line == "/reindex" then
      memory.invalidate_tree_cache()
      indexed = search.index_dir(".")
      ui.status_ok("reindexed "..indexed); goto continue
    elseif line == "/files" then
      ui.dimtext((memory.get_project_tree() or "(none)").."\n"); goto continue
    elseif line == "/search" then
      ui.boldtext("  query> ")
      local q = io.read("*l")
      if q and q ~= "" then ui.dimtext(search.format_results(search.query(q,10)).."\n") end
      goto continue
    elseif line == "/errors" then
      local errs = memory.get_errors(10)
      if #errs == 0 then ui.status_ok("no errors")
      else
        ui.boldtext("  Recent errors ("..#errs.."):\n")
        for _, e in ipairs(errs) do
          local ts = e.ts and os.date("%H:%M:%S", e.ts) or "?"
          ui.status(ICON.err, P.red,
            ui.fg(P.dim)..ts.." "..ui.RESET..ui.fg(P.red).."["..(e.tool or "?").."] "..ui.RESET
            ..(e.args or ""):sub(1,50)..ui.fg(P.dim)..": "..(e.error or ""):sub(1,80)..ui.RESET)
        end
      end; goto continue
    elseif line == "/learn" then
      local learned = memory.get_learned_patterns(10)
      if learned == "" then ui.status_ok("no learned patterns yet")
      else ui.dimtext(learned.."\n") end
      goto continue
    elseif line == "/plan" then
      local plan_str = memory.format_plan()
      if plan_str == "" then ui.status_ok("no active plan")
      else ui.dimtext(plan_str.."\n") end
      goto continue
    elseif line:match("^/prefs%s+(.+)=(.+)$") then
      local k, v = line:match("^/prefs%s+(.+)=(.+)$")
      k = k:match("^%s*(.-)%s*$"); v = v:match("^%s*(.-)%s*$")
      memory.set_preference(k, v)
      ui.status_ok("set "..k.." = "..v); goto continue
    elseif line == "/prefs" then
      local prefs = memory.get_preferences()
      if prefs == "" then ui.status_ok("no preferences set")
      else ui.dimtext("  Preferences:\n"..prefs.."\n") end
      goto continue
    elseif line == "/bench" then
      ui.status_info("Running benchmark...")
      local bench_cmd = jenova_root.."/llama.cpp/build/bin/llama-bench -m "..jenova_root.."/models/Qwen2.5-Coder-7B-Q5_K_M.gguf -ngl 99 -fa 1 -pg 512,128 2>&1"
      local bp = io.popen(bench_cmd)
      local bout = bp and bp:read("*a") or "(bench failed)"
      if bp then bp:close() end
      ui.dimtext(bout.."\n"); goto continue
    elseif line == "/stats" then
      local scode, sout = http.get(API_URL .. "/health", 3)
      local dur = memory.get_session_duration()
      local acts = memory.get_session_action_count()
      ui.dimtext("  Server: "..tostring(scode).." "..sout:sub(1,200).."\n")
      ui.dimtext("  Session: "..memory.get_session_id().." | "..dur.."s | "..acts.." actions\n")
      local mp = io.popen("nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null")
      local mout = mp and mp:read("*a") or ""
      if mp then mp:close() end
      if mout and mout ~= "" then ui.dimtext("  GPU: "..mout:gsub("\n","").."\n") end
      goto continue
    elseif line == "/diag" then
      ui.boldtext("\n  === DIAGNOSTICS ===\n\n")
      -- 1. Server health
      local t0 = ffi_defs.wall_time()
      local scode, sout = http.get(API_URL .. "/health", 5)
      local latency = math.floor((ffi_defs.wall_time() - t0) * 1000)
      ui.dimtext("  Server:     "..tostring(scode).." ("..latency.."ms, "..(sout or ""):gsub("\n"," "):sub(1,40)..")\n")
      if scode ~= 200 then
        ui.status_err("Server not healthy — check jenova-ca log")
      end
      -- 2. Config
      ui.dimtext("  Endpoint:   "..ENDPOINT.."\n")
      ui.dimtext("  Timeout:    "..HTTP_TIMEOUT.."s\n")
      ui.dimtext("  Max turns:  "..MAX_TURNS.."\n")
      ui.dimtext("  Context:    "..#messages.." messages in history\n")
      -- 3. Context size estimate
      local diag_send = {{ role = "system", content = build_system_prompt() }}
      for _, m in ipairs(messages) do diag_send[#diag_send+1] = m end
      local est_tokens = estimate_token_count(diag_send)
      ui.dimtext("  Est tokens: ~"..est_tokens.." (limit "..CONTEXT_WINDOW..")\n")
      if est_tokens > (CONTEXT_WINDOW * 0.75) then
        ui.status_warn("context is large — may cause slow/truncated responses. Consider /clear")
      end
      -- 4. Session errors
      local errs = memory.get_errors(5)
      ui.dimtext("  Errors:     "..#errs.." this session\n")
      for _, e in ipairs(errs) do
        ui.dimtext("    - ["..( e.tool or "?").."] "..(e.error or ""):sub(1,80).."\n")
      end
      -- 5. GPU
      local mp2 = io.popen("nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null")
      local mout2 = mp2 and mp2:read("*a") or ""
      if mp2 then mp2:close() end
      if mout2 and mout2 ~= "" then
        ui.dimtext("  GPU(NV):    "..mout2:gsub("\n","").."\n")
      end
      -- 6. Quick generation test
      ui.dimtext("  Gen test:   ")
      io.flush()
      local test_body = json.encode({
        model = MODEL,
        messages = {{ role = "user", content = "Reply with exactly: OK" }},
        max_tokens = 8,
        temperature = 0.0,
      })
      local gt0 = ffi_defs.wall_time()
      local gcode, gresp = http.post(ENDPOINT, test_body, 30)
      local gtime = math.floor((ffi_defs.wall_time() - gt0) * 1000)

      if gcode == 200 then
        local gok, gdata = pcall(json.decode, gresp)
        if gok and gdata and gdata.choices then
          local _ = gdata.choices[1].message
          local gtok = (gdata.usage or {}).completion_tokens or "?"
          ui.dimtext("OK ("..gtime.."ms, "..tostring(gtok).." tokens)\n")
        else
          ui.dimtext("FAIL — bad JSON ("..gtime.."ms)\n")
        end
      else
        ui.dimtext("FAIL — HTTP "..gcode.." ("..gtime.."ms)\n")
      end
      ui.boldtext("\n  === END DIAGNOSTICS ===\n\n")
      goto continue
    end

    while line:sub(-1) == "\\" do
      line = line:sub(1,-2).."\n"
      ui.continuation_prompt()
      local nl = io.read("*l"); if not nl then break end
      line = line .. nl
    end

    local tok, terr = pcall(agent_turn, line)
    if not tok then
      spinner_stop()
      if terr and terr:match("interrupted") then
        io.write("\n"); ui.status_warn("interrupted")
      else
        ui.status_err("error: "..tostring(terr):sub(1,100))
      end
    end
    ::continue::
  end
  ui.goodbye()
end

local ok, err = pcall(main)
if not ok then
  if err and err:match("interrupted") then
    ui.goodbye()
  else
    ui.fatal(tostring(err))
  end
end
