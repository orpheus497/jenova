#!/usr/bin/env luajit
-- coder-agent: Agentic coding assistant with shell/file access
-- Uses llama-server's OpenAI-compatible API with tool calling

local json = require("json")
local memory = require("memory")
local search = require("search")

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------
local API_URL = os.getenv("CODER_API_URL") or "http://127.0.0.1:8080"
local ENDPOINT = API_URL .. "/v1/chat/completions"
local MODEL = "qwen2.5-coder"
local MAX_TURNS = tonumber(os.getenv("CODER_MAX_TURNS")) or 10
local DEBUG = os.getenv("CODER_DEBUG") == "1"
local HOME = os.getenv("HOME") or "/home/orpheus497"
local CWD = nil -- set in main()

-- Track files written this turn to prevent write-read-rewrite loops
local files_written_this_turn = {}
local consecutive_same_tool = { name = nil, path = nil, count = 0 }

-------------------------------------------------------------------------------
-- Colors
-------------------------------------------------------------------------------
local C = {
  reset   = "\27[0m",
  bold    = "\27[1m",
  dim     = "\27[2m",
  red     = "\27[31m",
  green   = "\27[32m",
  yellow  = "\27[33m",
  blue    = "\27[34m",
  cyan    = "\27[36m",
  magenta = "\27[35m",
}

-------------------------------------------------------------------------------
-- Utility: expand ~ to HOME in paths
-------------------------------------------------------------------------------
local function expand_path(p)
  if not p then return p end
  if p:sub(1, 2) == "~/" then
    return HOME .. p:sub(2)
  elseif p == "~" then
    return HOME
  end
  return p
end

-------------------------------------------------------------------------------
-- Utility: confirm destructive actions (programmatic gate)
-------------------------------------------------------------------------------
local DESTRUCTIVE_SHELL_PATTERNS = {
  "^rm%s", "^rm$",
  "^mv%s",
  "^cp%s.*%-%-force", "^cp%s.*%-f%s",
  "^chmod%s", "^chown%s",
  "^dd%s",
  "^mkfs",
  "^rmdir%s",
  "^truncate%s",
  ">%s*[^>]",  -- redirect overwrite
  "^sed%s.*%-i",
  "^perl%s.*%-[ip]",
  "^git%s+reset%s+%-%-hard",
  "^git%s+clean%s+%-[fd]",
  "^git%s+checkout%s+%-%-",
  "^pkill%s", "^kill%s", "^killall%s",
}

local function is_destructive_shell(cmd)
  local trimmed = cmd:match("^%s*(.-)%s*$")
  for _, pat in ipairs(DESTRUCTIVE_SHELL_PATTERNS) do
    if trimmed:find(pat) then return true end
  end
  -- Check piped commands too
  for segment in trimmed:gmatch("|%s*(%S+)") do
    for _, pat in ipairs(DESTRUCTIVE_SHELL_PATTERNS) do
      if segment:find(pat) then return true end
    end
  end
  return false
end

local function confirm_action(action_type, detail)
  io.write("\n" .. C.yellow .. C.bold .. "  [confirm] " .. C.reset .. action_type .. "\n")
  io.write(C.dim .. "  " .. detail .. C.reset .. "\n")
  io.write(C.bold .. "  1" .. C.reset .. "=yes  "
    .. C.bold .. "2" .. C.reset .. "=no  "
    .. C.bold .. "3" .. C.reset .. "=suggest alternative\n")
  io.write(C.bold .. "  > " .. C.reset)
  io.flush()
  local choice = io.read("*l")
  if not choice then return "no", nil end
  choice = choice:match("^%s*(.-)%s*$")
  if choice == "1" or choice:lower() == "yes" or choice:lower() == "y" then
    return "yes", nil
  elseif choice == "3" then
    io.write(C.bold .. "  suggestion> " .. C.reset)
    io.flush()
    local suggestion = io.read("*l")
    return "suggest", suggestion
  else
    return "no", nil
  end
end

-------------------------------------------------------------------------------
-- Utility: debug print
-------------------------------------------------------------------------------
local function dbg(label, data)
  if not DEBUG then return end
  io.write(C.magenta .. "[DEBUG " .. label .. "] " .. C.reset)
  if type(data) == "string" then
    io.write(data:sub(1, 2000) .. "\n")
  else
    io.write(json.encode(data):sub(1, 2000) .. "\n")
  end
end

-------------------------------------------------------------------------------
-- Dynamic system prompt builder
-------------------------------------------------------------------------------
local function build_system_prompt()
  local parts = {}
  parts[#parts + 1] = [[You are an expert autonomous coding assistant running on FreeBSD with Vulkan GPUs.

## MANDATORY Rules
1. NEVER create, write, modify, or delete ANY file unless the user EXPLICITLY asked you to.
2. NEVER claim a file exists or doesn't exist without reading it or listing the directory first.
3. NEVER fabricate or guess file contents. Call read_file to find out.
4. ALWAYS read existing files BEFORE writing new ones. Understand what exists first.
5. Call ONE tool at a time. Wait for the result before deciding your next action.
6. Call tools immediately — do NOT narrate what you will do.
7. After receiving a tool result, continue with the next step. Do NOT stop to narrate.
8. If a tool returns "BLOCKED", the user denied it. Move on.
9. Write COMPLETE, COMPILABLE, SUBSTANTIVE code. Never write trivial placeholders like "Hello World" variants.
10. Once you write a file, you are DONE with that file. Do NOT read it back. Do NOT rewrite it. Do NOT append to it. Move to the next step or give your final answer.
11. NEVER use append_file to add code — it creates invalid files. Use write_file with the COMPLETE content.
12. When the user asks you to write code, study the existing code carefully, then write ONE file ONE time with quality content.

## Environment
- OS: FreeBSD 15.0
- Shell: /bin/sh (POSIX)
- GPUs: NVIDIA GTX 1650 Ti (Vulkan0) + Intel Xe Graphics TGL GT2 (Vulkan1)
- Working directory: ]] .. (CWD or ".") .. [[

## Tools Available
- `shell`: Run any shell command. Use for compilation, git, package management, testing, etc.
- `read_file`: Read file contents. Use to examine source code, configs, logs.
- `write_file`: Create or overwrite a file. ONLY when user asked you to write/create.
- `append_file`: Append to a file. ONLY when user asked you to write/modify.
- `list_dir`: List directory contents.
- `search_files`: Search project files by content keywords (BM25).

## Strategy
1. Read first, write second, report third. That's it.
2. Call ONE tool at a time.
3. After writing a file, give your final summary. Do NOT re-read or revise it.
4. If a tool returns an error, try to fix it and retry.
5. ALWAYS verify claims by calling tools before your final answer.]]

  local ctx = memory.format_for_prompt()
  if ctx ~= "" then
    parts[#parts + 1] = ctx
  end

  return table.concat(parts, "\n")
end

-------------------------------------------------------------------------------
-- Tool definitions (OpenAI format)
-------------------------------------------------------------------------------
local TOOLS = {
  {
    type = "function",
    ["function"] = {
      name = "shell",
      description = "Execute a shell command on FreeBSD and return stdout+stderr. Use for running programs, installing packages, git operations, compiling, etc.",
      parameters = {
        type = "object",
        properties = {
          command = {
            type = "string",
            description = "The shell command to execute"
          }
        },
        required = { "command" }
      }
    }
  },
  {
    type = "function",
    ["function"] = {
      name = "read_file",
      description = "Read the contents of a file and return them. Use for examining source code, configs, logs, etc.",
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "Absolute or relative path to the file"
          }
        },
        required = { "path" }
      }
    }
  },
  {
    type = "function",
    ["function"] = {
      name = "write_file",
      description = "Write content to a file, creating it if it doesn't exist or overwriting if it does.",
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "Absolute or relative path to the file"
          },
          content = {
            type = "string",
            description = "The content to write to the file"
          }
        },
        required = { "path", "content" }
      }
    }
  },
  {
    type = "function",
    ["function"] = {
      name = "append_file",
      description = "Append content to the end of an existing file.",
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "Absolute or relative path to the file"
          },
          content = {
            type = "string",
            description = "The content to append"
          }
        },
        required = { "path", "content" }
      }
    }
  },
  {
    type = "function",
    ["function"] = {
      name = "list_dir",
      description = "List the contents of a directory.",
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "Path to the directory (default: current directory)"
          }
        },
        required = {}
      }
    }
  },
  {
    type = "function",
    ["function"] = {
      name = "search_files",
      description = "Search project files by content keywords. Returns the most relevant files matching the query. Use this to find files related to a topic before reading them.",
      parameters = {
        type = "object",
        properties = {
          query = {
            type = "string",
            description = "Search keywords (e.g. 'error handling login', 'database connection pool')"
          },
          top_k = {
            type = "number",
            description = "Number of results to return (default: 5)"
          }
        },
        required = { "query" }
      }
    }
  },
}

-------------------------------------------------------------------------------
-- Tool execution
-------------------------------------------------------------------------------
local function exec_shell(args)
  local cmd = args.command
  if not cmd or cmd == "" then return "error: no command provided" end
  cmd = cmd:gsub("^~", HOME)
  cmd = cmd:gsub(" ~/", " " .. HOME .. "/")
  if is_destructive_shell(cmd) then
    local choice, suggestion = confirm_action("shell (destructive)", cmd)
    if choice == "no" then
      return "BLOCKED: user denied this command"
    elseif choice == "suggest" and suggestion then
      return "BLOCKED: user suggests instead: " .. suggestion
    end
  end
  io.write(C.dim .. "  $ " .. cmd .. C.reset .. "\n")
  io.flush()
  local tmpfile = os.tmpname()
  local exit_code = os.execute(cmd .. " >" .. tmpfile .. " 2>&1")
  local f = io.open(tmpfile, "r")
  local output = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(tmpfile)
  local code = 0
  if type(exit_code) == "number" then
    code = exit_code
  elseif type(exit_code) == "boolean" then
    code = exit_code and 0 or 1
  end
  if code ~= 0 then
    output = output .. "\n[exit code: " .. tostring(code) .. "]"
    memory.log_error("shell", cmd:sub(1, 100), output:sub(1, 200))
  end
  if #output > 16000 then
    output = output:sub(1, 8000) .. "\n\n... [truncated " .. #output .. " bytes] ...\n\n" .. output:sub(-4000)
  end
  memory.log("shell", { command = cmd:sub(1, 200), exit_code = code })
  return output
end

local function exec_read_file(args)
  local path = expand_path(args.path)
  if not path or path == "" then return "error: no path provided" end
  if files_written_this_turn[path] then
    return "You just wrote this file. You already know its contents. Do NOT re-read files you just wrote. Give your final answer."
  end
  io.write(C.dim .. "  [read] " .. path .. C.reset .. "\n")
  io.flush()
  local f = io.open(path, "r")
  if not f then
    local err = "error: cannot open file: " .. path
    memory.log_error("read_file", path, err)
    return err
  end
  local content = f:read("*a")
  f:close()
  if #content > 32000 then
    content = content:sub(1, 16000) .. "\n\n... [truncated " .. #content .. " bytes] ...\n\n" .. content:sub(-8000)
  end
  memory.log("read_file", { path = path, size = #content })
  return content
end

local function exec_write_file(args)
  local path = expand_path(args.path)
  local content = args.content
  if not path or path == "" then return "error: no path provided" end
  if not content then return "error: no content provided" end
  if files_written_this_turn[path] then
    return "ALREADY WRITTEN: you already wrote to " .. path .. " this turn. Do NOT rewrite it. Move on to your final answer."
  end
  local exists = io.open(path, "r")
  local label = exists and "overwrite file" or "create new file"
  if exists then exists:close() end
  local preview = #content > 120 and content:sub(1, 120) .. "..." or content
  local choice, suggestion = confirm_action(label, path .. " (" .. #content .. " bytes)\n  " .. C.dim .. preview:gsub("\n", "\\n") .. C.reset)
  if choice == "no" then
    return "BLOCKED: user denied writing to " .. path
  elseif choice == "suggest" and suggestion then
    return "BLOCKED: user suggests instead: " .. suggestion
  end
  io.write(C.dim .. "  [write] " .. path .. " (" .. #content .. " bytes)" .. C.reset .. "\n")
  io.flush()
  local dir = path:match("^(.+)/[^/]+$")
  if dir then os.execute("mkdir -p " .. dir) end
  local f = io.open(path, "w")
  if not f then
    local err = "error: cannot open file for writing: " .. path
    memory.log_error("write_file", path, err)
    return err
  end
  f:write(content)
  f:close()
  files_written_this_turn[path] = true
  memory.log("write_file", { path = path, size = #content })
  return "ok: wrote " .. #content .. " bytes to " .. path .. ". File is complete. Do NOT re-read or rewrite it. Give your final answer now."
end

local function exec_append_file(args)
  local path = expand_path(args.path)
  local content = args.content
  if not path or path == "" then return "error: no path provided" end
  if not content then return "error: no content provided" end
  if files_written_this_turn[path] then
    return "ALREADY WRITTEN: you already wrote to " .. path .. " this turn. Do NOT append or rewrite. Move on to your final answer."
  end
  local preview = #content > 120 and content:sub(1, 120) .. "..." or content
  local choice, suggestion = confirm_action("append to file", path .. " (" .. #content .. " bytes)\n  " .. C.dim .. preview:gsub("\n", "\\n") .. C.reset)
  if choice == "no" then
    return "BLOCKED: user denied appending to " .. path
  elseif choice == "suggest" and suggestion then
    return "BLOCKED: user suggests instead: " .. suggestion
  end
  io.write(C.dim .. "  [append] " .. path .. " (" .. #content .. " bytes)" .. C.reset .. "\n")
  io.flush()
  local f = io.open(path, "a")
  if not f then
    local err = "error: cannot open file for appending: " .. path
    memory.log_error("append_file", path, err)
    return err
  end
  f:write(content)
  f:close()
  files_written_this_turn[path] = true
  memory.log("append_file", { path = path, size = #content })
  return "ok: appended " .. #content .. " bytes to " .. path .. ". File is complete. Do NOT re-read or rewrite it. Give your final answer now."
end

local function exec_list_dir(args)
  local path = expand_path(args.path or ".")
  io.write(C.dim .. "  [ls] " .. path .. C.reset .. "\n")
  io.flush()
  return exec_shell({ command = "ls -la " .. path })
end

local function exec_search_files(args)
  local query = args.query
  if not query or query == "" then return "error: no query provided" end
  local top_k = args.top_k or 5
  io.write(C.dim .. "  [search] " .. query .. C.reset .. "\n")
  io.flush()
  local results = search.query(query, top_k)
  memory.log("search_files", { query = query, hits = #results })
  return search.format_results(results)
end

local TOOL_HANDLERS = {
  shell        = exec_shell,
  read_file    = exec_read_file,
  write_file   = exec_write_file,
  append_file  = exec_append_file,
  list_dir     = exec_list_dir,
  search_files = exec_search_files,
}

local function execute_tool(name, arguments)
  local handler = TOOL_HANDLERS[name]
  if not handler then
    return "error: unknown tool '" .. tostring(name) .. "'"
  end
  local args
  if type(arguments) == "string" then
    local ok, parsed = pcall(json.decode, arguments)
    if not ok then return "error: invalid JSON arguments: " .. tostring(parsed) end
    args = parsed
  elseif type(arguments) == "table" then
    args = arguments
  else
    args = {}
  end
  local ok, result = pcall(handler, args)
  if not ok then
    local err = "error: tool execution failed: " .. tostring(result)
    memory.log_error(name, json.encode(args):sub(1, 100), err)
    return err
  end
  return result or ""
end

-------------------------------------------------------------------------------
-- Content-fallback tool call parser
-- Extracts tool calls from model text when server PEG parser fails
-------------------------------------------------------------------------------
local function parse_tool_calls_from_content(content)
  if not content or content == "" then return nil end

  local calls = {}

  -- Pattern 1: <tool_call>{"name": ..., "arguments": ...}</tool_call> (Hermes 2 Pro format)
  for block in content:gmatch("<tool_call>(.-)<%s*/tool_call>") do
    local ok, tc = pcall(json.decode, block)
    if ok and tc and tc.name then
      calls[#calls + 1] = {
        id = "fallback_" .. tostring(#calls + 1),
        ["function"] = {
          name = tc.name,
          arguments = tc.arguments or {},
        }
      }
    end
  end

  if #calls > 0 then
    dbg("content-fallback", "extracted " .. #calls .. " tool call(s) from <tool_call> blocks")
    return calls
  end

  -- Pattern 2: bare JSON object with "name" and "arguments" keys
  for block in content:gmatch('%{%s*"name"%s*:%s*"[^"]+"%s*,%s*"arguments"%s*:%s*%b{}%s*%}') do
    local ok, tc = pcall(json.decode, block)
    if ok and tc and tc.name then
      calls[#calls + 1] = {
        id = "fallback_" .. tostring(#calls + 1),
        ["function"] = {
          name = tc.name,
          arguments = tc.arguments or {},
        }
      }
    end
  end

  if #calls > 0 then
    dbg("content-fallback", "extracted " .. #calls .. " tool call(s) from bare JSON")
    return calls
  end

  -- Pattern 3: ```json blocks containing tool calls
  for block in content:gmatch("```json%s*(.-)%s*```") do
    local ok, tc = pcall(json.decode, block)
    if ok and tc and tc.name then
      calls[#calls + 1] = {
        id = "fallback_" .. tostring(#calls + 1),
        ["function"] = {
          name = tc.name,
          arguments = tc.arguments or {},
        }
      }
    end
  end

  if #calls > 0 then
    dbg("content-fallback", "extracted " .. #calls .. " tool call(s) from ```json blocks")
    return calls
  end

  return nil
end

-------------------------------------------------------------------------------
-- Detect if model text indicates it INTENDED to call tools but didn't
-------------------------------------------------------------------------------
local INTENT_PATTERNS = {
  "let me (%w+) the",
  "i'?ll (%w+) the",
  "i will (%w+) the",
  "let me check",
  "let me read",
  "let me run",
  "let me look",
  "i'?ll check",
  "i'?ll read",
  "i'?ll run",
  "i need to (%w+)",
  "first,? i'?ll",
  "now i'?ll",
  "now let me",
}

local function text_indicates_tool_intent(text)
  if not text or text == "" then return false end
  local lower = text:lower()
  for _, pat in ipairs(INTENT_PATTERNS) do
    if lower:find(pat) then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- HTTP via curl
-------------------------------------------------------------------------------
local function http_post(url, body)
  local tmpfile_body = os.tmpname()
  local tmpfile_resp = os.tmpname()
  local f = io.open(tmpfile_body, "w")
  f:write(body)
  f:close()
  local cmd = string.format(
    'curl -s -S -X POST -H "Content-Type: application/json" -d @%s -o %s -w "%%{http_code}" %s 2>&1',
    tmpfile_body, tmpfile_resp, url
  )
  local p = io.popen(cmd)
  local status_output = p:read("*a")
  p:close()
  os.remove(tmpfile_body)

  local resp_f = io.open(tmpfile_resp, "r")
  local resp_body = resp_f and resp_f:read("*a") or ""
  if resp_f then resp_f:close() end
  os.remove(tmpfile_resp)

  local http_code = status_output:match("(%d%d%d)$") or "000"
  return tonumber(http_code), resp_body
end

-------------------------------------------------------------------------------
-- Chat API
-------------------------------------------------------------------------------
local messages = {}

local function chat(user_msg)
  if user_msg then
    messages[#messages + 1] = { role = "user", content = user_msg }
  end

  local payload = {
    model = MODEL,
    messages = {},
    tools = TOOLS,
    tool_choice = "auto",
  }

  local send_messages = {{ role = "system", content = build_system_prompt() }}
  for _, m in ipairs(messages) do
    send_messages[#send_messages + 1] = m
  end
  payload.messages = send_messages

  local body = json.encode(payload)
  dbg("request", body)

  io.write(C.dim .. "  thinking..." .. C.reset)
  io.flush()
  local code, resp = http_post(ENDPOINT, body)
  io.write("\r\27[K") -- clear "thinking..." line
  io.flush()

  dbg("response-code", tostring(code))
  dbg("response-body", resp)

  if code ~= 200 then
    io.write(C.red .. "API error (HTTP " .. code .. "): " .. resp:sub(1, 500) .. C.reset .. "\n")
    return nil
  end

  local ok, data = pcall(json.decode, resp)
  if not ok then
    io.write(C.red .. "JSON decode error: " .. tostring(data) .. C.reset .. "\n")
    dbg("raw-response", resp)
    return nil
  end

  if not data.choices or #data.choices == 0 then
    io.write(C.red .. "No choices in response" .. C.reset .. "\n")
    return nil
  end

  local choice = data.choices[1]
  local msg = choice.message
  if not msg then
    io.write(C.red .. "No message in choice" .. C.reset .. "\n")
    return nil
  end

  messages[#messages + 1] = msg
  memory.log("assistant", { content = (msg.content or ""):sub(1, 200), has_tool_calls = msg.tool_calls ~= nil })

  return msg, choice.finish_reason
end

-------------------------------------------------------------------------------
-- Agent loop: handle tool calls with content-fallback parsing
-------------------------------------------------------------------------------
local function agent_turn(user_msg)
  memory.log("user", { content = user_msg:sub(1, 200) })

  -- Reset per-turn state
  files_written_this_turn = {}
  consecutive_same_tool = { name = nil, path = nil, count = 0 }

  local msg, finish = chat(user_msg)
  if not msg then return end

  local turn = 0
  local max_nudges = 2
  local nudge_count = 0

  while turn < MAX_TURNS do
    -- Determine tool calls: structured first, then fallback from content
    local tool_calls = msg.tool_calls

    if (not tool_calls or #tool_calls == 0) and msg.content then
      tool_calls = parse_tool_calls_from_content(msg.content)
      if tool_calls then
        dbg("fallback", "using content-parsed tool calls instead of structured")
      end
    end

    if tool_calls and #tool_calls > 0 then
      turn = turn + 1
      nudge_count = 0

      local tc = tool_calls[1]
      local skipped = #tool_calls - 1

      if skipped > 0 then
        dbg("sequential", "executing 1 of " .. #tool_calls .. " calls, deferring " .. skipped)
      end

      local fn = tc["function"] or tc
      local name = fn.name or tc.name
      local arguments = fn.arguments or tc.arguments
      local tool_call_id = tc.id or ("call_" .. tostring(turn))

      -- Loop detection: if same tool+path 3 times, force stop
      local args_table
      if type(arguments) == "string" then
        local ok2, p2 = pcall(json.decode, arguments)
        args_table = ok2 and p2 or {}
      else
        args_table = arguments or {}
      end
      local tool_path = args_table.path or args_table.command or ""
      if name == consecutive_same_tool.name and tool_path == consecutive_same_tool.path then
        consecutive_same_tool.count = consecutive_same_tool.count + 1
      else
        consecutive_same_tool = { name = name, path = tool_path, count = 1 }
      end

      if consecutive_same_tool.count >= 3 then
        io.write(C.red .. "  [loop detected: " .. name .. " on " .. tool_path .. " x" .. consecutive_same_tool.count .. " — breaking]" .. C.reset .. "\n")
        messages[#messages + 1] = {
          role = "user",
          content = "[system: Loop detected. You have called " .. name .. " on the same target " .. consecutive_same_tool.count .. " times. STOP calling tools and give your final answer NOW.]"
        }
        msg, finish = chat(nil)
        if not msg then return end
        break
      end

      io.write(C.yellow .. "  [tool call, turn " .. turn .. "/" .. MAX_TURNS .. "]" .. C.reset .. "\n")

      io.write(C.cyan .. "  -> " .. (name or "?") .. C.reset .. "\n")
      local result = execute_tool(name, arguments)

      messages[#messages + 1] = {
        role = "tool",
        content = result,
        tool_call_id = tool_call_id,
      }

      if skipped > 0 then
        messages[#messages + 1] = {
          role = "user",
          content = "[system: Only one tool call was executed. Continue with the next step based on the result you just received. Call one tool at a time.]"
        }
      end

      msg, finish = chat(nil)
      if not msg then return end

    elseif msg.content and text_indicates_tool_intent(msg.content) and nudge_count < max_nudges then
      nudge_count = nudge_count + 1
      dbg("nudge", "model indicated tool intent, nudging (" .. nudge_count .. "/" .. max_nudges .. ")")
      messages[#messages + 1] = {
        role = "user",
        content = "[system: You said you would use a tool. Do it now — call the tool directly.]"
      }
      msg, finish = chat(nil)
      if not msg then return end

    else
      break
    end
  end

  -- Print final text response
  if msg.content and msg.content ~= "" then
    -- Strip any lingering <tool_call> blocks from display
    local display = msg.content:gsub("<tool_call>.-</tool_call>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if display ~= "" then
      io.write("\n" .. C.green .. C.bold .. "coder" .. C.reset .. ": " .. display .. "\n\n")
    end
  end
end

-------------------------------------------------------------------------------
-- Check server health
-------------------------------------------------------------------------------
local function check_server()
  local p = io.popen("curl -s -o /dev/null -w '%{http_code}' " .. API_URL .. "/health 2>/dev/null")
  local code = p:read("*a")
  p:close()
  return code == "200"
end

-------------------------------------------------------------------------------
-- Main REPL
-------------------------------------------------------------------------------
local function main()
  -- Get working directory
  local p = io.popen("pwd")
  CWD = p:read("*l")
  p:close()

  -- Initialize memory
  memory.init()

  -- Index project files for BM25 search
  local indexed = search.index_dir(".", {
    "lua", "sh", "c", "h", "cpp", "py", "js", "ts", "go", "rs",
    "md", "txt", "json", "yaml", "yml", "toml", "conf", "cfg",
    "html", "css", "Makefile",
  })

  -- Check server
  if not check_server() then
    io.write(C.red .. "llama-server not running at " .. API_URL .. C.reset .. "\n")
    io.write(C.dim .. "Start it with: ./coder-server" .. C.reset .. "\n")
    os.exit(1)
  end

  io.write(C.bold .. C.blue .. "coder" .. C.reset .. " — autonomous coding assistant\n")
  io.write(C.dim .. "Server: " .. API_URL .. " | Turns: " .. MAX_TURNS .. " | Files indexed: " .. indexed .. C.reset .. "\n")
  io.write(C.dim .. "Commands: /clear /history /debug /context /quit" .. C.reset .. "\n\n")

  while true do
    io.write(C.bold .. "you" .. C.reset .. ": ")
    io.flush()
    local line = io.read("*l")
    if not line then break end

    line = line:match("^%s*(.-)%s*$")
    if line == "" then goto continue end

    if line == "/quit" or line == "/exit" or line == "/q" then
      break

    elseif line == "/clear" then
      messages = {}
      io.write(C.dim .. "Conversation cleared.\n" .. C.reset)
      goto continue

    elseif line == "/history" then
      for i, m in ipairs(messages) do
        io.write(C.dim .. string.format("[%d] %s: %s\n", i, m.role, (m.content or "(tool_calls)"):sub(1, 80)) .. C.reset)
      end
      goto continue

    elseif line == "/debug" then
      DEBUG = not DEBUG
      io.write(C.dim .. "Debug mode: " .. (DEBUG and "ON" or "OFF") .. "\n" .. C.reset)
      goto continue

    elseif line == "/context" then
      io.write(C.dim .. "=== System Prompt ===\n" .. build_system_prompt() .. "\n=== End ===\n" .. C.reset)
      goto continue

    elseif line == "/reindex" then
      memory.invalidate_tree_cache()
      indexed = search.index_dir(".")
      io.write(C.dim .. "Re-indexed " .. indexed .. " files.\n" .. C.reset)
      goto continue
    end

    -- Multiline input: if line ends with \, keep reading
    while line:sub(-1) == "\\" do
      line = line:sub(1, -2) .. "\n"
      io.write(C.dim .. "... " .. C.reset)
      io.flush()
      local next_line = io.read("*l")
      if not next_line then break end
      line = line .. next_line
    end

    agent_turn(line)

    ::continue::
  end

  io.write(C.dim .. "\nbye\n" .. C.reset)
end

main()
