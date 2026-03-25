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
  int setpgid(pid_t pid, pid_t pgid);
  pid_t waitpid(pid_t pid, int *status, int options);
  int kill(pid_t pid, int sig);

  /* flags */
  static const int O_RDONLY = 0;
  static const int O_WRONLY = 1;
  static const int O_RDWR   = 2;
  static const int O_CREAT  = 0x0200;
  static const int O_APPEND = 0x0008;
  static const int O_TRUNC  = 0x0400;

  /* waitpid options */
  static const int WNOHANG = 1;
]]

local daemon = {}

-- Reap any zombie children (call periodically or after SIGCHLD)
function daemon.reap_children()
  local reaped = 0
  local status = ffi.new("int[1]")
  while true do
    local pid = ffi.C.waitpid(-1, status, ffi.C.WNOHANG)
    if pid <= 0 then break end
    reaped = reaped + 1
  end
  return reaped
end

-- Check if a PID is alive
function daemon.is_alive(pid)
  if not pid or pid <= 0 then return false end
  return ffi.C.kill(pid, 0) == 0
end

-- Write a PID file atomically
function daemon.write_pidfile(path, pid)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(tostring(pid) .. "\n")
  f:close()
  return true
end

-- Read a PID file, return pid or nil
function daemon.read_pidfile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*l")
  f:close()
  if not content then return nil end
  return tonumber(content)
end

-- Remove a PID file
function daemon.remove_pidfile(path)
  os.remove(path)
end

-- Check if a process from a PID file is still running.
-- Returns pid if alive, nil otherwise. Cleans stale pidfile.
function daemon.check_pidfile(path)
  local pid = daemon.read_pidfile(path)
  if not pid then return nil end
  if daemon.is_alive(pid) then
    return pid
  end
  daemon.remove_pidfile(path)
  return nil
end

-- Start a command in background. cmd_table is an array-like Lua table of argv (first is program).
-- log_path optional; if provided, stdout/stderr are redirected to that file (created/appended).
-- pidfile optional; if provided, child PID is written to this file for lifecycle tracking.
function daemon.start_background(cmd_table, log_path, working_dir, pidfile)
  if type(cmd_table) ~= "table" or #cmd_table == 0 then return false, "invalid command" end

  -- If pidfile provided, check if already running
  if pidfile then
    local existing = daemon.check_pidfile(pidfile)
    if existing then
      return true, existing
    end
  end

  -- Reap any pending zombies before forking
  daemon.reap_children()

  local argc = #cmd_table
  local argv = ffi.new("char *[?]", argc + 1)
  for i = 1, argc do
    argv[i-1] = ffi.cast("char *", ffi.new("char[?]", #cmd_table[i] + 1, cmd_table[i]))
  end
  argv[argc] = nil

  local pid = ffi.C.fork()
  if pid < 0 then return false, "fork failed" end
  if pid > 0 then
    -- parent: write pidfile and reap zombies
    if pidfile then
      daemon.write_pidfile(pidfile, pid)
    end
    return true, tonumber(pid)
  end

  -- child: new process group for clean shutdown
  ffi.C.setpgid(0, 0)
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

-- Stop a daemon by pidfile. Sends SIGTERM, waits briefly, then SIGKILL if needed.
function daemon.stop_by_pidfile(pidfile)
  local pid = daemon.read_pidfile(pidfile)
  if not pid then return false, "no pidfile" end
  if not daemon.is_alive(pid) then
    daemon.remove_pidfile(pidfile)
    return true, "already dead"
  end
  ffi.C.kill(-pid, 15) -- SIGTERM process group
  ffi.C.kill(pid, 15) -- SIGTERM process itself
  for _ = 1, 10 do
    local tv = ffi.new("struct timeval", {tv_sec=0, tv_usec=100000})
    ffi.C.select(0, nil, nil, nil, tv)
    if not daemon.is_alive(pid) then
      daemon.remove_pidfile(pidfile)
      return true, "stopped"
    end
  end
  ffi.C.kill(pid, 9) -- SIGKILL
  daemon.remove_pidfile(pidfile)
  return true, "killed"
end

return daemon
