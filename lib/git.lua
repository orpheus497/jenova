local git = {}
local os = require("os")

local function run_cmd(cmd, cwd)
    local full_cmd = "cd '" .. cwd:gsub("'", "'\\''") .. "' && " .. cmd
    local f = io.popen(full_cmd .. " 2>&1")
    if not f then return false, "failed to run command" end
    local output = f:read("*a")
    local success = {f:close()}
    return success[1], output
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
    return run_cmd("git push " .. remote .. " " .. branch, workspace_path)
end

function git.pull(workspace_path, remote, branch)
    remote = remote or "origin"
    branch = branch or "main"
    return run_cmd("git pull " .. remote .. " " .. branch, workspace_path)
end

return git
