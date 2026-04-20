-- context/manager.lua — System and user context collection
-- Equivalent to src/context.ts

local app_state = require("state.app_state")

local Context = {}

-- ── System Context ────────────────────────────────────────────────────

function Context.get_system_context()
    local context = {
        platform = Context.get_platform(),
        os_version = Context.get_os_version(),
        working_directory = app_state.get_cwd(),
        date = os.date("%Y-%m-%d"),
        time = os.date("%H:%M:%S"),
        is_git_repo = Context.is_git_repository(),
    }

    -- Add git info if in a repo
    if context.is_git_repo then
        context.git_branch = Context.get_git_branch()
        context.git_status = Context.get_git_status()
    end

    return context
end

-- ── Platform Detection ────────────────────────────────────────────────

function Context.get_platform()
    local handle = io.popen("uname -s 2>/dev/null")
    if handle then
        local result = handle:read("*a"):gsub("%s+$", "")
        handle:close()

        if result == "Darwin" then
            return "macos"
        elseif result == "Linux" then
            return "linux"
        elseif result:find("BSD") then
            return "freebsd"
        end
    end

    return "unix"
end

function Context.get_os_version()
    local platform = Context.get_platform()

    if platform == "linux" or platform == "freebsd" then
        local handle = io.popen("uname -r 2>/dev/null")
        if handle then
            local version = handle:read("*a"):gsub("%s+$", "")
            handle:close()
            return (platform == "freebsd" and "FreeBSD " or "Linux ") .. version
        end
    elseif platform == "macos" then
        local handle = io.popen("sw_vers -productVersion 2>/dev/null")
        if handle then
            local version = handle:read("*a"):gsub("%s+$", "")
            handle:close()
            return "macOS " .. version
        end
    end

    return "Unknown"
end

-- ── Git Context ───────────────────────────────────────────────────────

function Context.is_git_repository()
    local handle = io.popen("git rev-parse --is-inside-work-tree " .. "2>/dev/null")
    if not handle then
        return false
    end

    local result = handle:read("*a"):gsub("%s+$", "")
    handle:close()

    return result == "true"
end

function Context.get_git_branch()
    local handle = io.popen("git branch --show-current " .. "2>/dev/null")
    if not handle then
        return nil
    end

    local branch = handle:read("*a"):gsub("%s+$", "")
    handle:close()

    return #branch > 0 and branch or nil
end

function Context.get_git_status()
    local handle = io.popen("git status --short " .. "2>/dev/null")
    if not handle then
        return nil
    end

    local status = handle:read("*a"):gsub("%s+$", "")
    handle:close()

    if #status == 0 then
        return "(clean)"
    else
        local lines = {}
        for line in status:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end
        return table.concat(lines, "\n")
    end
end

-- ── User Context ──────────────────────────────────────────────────────

function Context.get_user_context()
    local context = {
        username = os.getenv("USER") or os.getenv("USERNAME") or "unknown",
        home_directory = os.getenv("HOME") or "~",
        shell = os.getenv("SHELL") or "unknown",
        terminal = os.getenv("TERM") or "unknown",
        editor = os.getenv("EDITOR") or "unknown",
    }

    return context
end

-- ── Build Context String ──────────────────────────────────────────────

function Context.build_context_string()
    local sys_ctx = Context.get_system_context()
    local user_ctx = Context.get_user_context()

    local parts = {
        string.format("Platform: %s", sys_ctx.platform),
        string.format("OS Version: %s", sys_ctx.os_version),
        string.format("Working directory: %s", sys_ctx.working_directory),
        string.format("Date: %s", sys_ctx.date),
        string.format("Shell: %s", user_ctx.shell),
    }

    if sys_ctx.is_git_repo then
        table.insert(parts, string.format("Git branch: %s", sys_ctx.git_branch or "unknown"))
        table.insert(parts, string.format("Git status: %s", sys_ctx.git_status or "unknown"))
    end

    return table.concat(parts, "\n")
end

return Context
