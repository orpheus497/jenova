-- daemon.lua: Process lifecycle management via FFI fork/exec
-- Uses centralized definitions from ffi_defs.lua.

local ffi = require("ffi")
local ffi_defs = require("ffi_defs")

local daemon = {}

function daemon.reap_children()
  local reaped = 0
  local status = ffi.new("int[1]")
  while true do
    local pid = ffi.C.waitpid(-1, status, ffi_defs.WNOHANG)
    if pid <= 0 then break end
    reaped = reaped + 1
  end
  return reaped
end

function daemon.is_alive(pid)
  if not pid or pid <= 0 then return false end
  return ffi.C.kill(pid, 0) == 0
end

function daemon.write_pidfile(path, pid)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(tostring(pid) .. "\n")
  f:close()
  os.rename(tmp, path)
  return true
end

function daemon.read_pidfile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*l")
  f:close()
  if not content then return nil end
  return tonumber(content)
end

function daemon.remove_pidfile(path)
  os.remove(path)
end

function daemon.check_pidfile(path)
  local pid = daemon.read_pidfile(path)
  if not pid then return nil end
  if daemon.is_alive(pid) then
    return pid
  end
  daemon.remove_pidfile(path)
  return nil
end

function daemon.start_background(cmd_table, log_path, working_dir, pidfile, env)
  if type(cmd_table) ~= "table" or #cmd_table == 0 then return false, "invalid command" end

  if pidfile then
    local existing = daemon.check_pidfile(pidfile)
    if existing then
      return true, existing
    end
  end

  daemon.reap_children()

  local argc = #cmd_table
  local argv_bufs = {}
  local argv = ffi.new("char *[?]", argc + 1)
  for i = 1, argc do
    argv_bufs[i] = ffi.new("char[?]", #cmd_table[i] + 1, cmd_table[i])
    argv[i-1] = argv_bufs[i]
  end
  argv[argc] = nil

  -- Create a pipe for parent/child exec handshake:
  -- child closes write end on successful execvp (FD_CLOEXEC), or writes a byte on error.
  -- parent reads: EOF = success, byte = exec failure.
  local pipefd = ffi.new("int[2]")
  if ffi.C.pipe(pipefd) ~= 0 then return false, "pipe() failed" end

  local pid = ffi.C.fork()
  if pid < 0 then
    ffi.C.close(pipefd[0])
    ffi.C.close(pipefd[1])
    return false, "fork failed"
  end

  if pid > 0 then
    ffi.C.close(pipefd[1])
    local buf = ffi.new("char[1]")
    local n = ffi.C.read(pipefd[0], buf, 1)
    ffi.C.close(pipefd[0])
    if n < 0 then
      local status_buf = ffi.new("int[1]")
      ffi.C.waitpid(pid, status_buf, ffi_defs.WNOHANG)
      return false, "pipe read failed"
    end
    if n > 0 then
      local status_buf = ffi.new("int[1]")
      ffi.C.waitpid(pid, status_buf, 0)
      return false, "child exec failed"
    end
    if pidfile then
      local ok, err = daemon.write_pidfile(pidfile, pid)
      if not ok then
        return false, err or "failed to write pidfile"
      end
    end
    return true, tonumber(pid)
  end

  -- Child: close read end, set FD_CLOEXEC on write end so execvp closes it automatically.
  ffi.C.close(pipefd[0])
  ffi.C.fcntl(pipefd[1], ffi_defs.F_SETFD, ffi_defs.FD_CLOEXEC)

  ffi.C.setpgid(0, 0)
  ffi.C.setsid()
  if working_dir and working_dir ~= "" then ffi.C.chdir(working_dir) end

  if env and type(env) == "table" then
    for k, v in pairs(env) do
      ffi.C.setenv(k, tostring(v), 1)
    end
  end

  if log_path and log_path ~= "" then
    local fd = ffi.C.open(log_path,
      ffi_defs.O_WRONLY + ffi_defs.O_CREAT + ffi_defs.O_APPEND, 438)
    if fd >= 0 then
      ffi.C.dup2(fd, 1)
      ffi.C.dup2(fd, 2)
      ffi.C.close(fd)
    end
  end

  ffi.C.execvp(argv[0], argv)
  -- execvp failed: write an error byte to the pipe so parent knows.
  local errbyte = ffi.new("char[1]", { 1 })
  ffi.C.write(pipefd[1], errbyte, 1)
  ffi.C._exit(127)
end

function daemon.stop_by_pidfile(pidfile)
  local pid = daemon.read_pidfile(pidfile)
  if not pid then return false, "no pidfile" end
  if not daemon.is_alive(pid) then
    daemon.remove_pidfile(pidfile)
    daemon.reap_children()
    return true, "already dead"
  end
  ffi.C.kill(-pid, 15)
  ffi.C.kill(pid, 15)
  for _ = 1, 20 do
    local tv = ffi.new("struct timeval", {tv_sec=0, tv_usec=100000})
    ffi.C.select(0, nil, nil, nil, tv)
    if not daemon.is_alive(pid) then
      daemon.remove_pidfile(pidfile)
      daemon.reap_children()
      return true, "stopped"
    end
  end
  ffi.C.kill(-pid, 9)
  ffi.C.kill(pid, 9)
  local tv = ffi.new("struct timeval", {tv_sec=0, tv_usec=200000})
  ffi.C.select(0, nil, nil, nil, tv)
  daemon.reap_children()
  daemon.remove_pidfile(pidfile)
  return true, "killed"
end

return daemon
