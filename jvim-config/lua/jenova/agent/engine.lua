-- jvim-config/lua/jenova/agent/engine.lua
-- 100% jvim-native Query Engine. No CLI dependencies.

local registry = require("jenova.agent.registry")
local M = {}

local function parse_tool_calls(text)
  local tool_uses = {}
  -- Only support the strict JSON fence protocol for jvim integration
  for json_str in text:gmatch("```json%s*\n?(.-)\n?```") do
    local ok, data = pcall(vim.json.decode, json_str)
    if ok and type(data) == "table" then
      local name = data.name or data.tool
      if name and registry.get(name) then
        table.insert(tool_uses, {
          id = "tc-" .. math.random(1000, 9999),
          name = name,
          input = data.arguments or data.parameters or data.input or {}
        })
      end
    end
  end
  return tool_uses
end

function M.new(options)
  local self = setmetatable({}, { __index = M })
  self.system_prompt = options.system_prompt or ""
  self.messages = {}
  self.on_text = options.on_text or function() end
  self.on_tool_use = options.on_tool_use or function() end
  self.on_tool_result = options.on_tool_result or function() end
  return self
end

function M:query(user_message, provider)
  table.insert(self.messages, { role = "user", content = user_message })
  
  local turns = 0
  while turns < 10 do
    turns = turns + 1
    
    local request = {
      model = "jenova",
      messages = self.messages,
      system = self.system_prompt,
      stream = true,
      -- We do NOT send tool definitions to the API. 
      -- We use the prompt-based Option B instead.
    }
    
    local raw_response = provider.generate_request(request)
    local tool_uses = parse_tool_calls(raw_response.content or "")
    
    if #tool_uses == 0 then
      if raw_response.content then
        table.insert(self.messages, { role = "assistant", content = raw_response.content })
        self.on_text(raw_response.content)
      end
      return
    end

    -- Process tools
    local assistant_msg = { role = "assistant", content = raw_response.content, tool_calls = {} }
    for _, tu in ipairs(tool_uses) do
      self.on_tool_use(tu.name, tu.input)
      local res, err = registry.execute(tu.name, tu.input, { cwd = vim.fn.getcwd() })
      local result_text = err or vim.json.encode(res)
      self.on_tool_result(tu.name, res or { error = err })
      
      table.insert(self.messages, {
        role = "user",
        content = "[Tool Result: " .. tu.name .. "]\n" .. result_text
      })
    end
  end
end

return M
