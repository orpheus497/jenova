#!/usr/bin/env luajit
-- Regression test for the FFI variadic-argument ABI bug.
--
-- lib/ffi_defs.lua once declared fcntl/open with a variadic third argument.
-- LuaJIT promotes a Lua number in a variadic slot to a double (SSE register);
-- the kernel reads the integer register and silently discards the argument.
-- The result was that set_nonblocking() and set_cloexec() did nothing at all,
-- leaving every socket in the proxy blocking and every fd inheritable.
--
-- This test would have caught that in five lines. Keep it.

local root = os.getenv("JENOVA_ROOT") or "."
package.path = root .. "/lib/?.lua;" .. package.path

local ffi = require("ffi")
local bit = require("bit")
local d   = require("ffi_defs")

local failures = 0
local function check(name, ok)
  print((ok and "  ok   " or "  FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local fd = ffi.C.socket(2, 1, 0)   -- AF_INET, SOCK_STREAM
assert(fd >= 0, "socket() failed")

-- set_nonblocking(), as lib/proxy.lua implements it
local fl = ffi.C.fcntl(fd, d.F_GETFL, 0)
ffi.C.fcntl(fd, d.F_SETFL, bit.bor(fl < 0 and 0 or fl, d.O_NONBLOCK))
check("O_NONBLOCK is actually set on the socket",
      bit.band(ffi.C.fcntl(fd, d.F_GETFL, 0), d.O_NONBLOCK) ~= 0)

-- set_cloexec(), as lib/proxy.lua implements it
local fg = ffi.C.fcntl(fd, d.F_GETFD, 0)
ffi.C.fcntl(fd, d.F_SETFD, bit.bor(fg < 0 and 0 or fg, d.FD_CLOEXEC))
check("FD_CLOEXEC is actually set on the socket",
      bit.band(ffi.C.fcntl(fd, d.F_GETFD, 0), d.FD_CLOEXEC) ~= 0)
ffi.C.close(fd)

-- open() mode argument, as lib/daemon.lua passes it for daemon log files
local path = os.getenv("TMPDIR") or "/tmp"
path = path .. "/jenova_ffi_mode_test." .. tostring(os.time())
os.remove(path)
local lfd = ffi.C.open(path, d.O_WRONLY + d.O_CREAT + d.O_APPEND, 420)  -- 0644
if lfd >= 0 then ffi.C.close(lfd) end
local h = io.popen("ls -l '" .. path .. "' 2>/dev/null")
local line = h and h:read("*l") or ""
if h then h:close() end
os.remove(path)
check("open() honours its mode argument (not 0000): " .. (line:match("^(%S+)") or "?"),
      line:match("^%-rw") ~= nil)

-- fd_set: lib/proxy.lua once called ffi.new("fd_set"), a ctype that is never
-- cdef'd anywhere, so async_popen_read threw on every single call.
check("ffi_defs.fd_set_new() allocates an fd_set", (function()
  local ok = pcall(function()
    local s = d.fd_set_new(); d.FD_ZERO(s); d.FD_SET(3, s); return d.FD_ISSET(3, s)
  end)
  return ok
end)())
check('ffi.new("fd_set") is still NOT a valid ctype (use fd_set_new)',
      not pcall(function() return ffi.new("fd_set") end))

os.exit(failures == 0 and 0 or 1)
