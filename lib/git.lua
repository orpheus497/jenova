local git = {}
local os = require("os")

local function run_cmd(cmd, cwd)
    local full_cmd = "cd '" .. cwd:gsub("'", "'\\''") .. "' && " .. cmd .. " 2>&1"
    if _G.async_popen_read then
        local output, status = _G.async_popen_read(full_cmd)
        if not output then return false, status end
        -- Check exit code via waitpid status (success is usually 0)
        -- waitpid status is WIFEXITED && WEXITSTATUS. On POSIX, status 0 means success.
        local bit = require("bit")
        local wifexited = bit.band(status, 0x7f) == 0
        local wexitstatus = bit.rshift(bit.band(status, 0xff00), 8)
        if not wifexited or wexitstatus ~= 0 then return false, output end
        return true, output
    else
        local f = io.popen(full_cmd)
        if not f then return false, "failed to run command" end
        local output = f:read("*a")
        local success = {f:close()}
        return success[1], output
    end
end

function git.init(workspace_path)
    return run_cmd("git init && git config user.email 'jenova@local' && git config user.name 'Jenova'", workspace_path)
end

function git.status(workspace_path)
    local ok, out = run_cmd("git status --short", workspace_path)
    return ok, out
end

function git.add(workspace_path, filepath)
    return run_cmd("git add '" .. filepath:gsub("'", "'\\''") .. "'", workspace_path)
end

function git.commit(workspace_path, message)
    return run_cmd("git commit -m '" .. message:gsub("'", "'\\''") .. "'", workspace_path)
end

function git.push(workspace_path, remote, branch)
    remote = remote or "origin"
    branch = branch or "main"
    local safe_remote = remote:gsub("'", "'\\''")
    local safe_branch = branch:gsub("'", "'\\''")
    return run_cmd("git push '" .. safe_remote .. "' '" .. safe_branch .. "'", workspace_path)
end

function git.pull(workspace_path, remote, branch)
    remote = remote or "origin"
    branch = branch or "main"
    local safe_remote = remote:gsub("'", "'\\''")
    local safe_branch = branch:gsub("'", "'\\''")
    return run_cmd("git pull '" .. safe_remote .. "' '" .. safe_branch .. "'", workspace_path)
end

return git
