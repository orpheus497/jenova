-- http.lua: Minimal HTTP client using LuaJIT FFI (no external dependencies)
-- Uses centralized definitions from ffi_defs.lua.

local ffi = require("ffi")
local ffi_defs = require("ffi_defs")

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = ffi_defs.SOL_SOCKET
local SO_RCVTIMEO = ffi_defs.SO_RCVTIMEO
local SO_SNDTIMEO = ffi_defs.SO_SNDTIMEO

local EAGAIN      = ffi_defs.EAGAIN
local ETIMEDOUT   = ffi_defs.ETIMEDOUT
local EINTR       = ffi_defs.EINTR
local EWOULDBLOCK = ffi_defs.EWOULDBLOCK

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
  if addr ~= ffi.cast("in_addr_t", 0xffffffff) then return addr end

  local hints = ffi.new("struct addrinfo[1]")
  hints[0].ai_family = AF_INET
  hints[0].ai_socktype = SOCK_STREAM
  hints[0].ai_protocol = 0

  local res = ffi.new("struct addrinfo*[1]")
  local rc = ffi.C.getaddrinfo(host, nil, hints, res)
  if rc ~= 0 then
    return ffi.cast("in_addr_t", 0xffffffff)
  end
  local ai = res[0]
  if ai == nil then
    return ffi.cast("in_addr_t", 0xffffffff)
  end

  local sa = ffi.cast("struct sockaddr_in *", ai.ai_addr)
  local out = sa.sin_addr.s_addr
  ffi.C.freeaddrinfo(ai)
  return out
end

local function send_all(fd, data)
  local sent = 0
  while sent < #data do
    local n = ffi.C.send(fd, ffi.cast("const char *", data) + sent, #data - sent, 0)
    if n > 0 then
      sent = sent + tonumber(n)
    else
      local err = get_errno()
      if err == EINTR or err == EAGAIN or err == EWOULDBLOCK then
        local _, is_main = coroutine.running()
        if not is_main then
          coroutine.yield("write", fd)
        else
          local tv_sleep = ffi.new("struct timeval")
          tv_sleep.tv_sec = 0
          tv_sleep.tv_usec = 50000
          ffi.C.select(0, nil, nil, nil, tv_sleep)
        end
      else
        return false, "send() failed: " .. get_errstr(err)
      end
    end
  end
  return true
end

local function recv_all(fd, buf, buf_size, deadline)
  local chunks = {}
  local total_recv = 0
  local recv_err = nil
  local MAX_RECV_SIZE = 10 * 1024 * 1024  -- 10MB cap
  
  -- Default deadline: 30 seconds
  deadline = deadline or (os.time() + 30)
  
  while true do
    if os.time() >= deadline then
      recv_err = "recv() timed out"
      break
    end
    
    local recv_n = ffi.C.recv(fd, buf, buf_size, 0)
    if recv_n > 0 then
      total_recv = total_recv + tonumber(recv_n)
      if total_recv > MAX_RECV_SIZE then
        recv_err = "response too large"
        break
      end
      chunks[#chunks + 1] = ffi.string(buf, recv_n)
    elseif recv_n == 0 then
      break
    else
      local err = get_errno()
      if err == EINTR then
        -- retry immediately
      elseif err == EAGAIN or err == EWOULDBLOCK or err == ETIMEDOUT then
        local _, is_main = coroutine.running()
        if not is_main then
          coroutine.yield("read", fd)
        else
          local tv_sleep = ffi.new("struct timeval")
          tv_sleep.tv_sec = 0
          tv_sleep.tv_usec = 50000
          ffi.C.select(0, nil, nil, nil, tv_sleep)
        end
      else
        recv_err = "recv() fatal error: " .. get_errstr(err)
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

  -- Set non-blocking to work with coroutine yields
  local flags = ffi.C.fcntl(fd, ffi_defs.F_GETFL, 0)
  ffi.C.fcntl(fd, ffi_defs.F_SETFL, bit.bor(flags, ffi_defs.O_NONBLOCK))

  local tv = ffi.new("struct timeval")
  tv.tv_sec = timeout
  tv.tv_usec = 0
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))

  local addr = ffi.new("struct sockaddr_in")
  if not ffi_defs.IS_LINUX then
    addr.sin_len = ffi.sizeof(addr)
  end
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)

  local resolved = resolve_host(host)
  addr.sin_addr.s_addr = resolved

  if resolved == ffi.cast("in_addr_t", 0xffffffff) then
    ffi.C.close(fd)
    return 0, "invalid host: " .. host
  end

  local co, is_main = coroutine.running()
  if co and not is_main then
    local flags = ffi.C.fcntl(fd, ffi_defs.F_GETFL, 0)
    ffi.C.fcntl(fd, ffi_defs.F_SETFL, bit.bor(flags, ffi_defs.O_NONBLOCK))
    local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
    if ret ~= 0 then
      local err = get_errno()
      if err == ffi_defs.EINPROGRESS or err == ffi_defs.EAGAIN or err == ffi_defs.EWOULDBLOCK then
        coroutine.yield("write", fd)
        local opt = ffi.new("int[1]")
        local len = ffi.new("socklen_t[1]", ffi.sizeof("int"))
        ffi.C.getsockopt(fd, SOL_SOCKET, SO_ERROR, opt, len)
        if opt[0] ~= 0 then
          ffi.C.close(fd)
          return 0, "connect() async failed: " .. get_errstr(opt[0])
        end
      else
        ffi.C.close(fd)
        return 0, "connect() failed: " .. get_errstr(err)
      end
    end
    -- Success or async success: keep it non-blocking for send_all/recv_all
  else
    local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
    if ret < 0 then
      ffi.C.close(fd)
      return 0, "connect() failed: " .. get_errstr(get_errno())
    end
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
  local chunks, recv_err = recv_all(fd, buf, 131072, os.time() + timeout)
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

  -- Set non-blocking to work with coroutine yields
  local flags = ffi.C.fcntl(fd, ffi_defs.F_GETFL, 0)
  ffi.C.fcntl(fd, ffi_defs.F_SETFL, bit.bor(flags, ffi_defs.O_NONBLOCK))

  local tv = ffi.new("struct timeval")
  tv.tv_sec = timeout
  tv.tv_usec = 0
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
  ffi.C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))

  local addr = ffi.new("struct sockaddr_in")
  if not ffi_defs.IS_LINUX then
    addr.sin_len = ffi.sizeof(addr)
  end
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)

  local resolved = resolve_host(host)
  addr.sin_addr.s_addr = resolved

  if resolved == ffi.cast("in_addr_t", 0xffffffff) then
    ffi.C.close(fd)
    return 0, "invalid host"
  end

  local co, is_main = coroutine.running()
  if co and not is_main then
    local flags = ffi.C.fcntl(fd, ffi_defs.F_GETFL, 0)
    ffi.C.fcntl(fd, ffi_defs.F_SETFL, bit.bor(flags, ffi_defs.O_NONBLOCK))
    local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
    if ret ~= 0 then
      local err = get_errno()
      if err == ffi_defs.EINPROGRESS or err == ffi_defs.EAGAIN or err == ffi_defs.EWOULDBLOCK then
        coroutine.yield("write", fd)
        local opt = ffi.new("int[1]")
        local len = ffi.new("socklen_t[1]", ffi.sizeof("int"))
        ffi.C.getsockopt(fd, SOL_SOCKET, SO_ERROR, opt, len)
        if opt[0] ~= 0 then
          ffi.C.close(fd)
          return 0, "connect() async failed: " .. get_errstr(opt[0])
        end
      else
        ffi.C.close(fd)
        return 0, "connect() failed: " .. get_errstr(err)
      end
    end
    -- Success or async success: keep it non-blocking for send_all/recv_all
  else
    local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
    if ret < 0 then
      ffi.C.close(fd)
      return 0, "connect() failed: " .. get_errstr(get_errno())
    end
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
  local chunks, recv_err = recv_all(fd, buf, 65536, os.time() + timeout)
  ffi.C.close(fd)

  if recv_err then return 499, recv_err end

  local raw = table.concat(chunks)
  if raw == "" then return 0, "empty response" end

  return parse_response(raw)
end

return http
