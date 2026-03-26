-- http.lua: Minimal HTTP client using LuaJIT FFI (no external dependencies)
-- Uses centralized definitions from ffi_defs.lua.

local ffi = require("ffi")
local ffi_defs = require("ffi_defs")

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 0xffff
local SO_RCVTIMEO = 0x1006
local SO_SNDTIMEO = 0x1005

local EAGAIN      = 35
local ETIMEDOUT   = 60
local EINTR       = 4
local EWOULDBLOCK = EAGAIN

local http = {}

local function get_errno()
  return ffi.errno()
end

local function get_errstr(err)
  return ffi.string(ffi.C.strerror(err or ffi.errno()))
end

local function parse_url(url)
  local host, port, path = url:match("^https?://([^:/%s]+):(%d+)(.*)")
  if not host then
    host, path = url:match("^https?://([^/%s]+)(.*)")
    port = "80"
  end
  if not path or path == "" then path = "/" end
  return host, tonumber(port), path
end

local function resolve_host(host)
  local addr = ffi.C.inet_addr(host)
  if tonumber(addr) ~= 0xffffffff then return addr end

  local hints = ffi.new("struct addrinfo[1]")
  hints[0].ai_family = AF_INET
  hints[0].ai_socktype = SOCK_STREAM
  hints[0].ai_protocol = 0

  local res = ffi.new("struct addrinfo*[1]")
  local rc = ffi.C.getaddrinfo(host, nil, hints, res)
  if rc ~= 0 then
    return 0xffffffff
  end
  local ai = res[0]
  if ai == nil then
    return 0xffffffff
  end

  local sa = ffi.cast("struct sockaddr_in *", ai.ai_addr)
  local out = sa.sin_addr.s_addr
  ffi.C.freeaddrinfo(ai)  -- Fixed: pass ai directly, not res[0]
  return out
end

local function send_all(fd, data)
  local sent = 0
  local retries = 0
  local MAX_SEND_RETRIES = 50
  while sent < #data do
    local n = ffi.C.send(fd, data:sub(sent + 1), #data - sent, 0)
    if n <= 0 then
      local err = get_errno()
      if err == EINTR or err == EAGAIN or err == EWOULDBLOCK then
        retries = retries + 1
        if retries > MAX_SEND_RETRIES then
          return false, "send() stalled after " .. retries .. " retries"
        end
        local tv_sleep = ffi.new("struct timeval")
        tv_sleep.tv_sec = 0
        tv_sleep.tv_usec = 50000
        ffi.C.select(0, nil, nil, nil, tv_sleep)
        goto continue
      end
      return false, "send() failed: " .. get_errstr(err)
    end
    sent = sent + tonumber(n)
    retries = 0
    ::continue::
  end
  return true
end

local function recv_all(fd, buf, buf_size)
  local chunks = {}
  local total_recv = 0
  local stall_count = 0
  local recv_err = nil
  local MAX_RECV_SIZE = 10 * 1024 * 1024  -- 10MB cap to prevent memory exhaustion
  while true do
    ::retry::
    local recv_n = ffi.C.recv(fd, buf, buf_size, 0)
    if recv_n > 0 then
      total_recv = total_recv + tonumber(recv_n)
      if total_recv > MAX_RECV_SIZE then
        recv_err = "response too large (>" .. (MAX_RECV_SIZE/1048576) .. "MB)"
        break
      end
      chunks[#chunks + 1] = ffi.string(buf, recv_n)
      stall_count = 0
    elseif recv_n == 0 then
      break
    else
      local err = get_errno()
      if err == EINTR then
        goto retry
      elseif err == EAGAIN or err == EWOULDBLOCK or err == ETIMEDOUT then
        stall_count = stall_count + 1
        if stall_count >= 10 then break end
        local tv_sleep = ffi.new("struct timeval")
        tv_sleep.tv_sec = 0
        tv_sleep.tv_usec = 50000
        ffi.C.select(0, nil, nil, nil, tv_sleep)
      else
        recv_err = "recv() fatal error: " .. get_errstr(err) .. " (errno=" .. tostring(err) .. ")"
        break
      end
    end
  end
  return chunks, recv_err
end

local function decode_chunked(after_headers)
  local decoded = {}
  local pos = 1
  while pos <= #after_headers do
    local chunk_end = after_headers:find("\r\n", pos)
    if not chunk_end then break end
    local size_str = after_headers:sub(pos, chunk_end - 1)
    local chunk_size = tonumber(size_str, 16)
    if not chunk_size or chunk_size == 0 then break end
    local chunk_data = after_headers:sub(chunk_end + 2, chunk_end + 1 + chunk_size)
    decoded[#decoded + 1] = chunk_data
    pos = chunk_end + 2 + chunk_size + 2
  end
  return table.concat(decoded)
end

local function parse_response(raw)
  if raw == "" then return 0, "" end
  local status_code = tonumber(raw:match("HTTP/%d%.%d%s+(%d+)")) or 0
  local header_end = raw:find("\r\n\r\n")
  if not header_end then return status_code, "" end

  local headers = raw:sub(1, header_end + 1)
  local after_headers = raw:sub(header_end + 4)
  if headers:lower():find("transfer%-encoding:%s*chunked") then
    return status_code, decode_chunked(after_headers)
  end
  return status_code, after_headers
end

function http.post(url, body, timeout)
  timeout = timeout or 600
  if url:lower():match("^https://") then
    return 0, "https endpoint not supported"
  end
  local host, port, path = parse_url(url)
  if not host then return 0, "invalid url: " .. tostring(url) end

  local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
  if fd < 0 then return 0, "socket() failed" end

  local tv = ffi.new("struct timeval")
  tv.tv_sec = timeout
  tv.tv_usec = 0
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))

  local addr = ffi.new("struct sockaddr_in")
  addr.sin_len = ffi.sizeof(addr)
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)

  local resolved = resolve_host(host)
  addr.sin_addr.s_addr = resolved

  if tonumber(addr.sin_addr.s_addr) == 0xffffffff then
    ffi.C.close(fd)
    return 0, "invalid host: " .. host
  end

  local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
  if ret < 0 then
    ffi.C.close(fd)
    return 0, "connect() failed"
  end

  local req = string.format(
    "POST %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
    path, host, port, #body, body)

  local ok, err = send_all(fd, req)
  if not ok then
    ffi.C.close(fd)
    return 0, err
  end

  local buf = ffi.new("char[?]", 131072)
  local chunks, recv_err = recv_all(fd, buf, 131072)
  ffi.C.close(fd)

  if recv_err then return 499, recv_err end

  local raw = table.concat(chunks)
  if raw == "" then return 0, "empty response (received 0 bytes after send)" end

  return parse_response(raw)
end

function http.get(url, timeout)
  timeout = timeout or 5
  if url:lower():match("^https://") then
    return 0, "https endpoint not supported"
  end
  local host, port, path = parse_url(url)
  if not host then return 0, "invalid url" end

  local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
  if fd < 0 then return 0, "socket() failed" end

  local tv = ffi.new("struct timeval")
  tv.tv_sec = timeout
  tv.tv_usec = 0
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))

  local addr = ffi.new("struct sockaddr_in")
  addr.sin_len = ffi.sizeof(addr)
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)

  local resolved = resolve_host(host)
  addr.sin_addr.s_addr = resolved

  if tonumber(addr.sin_addr.s_addr) == 0xffffffff then
    ffi.C.close(fd)
    return 0, "invalid host"
  end

  local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
  if ret < 0 then
    ffi.C.close(fd)
    return 0, "connect() failed"
  end

  local req = string.format(
    "GET %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n\r\n",
    path, host, port)

  local ok, err = send_all(fd, req)
  if not ok then
    ffi.C.close(fd)
    return 0, err
  end

  local buf = ffi.new("char[?]", 65536)
  local chunks, recv_err = recv_all(fd, buf, 65536)
  ffi.C.close(fd)

  if recv_err then return 499, recv_err end

  local raw = table.concat(chunks)
  if raw == "" then return 0, "empty response" end

  return parse_response(raw)
end

return http
