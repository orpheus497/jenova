#!/usr/bin/env luajit
-- coder-agent: Agentic coding assistant with shell/file access
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
local coder_root = os.getenv("CODER_ROOT") or script_dir:match("^(.*)/lib$") or script_dir .. "/.."
package.path = script_dir .. "/?.lua;" .. package.path

local json = require("json")
local http = require("http")
local memory = require("memory")
local search = require("search")
local embed = require("embed")
local ui = require("ui")

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
local HTTP_TIMEOUT = tonumber(os.getenv("CODER_TIMEOUT")) or 600
local MAX_ACTIONS  = 20

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

local function build_system_prompt()
  local parts = {}
  parts[#parts+1] = "You are coder, an expert autonomous coding agent on FreeBSD. CWD: " .. (CWD or ".")
  parts[#parts+1] = [[

TOOLS (call ONE per response as JSON):
  shell(command)       — Run shell commands: compile, test, diagnose, install (pkg, not apt).
  read_file(path)      — Read a file's contents. ALWAYS do this before editing.
  edit_file(path, old, new) — Replace exact text. old must match file content exactly.
  write_file(path, content) — Create/overwrite entire file. Use for NEW files only.
  list_dir(path)       — List directory contents.
  search_files(query, top_k) — Search project files by code identifiers/keywords.
  think(thought)       — Internal reasoning (hidden from user). Use to plan multi-step work.

RESPONSE FORMAT — respond ONLY with a JSON tool call:
{"name": "tool_name", "arguments": {"arg": "value"}}

WORKFLOW: Plan → Execute → Reflect
1. THINK first — plan your approach. Identify what you need to learn/verify.
2. READ before editing — never guess at file content.
3. VERIFY — check headers exist, libraries installed, code compiles.
4. EDIT precisely — copy exact whitespace from read_file output.
5. VALIDATE — compile/test after changes. If errors, fix immediately.
6. REFLECT — if something failed, try a DIFFERENT approach. Do NOT repeat.
7. REPORT — only after ALL work done, give 1-2 sentence summary.

CRITICAL:
- ONLY call tools. No narration, explanation, or code blocks.
- FreeBSD: use pkg (not apt), cc (not gcc), /usr/local/include for ports.
- If an action already failed (shown below), try something DIFFERENT.
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
  os.execute(full .. " >" .. tmpfile .. " 2>&1")
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

  if files_read_this_turn[path] and not files_written_this_turn[path] then
    ui.status_info("already read "..path)
    local content = files_read_this_turn[path]
    if #content > 16000 then
      content = content:sub(1,8000) .. "\n...[truncated "..#content.." bytes]...\n" .. content:sub(-4000)
    end
    return content .. "\n(already read this turn — proceed to edit)", true
  end

  ui.file_read(path)

  local f = io.open(path, "r")
  if not f then
    local bn = path:match("([^/]+)$")
    if bn and CWD then
      local p = io.popen(string.format("find %q -name %q -type f 2>/dev/null | head -1", CWD, bn))
      local found = p:read("*l"); p:close()
      if found and found ~= "" then
        ui.status_warn("found "..found)
        f = io.open(found, "r")
        if f then path = found end
      end
    end
    if not f then
      memory.log_error("read_file", path, "not found")
      ui.status_err("not found")
      return "error: file not found: "..path..". Use list_dir or search_files.", false
    end
  end

  local content = f:read("*a"); f:close()
  files_read_this_turn[path] = content
  last_read_path = path
  last_read_content = content
  local bn = path:match("([^/]+)$")
  if bn then files_read_this_turn[bn] = path end

  local kb = string.format("%.1fkb", #content/1024)
  ui.file_read_done(kb)

  if #content > 16000 then
    content = content:sub(1,8000) .. "\n...[truncated "..#content.." bytes]...\n" .. content:sub(-4000)
  end
  memory.log("read_file", { path = path, size = #content })
  return content, true
end

local function exec_edit_file(args)
  local path = resolve_path(args.path)
  local old_text = args.old
  local new_text = args.new
  if not path or path == "" then return "error: no path", false end
  if not old_text or old_text == "" then return "error: no 'old' text", false end
  if new_text == nil then return "error: no 'new' text", false end

  local content = files_read_this_turn[path]
  if not content then
    local f = io.open(path, "r")
    if not f then return "error: not found: "..path, false end
    content = f:read("*a"); f:close()
  end

  local s, e = content:find(old_text, 1, true)
  if not s then
    local norm_old = old_text:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
    if #norm_old < 3 then
      return "error: old text too short to match safely", false
    end
    local lines = {}
    for line in (content.."\n"):gmatch("([^\n]*)\n") do lines[#lines+1] = line end
    local norm_lines = {}
    for i, l in ipairs(lines) do norm_lines[i] = l:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","") end

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
      return "error: text not found in "..path..". Use read_file to check current content.", false
    end

    local old_line_count = 1
    for _ in old_text:gmatch("\n") do old_line_count = old_line_count + 1 end
    local found_end = math.min(found_start + old_line_count - 1, #lines)

    local actual_lines = {}
    for i = found_start, found_end do actual_lines[#actual_lines+1] = lines[i] end
    local actual_old = table.concat(actual_lines, "\n")

    s, e = content:find(actual_old, 1, true)
    if not s then
      return "error: fuzzy match failed in "..path..". Use read_file to check content.", false
    end
  end

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
      ui.file_backup(bk_path)
    end
  end

  local new_content = content:sub(1, s-1) .. new_text .. content:sub(e+1)
  ui.file_edit(path, #old_text, #new_text)

  local dir = path:match("^(.+)/[^/]+$")
  if dir then os.execute("mkdir -p "..dir) end
  local wf = io.open(path, "w")
  if not wf then
    memory.log_error("edit_file", path, "cannot write")
    return "error: cannot write "..path, false
  end
  wf:write(new_content); wf:close()

  files_read_this_turn[path] = new_content
  files_written_this_turn[path] = true
  last_read_path = path
  last_read_content = new_content
  memory.log("edit_file", { path = path, old_len = #old_text, new_len = #new_text })
  search.reindex_file(path)
  memory.invalidate_tree_cache()

  ui.status_ok("done")

  local ext = path:match("%.([^.]+)$")
  if ext == "c" or ext == "h" or ext == "cpp" or ext == "cc" or ext == "cxx" then
    local compile_cmd = string.format("cd %q && cc -fsyntax-only -Wall %q 2>&1", CWD or ".", path)
    ui.compile_check(path)
    local tmpf = os.tmpname()
    os.execute(compile_cmd .. " > " .. tmpf .. " 2>&1")
    local cf = io.open(tmpf, "r")
    local compile_out = cf and cf:read("*a") or ""
    if cf then cf:close() end
    os.remove(tmpf)
    if compile_out ~= "" and #compile_out > 5 then
      ui.status_warn("compile issues remain")
      return "ok: edited "..path.."\n\nCompile check:\n"..compile_out:sub(1, 2000).."\nFix the remaining errors.", true
    else
      ui.status_ok("compiles clean")
    end
  end

  return "ok: edited "..path, true
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
    local bk_dir = (CWD or ".") .. "/.coder/backups"
    os.execute("mkdir -p " .. bk_dir)
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
  if dir then os.execute("mkdir -p "..dir) end
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
    os.execute(compile_cmd .. " > " .. tmpf .. " 2>&1")
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
  think = exec_think,
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

  for block in content:gmatch("<tool_call>(.-)<%s*/tool_call>") do
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
    for block in content:gmatch(pat) do
      local ok, tc = pcall(json.decode, block)
      if ok and tc and tc.name and TOOL_HANDLERS[tc.name] then
        calls[#calls+1] = { id = "fb_"..#calls, ["function"] = { name = tc.name, arguments = tc.arguments or {} } }
      end
      if #calls >= MAX_ACTIONS then break end
    end
    if #calls > 0 then dbg("fb", #calls.." bare JSON"); return calls end
  end

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

-------------------------------------------------------------------------------
-- Chat API — v2: rebuilds system prompt each turn with fresh session context
-------------------------------------------------------------------------------
local messages = {}

local function trim_messages(max)
  max = max or 30
  if #messages <= max then return end
  local trimmed = {}
  if messages[1] then trimmed[1] = messages[1] end
  local start = math.max(2, #messages - max + 2)
  for i = start, #messages do
    local m = messages[i]
    if m.role == "tool" and m.content and #m.content > 1500 and i < #messages - 4 then
      m = { role = m.role, content = m.content:sub(1, 800) .. "\n...[truncated]", tool_call_id = m.tool_call_id }
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
  trim_messages(24)

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
    ui.status_err("timeout ("..HTTP_TIMEOUT.."s)")
    return nil
  end
  if code ~= 200 then
    ui.status_err("HTTP "..code)
    dbg("http-err", resp:sub(1,500))
    return nil
  end

  local ok, data = pcall(json.decode, resp)
  if not ok or not data or not data.choices or #data.choices == 0 then
    ui.status_err("bad response")
    dbg("bad-resp", resp:sub(1, 500))
    return nil
  end

  local msg = data.choices[1].message
  if not msg then
    ui.status_err("no message")
    return nil
  end

  local has_content = msg.content and msg.content:match("%S")
  local has_tools = msg.tool_calls and #msg.tool_calls > 0
  if not has_content and not has_tools then
    ui.status_warn("empty response from model")
    local fr = data.choices[1].finish_reason or "unknown"
    local pt = (data.usage or {}).prompt_tokens or "?"
    local ct = (data.usage or {}).completion_tokens or "?"
    ui.diagnostic("finish_reason="..fr..", prompt_tokens="..tostring(pt)..", completion_tokens="..tostring(ct))
    memory.log_error("chat", "empty_response", "finish="..fr.." pt="..tostring(pt).." ct="..tostring(ct))

    -- Single retry with a direct nudge
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
      max_tokens = 4096,
    })
    spinner_start("retrying")
    local rcode, rresp = http_post(ENDPOINT, retry_body)
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
    return nil
  end

  messages[#messages+1] = msg
  memory.log("assistant", { content = (msg.content or ""):sub(1,200), has_tc = msg.tool_calls ~= nil })
  return msg, data.choices[1].finish_reason
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

  -- RAG: hybrid search — only inject compact, relevant results
  rag_context = ""
  local rag = search.query(user_msg, 3, true)  -- reduced from 5 to 3 to save tokens
  if #rag > 0 then
    local parts = { "\nRelevant files:" }
    for i, r in ipairs(rag) do
      parts[#parts+1] = string.format("[%d] %s (%.0f%%, %db)", i, r.path, r.score * 100, r.size or 0)
      if r.snippet then
        parts[#parts+1] = r.snippet:sub(1, 500)  -- reduced from 800
      end
    end
    rag_context = table.concat(parts, "\n")
    if #rag_context > 2500 then  -- reduced from 4000
      rag_context = rag_context:sub(1, 2500) .. "\n...[truncated]"
    end
  end

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
      local narrating, reason = is_narrating(msg.content)

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
    ui.server_not_running(API_URL)
    os.exit(1)
  end

  io.write("\n")
  ui.draw_header()
  ui.draw_info({
    cwd = CWD,
    api_url = API_URL,
    indexed = tostring(indexed),
    embed = embed_ok and tostring(search.vec_count()) or nil,
    turns = tostring(MAX_TURNS),
    timeout = tostring(HTTP_TIMEOUT),
    session = memory.get_session_id(),
  })
  ui.separator("session")
  ui.draw_commands({
    "/clear", "/history", "/debug", "/context", "/reindex", "/files",
    "/search", "/errors", "/learn", "/plan", "/prefs", "/bench", "/stats", "/quit",
  })

  while true do
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
      local bench_cmd = coder_root.."/llama.cpp/build/bin/llama-bench -m "..coder_root.."/models/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf -ngl 99 -fa 1 -pg 512,128 2>&1"
      local bp = io.popen(bench_cmd); local bout = bp:read("*a"); bp:close()
      ui.dimtext(bout.."\n"); goto continue
    elseif line == "/stats" then
      local scode, sout = http.get(API_URL .. "/health", 3)
      local dur = memory.get_session_duration()
      local acts = memory.get_session_action_count()
      ui.dimtext("  Server: "..tostring(scode).." "..sout:sub(1,200).."\n")
      ui.dimtext("  Session: "..memory.get_session_id().." | "..dur.."s | "..acts.." actions\n")
      local mp = io.popen("nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null")
      local mout = mp:read("*a"); mp:close()
      if mout and mout ~= "" then ui.dimtext("  GPU: "..mout:gsub("\n","").."\n") end
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
