-- ffi_defs.lua: Centralized FFI definitions for Jenova
-- All C type/function declarations live here to prevent redefinition errors.
-- FreeBSD 15 / amd64 compatible.

local ffi = require("ffi")
local jit = require("jit")

local is_linux = jit.os == "Linux"

local socket_struct_defs
if is_linux then
  socket_struct_defs = [[
  typedef unsigned int socklen_t;
  typedef unsigned short sa_family_t;
  typedef unsigned short in_port_t;

  struct in_addr {
    uint32_t s_addr;
  };

  struct sockaddr_in {
    sa_family_t sin_family;
    in_port_t sin_port;
    struct in_addr sin_addr;
    unsigned char sin_zero[8];
  };

  struct sockaddr {
    sa_family_t sa_family;
    char sa_data[14];
  };
]]
else
  socket_struct_defs = [[
  typedef unsigned int socklen_t;
  typedef uint8_t sa_family_t;
  typedef unsigned short in_port_t;

  struct in_addr {
    uint32_t s_addr;
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
]]
end

ffi.cdef(socket_struct_defs .. [[
  typedef long ssize_t;
  typedef unsigned int in_addr_t;
  typedef unsigned int tcflag_t;
  typedef unsigned char cc_t;
  typedef unsigned int speed_t;
  typedef int pid_t;

  struct addrinfo {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
    socklen_t ai_addrlen;
    struct sockaddr *ai_addr;
    char *ai_canonname;
    struct addrinfo *ai_next;
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

  /* --- Sockets / networking --- */
  int socket(int domain, int type, int protocol);
  int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int listen(int sockfd, int backlog);
  int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
  int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
  int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen);
  ssize_t send(int sockfd, const void *buf, size_t len, int flags);
  ssize_t recv(int sockfd, void *buf, size_t len, int flags);
  int getaddrinfo(const char *node, const char *service,
                  const struct addrinfo *hints, struct addrinfo **res);
  void freeaddrinfo(struct addrinfo *res);
  in_addr_t inet_addr(const char *cp);
  uint16_t htons(uint16_t hostshort);

  /* --- File / process --- */
  int close(int fd);
  int open(const char *path, int oflag, ...);
  int dup2(int oldfd, int newfd);
  int fcntl(int fd, int cmd, ...);
  int select(int nfds, void *readfds, void *writefds, void *exceptfds,
             struct timeval *timeout);
  int ioctl(int fd, unsigned long request, ...);
  int isatty(int fd);
  int chdir(const char *path);
  int pipe(int pipefd[2]);
  ssize_t read(int fd, void *buf, size_t count);
  ssize_t write(int fd, const void *buf, size_t count);

  /* --- Terminal --- */
  int tcgetattr(int fd, struct termios *termios_p);
  int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);

  /* --- Process lifecycle --- */
  pid_t fork(void);
  int setsid(void);
  int execvp(const char *file, char *const argv[]);
  void _exit(int status);
  int setpgid(pid_t pid, pid_t pgid);
  int setenv(const char *name, const char *value, int overwrite);
  pid_t waitpid(pid_t pid, int *status, int options);
  int kill(pid_t pid, int sig);

  /* --- Misc --- */
  char *strerror(int errnum);
  int gettimeofday(struct timeval *tv, struct timezone *tz);

  /* --- Signals --- */
  typedef void (*sighandler_t)(int);
  sighandler_t signal(int sig, sighandler_t handler);
]])

local ffi_defs = {}

ffi_defs.IS_LINUX = is_linux

ffi_defs.F_GETFL    = 3
ffi_defs.F_SETFL    = 4
ffi_defs.F_GETFD    = 1
ffi_defs.F_SETFD    = 2
ffi_defs.FD_CLOEXEC = 1
ffi_defs.O_RDONLY   = 0
ffi_defs.O_WRONLY   = 1
ffi_defs.O_RDWR     = 2
ffi_defs.WNOHANG    = 1

-- Platform-specific socket and errno constants are hardcoded here because
-- LuaJIT FFI cannot call cpp-style '#include <errno.h>' at runtime.
-- Values are taken directly from the FreeBSD and Linux kernel headers:
--   FreeBSD: /usr/include/sys/socket.h, /usr/include/errno.h
--   Linux:   /usr/include/asm-generic/socket.h, /usr/include/asm-generic/errno-base.h
if is_linux then
  ffi_defs.O_NONBLOCK   = 0x0800
  ffi_defs.FIONBIO      = 0x5421
  ffi_defs.O_CREAT      = 0x0040
  ffi_defs.O_APPEND     = 0x0400
  ffi_defs.O_TRUNC      = 0x0200
  ffi_defs.SOL_SOCKET   = 1
  ffi_defs.SO_REUSEADDR = 2
  ffi_defs.SO_ERROR     = 4
  ffi_defs.SO_RCVTIMEO  = 20
  ffi_defs.SO_SNDTIMEO  = 21
  ffi_defs.SO_KEEPALIVE = 9
  ffi_defs.IPPROTO_TCP  = 6
  ffi_defs.TCP_NODELAY  = 1
  ffi_defs.EAGAIN       = 11
  ffi_defs.EWOULDBLOCK  = 11
  ffi_defs.EINPROGRESS  = 115
  ffi_defs.ETIMEDOUT    = 110
  ffi_defs.EINTR        = 4
else
  ffi_defs.O_NONBLOCK   = 0x0004
  ffi_defs.FIONBIO      = 0x8004667e
  ffi_defs.O_CREAT      = 0x0200
  ffi_defs.O_APPEND     = 0x0008
  ffi_defs.O_TRUNC      = 0x0400
  ffi_defs.SOL_SOCKET   = 0xffff
  ffi_defs.SO_REUSEADDR = 0x0004
  ffi_defs.SO_ERROR     = 0x1007
  ffi_defs.SO_RCVTIMEO  = 0x1006
  ffi_defs.SO_SNDTIMEO  = 0x1005
  ffi_defs.SO_KEEPALIVE = 0x0008
  ffi_defs.IPPROTO_TCP  = 6
  ffi_defs.TCP_NODELAY  = 1
  ffi_defs.EAGAIN       = 35
  ffi_defs.EWOULDBLOCK  = 35
  ffi_defs.EINPROGRESS  = 36
  ffi_defs.ETIMEDOUT    = 60
  ffi_defs.EINTR        = 4
end

-- FreeBSD signal numbers
ffi_defs.SIGINT  = 2
ffi_defs.SIGTERM = 15
ffi_defs.SIGPIPE = 13
ffi_defs.SIG_IGN = ffi.cast("sighandler_t", 1)

-- FD_SET implementation for LuaJIT FFI
local bit = require("bit")
ffi_defs.FD_SETSIZE = 1024

function ffi_defs.FD_ZERO(set)
  ffi.fill(set, ffi.sizeof(set))
end

function ffi_defs.FD_SET(fd, set)
  if fd < 0 or fd >= ffi_defs.FD_SETSIZE then return end
  local i = bit.rshift(fd, 5)
  local b = bit.lshift(1, bit.band(fd, 31))
  set[i] = bit.bor(set[i], b)
end

function ffi_defs.FD_ISSET(fd, set)
  if fd < 0 or fd >= ffi_defs.FD_SETSIZE then return false end
  local i = bit.rshift(fd, 5)
  local b = bit.lshift(1, bit.band(fd, 31))
  return bit.band(set[i], b) ~= 0
end

function ffi_defs.fd_set_new()
  local words = math.floor((ffi_defs.FD_SETSIZE + 31) / 32)
  return ffi.new("unsigned int[?]", words)
end

function ffi_defs.wall_time()
  local tv = ffi.new("struct timeval")
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1000000
end

return ffi_defs
