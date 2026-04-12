-- jenova/monitor.lua: Backend monitoring and status polling for Neovim UI.
-- Provides non-blocking HTTP queries to llama-server /health, /slots, and
-- /props endpoints, caching results for use by lualine, dashboard, and the
-- :JenovaMonitor floating window.

local M = {}

-- Cached state (updated by periodic timer)
M.state = {
  connected = false,
  model = "",
  slots_used = 0,
  slots_total = 0,
  ctx_used = 0,
  ctx_total = 0,
  tokens_predicted = 0,
  gpu_layers = 0,
  last_update = 0,
  proxy_ok = false,
  llama_ok = false,
  embed_ok = false,
}

-- Polling timer handle (stored on module to prevent GC collection)
M._timer = nil

-- Configuration
local POLL_INTERVAL_MS = 10000  -- 10 seconds between full polls
local CONNECT_TIMEOUT_MS = 3000

--- Get connection host/port from shared endpoints module.
--- Exposed as M.get_endpoints() for reuse by health.lua and dashboard.lua.
--- Always reads live env vars via jenova.endpoints so LAN discovery changes propagate.
local function is_lan_mode()
  local ep_ok, ep = pcall(require, "jenova.endpoints")
  if ep_ok then return ep.is_lan_mode() end
  return vim.env.JENOVA_LAN_MODE == "1"
end

local function get_endpoints()
  local ep_ok, ep = pcall(require, "jenova.endpoints")
  if ep_ok then
    return ep.all()
  end
  local host = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
  if host == "0.0.0.0" or host == "::" or host == "*" then
    host = "127.0.0.1"
  end
  return {
    host = host,
    proxy_port = tonumber(vim.env.JENOVA_PORT) or 8080,
    llama_port = tonumber(vim.env.JENOVA_LLAMA_PORT) or 8081,
    embed_port = tonumber(vim.env.JENOVA_LLAMA_EMBED_PORT or vim.env.LLAMA_EMBED_PORT) or 8082,
  }
end

local function llama_api_port(endpoints)
  if is_lan_mode() then return endpoints.proxy_port end
  return endpoints.llama_port
end

--- Build an HTTP URL, bracketing IPv6 literals as required by URL syntax
--- @param host string
--- @param port integer
--- @param path string
--- @return string
local function format_http_url(host, port, path)
  local formatted_host = host
  if host:find(":", 1, true) and not host:match("^%[.*%]$") then
    formatted_host = string.format("[%s]", host)
  end
  return string.format("http://%s:%d%s", formatted_host, port, path)
end

--- Non-blocking TCP probe
--- @param host string
--- @param port number
--- @param callback fun(ok: boolean)
local function tcp_probe(host, port, callback)
  local uv = vim.uv or vim.loop
  if not uv then
    callback(false)
    return
  end
  local tcp = uv.new_tcp()
  if not tcp then
    callback(false)
    return
  end
  local timeout = uv.new_timer()
  local closed = false
  local function close_handles()
    if not closed then
      closed = true
      pcall(function() tcp:close() end)
      if timeout then pcall(function() timeout:close() end) end
    end
  end
  if timeout then
    timeout:start(CONNECT_TIMEOUT_MS, 0, function()
      if not closed then
        close_handles()
        vim.schedule(function() callback(false) end)
      end
    end)
  end
  tcp:connect(host, port, function(err)
    if closed then return end
    close_handles()
    vim.schedule(function() callback(not err) end)
  end)
end

--- Non-blocking HTTP GET via vim.system (Neovim 0.10+)
--- @param url string
--- @param callback fun(ok: boolean, body: string|nil)
local function http_get(url, callback)
  if not vim.system then
    callback(false, nil)
    return
  end
  vim.system(
    { "curl", "-sf", "--max-time", "3", "--connect-timeout", "2", url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout and result.stdout ~= "" then
          callback(true, result.stdout)
        else
          callback(false, nil)
        end
      end)
    end
  )
end

--- Parse JSON safely
local function json_decode(str)
  local ok, result = pcall(vim.json.decode, str)
  if ok then return result end
  return nil
end

--- Update composite connected state from individual service probes.
--- "connected" requires both proxy and llama-server to be reachable.
local function update_connected_state()
  M.state.connected = M.state.proxy_ok and M.state.llama_ok
  vim.g.jenova_connected = M.state.connected
end

--- Poll /health endpoint for basic status
local function poll_health(endpoints, callback)
  local port = llama_api_port(endpoints)
  local url = format_http_url(endpoints.host, port, "/health")
  http_get(url, function(ok, body)
    if ok and body then
      local data = json_decode(body)
      -- llama-server returns status="ok"; proxy returns status="ok" + backend_ok=true
      if data and (data.status == "ok" or data.backend_ok == true) then
        M.state.llama_ok = true
        if data.slots_idle ~= nil then
          M.state.slots_used = (data.slots_processing or 0)
          M.state.slots_total = (data.slots_idle or 0) + (data.slots_processing or 0)
        end
        -- Only set proxy_ok from /health when in LAN mode (hitting the proxy).
        -- In local mode, /health hits llama-server directly; proxy_ok is driven
        -- by the dedicated TCP probe instead.
        if is_lan_mode() then
          M.state.proxy_ok = true
        end
        update_connected_state()
        if callback then callback(true) end
        return
      end
    end
    M.state.llama_ok = false
    update_connected_state()
    if callback then callback(false) end
  end)
end

--- Poll /slots endpoint for detailed slot and model info
local function poll_slots(endpoints, callback)
  local port = llama_api_port(endpoints)
  local url = format_http_url(endpoints.host, port, "/slots")
  http_get(url, function(ok, body)
    if ok and body then
      local data = json_decode(body)
      if data and type(data) == "table" and #data > 0 then
        -- Extract model name from first slot
        local slot = data[1]
        if type(slot.model) == "string" then
          -- Trim to just the filename without path and extension
          local model_name = slot.model:match("([^/\\]+)$") or slot.model
          model_name = model_name:gsub("%.gguf$", "")
          M.state.model = model_name
        end

        -- Aggregate context usage and performance across all slots
        local total_ctx = 0
        local used_ctx = 0
        local total_predicted = 0
        for _, s in ipairs(data) do
          if s.n_ctx then total_ctx = total_ctx + s.n_ctx end
          -- n_past = total tokens (prompt + generated) in KV cache for this slot
          used_ctx = used_ctx + (s.n_past or 0)
          if s.tokens_predicted then total_predicted = total_predicted + s.tokens_predicted end
          if s.n_gpu_layers then
            M.state.gpu_layers = s.n_gpu_layers
          end
        end
        M.state.ctx_total = total_ctx
        M.state.ctx_used = used_ctx
        M.state.tokens_predicted = total_predicted
      end
    end
    if callback then callback(ok) end
  end)
end

--- Poll /props endpoint for server properties (model info)
local function poll_props(endpoints, callback)
  local port = llama_api_port(endpoints)
  local url = format_http_url(endpoints.host, port, "/props")
  http_get(url, function(ok, body)
    if ok and body then
      local data = json_decode(body)
      if data then
        if data.total_slots then
          M.state.slots_total = data.total_slots
        end
        if data.default_generation_settings then
          local gs = data.default_generation_settings
          if type(gs.model) == "string" then
            local model_name = gs.model:match("([^/\\]+)$") or gs.model
            model_name = model_name:gsub("%.gguf$", "")
            M.state.model = model_name
          end
          if gs.n_ctx then
            M.state.ctx_total = gs.n_ctx
          end
          if gs.n_gpu_layers then
            M.state.gpu_layers = gs.n_gpu_layers
          end
        end
      end
    end
    if callback then callback(ok) end
  end)
end

--- Full poll cycle.
--- @param on_complete? fun() Optional callback invoked after all async probes finish.
function M.poll(on_complete)
  local endpoints = get_endpoints()

  -- Track parallel TCP probes + sequential HTTP chain with a countdown latch.
  -- TCP probes for proxy and embed run in parallel with the HTTP chain.
  local pending = 3  -- proxy TCP + embed TCP + HTTP chain (or llama TCP fallback)
  local function finish_one()
    pending = pending - 1
    if pending <= 0 then
      M.state.last_update = os.time()
      if on_complete then on_complete() end
    end
  end

  -- Probe all three services in parallel
  tcp_probe(endpoints.host, endpoints.proxy_port, function(ok)
    M.state.proxy_ok = ok
    update_connected_state()
    finish_one()
  end)

  tcp_probe(endpoints.host, endpoints.embed_port, function(ok)
    M.state.embed_ok = ok
    finish_one()
  end)

  -- HTTP polls for detailed info (only if curl is available)
  if vim.fn.executable("curl") == 1 then
    poll_health(endpoints, function()
      -- Chain: health -> props -> slots for progressive detail
      poll_props(endpoints, function()
        poll_slots(endpoints, function()
          finish_one()
        end)
      end)
    end)
  else
    -- Fallback: just TCP probe
    tcp_probe(endpoints.host, llama_api_port(endpoints), function(ok)
      M.state.llama_ok = ok
      update_connected_state()
      finish_one()
    end)
  end
end

--- Get a compact status string for lualine
function M.lualine_status()
  if not M.state.connected then
    return "AI: offline"
  end
  local parts = { "AI: on" }
  if M.state.model ~= "" then
    -- Shorten model name for status bar
    local short = M.state.model
    if #short > 20 then
      short = short:sub(1, 18) .. ".."
    end
    parts = { short }
  end
  if M.state.slots_total > 0 then
    parts[#parts + 1] = string.format("%d/%d", M.state.slots_used, M.state.slots_total)
  end
  return table.concat(parts, " | ")
end

--- Get service status icons for lualine
function M.service_icons()
  local proxy = M.state.proxy_ok and "P" or "p"
  local llama = M.state.llama_ok and "L" or "l"
  local embed = M.state.embed_ok and "E" or "e"
  return string.format("[%s%s%s]", proxy, llama, embed)
end

--- Start the periodic polling timer
function M.start_polling()
  local uv = vim.uv or vim.loop
  if not uv then return end

  -- Stop existing timer if re-called
  if M._timer then
    pcall(function() M._timer:close() end)
    M._timer = nil
  end

  -- Initial poll after 2 seconds (let UI settle)
  vim.defer_fn(function()
    M.poll()
  end, 2000)

  -- Periodic poll — store on module to prevent GC collection
  M._timer = uv.new_timer()
  if M._timer then
    M._timer:start(POLL_INTERVAL_MS, POLL_INTERVAL_MS, vim.schedule_wrap(function()
      -- Guard: skip if timer was stopped between schedule and execution
      if not M._timer then return end
      M.poll()
    end))
  end

  -- Cleanup timer on Neovim exit to prevent late callbacks on invalid state
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() M.stop_polling() end,
    once = true,
  })
end

--- Stop polling and clean up timer handle
function M.stop_polling()
  if M._timer then
    pcall(function() M._timer:close() end)
    M._timer = nil
  end
end

--- Helper: render monitor lines into a buffer.
local function render_monitor_window(buf)
  local lines = M._build_monitor_lines()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  return lines
end

--- Open a floating window showing real-time backend stats
function M.open_monitor()
  -- Show window immediately with current (possibly stale) data, then refresh
  local lines = M._build_monitor_lines()
  local width = 60
  local height = #lines + 2

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Jenova Monitor ",
    title_pos = "center",
  }
  local win = vim.api.nvim_open_win(buf, true, win_opts)

  -- Highlight setup
  vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })

  -- Close on q or Escape
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true })

  -- Refresh on 'r' — uses poll callback instead of heuristic delay
  vim.keymap.set("n", "r", function()
    M.poll(function()
      render_monitor_window(buf)
    end)
  end, { buffer = buf, nowait = true })

  -- Trigger an immediate poll and refresh when data arrives
  M.poll(function()
    render_monitor_window(buf)
  end)
end

--- Build the lines for the monitor display
function M._build_monitor_lines()
  local s = M.state
  local endpoints = get_endpoints()

  local function status_icon(ok)
    return ok and "  ONLINE" or "  OFFLINE"
  end

  local lines = {
    "  Jenova Cognitive Architecture — Backend Monitor",
    string.rep("-", 56),
    "",
    "  Services:",
    string.format("    Proxy (:%d)     %s", endpoints.proxy_port, status_icon(s.proxy_ok)),
    string.format("    llama (:%d)     %s", endpoints.llama_port, status_icon(s.llama_ok)),
    string.format("    Embed (:%d)     %s", endpoints.embed_port, status_icon(s.embed_ok)),
    "",
    "  Model:",
    string.format("    Name:           %s", s.model ~= "" and s.model or "(unknown)"),
    string.format("    GPU Layers:     %s", s.gpu_layers > 0 and tostring(s.gpu_layers) or "(unknown)"),
    "",
    "  Inference:",
    string.format("    Slots:          %d / %d", s.slots_used, s.slots_total),
    string.format("    Context:        %s", s.ctx_total > 0 and string.format("%d tokens", s.ctx_total) or "(unknown)"),
    string.format("    KV Used:        %d tokens", s.ctx_used),
    string.format("    Predicted:      %d tokens", s.tokens_predicted),
    "",
    "  Connection:",
    string.format("    Host:           %s", endpoints.host),
    string.format("    Last Poll:      %s", s.last_update > 0 and os.date("%H:%M:%S", s.last_update) or "never"),
    "",
    string.rep("-", 56),
    "  [r] Refresh    [q/Esc] Close",
  }
  return lines
end

--- Public accessor for endpoint config (reused by health.lua and dashboard.lua)
M.get_endpoints = get_endpoints

return M
