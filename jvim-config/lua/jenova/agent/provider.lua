-- jenova/agent/provider.lua
-- jvim-native HTTP provider for the embedded agent.
--
-- Exposes the same surface as cli-agent's utils/http.lua so jenova_backend.lua
-- can use it via package.loaded injection.  When called from a coroutine the
-- HTTP calls are asynchronous (vim.system + coroutine.yield/resume), keeping
-- the editor event loop free.  When called outside a coroutine they fall back
-- to blocking vim.system():wait().

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

-- Run curl, yielding the calling coroutine if inside one so the editor stays
-- responsive.  Falls back to blocking :wait() when on the main thread directly.
local function run(cmd)
  local co = coroutine.running()
  if co then
    vim.system(cmd, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          coroutine.resume(co, nil, result.stderr or ("curl exit " .. result.code))
        else
          coroutine.resume(co, result.stdout, nil)
        end
      end)
    end)
    return coroutine.yield()
  end
  -- Blocking fallback
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or ("curl exit " .. result.code)
  end
  return result.stdout, nil
end

-- ── Public API (mirrors utils/http.lua) ───────────────────────────────────────

function M.get(url, headers)
  local hdr = headers
  if type(hdr) == "string" and #hdr > 0 then
    local ok, t = pcall(vim.json.decode, hdr)
    hdr = (ok and type(t) == "table") and t or {}
  end
  local header_args = make_headers(type(hdr) == "table" and hdr or {})
  local cmd = vim.list_extend(
    { "curl", "-s", "-S", "--max-time", "30", "--connect-timeout", "10" },
    header_args
  )
  table.insert(cmd, url)
  return run(cmd)
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

  local result, err = run(cmd)
  if tmpfile then pcall(os.remove, tmpfile) end
  return result, err
end

M.post = M.post_json

-- Streaming POST: calls on_chunk(text) for each SSE delta token.
-- When called from a coroutine the final response is returned after streaming
-- completes.  on_chunk fires via vim.schedule (always on the main thread).
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

  local co = coroutine.running()
  local buf = {}
  local sse_buffer = ""

  local agent = package.loaded["jenova.agent"]
  local handle = vim.system(cmd, {
    text = true,
    stdout = function(_, data)
      if data then
        table.insert(buf, data)
        if on_chunk then
          sse_buffer = sse_buffer .. data
          while true do
            local nl = sse_buffer:find("\n")
            if not nl then break end
            local line = sse_buffer:sub(1, nl - 1):gsub("\r$", "")
            sse_buffer = sse_buffer:sub(nl + 1)

            if line:sub(1, 6) == "data: " and line ~= "data: [DONE]" then
              local ok2, chunk = pcall(vim.json.decode, line:sub(7))
              if ok2 and chunk and chunk.choices and chunk.choices[1] then
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
  }, function(result)
    if tmpfile then pcall(os.remove, tmpfile) end
    -- Clear the active job reference now that curl has exited.
    if agent then agent._active_job = nil end
    local body_str = table.concat(buf)
    if co then
      vim.schedule(function()
        if result.code ~= 0 then
          coroutine.resume(co, nil, result.stderr or "curl failed")
        else
          coroutine.resume(co, body_str, nil)
        end
      end)
    end
  end)

  -- Register the handle so agent.stop() can kill the process.
  if agent then agent._active_job = handle end

  if co then
    return coroutine.yield()
  end

  local result = handle:wait()
  if tmpfile then pcall(os.remove, tmpfile) end
  if result.code ~= 0 then
    return nil, result.stderr or "curl failed"
  end
  return table.concat(buf), nil
end

--- Generate a completion, streaming chunks live to on_chunk while accumulating
--- the full response text for tool-call parsing.
---
--- @param request table  Full API request (messages, model, system, etc.)
--- @param on_chunk function|nil  Called per text delta (for live buffer updates).
---                               When nil, falls back to a blocking non-streaming POST.
--- @return string  The complete assembled response text.
function M.generate_request(request, on_chunk)
  local url = ep.proxy_url()
  local body = vim.json.encode(request)

  if on_chunk then
    -- Streaming path: accumulate text chunks while forwarding each to on_chunk.
    -- post_stream handles SSE parsing, calls on_chunk(delta) per token via vim.schedule,
    -- and yields the calling coroutine until streaming completes.
    local chunks = {}
    local function collect(delta)
      table.insert(chunks, delta)
      on_chunk(delta)
    end
    local _, err = M.post_stream(url, nil, body, collect)
    if err then error("generate_request (stream): " .. err) end
    return table.concat(chunks)
  end

  -- Non-streaming fallback (used when called outside a coroutine / no on_chunk).
  local res, err = M.post_json(url, nil, body)
  if err then error("generate_request: " .. err) end

  local ok, data = pcall(vim.json.decode, res)
  if not ok then return res or "" end

  if data.choices and data.choices[1] then
    local msg = data.choices[1].message or {}
    return msg.content or ""
  end

  -- Backend may return a raw string or non-standard envelope.
  return res or ""
end

-- ── Endpoint helpers for the jvim context ─────────────────────────────────────

function M.base_url()
  return string.format("http://%s:%d", ep.host(), ep.proxy_port())
end

return M
