-- hooks/manager.lua — Hook system for lifecycle and tool events
--
-- Hooks allow users to register shell commands or Lua callbacks that fire
-- in response to CLI events: session start, tool calls, permission checks,
-- conversation turns, etc.
--
-- Hook definitions live in the user's settings.json under "hooks":
--   {
--     "hooks": {
--       "PreToolUse": [
--         { "matcher": "Bash", "command": "echo 'about to run bash'" }
--       ],
--       "PostToolUse": [
--         { "matcher": "*", "command": "echo 'tool finished'" }
--       ],
--       "SessionStart": [
--         { "command": "echo 'session started'" }
--       ]
--     }
--   }

local config = require("config.loader")
local json = require("utils.json_fallback")

local M = {}

-- Known hook points
M.HOOK_POINTS = {
    "SessionStart",     -- Fires when a new session begins
    "SessionEnd",       -- Fires when a session ends
    "PreToolUse",       -- Before a tool is called (can block)
    "PostToolUse",      -- After a tool completes
    "PrePromptSubmit",  -- Before user prompt is sent to LLM
    "PostResponse",     -- After LLM response is received
    "Notification",     -- When a notification is generated
    "Stop",             -- When generation is stopped
}

-- In-memory Lua callback registry (for programmatic hooks)
local lua_hooks = {}

-- ── Registration ─────────────────────────────────────────────────────────

--- Register a Lua callback hook.
--- @param hook_point string  One of M.HOOK_POINTS
--- @param callback function  fn(context) → { allow = bool, message = string? }
--- @param options table?     { matcher = string?, priority = number? }
function M.register(hook_point, callback, options)
    options = options or {}
    if not lua_hooks[hook_point] then
        lua_hooks[hook_point] = {}
    end
    table.insert(lua_hooks[hook_point], {
        callback = callback,
        matcher = options.matcher,
        priority = options.priority or 0,
    })
    -- Sort by priority (higher first)
    table.sort(lua_hooks[hook_point], function(a, b)
        return a.priority > b.priority
    end)
end

--- Unregister all Lua hooks for a given hook point.
function M.clear(hook_point)
    if hook_point then
        lua_hooks[hook_point] = nil
    else
        lua_hooks = {}
    end
end

-- ── Execution ────────────────────────────────────────────────────────────

--- Run all hooks for a given hook point.
--- Returns { blocked = bool, message = string? } if any hook blocks.
--- For non-blocking hooks, returns { blocked = false }.
function M.run(hook_point, context)
    context = context or {}

    -- 1. Run config-defined shell hooks
    local shell_result = M._run_shell_hooks(hook_point, context)
    if shell_result and shell_result.blocked then
        return shell_result
    end

    -- 2. Run Lua callback hooks
    local lua_result = M._run_lua_hooks(hook_point, context)
    if lua_result and lua_result.blocked then
        return lua_result
    end

    return { blocked = false }
end

--- Convenience: run PreToolUse hooks and check if tool is allowed.
function M.check_tool_permission(tool_name, args)
    local result = M.run("PreToolUse", {
        tool_name = tool_name,
        args = args,
    })
    if result.blocked then
        return false, result.message or "Blocked by hook"
    end
    return true
end

--- Convenience: run PostToolUse hooks after tool execution.
function M.notify_tool_complete(tool_name, args, result)
    M.run("PostToolUse", {
        tool_name = tool_name,
        args = args,
        result = result,
    })
end

-- ── Shell hook execution ─────────────────────────────────────────────────

function M._run_shell_hooks(hook_point, context)
    local hooks_config = config.get("hooks")
    if not hooks_config or type(hooks_config) ~= "table" then
        return nil
    end

    local hooks = hooks_config[hook_point]
    if not hooks or type(hooks) ~= "table" then
        return nil
    end

    for _, hook in ipairs(hooks) do
        -- Check matcher
        if M._matches(hook.matcher, context) then
            local command = hook.command
            if command and #command > 0 then
                -- Build the command line with inline `VAR='val' command` prefix.
                local full_cmd = M._build_full_cmd(hook_point, context, command)

                local handle = io.popen(full_cmd)
                if handle then
                    local output = handle:read("*a")
                    local _, exit_type, exit_code = handle:close()

                    -- Non-zero exit from PreToolUse blocks the tool.
                    -- handle:close() returns true on success; on failure it
                    -- returns nil, "exit", <status> or nil, "signal", <signum>.
                    local failed = exit_type == "exit" and (exit_code or 0) ~= 0
                    if failed and hook_point == "PreToolUse" then
                        return {
                            blocked = true,
                            message = output and output:gsub("%s+$", "") or "Blocked by hook",
                        }
                    end
                end
            end
        end
    end

    return nil
end

-- ── Lua hook execution ───────────────────────────────────────────────────

function M._run_lua_hooks(hook_point, context)
    local hooks = lua_hooks[hook_point]
    if not hooks then
        return nil
    end

    for _, hook in ipairs(hooks) do
        if M._matches(hook.matcher, context) then
            local ok, result = pcall(hook.callback, context)
            if ok and type(result) == "table" and result.blocked then
                return result
            end
            if not ok then
                io.stderr:write(string.format("Hook error (%s): %s\n", hook_point, tostring(result)))
            end
        end
    end

    return nil
end

-- ── Matcher ──────────────────────────────────────────────────────────────

function M._matches(matcher, context)
    if not matcher or matcher == "*" then
        return true
    end

    -- Match against tool_name if present
    if context.tool_name then
        if matcher == context.tool_name then
            return true
        end
        -- Simple glob: "Bash*" matches "Bash", "BashTool", etc.
        if matcher:match("%*$") then
            local prefix = matcher:sub(1, -2)
            if context.tool_name:sub(1, #prefix) == prefix then
                return true
            end
        end
    end

    return false
end

-- ── Environment helpers ──────────────────────────────────────────────────

local shell = require("utils.shell")

-- Build the full command string including environment variables using
-- inline `VAR='val' command` prefix syntax.
function M._build_full_cmd(hook_point, context, command)
    local env = {
        { "JENOVA_HOOK", hook_point }
    }

    if context.tool_name then
        table.insert(env, { "JENOVA_TOOL_NAME", context.tool_name })
    end

    if context.args then
        local ok, args_json = pcall(json.stringify, context.args)
        if ok then
            table.insert(env, { "JENOVA_TOOL_INPUT", args_json })
        end
    end

    local env_prefix = ""
    for _, pair in ipairs(env) do
        env_prefix = env_prefix .. shell.format_env(pair[1], pair[2])
    end

    return env_prefix .. command .. " 2>&1"
end

-- Kept for backwards compatibility with any callers that still expected a
-- pure env-prefix string.
function M._build_env_prefix(hook_point, context)
    local env = {
        { "JENOVA_HOOK", hook_point }
    }
    if context.tool_name then
        table.insert(env, { "JENOVA_TOOL_NAME", context.tool_name })
    end
    if context.args then
        local ok, args_json = pcall(json.stringify, context.args)
        if ok then
            table.insert(env, { "JENOVA_TOOL_INPUT", args_json })
        end
    end
    
    local env_prefix = ""
    for _, pair in ipairs(env) do
        env_prefix = env_prefix .. shell.format_env(pair[1], pair[2])
    end
    return env_prefix
end

-- ── List configured hooks ────────────────────────────────────────────────

function M.list()
    local result = {}

    -- Shell hooks from config
    local hooks_config = config.get("hooks")
    if hooks_config and type(hooks_config) == "table" then
        for point, hooks in pairs(hooks_config) do
            for _, hook in ipairs(hooks) do
                table.insert(result, {
                    type = "shell",
                    hook_point = point,
                    matcher = hook.matcher or "*",
                    command = hook.command or "",
                })
            end
        end
    end

    -- Lua hooks
    for point, hooks in pairs(lua_hooks) do
        for _, hook in ipairs(hooks) do
            table.insert(result, {
                type = "lua",
                hook_point = point,
                matcher = hook.matcher or "*",
                priority = hook.priority,
            })
        end
    end

    return result
end

--- Reload all Lua hooks by clearing the registry.
--- Shell hooks are read from config on every run, so no reload needed for them.
function M.reload()
    for point, _ in pairs(lua_hooks) do
        lua_hooks[point] = {}
    end
    return true
end

return M
