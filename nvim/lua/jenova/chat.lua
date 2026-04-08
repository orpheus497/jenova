local M = {}
local ep = require("jenova.endpoints")

local CHAT_DIR = vim.fn.stdpath("state") .. "/jenova/chats"
local SYSTEM_PROMPT = "You are Jenova, an expert coding assistant running fully locally on FreeBSD. "
  .. "Prefer concise, correct answers. Use shell, Lua, and C idioms appropriate for FreeBSD."
local MODEL = "jenova"
local SECRET = "jenova-local"
local TEMPERATURE = 0.7
local TOP_P = 0.9
local CHAT_WIDTH = 60

local USER_SEP = "---\n\n## user\n\n"
local ASST_SEP = "\n\n## assistant\n\n"

local active_job = nil
local toggle_buf = nil
local toggle_win = nil

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
  return CHAT_DIR .. "/" .. os.date("%Y%m%d_%H%M%S") .. ".md"
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

local function parse_messages(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local messages = {}
  local in_header = true
  local current_role = nil
  local current_content = {}

  for _, line in ipairs(lines) do
    if in_header then
      if line == "---" then
        in_header = false
      end
    else
      if line:match("^## user%s*$") then
        if current_role then
          table.insert(messages, {
            role = current_role,
            content = vim.trim(table.concat(current_content, "\n")),
          })
        end
        current_role = "user"
        current_content = {}
      elseif line:match("^## assistant%s*$") then
        if current_role then
          table.insert(messages, {
            role = current_role,
            content = vim.trim(table.concat(current_content, "\n")),
          })
        end
        current_role = "assistant"
        current_content = {}
      elseif current_role then
        table.insert(current_content, line)
      end
    end
  end

  if current_role and #current_content > 0 then
    local content = vim.trim(table.concat(current_content, "\n"))
    if content ~= "" then
      table.insert(messages, { role = current_role, content = content })
    end
  end

  return messages
end

local function build_header(topic)
  topic = topic or "?"
  return string.format(
    "# topic: %s\n- model: %s\n- temperature: %s\n- top_p: %s\n",
    topic, MODEL, TEMPERATURE, TOP_P
  )
end

local function init_chat_buffer(buf, topic)
  local header = build_header(topic)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(header .. "---\n\n## user\n\n", "\n"))
  set_chat_buf_options(buf)
end

local function save_chat(buf)
  if not is_chat_buf(buf) then return end
  local path = chat_filepath(buf)
  if not path then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local f = io.open(path, "w")
  if f then
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
  end
  vim.bo[buf].modified = false
end

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

  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    buffer = buf,
    callback = function()
      if vim.bo[buf].modified then
        save_chat(buf)
      end
    end,
  })

  local total = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(win, { total, 0 })

  toggle_buf = buf
  toggle_win = win
  return buf, win
end

local function stop_generation()
  if active_job then
    active_job:kill(9)
    active_job = nil
  end
end

local function stream_response(buf, messages, on_done)
  stop_generation()

  local url = ep.proxy_url()
  local payload = vim.json.encode({
    model = MODEL,
    messages = messages,
    temperature = TEMPERATURE,
    top_p = TOP_P,
    stream = true,
  })

  local tmpfile = vim.fn.tempname() .. ".json"
  local f = io.open(tmpfile, "w")
  if not f then
    vim.notify("Failed to create temp file", vim.log.levels.ERROR, { title = "Jenova Chat" })
    return
  end
  f:write(payload)
  f:close()

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "## assistant", "" })
  local insert_line = vim.api.nvim_buf_line_count(buf)
  local response_lines = { "" }

  local partial_line = ""

  local function append_text(text)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end

      partial_line = partial_line .. text
      local split = vim.split(partial_line, "\n", { plain = true })

      response_lines[#response_lines] = split[1]
      for i = 2, #split do
        table.insert(response_lines, split[i])
      end
      partial_line = split[#split]
      response_lines[#response_lines] = partial_line

      local start = insert_line - 1
      vim.api.nvim_buf_set_lines(buf, start, start + #response_lines, false, response_lines)

      local total = vim.api.nvim_buf_line_count(buf)
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
      end
    end)
  end

  local sse_buffer = ""

  local function process_sse(data)
    sse_buffer = sse_buffer .. data
    while true do
      local nl = sse_buffer:find("\n")
      if not nl then break end
      local line = sse_buffer:sub(1, nl - 1):gsub("\r$", "")
      sse_buffer = sse_buffer:sub(nl + 1)

      if line == "data: [DONE]" then
        -- stream finished
      elseif line:sub(1, 6) == "data: " then
        local json_str = line:sub(7)
        local ok, parsed = pcall(vim.json.decode, json_str)
        if ok and parsed and parsed.choices and parsed.choices[1] then
          local delta = parsed.choices[1].delta
          if delta and delta.content then
            append_text(delta.content)
          end
        end
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
          process_sse(data)
        end
      end,
      stderr = function(_, data)
        if data and data ~= "" then
          vim.schedule(function()
            if data:match("%S") then
              vim.notify("curl: " .. vim.trim(data), vim.log.levels.WARN, { title = "Jenova Chat" })
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
          save_chat(buf)
        end
        if on_done then on_done() end
      end)
    end
  )
end

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
  for _, f in ipairs(files) do
    local mtime = vim.fn.getftime(f)
    if mtime > latest_time then
      latest_time = mtime
      latest = f
    end
  end

  if latest then
    return open_chat_split(latest)
  else
    return open_chat_split()
  end
end

function M.respond()
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    vim.notify("Not a Jenova chat buffer", vim.log.levels.WARN, { title = "Jenova Chat" })
    return
  end

  local messages = parse_messages(buf)
  if #messages == 0 then
    vim.notify("No messages to send", vim.log.levels.WARN, { title = "Jenova Chat" })
    return
  end

  table.insert(messages, 1, { role = "system", content = SYSTEM_PROMPT })
  stream_response(buf, messages)
end

function M.send_message(text, prefix)
  local buf = vim.api.nvim_get_current_buf()
  if not is_chat_buf(buf) then
    buf = M.toggle_chat()
    if not buf then return end
  end

  local msg = prefix and (prefix .. text) or text
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local last_line = lines[#lines] or ""
  local new_lines = {}
  if vim.trim(last_line) ~= "" then
    table.insert(new_lines, "")
  end
  for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
    table.insert(new_lines, l)
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, new_lines)
  save_chat(buf)

  local messages = parse_messages(buf)
  table.insert(messages, 1, { role = "system", content = SYSTEM_PROMPT })
  stream_response(buf, messages)
end

function M.visual_chat()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local selection = table.concat(lines, "\n")
  local ft = vim.bo.filetype or ""

  local buf = open_chat_split()
  if not buf then return end

  local msg = string.format("I have the following from %s:\n\n```%s\n%s\n```\n\nLet's discuss this code.",
    vim.fn.expand("%:t"), ft, selection)

  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last = buf_lines[#buf_lines] or ""
  local new_lines = {}
  if vim.trim(last) ~= "" then
    table.insert(new_lines, "")
  end
  for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
    table.insert(new_lines, l)
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, new_lines)
  save_chat(buf)

  local total = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
  end
end

function M.visual_rewrite()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  local src_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(src_buf, start_line - 1, end_line, false)
  local selection = table.concat(lines, "\n")
  local ft = vim.bo.filetype or ""

  vim.ui.input({ prompt = "Rewrite instruction: " }, function(instruction)
    if not instruction or instruction == "" then return end

    local user_msg = string.format(
      "Visual Rewrite: %s\n\nI have the following selection:\n```%s\n%s\n```",
      instruction, ft, selection
    )

    local messages = {
      { role = "system", content = SYSTEM_PROMPT },
      { role = "user", content = user_msg },
    }

    local url = ep.proxy_url()
    local payload = vim.json.encode({
      model = MODEL,
      messages = messages,
      temperature = TEMPERATURE,
      top_p = TOP_P,
      stream = true,
    })

    local tmpfile = vim.fn.tempname() .. ".json"
    local f = io.open(tmpfile, "w")
    if not f then return end
    f:write(payload)
    f:close()

    local response_text = ""
    local sse_buf = ""

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
                if delta and delta.content then
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
            local cleaned = response_text
            if cleaned:match("^```") then
              cleaned = cleaned:gsub("^```[^\n]*\n", ""):gsub("\n?```%s*$", "")
            end
            local new_lines = vim.split(cleaned, "\n", { plain = true })
            vim.api.nvim_buf_set_lines(src_buf, start_line - 1, end_line, false, new_lines)
          end
        end)
      end
    )
  end)
end

function M.web_search()
  vim.ui.input({ prompt = "Web search: " }, function(query)
    if not query or query == "" then return end

    local buf = open_chat_split()
    if not buf then return end

    local msg = "Web Search: " .. query
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last = buf_lines[#buf_lines] or ""
    local new_lines = {}
    if vim.trim(last) ~= "" then
      table.insert(new_lines, "")
    end
    table.insert(new_lines, msg)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, new_lines)
    save_chat(buf)

    local messages = parse_messages(buf)
    table.insert(messages, 1, { role = "system", content = SYSTEM_PROMPT })
    stream_response(buf, messages)
  end)
end

function M.chat_with_context()
  local src_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local filename = vim.fn.expand("%:t")
  local filepath = vim.fn.expand("%:p")
  local content = table.concat(lines, "\n")

  local buf = open_chat_split()
  if not buf then return end

  local msg = string.format(
    "Open File Chat: I'm working on file: %s\nPath: %s\n\n```\n%s\n```\n\nLet's discuss this file and help me move the task forward.",
    filename, filepath, content
  )

  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last = buf_lines[#buf_lines] or ""
  local new_lines = {}
  if vim.trim(last) ~= "" then
    table.insert(new_lines, "")
  end
  for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
    table.insert(new_lines, l)
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, new_lines)
  save_chat(buf)

  local messages = parse_messages(buf)
  table.insert(messages, 1, { role = "system", content = SYSTEM_PROMPT })
  stream_response(buf, messages)
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
    vim.notify("Not a Jenova chat buffer", vim.log.levels.WARN, { title = "Jenova Chat" })
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
  vim.notify("Chat deleted", vim.log.levels.INFO, { title = "Jenova Chat" })
end

function M.inline_rewrite()
  local line = vim.api.nvim_get_current_line()
  local lnum = vim.fn.line(".")

  vim.ui.input({ prompt = "Inline rewrite instruction: " }, function(instruction)
    if not instruction or instruction == "" then return end

    local src_buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo.filetype or ""
    local user_msg = string.format(
      "Visual Rewrite: %s\n\nI have the following selection:\n```%s\n%s\n```",
      instruction, ft, line
    )

    local messages = {
      { role = "system", content = SYSTEM_PROMPT },
      { role = "user", content = user_msg },
    }

    local url = ep.proxy_url()
    local payload = vim.json.encode({
      model = MODEL,
      messages = messages,
      temperature = TEMPERATURE,
      top_p = TOP_P,
      stream = true,
    })

    local tmpfile = vim.fn.tempname() .. ".json"
    local f = io.open(tmpfile, "w")
    if not f then return end
    f:write(payload)
    f:close()

    local response_text = ""
    local sse_buf = ""

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
          sse_buf = sse_buf .. data
          while true do
            local nl = sse_buf:find("\n")
            if not nl then break end
            local sline = sse_buf:sub(1, nl - 1):gsub("\r$", "")
            sse_buf = sse_buf:sub(nl + 1)
            if sline:sub(1, 6) == "data: " and sline ~= "data: [DONE]" then
              local ok, parsed = pcall(vim.json.decode, sline:sub(7))
              if ok and parsed and parsed.choices and parsed.choices[1] then
                local delta = parsed.choices[1].delta
                if delta and delta.content then
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
            local cleaned = response_text
            if cleaned:match("^```") then
              cleaned = cleaned:gsub("^```[^\n]*\n", ""):gsub("\n?```%s*$", "")
            end
            local new_lines = vim.split(cleaned, "\n", { plain = true })
            vim.api.nvim_buf_set_lines(src_buf, lnum - 1, lnum, false, new_lines)
          end
        end)
      end
    )
  end)
end

function M.stop()
  stop_generation()
  vim.notify("Generation stopped", vim.log.levels.INFO, { title = "Jenova Chat" })
end

local _setup_done = false

function M.setup()
  if _setup_done then return end
  _setup_done = true

  vim.api.nvim_create_user_command("JenovaChat", function() M.toggle_chat() end, { desc = "Toggle Jenova Chat" })
  vim.api.nvim_create_user_command("JenovaChatNew", function() M.open_chat() end, { desc = "New Jenova Chat" })
  vim.api.nvim_create_user_command("JenovaChatRespond", function() M.respond() end, { desc = "Send chat message" })
  vim.api.nvim_create_user_command("JenovaChatDelete", function() M.delete_chat() end, { desc = "Delete current chat" })
  vim.api.nvim_create_user_command("JenovaChatFresh", function() M.fresh_chat() end, { desc = "Fresh chat (wipe all)" })
  vim.api.nvim_create_user_command("JenovaChatStop", function() M.stop() end, { desc = "Stop generation" })
  vim.api.nvim_create_user_command("JenovaWebSearch", function() M.web_search() end, { desc = "Web search" })
  vim.api.nvim_create_user_command("JenovaChatContext", function() M.chat_with_context() end, { desc = "Chat with file context" })

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

  vim.keymap.set("v", "<leader>aw", function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    M.visual_rewrite()
  end, opts("Visual Rewrite"))

  vim.keymap.set("n", "<leader>as", function() M.web_search() end, opts("Web Search"))
  vim.keymap.set("n", "<leader>ai", function() M.inline_rewrite() end, opts("Inline Rewrite"))
  vim.keymap.set("n", "<leader>ax", function() M.stop() end, opts("Stop Generation"))
end

return M
