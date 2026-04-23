local M = {}

local function ep()
  return require("jenova.endpoints")
end

local CHAT_DIR = vim.fn.stdpath("state") .. "/jenova/chats"
local MODEL = "jenova"
local SECRET = "jenova-local"
local TEMPERATURE = 0.7
local TOP_P = 0.9
local CHAT_WIDTH = 60

-- ── Mode state ────────────────────────────────────────────────────────────────
-- agent_mode=true  → full QueryEngine loop with tool use and editor context
-- agent_mode=false → plain streaming direct to proxy (legacy behaviour)
local agent_mode = true

local active_job  = nil
local toggle_buf  = nil
local toggle_win  = nil

-- ── Agent activity state (read by statusline) ─────────────────────────────────
-- These are module-level so jvim.statusline can poll them without requiring
-- a direct callback registration.
M._agent_running   = false   -- true while a query coroutine is active
M._agent_tool      = nil     -- name of currently running tool, or nil
M._agent_turn      = 0       -- current turn index
M._agent_tokens_in  = 0
M._agent_tokens_out = 0
M._agent_cost       = 0.0

-- ── Utilities ─────────────────────────────────────────────────────────────────

local function ensure_chat_dir()
  if vim.fn.isdirectory(CHAT_DIR) == 0 then
    vim.fn.mkdir(CHAT_DIR, "p")
  end
end

local function chat_filepath(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and name:find(CHAT_DIR, 1, true) then
    return name
  end
  return nil
end

local function new_chat_filename()
  ensure_chat_dir()
  local pid = vim.fn.getpid()
  local suffix = string.format("%04x", math.random(0, 0xFFFF))
  return CHAT_DIR .. "/" .. os.date("%Y%m%d_%H%M%S") .. "_" .. pid .. "_" .. suffix .. ".md"
end

local function is_chat_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  return name:find("/jenova/chats/", 1, true) ~= nil
end

local function set_chat_buf_options(buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = ""
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = true
end

local function mode_tag()
  return agent_mode and "[agent]" or "[chat]"
end

-- ── Header / parsing ──────────────────────────────────────────────────────────

local function build_header(topic)
  topic = topic or "Jenova Chat"
  return string.format(
    "# topic: %s  %s\n- model: %s\n- temperature: %s\n- top_p: %s\n",
    topic, mode_tag(), MODEL, TEMPERATURE, TOP_P
  )
end

-- Update the header line of an existing chat buffer to reflect the current mode.
local function refresh_header_mode(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  -- Replace or append the mode tag
  local updated = first:gsub("%[agent%]", ""):gsub("%[chat%]", "")
  updated = vim.trim(updated) .. "  " .. mode_tag()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { updated })
end

local function init_chat_buffer(buf, topic)
  local header = build_header(topic)
  local init_lines = vim.split(header .. "---\n\n## user\n\n", "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, init_lines)
  set_chat_buf_options(buf)
end

local function parse_messages(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local messages = {}
  local found_header_end = false
  local current_role = nil
  local current_content = {}

  local function flush()
    if current_role then
      local content = vim.trim(table.concat(current_content, "\n"))
      if content ~= "" then
        table.insert(messages, { role = current_role, content = content })
      end
    end
  end

  for i, line in ipairs(lines) do
    if not found_header_end then
      if line:match("^%-%-%-") and i > 1 then
        found_header_end = true
      end
    else
      if line:match("^## user%s*$") then
        flush()
        current_role = "user"
        current_content = {}
      elseif line:match("^## assistant%s*$") then
        flush()
        current_role = "assistant"
        current_content = {}
      elseif current_role then
        table.insert(current_content, line)
      end
    end
  end

  flush()
  return messages
end

-- ── File I/O ──────────────────────────────────────────────────────────────────

local function save_chat(buf)
  if not is_chat_buf(buf) then return end
  local path = chat_filepath(buf)
  if not path then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ret = vim.fn.writefile(lines, path)
  if ret == 0 then
    vim.bo[buf].modified = false
  else
    vim.notify("Failed to save chat: " .. path, vim.log.levels.ERROR, { title = "Jenova" })
  end
end

-- ── Scroll ────────────────────────────────────────────────────────────────────

local function scroll_to_bottom(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
  end
end

-- ── Window management ─────────────────────────────────────────────────────────

local function open_chat_split(path)
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, CHAT_WIDTH)

  if path and vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  else
    local new_path = path or new_chat_filename()
    vim.cmd("edit " .. vim.fn.fnameescape(new_path))
    local buf = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_line_count(buf) <= 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
      init_chat_buffer(buf)
    end
  end

  local buf = vim.api.nvim_get_current_buf()
  set_chat_buf_options(buf)

  if not vim.b[buf]._jenova_chat_autocmd then
    local group = vim.api.nvim_create_augroup("JenovaChatAutoSave_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
      group = group,
      buffer = buf,
      callback = function()
        if vim.bo[buf].modified then
          save_chat(buf)
        end
      end,
    })
    vim.b[buf]._jenova_chat_autocmd = true
  end

  scroll_to_bottom(buf)

  toggle_buf = buf
  toggle_win = win
  return buf, win
end

-- ── Generation control ────────────────────────────────────────────────────────

local function stop_generation()
  if active_job then
    active_job:kill(9)
    active_job = nil
  end
  -- Also signal the agent to abort.
  local ok, agent = pcall(require, "jenova.agent")
  if ok and agent then
    pcall(agent.stop)
  end
end

-- ── Buffer helpers ────────────────────────────────────────────────────────────

local function append_user_section(buf, msg_text)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last = lines[#lines] or ""

  local new_lines = {}
  local needs_user_header = true
  for i = #lines, math.max(1, #lines - 5), -1 do
    if lines[i] and lines[i]:match("^## user%s*$") then
      local has_content = false
      for j = i + 1, #lines do
        if vim.trim(lines[j]) ~= "" then
          has_content = true
          break
        end
      end
      if not has_content then
        needs_user_header = false
      end
      break
    end
  end

  if needs_user_header then
    if vim.trim(last) ~= "" then
      table.insert(new_lines, "")
    end
    table.insert(new_lines, "## user")
    table.insert(new_lines, "")
  end

  for _, l in ipairs(vim.split(msg_text, "\n", { plain = true })) do
    table.insert(new_lines, l)
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, new_lines)
end

-- ── Plain streaming (conversation mode) ───────────────────────────────────────

local function stream_response(buf, messages, on_done)
  stop_generation()

  if vim.fn.executable("curl") ~= 1 then
    vim.notify("curl not found. Install curl to enable chat streaming.", vim.log.levels.ERROR, { title = "Jenova" })
    return
  end

  local url = ep().proxy_url()
  local payload = vim.json.encode({
    model = MODEL,
    messages = messages,
    temperature = TEMPERATURE,
    top_p = TOP_P,
    stream = true,
    max_tokens = 16384,
  })

  local tmpfile = vim.fn.tempname() .. ".json"
  if vim.fn.writefile({ payload }, tmpfile) ~= 0 then
    vim.notify("Failed to create temp file", vim.log.levels.ERROR, { title = "Jenova" })
    return
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "## assistant", "" })
  local insert_line = vim.api.nvim_buf_line_count(buf)
  local current_lines = { "" }
  local got_content = false

  local function append_text(text)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      got_content = true
      local pieces = vim.split(text, "\n", { plain = true })
      current_lines[#current_lines] = current_lines[#current_lines] .. pieces[1]
      for i = 2, #pieces do
        table.insert(current_lines, pieces[i])
      end
      local start_idx = insert_line - 1
      local end_idx = start_idx + #current_lines
      local buf_total = vim.api.nvim_buf_line_count(buf)
      if end_idx > buf_total then end_idx = buf_total end
      pcall(vim.api.nvim_buf_set_lines, buf, start_idx, end_idx, false, current_lines)
      scroll_to_bottom(buf)
    end)
  end

  local sse_buffer = ""
  local got_error = false

  local function process_sse(data)
    sse_buffer = sse_buffer .. data
    while true do
      local nl = sse_buffer:find("\n")
      if not nl then break end
      local line = sse_buffer:sub(1, nl - 1):gsub("\r$", "")
      sse_buffer = sse_buffer:sub(nl + 1)

      if line == "data: [DONE]" then
      elseif line:sub(1, 6) == "data: " then
        local json_str = line:sub(7)
        local ok, parsed = pcall(vim.json.decode, json_str)
        if ok and parsed then
          if parsed.choices and parsed.choices[1] then
            local delta = parsed.choices[1].delta
            if delta and type(delta.content) == "string" then
              append_text(delta.content)
            end
          elseif parsed.error then
            got_error = true
            local err_msg = parsed.error.message or vim.json.encode(parsed.error)
            append_text("[Error: " .. err_msg .. "]")
          end
        end
      elseif not got_content and line:match("^HTTP/1%.. %d%d%d") then
        local code = tonumber(line:match("(%d%d%d)"))
        if code and code >= 400 then
          got_error = true
          append_text("[Backend error: HTTP " .. code .. "]")
        end
      end
    end

    if not got_content and not got_error and #sse_buffer > 200 then
      local ok, parsed = pcall(vim.json.decode, sse_buffer)
      if ok and parsed and parsed.error then
        got_error = true
        local err_msg = parsed.error.message or vim.json.encode(parsed.error)
        append_text("[Error: " .. err_msg .. "]")
        sse_buffer = ""
      end
    end
  end

  active_job = vim.system(
    {
      "curl", "--no-buffer", "-s", "-N",
      "-H", "Content-Type: application/json",
      "-H", "Authorization: Bearer " .. SECRET,
      "-d", "@" .. tmpfile,
      url,
    },
    {
      stdout = function(_, data)
        if data then
          process_sse(type(data) == "string" and data or tostring(data))
        end
      end,
      stderr = function(_, data)
        if data then data = type(data) == "string" and data or tostring(data) end
        if data and data:match("%S") then
          vim.schedule(function()
            if data:find("Could not resolve host") or data:find("Connection refused") then
              vim.notify("Backend unreachable: " .. vim.trim(data), vim.log.levels.ERROR, { title = "Jenova" })
            end
          end)
        end
      end,
    },
    function(result)
      vim.schedule(function()
        active_job = nil
        pcall(os.remove, tmpfile)

        if vim.api.nvim_buf_is_valid(buf) then
          if not got_content and not got_error then
            if result.code ~= 0 then
              pcall(vim.api.nvim_buf_set_lines, buf, insert_line - 1, insert_line, false,
                { "[Connection failed — is the Jenova backend running?]" })
            end
          end

          vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "## user", "" })
          save_chat(buf)
          scroll_to_bottom(buf)
          vim.cmd("startinsert!")
        end
        if on_done then on_done() end
      end)
    end
  )
end

-- ── Agent response (agent mode) ───────────────────────────────────────────────

-- Spinner frames for the thinking indicator
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function agent_respond(buf, prompt, on_done)
  local ok, agent = pcall(require, "jenova.agent")
  if not ok or not agent then
    vim.notify(
      "Embedded agent not available — run: make sync-modules && make install",
      vim.log.levels.WARN, { title = "Jenova" })
    return false
  end

  -- ── State ───────────────────────────────────────────────────────────────
  -- We render assistant output by maintaining a single mutable "transient"
  -- line at the bottom of the buffer that displays either the spinner or a
  -- ⚙ tool badge. Permanent content (assistant text, completed ✓/✗ tool
  -- badges, error rows) is committed ABOVE the transient line. Treating the
  -- transient row as a single in-place slot prevents the mid-stream tearing
  -- and stale "thinking…" lines that the previous renderer left behind.

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "## assistant", "" })

  local transient_lnum = nil   -- 1-based row of the live spinner/badge, or nil
  local stream_lines   = nil   -- accumulator for the current text run
  local stream_start   = nil   -- 1-based row where the current stream begins
  local active_tool    = nil   -- { name = ..., lnum = ... } when a tool is running
  local spinner_idx    = 0
  local spinner_timer  = nil

  local function buf_append(lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end

  local function clear_transient()
    if not transient_lnum then return end
    if not vim.api.nvim_buf_is_valid(buf) then transient_lnum = nil; return end
    pcall(vim.api.nvim_buf_set_lines, buf,
      transient_lnum - 1, transient_lnum, false, {})
    transient_lnum = nil
  end

  local function commit_stream()
    -- Stream rows are already in the buffer (text was written in place);
    -- just drop the accumulator so the next run starts fresh.
    stream_lines = nil
    stream_start = nil
  end

  local function stop_spinner()
    if spinner_timer then
      pcall(function() spinner_timer:stop(); spinner_timer:close() end)
      spinner_timer = nil
    end
  end

  local function spinner_label()
    spinner_idx = (spinner_idx % #SPINNER) + 1
    if active_tool then
      return string.format("%s %s…", SPINNER[spinner_idx], active_tool.name)
    end
    return string.format("%s thinking…", SPINNER[spinner_idx])
  end

  local function ensure_transient()
    if transient_lnum then return end
    buf_append({ spinner_label() })
    transient_lnum = vim.api.nvim_buf_line_count(buf)
  end

  local function start_spinner()
    ensure_transient()
    if spinner_timer then return end
    spinner_timer = (vim.uv or vim.loop).new_timer()
    spinner_timer:start(0, 100, vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(buf) then stop_spinner(); return end
      if not transient_lnum then return end
      pcall(vim.api.nvim_buf_set_lines, buf,
        transient_lnum - 1, transient_lnum, false, { spinner_label() })
    end))
  end

  -- Module statusline state
  M._agent_running = true
  M._agent_tool    = nil
  M._agent_turn    = (M._agent_turn or 0) + 1

  start_spinner()

  local function append_text(text)
    if not vim.api.nvim_buf_is_valid(buf) or text == "" then return end
    -- Replace the transient line with a fresh empty stream row before the
    -- first chunk arrives, so streamed text grows in place where the
    -- spinner used to sit.
    if not stream_start then
      if transient_lnum then
        pcall(vim.api.nvim_buf_set_lines, buf,
          transient_lnum - 1, transient_lnum, false, { "" })
        stream_start   = transient_lnum
        transient_lnum = nil
      else
        buf_append({ "" })
        stream_start = vim.api.nvim_buf_line_count(buf)
      end
      stream_lines = { "" }
    end

    local pieces = vim.split(text, "\n", { plain = true })
    stream_lines[#stream_lines] = stream_lines[#stream_lines] .. pieces[1]
    for i = 2, #pieces do table.insert(stream_lines, pieces[i]) end

    pcall(vim.api.nvim_buf_set_lines, buf,
      stream_start - 1,
      stream_start - 1 + #stream_lines,
      false, stream_lines)
    scroll_to_bottom(buf)
  end

  agent.query(prompt, {
    on_text = function(text)
      vim.schedule(function() append_text(text) end)
    end,

    on_thinking = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        active_tool = nil
        M._agent_tool = nil
        ensure_transient()
      end)
    end,

    on_tool_use = function(name, _)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        commit_stream()
        clear_transient()
        active_tool = { name = name }
        M._agent_tool = name
        -- Append a fresh transient row that the spinner will animate.
        ensure_transient()
        active_tool.lnum = transient_lnum
        scroll_to_bottom(buf)
      end)
    end,

    on_tool_result = function(name, result)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local success = not (type(result) == "table" and result.error)
        local icon    = success and "✓" or "✗"
        local row     = active_tool and active_tool.lnum or transient_lnum
        if row and vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false,
            { string.format("%s %s", icon, name) })
        end
        if transient_lnum == row then transient_lnum = nil end
        active_tool = nil
        M._agent_tool = nil
        -- Spinner timer keeps running; ensure_transient appends a new line
        -- below the now-permanent badge.
        ensure_transient()
        scroll_to_bottom(buf)
      end)
    end,

    on_error = function(msg)
      vim.schedule(function()
        stop_spinner()
        commit_stream()
        clear_transient()
        active_tool = nil
        M._agent_running = false
        M._agent_tool    = nil
        if vim.api.nvim_buf_is_valid(buf) then
          buf_append({ string.format("✗ Error: %s", msg) })
          buf_append({ "", "## user", "" })
          save_chat(buf)
          scroll_to_bottom(buf)
          vim.cmd("startinsert!")
        end
        if on_done then on_done() end
      end)
    end,

    on_done = function(usage)
      vim.schedule(function()
        stop_spinner()
        commit_stream()
        clear_transient()
        active_tool = nil
        M._agent_running = false
        M._agent_tool    = nil

        if vim.api.nvim_buf_is_valid(buf) then
          if usage and (usage.input or 0) + (usage.output or 0) > 0 then
            M._agent_tokens_in  = usage.input  or 0
            M._agent_tokens_out = usage.output or 0
            M._agent_cost       = usage.cost   or 0.0
            local cost_line
            if usage.cost and usage.cost > 0 then
              cost_line = string.format(
                "> turn %d  in:%d out:%d  $%.4f",
                M._agent_turn, usage.input, usage.output, usage.cost)
            else
              cost_line = string.format(
                "> turn %d  in:%d out:%d",
                M._agent_turn, usage.input, usage.output)
            end
            buf_append({ "", cost_line })
          end
          buf_append({ "", "## user", "" })
          save_chat(buf)
          scroll_to_bottom(buf)
          vim.cmd("startinsert!")
        end
        if on_done then on_done() end
      end)
    end,
  })
  return true
end

-- ── Slash command dispatcher ───────────────────────────────────────────────────

local function dispatch_slash(buf, cmd_line)
  local cmd = (cmd_line:match("^/(%S+)") or ""):lower()
  local arg = (cmd_line:match("^/%S+%s+(.*)") or ""):match("^%s*(.-)%s*$")
  local function info(line)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "<!-- " .. line .. " -->", "" })
    scroll_to_bottom(buf)
  end
  if cmd == "clear" then
    local ok, agent = pcall(require, "jenova.agent")
    if ok and agent then agent.clear() end
    M._agent_turn = 0
    vim.notify("Session cleared", vim.log.levels.INFO, { title = "Jenova" })

  elseif cmd == "reset" then
    local ok, agent = pcall(require, "jenova.agent")
    if ok and agent then agent.reset() end
    M._agent_turn = 0
    vim.notify("Agent reset — engine will rebuild on next query",
      vim.log.levels.INFO, { title = "Jenova" })

  elseif cmd == "stop" then
    M.stop()

  elseif cmd == "history" then
    local ok, agent = pcall(require, "jenova.agent")
    local msgs = ok and agent and agent.get_messages() or {}
    local lines = { "", "<!-- /history -->", string.format("  %d messages in context:", #msgs) }
    for i, m in ipairs(msgs) do
      local snippet = (m.content or ""):sub(1, 80):gsub("\n", " ")
      table.insert(lines, string.format("  [%d] %s: %s%s",
        i, m.role, snippet, #(m.content or "") > 80 and "…" or ""))
    end
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "debug" then
    local ok, agent = pcall(require, "jenova.agent")
    local usage = ok and agent and agent.get_usage() or {}
    local state = {
      running  = M._agent_running,
      turn     = M._agent_turn,
      tool     = M._agent_tool,
      tokens_in  = usage.input_tokens  or 0,
      tokens_out = usage.output_tokens or 0,
      cost     = usage.total_cost_usd  or 0,
    }
    local encoded = vim.json.encode(state)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false,
      { "", "<!-- /debug -->", "```json", encoded, "```", "" })
    scroll_to_bottom(buf)

  elseif cmd == "diag" then
    local diags = vim.diagnostic.get(nil)
    local lines = { "", "<!-- /diag -->",
      string.format("  %d diagnostics across all buffers:", #diags) }
    local counts = { [1]=0,[2]=0,[3]=0,[4]=0 }
    for _, d in ipairs(diags) do counts[d.severity] = (counts[d.severity] or 0) + 1 end
    table.insert(lines, string.format("  E:%d W:%d I:%d H:%d",
      counts[1], counts[2], counts[3], counts[4]))
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "tools" then
    -- /tools                — list registered tools
    -- /tools on | enable    — re-enable tool dispatch
    -- /tools off | disable  — strip tools, plain chat replies only
    -- /tools status         — show whether tools are currently enabled
    local sub = arg:lower()
    if sub == "on" or sub == "enable" then
      pcall(function()
        local s = require("jenova.agent.shared.state.app_state")
        s.set("tools_enabled", true)
        local c = require("jenova.agent.shared.config.loader")
        c.set("tools_enabled", true)
      end)
      info("/tools enabled — model can call tools")
      return
    elseif sub == "off" or sub == "disable" then
      pcall(function()
        local s = require("jenova.agent.shared.state.app_state")
        s.set("tools_enabled", false)
        local c = require("jenova.agent.shared.config.loader")
        c.set("tools_enabled", false)
      end)
      info("/tools disabled — replies will be plain chat (no tools)")
      return
    elseif sub == "status" then
      local enabled = true
      pcall(function()
        local s = require("jenova.agent.shared.state.app_state")
        local v = s.get("tools_enabled")
        if v ~= nil then enabled = v and true or false end
      end)
      info("/tools status: " .. (enabled and "enabled" or "disabled"))
      return
    end
    local ok, reg = pcall(require, "jenova.agent.shared.tools.registry")
    if not ok then ok, reg = pcall(require, "tools.registry") end
    local lines = { "", "<!-- /tools -->" }
    if ok and reg and reg.list_tools then
      for _, t in ipairs(reg.list_tools()) do
        table.insert(lines, string.format("  • %s — %s",
          t.name or "?",
          (t.description or ""):sub(1, 60)))
      end
    elseif ok and reg and reg._tools then
      for name, _ in pairs(reg._tools) do
        table.insert(lines, "  • " .. name)
      end
    else
      table.insert(lines, "  (registry not available)")
    end
    table.insert(lines, "  ──")
    table.insert(lines, "  /tools on|off    toggle tool dispatch")
    table.insert(lines, "  /tools status    show current state")
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  elseif cmd == "permissions" or cmd == "perm" then
    -- /permissions [default|auto|plan|yolo]
    -- yolo is an alias for bypassPermissions (silently auto-approve everything)
    local sub = arg:lower()
    local mode_map = {
      default = "default",
      ask     = "default",
      auto    = "auto",
      plan    = "plan",
      yolo    = "bypassPermissions",
      bypass  = "bypassPermissions",
    }
    if sub == "" then
      local mode = "default"
      pcall(function()
        local s = require("jenova.agent.shared.state.app_state")
        mode = s.get("permission_mode") or mode
      end)
      info("permission mode: " .. mode .. "  (use /permissions default|auto|plan|yolo)")
      return
    end
    local mode = mode_map[sub]
    if not mode then
      info("unknown mode '" .. sub .. "' (try: default, auto, plan, yolo)")
      return
    end
    pcall(function()
      local s = require("jenova.agent.shared.state.app_state")
      s.set("permission_mode", mode)
      local c = require("jenova.agent.shared.config.loader")
      c.set("permission_mode", mode)
    end)
    info("permission mode → " .. mode)

  elseif cmd == "tool-choice" or cmd == "toolchoice" then
    -- /tool-choice [auto|required|none]
    local sub = arg:lower()
    if sub == "" then
      local choice = "auto"
      pcall(function()
        local s = require("jenova.agent.shared.state.app_state")
        choice = s.get("tool_choice") or choice
      end)
      info("tool_choice: " .. choice .. "  (use /tool-choice auto|required)")
      return
    end
    if sub ~= "auto" and sub ~= "required" and sub ~= "none" then
      info("invalid tool_choice (use: auto, required, none)")
      return
    end
    pcall(function()
      local s = require("jenova.agent.shared.state.app_state")
      s.set("tool_choice", sub)
      local c = require("jenova.agent.shared.config.loader")
      c.set("tool_choice", sub)
    end)
    info("tool_choice → " .. sub)

  elseif cmd == "model" then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false,
      { "", string.format("<!-- /model: %s -->", MODEL), "" })
    scroll_to_bottom(buf)

  elseif cmd == "thinking" then
    vim.notify("Thinking mode toggle not yet supported for this model",
      vim.log.levels.INFO, { title = "Jenova" })

  elseif cmd == "help" then
    local lines = {
      "",
      "<!-- /help -->",
      "  /clear              clear session history (keep engine)",
      "  /reset              destroy engine, rebuild on next query",
      "  /stop               abort in-flight generation",
      "  /history            show message context summary",
      "  /debug              show engine state as JSON",
      "  /diag               show LSP diagnostics summary",
      "  /tools [on|off]     list / toggle tool dispatch",
      "  /tool-choice MODE   auto | required | none",
      "  /permissions MODE   default | auto | plan | yolo",
      "  /model              show current model",
      "  /thinking           toggle extended thinking (if supported)",
      "  /help               this reference",
      "",
    }
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    scroll_to_bottom(buf)

  else
    vim.notify("Unknown slash command: /" .. cmd .. "  (try /help)",
      vim.log.levels.WARN, { title = "Jenova" })
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open_chat(path)
  return open_chat_split(path)
end

function M.toggle_chat()
  if toggle_win and vim.api.nvim_win_is_valid(toggle_win) then
    vim.api.nvim_win_close(toggle_win, true)
    toggle_win = nil
    return
  end

  if toggle_buf and vim.api.nvim_buf_is_valid(toggle_buf) and is_chat_buf(toggle_buf) then
    local path = chat_filepath(toggle_buf)
    if path then
      return open_chat_split(path)
    end
  end

  local latest = nil
  local latest_time = 0
  ensure_chat_dir()
  local files = vim.fn.glob(CHAT_DIR .. "/*.md", false, true)
  for _, fpath in ipairs(files) do
    local mtime = vim.fn.getftime(fpath)
    if mtime > latest_time then
      latest_time = mtime
      latest = fpath
    end
  end

  if latest then
    return open_chat_split(latest)
  else
    return open_chat_split()
  end
end

-- Toggle between agent mode and plain conversation mode.
function M.toggle_mode()
  agent_mode = not agent_mode
  local label = agent_mode and "Agent mode (tools + context)" or "Conversation mode (plain stream)"
  vim.notify(label, vim.log.levels.INFO, { title = "Jenova" })

  -- Update header in all open chat buffers.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_chat_buf(buf) then
      refresh_header_mode(buf)
      save_chat(buf)
    end
  end
end

function M.respond()
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    vim.notify("Not a Jenova chat buffer", vim.log.levels.WARN, { title = "Jenova" })
    return
  end

  local messages = parse_messages(buf)
  if #messages == 0 then
    vim.notify("No messages to send", vim.log.levels.WARN, { title = "Jenova" })
    return
  end

  -- Extract last user message
  local prompt = ""
  for i = #messages, 1, -1 do
    if messages[i].role == "user" then
      prompt = messages[i].content
      break
    end
  end

  -- Multi-line continuation: if prompt ends with backslash, wait for more input
  if prompt:match("\\%s*$") then
    vim.notify("Multi-line: remove trailing \\ and send again to submit",
      vim.log.levels.INFO, { title = "Jenova" })
    return
  end

  -- Slash command dispatch
  if prompt:match("^/") then
    dispatch_slash(buf, prompt)
    -- Remove the slash command line from the buffer and add fresh user section
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Remove the last user section that contained the slash command
    local last_user = 0
    for i = #lines, 1, -1 do
      if lines[i]:match("^## user%s*$") then last_user = i; break end
    end
    if last_user > 0 then
      vim.api.nvim_buf_set_lines(buf, last_user - 1, -1, false, { "## user", "" })
    else
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "## user", "" })
    end
    save_chat(buf)
    scroll_to_bottom(buf)
    vim.cmd("startinsert!")
    return
  end

  if agent_mode and prompt ~= "" then
    agent_respond(buf, prompt)
    return
  end

  -- Fallback: plain streaming (conversation mode or empty prompt).
  stream_response(buf, messages)
end

function M.send_message(text, prefix)
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    buf = M.toggle_chat()
    if not buf then return end
  end

  local msg = prefix and (prefix .. text) or text
  append_user_section(buf, msg)
  save_chat(buf)
  scroll_to_bottom(buf)
end

function M.visual_chat()
  local src_buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  local lines = vim.api.nvim_buf_get_lines(src_buf, start_line - 1, end_line, false)
  local selection = table.concat(lines, "\n")
  local ft = vim.bo[src_buf].filetype or ""
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src_buf), ":t")

  local buf = open_chat_split()
  if not buf then return end

  local context = string.format("Selected code from %s:\n\n```%s\n%s\n```\n",
    filename, ft, selection)

  append_user_section(buf, context)
  save_chat(buf)
  scroll_to_bottom(buf)
  vim.cmd("startinsert!")
end

local function strip_code_fences(text)
  local stripped = text
  stripped = stripped:gsub("^%s*", "")
  if stripped:match("^```") then
    stripped = stripped:gsub("^```[^\n]*\n", "")
    stripped = stripped:gsub("\n?```%s*$", "")
  end
  return stripped
end

local function do_rewrite(src_buf, start_ln, end_ln, instruction, selection, ft)
  if vim.fn.executable("curl") ~= 1 then
    vim.notify("curl not found. Install curl to enable rewrite.", vim.log.levels.ERROR, { title = "Jenova" })
    return
  end

  local user_msg = string.format(
    "Visual Rewrite: %s\n\nI have the following selection:\n```%s\n%s\n```",
    instruction, ft, selection
  )

  local messages = {
    { role = "user", content = user_msg },
  }

  local url = ep().proxy_url()
  local payload = vim.json.encode({
    model = MODEL,
    messages = messages,
    temperature = TEMPERATURE,
    top_p = TOP_P,
    stream = true,
    max_tokens = 16384,
  })

  local tmpfile = vim.fn.tempname() .. ".json"
  if vim.fn.writefile({ payload }, tmpfile) ~= 0 then
    vim.notify("Failed to create temp file", vim.log.levels.ERROR, { title = "Jenova" })
    return
  end

  local response_text = ""
  local sse_buf = ""

  vim.notify("Rewriting...", vim.log.levels.INFO, { title = "Jenova" })

  active_job = vim.system(
    {
      "curl", "--no-buffer", "-s", "-N",
      "-H", "Content-Type: application/json",
      "-H", "Authorization: Bearer " .. SECRET,
      "-d", "@" .. tmpfile,
      url,
    },
    {
      stdout = function(_, data)
        if not data then return end
        data = type(data) == "string" and data or tostring(data)
        sse_buf = sse_buf .. data
        while true do
          local nl = sse_buf:find("\n")
          if not nl then break end
          local line = sse_buf:sub(1, nl - 1):gsub("\r$", "")
          sse_buf = sse_buf:sub(nl + 1)
          if line:sub(1, 6) == "data: " and line ~= "data: [DONE]" then
            local ok, parsed = pcall(vim.json.decode, line:sub(7))
            if ok and parsed and parsed.choices and parsed.choices[1] then
              local delta = parsed.choices[1].delta
              if delta and type(delta.content) == "string" then
                response_text = response_text .. delta.content
              end
            end
          end
        end
      end,
    },
    function(result)
      vim.schedule(function()
        active_job = nil
        pcall(os.remove, tmpfile)
        if vim.api.nvim_buf_is_valid(src_buf) and response_text ~= "" then
          local cleaned = strip_code_fences(response_text)
          local new_lines = vim.split(cleaned, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(src_buf, start_ln - 1, end_ln, false, new_lines)
          vim.notify("Rewrite applied", vim.log.levels.INFO, { title = "Jenova" })
        elseif response_text == "" then
          if result.code ~= 0 then
            vim.notify("Rewrite failed: connection error (is the backend running?)",
              vim.log.levels.ERROR, { title = "Jenova" })
          else
            vim.notify("Rewrite failed: empty response from backend",
              vim.log.levels.ERROR, { title = "Jenova" })
          end
        end
      end)
    end
  )
end

function M.visual_rewrite()
  local src_buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  local lines = vim.api.nvim_buf_get_lines(src_buf, start_line - 1, end_line, false)
  local selection = table.concat(lines, "\n")
  local ft = vim.bo[src_buf].filetype or ""

  vim.ui.input({ prompt = "Rewrite instruction: " }, function(instruction)
    if not instruction or instruction == "" then return end
    do_rewrite(src_buf, start_line, end_line, instruction, selection, ft)
  end)
end

function M.web_search()
  vim.ui.input({ prompt = "Web search: " }, function(query)
    if not query or query == "" then return end

    local buf = open_chat_split()
    if not buf then return end

    local msg = "Web Search: " .. query
    append_user_section(buf, msg)
    save_chat(buf)
    scroll_to_bottom(buf)
    vim.cmd("startinsert!")
  end)
end

function M.chat_with_context()
  local src_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src_buf), ":t")
  local filepath = vim.api.nvim_buf_get_name(src_buf)
  local content = table.concat(lines, "\n")

  local buf = open_chat_split()
  if not buf then return end

  local context = string.format(
    "Open File Chat: Working on: %s\nPath: %s\n\n```\n%s\n```\n\n",
    filename, filepath, content
  )

  append_user_section(buf, context)
  save_chat(buf)
  scroll_to_bottom(buf)
  vim.cmd("startinsert!")
end

function M.fresh_chat()
  ensure_chat_dir()
  if vim.fn.isdirectory(CHAT_DIR) == 1 then
    vim.fn.delete(CHAT_DIR, "rf")
    vim.fn.mkdir(CHAT_DIR, "p")
  end
  return open_chat_split()
end

function M.delete_chat()
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    vim.notify("Not a Jenova chat buffer", vim.log.levels.WARN, { title = "Jenova" })
    return
  end
  local path = chat_filepath(buf)
  if path then
    os.remove(path)
  end
  if toggle_buf == buf then
    toggle_buf = nil
    toggle_win = nil
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.notify("Chat deleted", vim.log.levels.INFO, { title = "Jenova" })
end

function M.inline_rewrite()
  local src_buf = vim.api.nvim_get_current_buf()
  local lnum = vim.fn.line(".")
  local line = vim.api.nvim_get_current_line()
  local ft = vim.bo[src_buf].filetype or ""

  vim.ui.input({ prompt = "Inline rewrite instruction: " }, function(instruction)
    if not instruction or instruction == "" then return end
    do_rewrite(src_buf, lnum, lnum, instruction, line, ft)
  end)
end

function M.stop()
  stop_generation()
  vim.notify("Generation stopped", vim.log.levels.INFO, { title = "Jenova" })
end

function M.agent_reset()
  local ok, agent = pcall(require, "jenova.agent")
  if ok and agent then
    agent.reset()
    vim.notify("Agent context reset", vim.log.levels.INFO, { title = "Jenova" })
  end
end

local _setup_done = false

function M.setup()
  if _setup_done then return end
  _setup_done = true

  vim.api.nvim_create_user_command("JenovaChat",        function() M.toggle_chat() end,   { desc = "Toggle Jenova Chat" })
  vim.api.nvim_create_user_command("JenovaChatNew",     function() M.open_chat() end,     { desc = "New Jenova Chat" })
  vim.api.nvim_create_user_command("JenovaChatRespond", function() M.respond() end,       { desc = "Send chat message" })
  vim.api.nvim_create_user_command("JenovaChatDelete",  function() M.delete_chat() end,   { desc = "Delete current chat" })
  vim.api.nvim_create_user_command("JenovaChatFresh",   function() M.fresh_chat() end,    { desc = "Fresh chat (wipe all)" })
  vim.api.nvim_create_user_command("JenovaChatStop",    function() M.stop() end,          { desc = "Stop generation" })
  vim.api.nvim_create_user_command("JenovaWebSearch",   function() M.web_search() end,    { desc = "Web search" })
  vim.api.nvim_create_user_command("JenovaChatContext", function() M.chat_with_context() end, { desc = "Chat with file context" })
  vim.api.nvim_create_user_command("JenovaToggleMode",  function() M.toggle_mode() end,   { desc = "Toggle agent/conversation mode" })
  vim.api.nvim_create_user_command("JenovaAgentReset",  function() M.agent_reset() end,   { desc = "Reset agent context" })

  local function opts(desc)
    return { noremap = true, silent = true, nowait = true, desc = "Jenova: " .. desc }
  end

  vim.keymap.set("v", "<leader>ae", function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    M.visual_chat()
  end, opts("Visual Chat"))

  vim.keymap.set("n", "<leader>ac", function() M.chat_with_context() end, opts("Chat with Buffer Context"))
  vim.keymap.set("n", "<leader>aF", function() M.fresh_chat() end, opts("New Chat (Fresh Context)"))
  vim.keymap.set("n", "<leader>at", function() M.toggle_chat() end, opts("Toggle Chat"))
  vim.keymap.set("n", "<leader>ar", function() M.respond() end, opts("Chat Respond"))
  vim.keymap.set("n", "<leader>ad", function() M.delete_chat() end, opts("Delete Chat"))
  vim.keymap.set("n", "<leader>an", function() M.open_chat() end, opts("New Chat"))
  vim.keymap.set("n", "<leader>am", function() M.toggle_mode() end, opts("Toggle Agent/Conversation Mode"))
  vim.keymap.set("n", "<leader>aR", function() M.agent_reset() end, opts("Reset Agent Context"))

  vim.keymap.set("v", "<leader>aw", function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    M.visual_rewrite()
  end, opts("Visual Rewrite"))

  vim.keymap.set("n", "<leader>as", function() M.web_search() end, opts("Web Search"))
  vim.keymap.set("n", "<leader>ai", function() M.inline_rewrite() end, opts("Inline Rewrite"))
  vim.keymap.set("n", "<leader>ax", function() M.stop() end, opts("Stop Generation"))

  vim.keymap.set("n", "<leader>aa", function() M.toggle_chat() end, opts("Open / focus chat"))

  vim.keymap.set("n", "<leader>af", function()
    local src_buf = vim.api.nvim_get_current_buf()
    local diags = vim.diagnostic.get(src_buf)
    if #diags == 0 then
      vim.notify("No diagnostics in current buffer", vim.log.levels.INFO, { title = "Jenova" })
      return
    end
    local lines = {}
    for _, d in ipairs(diags) do
      table.insert(lines, string.format("  line %d: [%s] %s",
        d.lnum + 1,
        vim.diagnostic.severity[d.severity] or "?",
        d.message))
    end
    local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src_buf), ":t")
    local prompt = string.format(
      "Fix all LSP diagnostics in `%s`:\n%s\n\nApply fixes directly.",
      fname, table.concat(lines, "\n"))
    local cbuf = M.toggle_chat()
    if cbuf then
      append_user_section(cbuf, prompt)
      save_chat(cbuf)
      scroll_to_bottom(cbuf)
      M.respond()
    end
  end, opts("Fix diagnostics in current buffer"))
end

return M
