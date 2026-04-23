-- jenova/agent/provider.lua
-- jvim-native HTTP provider for the embedded agent.
--
-- Replaces cli-agent's io.popen("curl...") HTTP layer with vim.system so HTTP
-- calls are non-blocking and run on the libuv event loop instead of blocking
-- the Lua thread.  The module exposes the same surface as cli-agent's
-- utils/http.lua so jenova_backend.lua can use it without changes.

local M = {}

local ep = require("jenova.endpoints")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_headers(headers_tbl)
  local args = {}
  if type(headers_tbl) == "table" then
    for k, v in pairs(headers_tbl) do
      local sk = tostring(k):gsub("[\r\n]", "")
      local sv = tostring(v):gsub("[\r\n]", "")
      table.insert(args, "-H")
      table.insert(args, sk .. ": " .. sv)
    end
  end
  return args
end

local function write_tempfile(body)
  local path = vim.fn.tempname() .. "_jenova_agent.json"
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(body)
  f:close()
  return path
end

-- Synchronous wrapper around vim.system used for blocking calls that the
-- engine still expects to be synchronous (e.g. is_available health check).
local function run_sync(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or ("exit " .. result.code)
  end
  return result.stdout, nil
end

-- ── Public API (mirrors utils/http.lua) ───────────────────────────────────────

function M.get(url, headers)
  local header_args = make_headers(
    type(headers) == "string" and vim.json.decode(headers) or headers
  )
  local cmd = vim.list_extend(
    { "curl", "-s", "-S", "--max-time", "30", "--connect-timeout", "10" },
    header_args
  )
  table.insert(cmd, url)
  return run_sync(cmd)
end

function M.post_json(url, headers, body)
  local hdr = headers
  if type(hdr) == "string" and #hdr > 0 then
    local ok, t = pcall(vim.json.decode, hdr)
    hdr = (ok and type(t) == "table") and t or {}
  end
  if type(hdr) ~= "table" then hdr = {} end
  if not hdr["Content-Type"] then hdr["Content-Type"] = "application/json" end

  local tmpfile = body and write_tempfile(body)
  if not tmpfile and body and #body > 0 then
    return nil, "failed to write temp file"
  end

  local header_args = make_headers(hdr)
  local cmd = vim.list_extend(
    { "curl", "-s", "-S", "--max-time", "300", "--connect-timeout", "10", "-X", "POST" },
    header_args
  )
  if tmpfile then
    table.insert(cmd, "-d")
    table.insert(cmd, "@" .. tmpfile)
  end
  table.insert(cmd, url)

  local result, err = run_sync(cmd)
  if tmpfile then pcall(os.remove, tmpfile) end
  return result, err
end

M.post = M.post_json

-- Streaming POST: calls on_chunk(text) for each SSE token as it arrives,
-- then returns the full raw SSE body.
function M.post_stream(url, headers_str, body, on_chunk)
  local hdr = {}
  if type(headers_str) == "string" and #headers_str > 0 then
    local ok, t = pcall(vim.json.decode, headers_str)
    if ok and type(t) == "table" then hdr = t end
  end
  if not hdr["Content-Type"] then hdr["Content-Type"] = "application/json" end

  local tmpfile = body and write_tempfile(body)
  if not tmpfile and body and #body > 0 then
    return nil, "failed to write temp file"
  end

  local header_args = make_headers(hdr)
  local cmd = vim.list_extend(
    { "curl", "--no-buffer", "-s", "-N", "-X", "POST" },
    header_args
  )
  if tmpfile then
    table.insert(cmd, "-d")
    table.insert(cmd, "@" .. tmpfile)
  end
  table.insert(cmd, url)

  local buf = {}
  local result = vim.system(cmd, {
    text = true,
    stdout = function(_, data)
      if data then
        table.insert(buf, data)
        if on_chunk then
          -- Extract and forward text tokens inline.
          for line in data:gmatch("[^\n]+") do
            if line:sub(1, 6) == "data: " and line ~= "data: [DONE]" then
              local ok, chunk = pcall(vim.json.decode, line:sub(7))
              if ok and chunk and chunk.choices and chunk.choices[1] then
                local delta = chunk.choices[1].delta or {}
                if type(delta.content) == "string" and delta.content ~= "" then
                  vim.schedule(function() on_chunk(delta.content) end)
                end
              end
            end
          end
        end
      end
    end,
  }):wait()

  if tmpfile then pcall(os.remove, tmpfile) end

  if result.code ~= 0 then
    return nil, result.stderr or ("curl exit " .. result.code)
  end
  return table.concat(buf), nil
end

-- ── Endpoint helpers for the jvim context ─────────────────────────────────────

function M.base_url()
  return string.format("http://%s:%d", ep.host(), ep.proxy_port())
end

return M
