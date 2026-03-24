-- http.lua: Minimal HTTP client using LuaJIT FFI (no external dependencies)
-- Only implements POST with JSON body, which is all coder-agent needs.

local ffi = require("ffi")

ffi.cdef[[
  typedef int ssize_t;
  typedef unsigned int socklen_t;
  typedef uint8_t sa_family_t;
  typedef unsigned short in_port_t;
  typedef unsigned int in_addr_t;

  struct in_addr {
    in_addr_t s_addr;
  };

  struct sockaddr_in {
    uint8_t sin_len;
    sa_family_t sin_family;
    in_port_t sin_port;
    struct in_addr sin_addr;
    char sin_zero[8];
  };

  struct sockaddr {
    uint8_t sa_len;
    sa_family_t sa_family;
    char sa_data[14];
  };

  struct timeval {
    long tv_sec;
    long tv_usec;
  };

  int socket(int domain, int type, int protocol);
  int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  ssize_t send(int sockfd, const void *buf, size_t len, int flags);
  ssize_t recv(int sockfd, void *buf, size_t len, int flags);
  int close(int fd);
  int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
  in_addr_t inet_addr(const char *cp);
  uint16_t htons(uint16_t hostshort);
  char *strerror(int errnum);
]]

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 0xffff
local SO_RCVTIMEO = 0x1006
local SO_SNDTIMEO = 0x1005

-- Platform-specific errnos (FreeBSD defaults, but we'll use ffi.errno where possible)
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

function http.post(url, body, timeout)
  timeout = timeout or 600
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
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)
  addr.sin_addr.s_addr = ffi.C.inet_addr(host)

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

  local sent = 0
  while sent < #req do
    local n = ffi.C.send(fd, req:sub(sent + 1), #req - sent, 0)
    if n <= 0 then
      ffi.C.close(fd)
      return 0, "send() failed"
    end
    sent = sent + tonumber(n)
  end

  local buf = ffi.new("char[65536]")
  local chunks = {}
  local total_recv = 0
  local stall_count = 0
  local recv_err = nil
  while true do
    ::retry_post::
    local n = ffi.C.recv(fd, buf, 65536, 0)
    if n > 0 then
      chunks[#chunks + 1] = ffi.string(buf, n)
      total_recv = total_recv + tonumber(n)
      stall_count = 0
    elseif n == 0 then
      break
    else
      local err = get_errno()
      if err == EINTR then
        goto retry_post
      elseif err == EAGAIN or err == EWOULDBLOCK or err == ETIMEDOUT then
        stall_count = stall_count + 1
        if stall_count >= 3 or (stall_count >= 2 and total_recv > 0) then
          break
        end
        os.execute("sleep 0.1")
      else
        -- Fatal error (e.g., ECONNRESET)
        recv_err = "recv() fatal error: " .. get_errstr(err) .. " (errno=" .. tostring(err) .. ")"
        break
      end
    end
  end
  ffi.C.close(fd)

  if recv_err then return 499, recv_err end

  local raw = table.concat(chunks)
  if raw == "" then return 0, "empty response (received 0 bytes after send)" end

  local status_code = tonumber(raw:match("HTTP/%d%.%d%s+(%d+)")) or 0
  local header_end = raw:find("\r\n\r\n")
  local resp_body = ""
  if header_end then
    local headers = raw:sub(1, header_end + 1)
    local after_headers = raw:sub(header_end + 4)
    if headers:lower():find("transfer%-encoding:%s*chunked") then
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
      resp_body = table.concat(decoded)
    else
      resp_body = after_headers
    end
  end

  return status_code, resp_body
end

function http.get(url, timeout)
  timeout = timeout or 5
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
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)
  addr.sin_addr.s_addr = ffi.C.inet_addr(host)

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

  local n = ffi.C.send(fd, req, #req, 0)
  if n <= 0 then
    ffi.C.close(fd)
    return 0, "send() failed"
  end

  local buf = ffi.new("char[8192]")
  local chunks = {}
  local total_recv = 0
  local stall_count = 0
  local recv_err = nil
  while true do
    ::retry_get::
    local n = ffi.C.recv(fd, buf, 8192, 0)
    if n > 0 then
      chunks[#chunks + 1] = ffi.string(buf, n)
      total_recv = total_recv + tonumber(n)
      stall_count = 0
    elseif n == 0 then
      break
    else
      local err = get_errno()
      if err == EINTR then
        goto retry_get
      elseif err == EAGAIN or err == EWOULDBLOCK or err == ETIMEDOUT then
        stall_count = stall_count + 1
        if stall_count >= 3 or (stall_count >= 2 and total_recv > 0) then
          break
        end
        os.execute("sleep 0.1")
      else
        recv_err = "recv() fatal error: " .. get_errstr(err) .. " (errno=" .. tostring(err) .. ")"
        break
      end
    end
  end
  ffi.C.close(fd)

  if recv_err then return 499, recv_err end

  local raw = table.concat(chunks)
  if raw == "" then return 0, "empty response" end
  local status_code = tonumber(raw:match("HTTP/%d%.%d%s+(%d+)")) or 0
  local header_end = raw:find("\r\n\r\n")
  local resp_body = header_end and raw:sub(header_end + 4) or ""

  return status_code, resp_body
end

return http
