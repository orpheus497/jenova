local root = "/home/orpheus497/Documents/Projects/jenova"
package.path = package.path .. ";" .. root .. "/lib/?.lua"

function sys_exec_sync(cmd)
    return os.execute(cmd)
end

function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local tmp_file = (os.getenv("JENOVA_STATE") or (root .. "/.system")) .. "/status.out"
local cmd = shell_quote(root .. "/bin/jenova-ca") .. " status > " .. shell_quote(tmp_file) .. " 2>&1"
print("Command: " .. cmd)
sys_exec_sync(cmd)
local f = io.open(tmp_file, "r")
if f then
    print("Output: " .. f:read("*a"))
    f:close()
end
