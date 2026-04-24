-- jenova/agent/engine.lua
-- 100% jvim-native Query Engine. No CLI dependencies.

local registry = require("jenova.agent.registry")
local M = {}

-- Extract all ```json ... ``` blocks from a response string.
-- Lua's `.` doesn't match newlines, so we scan boundaries manually.
local function extract_json_blocks(text)
  local blocks = {}
  local pos = 1
  while pos <= #text do
    local s = text:find("```json", pos, true)
    if not s then break end
    local body_start = s + 7  -- skip "```json"
    -- Skip optional leading newline
    if text:sub(body_start, body_start) == "\n" then
      body_start = body_start + 1
    end
    local e = text:find("```", body_start, true)
    if not e then break end
    -- Trim trailing whitespace from the block
    local raw = text:sub(body_start, e - 1):gsub("%s+$", "")
    table.insert(blocks, raw)
    pos = e + 3
  end
  return blocks
end

local function parse_tool_calls(text)
  local tool_uses = {}
  for _, json_str in ipairs(extract_json_blocks(text)) do
    local ok, data = pcall(vim.json.decode, json_str)
    if ok and type(data) == "table" then
      local name = data.name or data.tool
      if name and registry.get(name) then
        table.insert(tool_uses, {
          id    = "tc-" .. math.random(1000, 9999),
          name  = name,
          input = data.arguments or data.parameters or data.input or {},
        })
      end
    end
  end
  return tool_uses
end

function M.new(options)
  local self = setmetatable({}, { __index = M })
  self.system_prompt  = options.system_prompt  or ""
  self.messages       = {}
  self.on_text        = options.on_text        or function() end
  self.on_tool_use    = options.on_tool_use    or function() end
  self.on_tool_result = options.on_tool_result or function() end
  self.on_thinking    = options.on_thinking    or function() end
  self._stop          = false
  return self
end

function M:query(user_message, provider)
  self._stop = false
  table.insert(self.messages, { role = "user", content = user_message })

  local turns = 0
  while turns < 10 do
    if self._stop then return end
    turns = turns + 1

    -- Between tool turns, signal "thinking" so the spinner updates.
    if turns > 1 then
      self.on_thinking()
    end

    local request = {
      model    = "jenova",
      messages = self.messages,
      system   = self.system_prompt,
      stream   = true,
      -- Tool schemas are not sent to the API. The model is instructed via
      -- the system prompt to emit tool calls as ```json { "name": ..., "arguments": {...} } ```
      -- blocks. This works with any backend that follows prompt instructions.
    }

    -- Stream the response: on_text fires per chunk so the buffer updates live.
    -- provider.generate_request accumulates the full content for tool-call parsing
    -- and simultaneously calls on_chunk (which is self.on_text) per delta.
    local content = provider.generate_request(request, self.on_text)

    local tool_uses = parse_tool_calls(content)

    if #tool_uses == 0 then
      -- Pure text response — content was already streamed chunk by chunk via on_text.
      -- Commit to history so subsequent turns have the full context.
      if content ~= "" then
        table.insert(self.messages, { role = "assistant", content = content })
      end
      return
    end

    -- Tool turn: commit the assistant's full response (which includes the JSON fences)
    -- then execute each tool and feed the results back as user messages.
    table.insert(self.messages, { role = "assistant", content = content })

    for _, tu in ipairs(tool_uses) do
      if self._stop then return end
      self.on_tool_use(tu.name, tu.input)
      local res, err = registry.execute(tu.name, tu.input, { cwd = vim.fn.getcwd() })
      -- Check again after the tool returns — it may have yielded (e.g. shell) and
      -- the user could have pressed stop while it was running.
      if self._stop then return end
      local result_text = err and ("Error: " .. err) or vim.json.encode(res)
      self.on_tool_result(tu.name, res or { error = err })
      table.insert(self.messages, {
        role    = "user",
        content = "[Tool Result: " .. tu.name .. "]\n" .. result_text,
      })
    end
  end

  error("agent: maximum turn limit (10) reached without a final response")
end

return M
