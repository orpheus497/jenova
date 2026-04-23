-- tools/bash.lua — ShellTool: Execute shell commands
-- Uses jenova.process (C FFI) for proper subprocess management with
-- timeout, output capture, and exit code handling. Falls back to io.popen.

local json = require("utils.json_fallback")

local M = {}

M.name = "Shell"
M.description = "Execute a POSIX sh command on the system. Use for running scripts, installing packages, compiling code, managing files, build/test tasks, or any system operation. Always provide a description of what the command does."

M.parameters = {
    type = "object",
    properties = {
        command = {
            type = "string",
            description = "The POSIX sh command to execute. Use sh-compatible syntax only (no bashisms like arrays, [[ ]], or process substitution)."
        },
        description = {
            type = "string",
            description = "Brief description of what the command does (shown to user)"
        },
        timeout = {
            type = "integer",
            description = "Timeout in milliseconds (default: 120000)"
        },
    },
    required = { "command" }
}

function M.is_enabled() return true end

function M.is_read_only(input)
    if not input or not input.command then return false end
    local cmd = input.command:lower()

    -- A command is only considered read-only if it is a *single* command with
    -- no shell metacharacters. A previous implementation did a plain prefix
    -- match, which meant `ls; rm -rf /` was classified as read-only because
    -- it starts with `ls`. Reject anything that contains shell operators so a
    -- chained destructive command can't sneak past the read-only gate.
    if cmd:find("[;&|`$><]") or cmd:find("%$%(") or cmd:find("\n") then
        return false
    end

    local read_only_prefixes = {
        "ls", "cat", "head", "tail", "grep", "find", "which", "echo",
        "pwd", "whoami", "date", "uname", "env", "printenv", "wc",
        "file", "stat", "du", "df", "git status", "git log", "git diff",
        "git branch", "git show", "git remote", "git tag",
        "python --version", "node --version", "npm --version",
        "cargo --version", "rustc --version", "go version",
    }
    for _, prefix in ipairs(read_only_prefixes) do
        -- Require either an exact match or a word boundary after the prefix
        -- so `lsof`, `catfoo`, or `git-status` aren't misclassified as the
        -- read-only `ls`, `cat`, or `git status`.
        if cmd == prefix or cmd:sub(1, #prefix + 1) == prefix .. " " then
            return true
        end
    end
    return false
end

function M.user_facing_name(input)
    if input and input.description and #input.description > 0 then
        local short = input.description:sub(1, 50)
        if #input.description > 50 then short = short .. "..." end
        return short
    end
    if input and input.command then
        local short = input.command:sub(1, 40)
        if #input.command > 40 then short = short .. "..." end
        return "Shell: " .. short
    end
    return "Shell"
end

function M.check_permissions(input, context)
    -- Always delegate to the central permissions manager so the bash tool
    -- respects the user's current permission mode (default / plan / bypass)
    -- and any interactive approvals they've given. The previous stub always
    -- returned `allowed = true`, which completely bypassed the permission
    -- system for write operations.
    local ok_mgr, manager = pcall(require, "permissions.manager")
    if not ok_mgr or not manager or not manager.can_use_tool then
        -- If the permissions module isn't loadable, fail closed for
        -- non-read-only commands so we don't silently grant execution.
        if M.is_read_only(input) then
            return { allowed = true }
        end
        return { allowed = false, reason = "permissions manager unavailable" }
    end

    local allowed, reason = manager.can_use_tool("Shell", input, context or {})
    if allowed then
        return { allowed = true }
    end
    return { allowed = false, reason = reason or "Permission denied" }
end

function M.call(args, context)
    local command = args.command
    if not command or command == "" then
        return { type = "error", error = "No command provided" }
    end

    local timeout = args.timeout or 120000
    local cwd = context and context.cwd or nil

    local _jenova = rawget(_G, "jenova")
    if type(_jenova) == "table" and _jenova.sandbox and _jenova.sandbox.validate_command then
        if _jenova.sandbox.validate_command(command) == 0 then
            return { type = "error", error = "Command blocked by sandbox" }
        end
    end

    -- Inject "trio" environment variables
    local trio = require("utils.trio")
    local endpoints = trio.get_endpoints()
    local env = {
        { "JENOVA_ROOT", endpoints.root or "" },
        { "JENOVA_API_URL", endpoints.proxy_url },
        { "JENOVA_CONNECT_HOST", endpoints.host },
        { "JENOVA_PORT", tostring(endpoints.port) },
        { "JENOVA_LLAMA_PORT", tostring(endpoints.llama_port) },
        { "JENOVA_LLAMA_EMBED_PORT", tostring(endpoints.embed_port) },
    }

    -- Use C FFI process spawning (preferred)
    if type(_jenova) == "table" and _jenova.process and _jenova.process.spawn_json then
        local env_table = {}
        for _, pair in ipairs(env) do
            env_table[pair[1]] = pair[2]
        end
        local config = json.stringify({
            command = "sh",
            args = { "-c", command },
            cwd = cwd,
            timeout_ms = timeout,
            inherit_env = true,
            env = env_table,
        })
        local result_json = _jenova.process.spawn_json(config)
        if result_json then
            local ok, result = pcall(json.parse, result_json)
            if ok and result then
                local output = result.stdout or ""
                if result.stderr and #result.stderr > 0 then
                    if #output > 0 then
                        output = output .. "\n" .. result.stderr
                    else
                        output = result.stderr
                    end
                end
                if result.timed_out then
                    output = output .. "\n[Process timed out after " .. timeout .. "ms]"
                end
                return {
                    type = "text",
                    text = output,
                    exit_code = result.exit_code or 0,
                    timed_out = result.timed_out or false,
                    duration_ms = result.duration_ms or 0,
                }
            end
        end
    end

    -- Fallback: use io.popen (sh -c) with env prefix
    local shell = require("utils.shell")
    local env_prefix = ""
    for _, pair in ipairs(env) do
        env_prefix = env_prefix .. shell.format_env(pair[1], pair[2])
    end
    -- Always invoke via sh (POSIX portable), not the process shell
    local full_cmd = env_prefix .. "sh -c " .. shell.quote(command) .. " 2>&1"
    local handle = io.popen(full_cmd, "r")
    if not handle then
        return { type = "error", error = "Failed to execute command via sh" }
    end
    local output = handle:read("*a")
    local _, _, code = handle:close()
    return {
        type = "text",
        text = output or "",
        exit_code = code or 0,
    }
end

return M
