-- ffi_defs.lua: Centralized FFI definitions for jenova-agent
-- Prevents redefinition errors across modules and provides common utilities.

local ffi = require("ffi")

-- Define all common structures and functions used by http.lua, ui.lua, and agent.lua
-- FreeBSD-compatible definitions.
ffi.cdef[[
  typedef long ssize_t;
  typedef unsigned int socklen_t;
  typedef uint8_t sa_family_t;
  typedef unsigned short in_port_t;
  typedef unsigned int in_addr_t;
  typedef unsigned short tcflag_t;
  typedef unsigned char cc_t;
  typedef unsigned int speed_t;

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

  struct timezone {
    int tz_minuteswest;
    int tz_dsttime;
  };

  struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;
    cc_t     c_cc[20];
    speed_t  c_ispeed;
    speed_t  c_ospeed;
  };

  int socket(int domain, int type, int protocol);
  int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int listen(int sockfd, int backlog);
  int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
  int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
  ssize_t send(int sockfd, const void *buf, size_t len, int flags);
  ssize_t recv(int sockfd, void *buf, size_t len, int flags);
  int close(int fd);
  int fcntl(int fd, int cmd, ...);
  int select(int nfds, void *readfds, void *writefds, void *exceptfds, struct timeval *timeout);
  in_addr_t inet_addr(const char *cp);
  uint16_t htons(uint16_t hostshort);
  char *strerror(int errnum);
  int ioctl(int fd, unsigned long request, ...);
  int tcgetattr(int fd, struct termios *termios_p);
  int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
  int isatty(int fd);
  int gettimeofday(struct timeval *tv, struct timezone *tz);
]]

local ffi_defs = {}

-- FreeBSD constants (from fcntl.h and sys/ioctl.h)
ffi_defs.F_SETFL = 4
ffi_defs.O_NONBLOCK = 0x0004
ffi_defs.FIONBIO = 0x8004667e

-- FD_SET implementation for LuaJIT FFI
local bit = require("bit")
function ffi_defs.FD_ZERO(set)
  ffi.fill(set, ffi.sizeof(set))
end

function ffi_defs.FD_SET(fd, set)
  local i = bit.rshift(fd, 5)
  local b = bit.lshift(1, bit.band(fd, 31))
  set[i] = bit.bor(set[i], b)
end

function ffi_defs.FD_ISSET(fd, set)
  local i = bit.rshift(fd, 5)
  local b = bit.lshift(1, bit.band(fd, 31))
  return bit.band(set[i], b) ~= 0
end

-- Returns wall clock time in seconds with microsecond precision
function ffi_defs.wall_time()
  local tv = ffi.new("struct timeval")
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1000000
end

return ffi_defs
