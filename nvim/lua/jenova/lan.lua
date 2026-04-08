-- jenova/lan.lua: LAN discovery for remote Jenova CA instances.
-- When Neovim is launched without jvim (no JENOVA_ROOT / JENOVA_CONNECT_HOST),
-- this module scans the local network for a running Jenova CA proxy and
-- configures the connection if one is found.
--
-- Discovery strategy:
--   1. Determine the local machine's IP and subnet via `ifconfig` or `ip addr`
--   2. Probe all candidate IPs in the local subnet (e.g., /24) on the 
--      Jenova proxy port (default 8080) via non-blocking TCP.
--   3. Validate by fetching /health from responsive hosts (llama-server check).
--   4. On success, set JENOVA_CONNECT_HOST, JENOVA_PORT, JENOVA_LLAMA_PORT
--      so that plugins and monitors pick them up.

local M = {}

--- Default ports to probe
local DEFAULT_PROXY_PORT = 8080
local DEFAULT_LLAMA_PORT = 8081
local DEFAULT_EMBED_PORT = 8082
local PROBE_TIMEOUT_MS = 1000 -- Increased for more reliable LAN discovery
local MAX_CONCURRENT = 50            -- parallel TCP probes in-flight
local MAX_VALIDATE_CONCURRENT = 5  -- cap concurrent curl processes for /health checks

--- Parse network interface output for IPv4 addresses (shared by ifconfig/ip addr).
local function parse_network_output(output)
  local networks = {}
  if not output or output == "" then return networks end

  -- FreeBSD/macOS ifconfig: "inet 192.168.1.5 netmask 0xffffff00"
  for ip, hex_mask in output:gmatch("inet (%d+%.%d+%.%d+%.%d+) netmask 0x(%x+)") do
    if ip ~= "127.0.0.1" then
      local mask_num = tonumber(hex_mask, 16) or 0
      local prefix = 0
      while mask_num > 0 do
        prefix = prefix + (mask_num % 2)
        mask_num = math.floor(mask_num / 2)
      end
      if prefix == 0 then prefix = 24 end
      table.insert(networks, { ip = ip, prefix = prefix })
    end
  end

  -- Linux ip addr: "inet 192.168.1.5/24"
  for ip, prefix in output:gmatch("inet (%d+%.%d+%.%d+%.%d+)/(%d+)") do
    if ip ~= "127.0.0.1" then
      table.insert(networks, { ip = ip, prefix = tonumber(prefix) })
    end
  end

  return networks
end

--- Parse local IP addresses from system commands (async via vim.system).
--- @param callback fun(networks: table) Called with list of {ip=string, prefix=number}
local function get_local_networks(callback)
  if not vim.system then callback({}) return end

  local ok, _ = pcall(vim.system, { "ifconfig" }, { text = true }, function(result)
    vim.schedule(function()
      local networks = parse_network_output((result and result.stdout) or "")
      if #networks > 0 then
        callback(networks)
      else
        -- Fallback: try Linux ip addr
        local ok2, _ = pcall(vim.system, { "ip", "-4", "addr", "show" }, { text = true }, function(r2)
          vim.schedule(function()
            callback(parse_network_output((r2 and r2.stdout) or ""))
          end)
        end)
        if not ok2 then callback({}) end
      end
    end)
  end)
  if not ok then callback({}) end
end

--- Parse an IPv4 address into 4 octets
local function ip_to_octets(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a then
    return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  end
  return nil
end

--- Generate candidate IPs for a subnet based on its prefix length.
--- Supports /24 (254 hosts), /23 (510), /22 (1022), /16 (limited to first 1024).
--- Subnets larger than /16 or smaller than /24 are clamped for safety.
local function generate_candidates(network)
  local a, b, c, d = ip_to_octets(network.ip)
  if not a then return {} end

  local prefix = network.prefix or 24
  -- Clamp to reasonable range for scanning
  if prefix < 16 then prefix = 16 end
  if prefix > 30 then return {} end

  local host_bits = 32 - prefix
  local host_count = math.min(2 ^ host_bits - 2, 1024)  -- cap at 1024 to avoid flooding

  -- Compute network address by truncating host bits
  local ip_num = a * 16777216 + b * 65536 + c * 256 + d
  local net_base = ip_num % 4294967296  -- ensure unsigned
  net_base = math.floor(net_base / (2 ^ host_bits)) * (2 ^ host_bits)

  local candidates = {}
  local local_ip = network.ip
  for i = 1, host_count do
    local candidate_num = net_base + i
    local ca = math.floor(candidate_num / 16777216) % 256
    local cb = math.floor(candidate_num / 65536) % 256
    local cc = math.floor(candidate_num / 256) % 256
    local cd = candidate_num % 256
    local candidate = string.format("%d.%d.%d.%d", ca, cb, cc, cd)
    if candidate ~= local_ip then
      table.insert(candidates, candidate)
    end
  end
  return candidates
end

-- Pin active timer/tcp handles to prevent GC during concurrent LAN scanning.
-- Handles are removed from this table when closed.
local _active_handles = {}

--- Non-blocking TCP probe for a single host:port
--- @param host string
--- @param port number
--- @param timeout_ms number
--- @param callback fun(ok: boolean)
local function tcp_probe(host, port, timeout_ms, callback)
  local uv = vim.uv or vim.loop
  if not uv then callback(false) return end
  local tcp = uv.new_tcp()
  if not tcp then callback(false) return end
  local timer = uv.new_timer()
  -- Pin handles to prevent GC collection during async operations
  _active_handles[tcp] = true
  if timer then _active_handles[timer] = true end
  local closed = false
  local function close_all()
    if not closed then
      closed = true
      pcall(function() tcp:close() end)
      _active_handles[tcp] = nil
      if timer then
        pcall(function() timer:close() end)
        _active_handles[timer] = nil
      end
    end
  end
  if timer then
    timer:start(timeout_ms, 0, function()
      if not closed then
        close_all()
        vim.schedule(function() callback(false) end)
      end
    end)
  end
  tcp:connect(host, port, function(err)
    if closed then return end
    close_all()
    vim.schedule(function() callback(not err) end)
  end)
end

--- Validate a candidate host by checking the proxy /health endpoint.
--- The proxy exposes /health on its own port and checks backend liveness internally.
--- @param host string
--- @param proxy_port number
--- @param callback fun(ok: boolean)
local function validate_health(host, proxy_port, callback)
  if not vim.system or vim.fn.executable("curl") ~= 1 then
    callback(true)
    return
  end
  local url = string.format("http://%s:%d/health", host, proxy_port)
  vim.system(
    { "curl", "-sf", "--max-time", "3", "--connect-timeout", "2", url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout then
          local has_status = result.stdout:find('"status"') ~= nil
          callback(has_status)
        else
          callback(false)
        end
      end)
    end
  )
end

--- Scan the local network for a Jenova CA instance.
--- Probes all /24 candidates on the proxy port, validates via /health.
--- @param opts? {port?: number, on_found: fun(host: string, port: number), on_complete?: fun()}
function M.discover(opts)
  opts = opts or {}
  local port = opts.port or DEFAULT_PROXY_PORT
  local on_found = opts.on_found
  local on_complete = opts.on_complete

  if not on_found then return end

  get_local_networks(function(networks)
  if #networks == 0 then
    if on_complete then on_complete() end
    return
  end

  -- Collect all candidate IPs from all local subnets
  local all_candidates = {}
  for _, net in ipairs(networks) do
    local candidates = generate_candidates(net)
    for _, c in ipairs(candidates) do
      table.insert(all_candidates, c)
    end
  end

  if #all_candidates == 0 then
    if on_complete then on_complete() end
    return
  end

  -- Batch-probe candidates with limited concurrency.
  -- Track both TCP probes (active) and HTTP validations (validate_pending)
  -- to prevent on_complete firing while validations are still in-flight.
  local found = false
  local idx = 1
  local active = 0
  local validate_pending = 0  -- HTTP validations in-flight (active counts TCP only)
  local total = #all_candidates

  local function check_complete()
    if not found and active == 0 and validate_pending == 0 and idx > total then
      if on_complete then on_complete() end
    end
  end

  -- Queue for HTTP validations waiting for a concurrency slot
  local validate_queue = {}

  local function drain_validate_queue()
    while #validate_queue > 0 and validate_pending < MAX_VALIDATE_CONCURRENT do
      if found then return end
      local queued = table.remove(validate_queue, 1)
      validate_pending = validate_pending + 1
      validate_health(queued, port, function(valid)
        validate_pending = validate_pending - 1
        if not found and valid then
          found = true
          on_found(queued, port)
        end
        drain_validate_queue()
        check_complete()
      end)
    end
  end

  local function probe_next()
    if found then return end
    while active < MAX_CONCURRENT and idx <= total do
      local candidate = all_candidates[idx]
      idx = idx + 1
      active = active + 1
      tcp_probe(candidate, port, PROBE_TIMEOUT_MS, function(ok)
        active = active - 1
        if not found and ok then
          table.insert(validate_queue, candidate)
          drain_validate_queue()
        end
        probe_next()
        check_complete()
      end)
    end
    check_complete()
  end

  probe_next()
  end) -- get_local_networks callback
end

--- Configure Neovim environment for a discovered remote Jenova CA instance.
--- Sets env vars so chat, llama.vim, and monitor all pick up the remote host.
--- @param host string  The LAN IP of the Jenova CA server
--- @param proxy_port? number  Proxy port (default 8080)
--- @param llama_port? number  llama-server port (default 8081)
function M.configure_remote(host, proxy_port, llama_port, embed_port)
  proxy_port = proxy_port or DEFAULT_PROXY_PORT
  llama_port = llama_port or DEFAULT_LLAMA_PORT
  embed_port = embed_port or DEFAULT_EMBED_PORT

  vim.env.JENOVA_CONNECT_HOST = host
  vim.env.JENOVA_PORT = tostring(proxy_port)
  vim.env.JENOVA_LLAMA_PORT = tostring(llama_port)
  vim.env.JENOVA_LLAMA_EMBED_PORT = tostring(embed_port)
  vim.env.JENOVA_LAN_MODE = "1"

  vim.g.jenova_connected = true
  vim.g.jenova_lan_host = host

  local ep_ok, endpoints = pcall(require, "jenova.endpoints")
  if ep_ok then
    endpoints.reconfigure_plugins()
  end

  vim.notify(
    string.format("Jenova CA found on LAN: %s (proxy:%d llama:%d embed:%d)",
      host, proxy_port, llama_port, embed_port),
    vim.log.levels.INFO,
    { title = "Jenova LAN" }
  )
end

--- Auto-discover and connect: convenience function for init.lua integration.
--- Only runs when JENOVA_CONNECT_HOST is not set (i.e., nvim launched without jvim).
--- @param opts? {silent?: boolean}
function M.auto_discover(opts)
  opts = opts or {}
  local silent = opts.silent or false

  -- Skip if already configured (launched via jvim or env set manually)
  if vim.env.JENOVA_CONNECT_HOST and vim.env.JENOVA_CONNECT_HOST ~= "" then
    return
  end

  -- Also skip if JENOVA_ROOT is set (jvim sets this)
  if vim.env.JENOVA_ROOT and vim.env.JENOVA_ROOT ~= "" and vim.env.JENOVA_ROOT ~= "$JENOVA_ROOT" then
    return
  end

  -- Skip if JENOVA_LAN_SCAN is explicitly disabled
  if vim.env.JENOVA_LAN_SCAN == "0" or vim.env.JENOVA_LAN_SCAN == "false" then
    return
  end

  M.discover({
    on_found = function(host, port)
      M.configure_remote(host, port)

      -- Start monitor polling now that we have a connection
      local mon_ok, monitor = pcall(require, "jenova.monitor")
      if mon_ok then
        monitor.start_polling()
      end
    end,
    on_complete = function()
      if not silent then
        vim.notify(
          "No Jenova CA found on LAN. AI features unavailable.\n" ..
          "Set JENOVA_CONNECT_HOST=<ip> or use jvim to start locally.",
          vim.log.levels.INFO,
          { title = "Jenova LAN" }
        )
      end
    end,
  })
end

return M
