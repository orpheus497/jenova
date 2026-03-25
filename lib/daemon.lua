local ffi = require("ffi")

ffi.cdef[[
  typedef int pid_t;
  pid_t fork(void);
  int setsid(void);
  int execvp(const char *file, char *const argv[]);
  void _exit(int status);
  int dup2(int oldfd, int newfd);
  int open(const char *path, int oflag, ...);
  int close(int fd);
  int chdir(const char *path);

  /* flags */
  static const int O_RDONLY = 0;
  static const int O_WRONLY = 1;
  static const int O_RDWR   = 2;
  static const int O_CREAT  = 0x0200;
  static const int O_APPEND = 0x0008;
]]

local daemon = {}

-- Start a command in background. cmd_table is an array-like Lua table of argv (first is program).
-- log_path optional; if provided, stdout/stderr are redirected to that file (created/appended).
function daemon.start_background(cmd_table, log_path, working_dir)
  if type(cmd_table) ~= "table" or #cmd_table == 0 then return false, "invalid command" end

  local argc = #cmd_table
  local argv = ffi.new("char *[?]", argc + 1)
  for i = 1, argc do
    argv[i-1] = ffi.cast("char *", ffi.new("char[?]", #cmd_table[i] + 1, cmd_table[i]))
  end
  argv[argc] = nil

  local pid = ffi.C.fork()
  if pid < 0 then return false, "fork failed" end
  if pid > 0 then
    -- parent
    return true, tonumber(pid)
  end

  -- child
  ffi.C.setsid()
  if working_dir and working_dir ~= "" then ffi.C.chdir(working_dir) end

  if log_path and log_path ~= "" then
    local fd = ffi.C.open(log_path, ffi.C.O_WRONLY + ffi.C.O_CREAT + ffi.C.O_APPEND, 438) -- 0666
    if fd >= 0 then
      ffi.C.dup2(fd, 1) -- stdout
      ffi.C.dup2(fd, 2) -- stderr
      ffi.C.close(fd)
    end
  end

  -- execute
  ffi.C.execvp(argv[0], argv)
  ffi.C._exit(127)
end

return daemon
