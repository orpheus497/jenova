-- context/manager.lua — System and user context collection
-- Equivalent to src/context.ts

local app_state = require("state.app_state")
local paths = require("utils.paths")

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

-- ── Toolchain Detection ───────────────────────────────────────────────

-- Probe which compilers and common build tools are available on PATH.
-- Returns a string like "cc, clang, make, cmake" or nil if nothing found.
function Context.get_toolchain()
    local candidates = {
        -- C/C++ compilers (order matters: prefer cc first as the POSIX alias)
        "cc", "gcc", "clang", "g++", "clang++", "c99", "c11",
        -- Build systems
        "make", "gmake", "cmake", "ninja", "meson",
        -- Other langs common in coding tasks
        "python3", "python", "node", "npm", "cargo", "rustc", "go",
        "java", "javac", "mvn", "gradle",
        -- Utils
        "git", "pkg-config",
    }
    local found = {}
    for _, tool in ipairs(candidates) do
        local h = io.popen("command -v " .. tool .. " 2>/dev/null")
        if h then
            local out = h:read("*l")
            h:close()
            if out and #out > 0 then
                found[#found + 1] = tool
            end
        end
    end
    return #found > 0 and table.concat(found, ", ") or nil
end



-- Scans the working directory (recursively, up to max_files entries) and
-- returns a compact tree string for injection into the system prompt.
-- Uses `find` as a portable fallback when jenova.fs is unavailable.
function Context.get_directory_snapshot(cwd, max_files)
    cwd = cwd or app_state.get_cwd()
    max_files = max_files or 300

    local files = {}

    -- Prefer Rust FFI glob (fastest, respects gitignore via rg internally)
    if jenova and jenova.fs and jenova.fs.glob then
        local json = require("utils.json_fallback")
        local raw = jenova.fs.glob("**/*", cwd, max_files)
        if raw then
            local ok, result = pcall(json.parse, raw)
            if ok and type(result) == "table" then
                for _, f in ipairs(result) do
                    -- Strip leading cwd prefix for readability
                    local rel = tostring(f):gsub("^" .. cwd:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "/?", "")
                    if #rel > 0 and not paths.is_restricted(rel) then
                        table.insert(files, rel)
                    end
                end
            end
        end
    end

    -- Fallback: use find
    if #files == 0 then
        local shell = require("utils.shell")
        local cmd = string.format(
            "find %s -not -path '*/.git/*' -not -name '.git' -not -path '*/.jenova/*' -not -path '*/.claude/*' -maxdepth 6 2>/dev/null | head -n %d",
            shell.quote(cwd), max_files
        )
        local handle = io.popen(cmd)
        if handle then
            for line in handle:lines() do
                local rel = line:gsub("^" .. cwd:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "/?", "")
                if #rel > 0 and rel ~= "." then
                    table.insert(files, rel)
                end
            end
            handle:close()
        end
    end

    if #files == 0 then return nil end

    table.sort(files)
    return table.concat(files, "\n")
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

    local snapshot = Context.get_directory_snapshot(sys_ctx.working_directory)
    if snapshot then
        table.insert(parts, "\nDirectory contents:\n" .. snapshot)
    end

    return table.concat(parts, "\n")
end

return Context
