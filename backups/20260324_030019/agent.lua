#!/usr/bin/env luajit
-- coder-agent: Agentic coding assistant with shell/file access
-- Uses llama-server's OpenAI-compatible API with tool calling

local json = require("json")

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------
local API_URL = os.getenv("CODER_API_URL") or "http://127.0.0.1:8080"
local ENDPOINT = API_URL .. "/v1/chat/completions"
local MODEL = "qwen2.5-coder"
local MAX_TURNS = tonumber(os.getenv("CODER_MAX_TURNS")) or 20
local SYSTEM_PROMPT = os.getenv("CODER_SYSTEM_PROMPT") or
  "You are my coding assistant on FreeBSD. You have access to tools for running shell commands, reading files, and writing files. Use them when needed to help me. Always show the results of commands you run. Be concise."

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
}

-------------------------------------------------------------------------------
-- Tool execution
-------------------------------------------------------------------------------
local function exec_shell(args)
  local cmd = args.command
  if not cmd or cmd == "" then return "error: no command provided" end
  io.write(C.dim .. "  $ " .. cmd .. C.reset .. "\n")
  local tmpfile = os.tmpname()
  local exit_code = os.execute(cmd .. " >" .. tmpfile .. " 2>&1")
  local f = io.open(tmpfile, "r")
  local output = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(tmpfile)
  -- Normalize exit code (Lua 5.1/LuaJIT returns number, not bool)
  local code = 0
  if type(exit_code) == "number" then
    code = exit_code
  elseif type(exit_code) == "boolean" then
    code = exit_code and 0 or 1
  end
  if code ~= 0 then
    output = output .. "\n[exit code: " .. tostring(code) .. "]"
  end
  -- Truncate very long output
  if #output > 16000 then
    output = output:sub(1, 8000) .. "\n\n... [truncated " .. #output .. " bytes] ...\n\n" .. output:sub(-4000)
  end
  return output
end

local function exec_read_file(args)
  local path = args.path
  if not path or path == "" then return "error: no path provided" end
  io.write(C.dim .. "  [read] " .. path .. C.reset .. "\n")
  local f = io.open(path, "r")
  if not f then return "error: cannot open file: " .. path end
  local content = f:read("*a")
  f:close()
  if #content > 32000 then
    content = content:sub(1, 16000) .. "\n\n... [truncated " .. #content .. " bytes] ...\n\n" .. content:sub(-8000)
  end
  return content
end

local function exec_write_file(args)
  local path = args.path
  local content = args.content
  if not path or path == "" then return "error: no path provided" end
  if not content then return "error: no content provided" end
  io.write(C.dim .. "  [write] " .. path .. " (" .. #content .. " bytes)" .. C.reset .. "\n")
  local f = io.open(path, "w")
  if not f then return "error: cannot open file for writing: " .. path end
  f:write(content)
  f:close()
  return "ok: wrote " .. #content .. " bytes to " .. path
end

local function exec_append_file(args)
  local path = args.path
  local content = args.content
  if not path or path == "" then return "error: no path provided" end
  if not content then return "error: no content provided" end
  io.write(C.dim .. "  [append] " .. path .. " (" .. #content .. " bytes)" .. C.reset .. "\n")
  local f = io.open(path, "a")
  if not f then return "error: cannot open file for appending: " .. path end
  f:write(content)
  f:close()
  return "ok: appended " .. #content .. " bytes to " .. path
end

local function exec_list_dir(args)
  local path = args.path or "."
  io.write(C.dim .. "  [ls] " .. path .. C.reset .. "\n")
  return exec_shell({ command = "ls -la " .. path })
end

local TOOL_HANDLERS = {
  shell      = exec_shell,
  read_file  = exec_read_file,
  write_file = exec_write_file,
  append_file = exec_append_file,
  list_dir   = exec_list_dir,
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
  else
    args = arguments or {}
  end
  local ok, result = pcall(handler, args)
  if not ok then
    return "error: tool execution failed: " .. tostring(result)
  end
  return result or ""
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
    messages = messages,
    tools = TOOLS,
    tool_choice = "auto",
  }

  -- Insert system prompt as first message
  local send_messages = {{ role = "system", content = SYSTEM_PROMPT }}
  for _, m in ipairs(messages) do
    send_messages[#send_messages + 1] = m
  end
  payload.messages = send_messages

  local body = json.encode(payload)
  local code, resp = http_post(ENDPOINT, body)

  if code ~= 200 then
    io.write(C.red .. "API error (HTTP " .. code .. "): " .. resp:sub(1, 500) .. C.reset .. "\n")
    return nil
  end

  local ok, data = pcall(json.decode, resp)
  if not ok then
    io.write(C.red .. "JSON decode error: " .. tostring(data) .. C.reset .. "\n")
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

  -- Add assistant message to history
  messages[#messages + 1] = msg

  return msg, choice.finish_reason
end

-------------------------------------------------------------------------------
-- Agent loop: handle tool calls
-------------------------------------------------------------------------------
local function agent_turn(user_msg)
  local msg, finish = chat(user_msg)
  if not msg then return end

  local turn = 0
  while msg.tool_calls and #msg.tool_calls > 0 and turn < MAX_TURNS do
    turn = turn + 1
    io.write(C.yellow .. "  [tools: " .. #msg.tool_calls .. " call(s), turn " .. turn .. "/" .. MAX_TURNS .. "]" .. C.reset .. "\n")

    for _, tc in ipairs(msg.tool_calls) do
      local fn = tc["function"] or tc
      local name = fn.name or tc.name
      local arguments = fn.arguments or tc.arguments
      local tool_call_id = tc.id or ("call_" .. tostring(turn))

      io.write(C.cyan .. "  -> " .. name .. C.reset .. "\n")
      local result = execute_tool(name, arguments)

      -- Add tool result to messages
      messages[#messages + 1] = {
        role = "tool",
        content = result,
        tool_call_id = tool_call_id,
      }
    end

    -- Get next response
    msg, finish = chat(nil)
    if not msg then return end
  end

  -- Print final text response
  if msg.content and msg.content ~= "" then
    io.write("\n" .. C.green .. C.bold .. "coder" .. C.reset .. ": " .. msg.content .. "\n\n")
  end
end

-------------------------------------------------------------------------------
-- Check server health
-------------------------------------------------------------------------------
local function wait_for_server()
  io.write(C.dim .. "Waiting for llama-server..." .. C.reset)
  io.flush()
  for _ = 1, 60 do
    local p = io.popen("curl -s -o /dev/null -w '%{http_code}' " .. API_URL .. "/health 2>/dev/null")
    local code = p:read("*a")
    p:close()
    if code == "200" then
      io.write(C.green .. " ready\n" .. C.reset)
      return true
    end
    io.write(".")
    io.flush()
    os.execute("sleep 1")
  end
  io.write(C.red .. " timeout\n" .. C.reset)
  return false
end

-------------------------------------------------------------------------------
-- Main REPL
-------------------------------------------------------------------------------
local function main()
  -- Check if server is already running, or wait
  local p = io.popen("curl -s -o /dev/null -w '%{http_code}' " .. API_URL .. "/health 2>/dev/null")
  local code = p:read("*a")
  p:close()

  if code ~= "200" then
    io.write(C.red .. "llama-server not running at " .. API_URL .. C.reset .. "\n")
    io.write(C.dim .. "Start it with: ./coder-server" .. C.reset .. "\n")
    os.exit(1)
  end

  io.write(C.bold .. C.blue .. "coder" .. C.reset .. " — coding assistant with shell/file access\n")
  io.write(C.dim .. "Server: " .. API_URL .. " | Max turns: " .. MAX_TURNS .. C.reset .. "\n")
  io.write(C.dim .. "Commands: /clear, /history, /quit" .. C.reset .. "\n\n")

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
