-- fs_fallback.lua — Filesystem operations with Rust FFI acceleration
-- Prefers jenova.fs (Rust FFI) when available, falls back to pure Lua.
-- All operations that touch the shell validate paths via utils.shell.quote()
-- to prevent command injection.

local M = {}

-- Detect FFI availability once at load time
local has_ffi = jenova and jenova.fs ~= nil

--- Read entire file contents
--- @param path string File path
--- @return string|nil content File contents or nil on error
--- @return string|nil error Error message
function M.read(path)
    if has_ffi and jenova.fs.read then
        local result = jenova.fs.read(path, 0, 0)
        if result then
            -- jenova.fs.read returns a JSON object with {content, total_lines, ...}.
            -- Parse it and return only the content field so callers get plain text.
            local json = require("utils.json_fallback")
            local ok, parsed = pcall(json.parse, result)
            if ok and type(parsed) == "table" then
                if parsed.error then
                    return nil, parsed.error
                end
                if parsed.content then
                    return parsed.content
                end
            end
            -- If not JSON (should not happen), return raw result
            return result
        end
        return nil, "read failed"
    end
    local f, err = io.open(path, "r")
    if not f then
        return nil, err
    end
    local content = f:read("*a")
    f:close()
    return content
end

--- Write content to a file
--- @param path string File path
--- @param content string Content to write
--- @return boolean success
--- @return string|nil error Error message
function M.write(path, content)
    if has_ffi and jenova.fs.write then
        local ok = jenova.fs.write(path, content)
        if ok then return true end
        return false, "write failed"
    end
    local f, err = io.open(path, "w")
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    return true
end

--- Append content to a file
--- @param path string File path
--- @param content string Content to append
--- @return boolean success
--- @return string|nil error Error message
function M.append(path, content)
    local f, err = io.open(path, "a")
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    return true
end

--- Check if a file exists
--- @param path string File path
--- @return boolean exists
function M.exists(path)
    if has_ffi and jenova.fs.exists then
        return jenova.fs.exists(path)
    end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

--- Create a directory (and parents)
--- @param path string Directory path
--- @return boolean success
function M.mkdir(path)
    if has_ffi and jenova.fs.mkdir then
        return jenova.fs.mkdir(path)
    end
    local shell = require("utils.shell")
    local is_windows = package.config:sub(1, 1) == "\\"
    local cmd
    if is_windows then
        cmd = string.format('if not exist %s mkdir %s', shell.quote(path), shell.quote(path))
    else
        cmd = string.format('mkdir -p %s 2>/dev/null', shell.quote(path))
    end
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

--- List files in a directory
--- @param path string Directory path
--- @return table|nil files List of filenames or nil
function M.list_dir(path)
    if has_ffi and jenova.fs.list_dir then
        local result = jenova.fs.list_dir(path)
        if result then
            local json = require("utils.json_fallback")
            local ok, entries = pcall(json.parse, result)
            if ok and type(entries) == "table" then
                return entries
            end
        end
        return nil
    end
    local shell = require("utils.shell")
    local is_windows = package.config:sub(1, 1) == "\\"
    local cmd
    if is_windows then
        cmd = string.format('dir /b %s 2>nul', shell.quote(path))
    else
        cmd = string.format('ls -1 %s 2>/dev/null', shell.quote(path))
    end
    local handle = io.popen(cmd)
    if not handle then
        return nil
    end
    local files = {}
    for line in handle:lines() do
        table.insert(files, line)
    end
    handle:close()
    return files
end

-- Alias for list_dir
M.listdir = M.list_dir

--- Get file size
--- @param path string File path
--- @return number|nil size File size in bytes or nil
function M.file_size(path)
    if has_ffi and jenova.fs.stat then
        local json = require("utils.json_fallback")
        local result = jenova.fs.stat(path)
        if result then
            local ok, stat = pcall(json.parse, result)
            if ok and type(stat) == "table" then
                return stat.size
            end
        end
        return nil
    end
    local f = io.open(path, "r")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

--- Check if path is a directory
--- @param path string Path to check
--- @return boolean is_dir
function M.is_directory(path)
    if has_ffi and jenova.fs.is_dir then
        return jenova.fs.is_dir(path)
    end
    local shell = require("utils.shell")
    local is_windows = package.config:sub(1, 1) == "\\"
    if is_windows then
        local cmd = string.format('if exist %s\\ (exit 0) else (exit 1)', shell.quote(path))
        local ok = os.execute(cmd)
        return ok == true or ok == 0
    else
        local cmd = string.format('test -d %s && echo yes || echo no', shell.quote(path))
        local handle = io.popen(cmd)
        if not handle then return false end
        local result = handle:read("*l")
        handle:close()
        return result == "yes"
    end
end

--- Remove a file or empty directory
--- @param path string Path to remove
--- @return boolean success
function M.remove(path)
    if has_ffi and jenova.fs.remove then
        return jenova.fs.remove(path)
    end
    return os.remove(path) ~= nil
end

--- Recursively remove a file or directory and all its contents
--- @param path string Path to remove
--- @return boolean success
function M.remove_recursive(path)
    if has_ffi and jenova.fs.remove_recursive then
        return jenova.fs.remove_recursive(path)
    end
    -- Pure Lua fallback: use shell command
    local shell = require("utils.shell")
    local is_windows = package.config:sub(1, 1) == "\\"
    local cmd
    if is_windows then
        cmd = string.format('rmdir /s /q %s 2>nul', shell.quote(path))
    else
        cmd = string.format('rm -rf %s 2>/dev/null', shell.quote(path))
    end
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

--- Copy a file
--- @param src string Source path
--- @param dst string Destination path
--- @return boolean success
function M.copy(src, dst)
    if has_ffi and jenova.fs.copy then
        local bytes = jenova.fs.copy(src, dst)
        return bytes ~= nil
    end
    -- Pure Lua fallback: read then write
    local content = M.read(src)
    if not content then return false end
    return M.write(dst, content)
end

--- Rename/move a file or directory
--- @param src string Source path
--- @param dst string Destination path
--- @return boolean success
function M.rename(src, dst)
    if has_ffi and jenova.fs.rename then
        return jenova.fs.rename(src, dst)
    end
    return os.rename(src, dst) ~= nil
end

return M
