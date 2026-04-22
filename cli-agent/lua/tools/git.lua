-- tools/git.lua — GitTool: Git repository inspection (read-only)
-- Exposes a safe subset of git subcommands for repo inspection.
-- Security: all user arguments are passed via shell.quote(); destructive
-- options and shell metacharacters are rejected before execution.

local paths = require("utils.paths")
local shell = require("utils.shell")

local M = {}
M.name = "Git"
M.description = "Run read-only git commands to inspect the repository: diff, log, show, status, blame, branch, remote, ls-files. Use this to understand recent changes before editing files. Only works inside a git repository."

M.parameters = {
    type = "object",
    properties = {
        subcommand = {
            type = "string",
            description = "git subcommand — one of: diff, log, show, status, blame, branch, remote, ls-files, rev-parse, shortlog, describe",
        },
        args = {
            type = "string",
            description = "Extra arguments passed to git (e.g. '--stat HEAD~3', 'HEAD -- src/foo.c'). Shell metacharacters are rejected.",
        },
        path = {
            type = "string",
            description = "Working directory for the git command (default: session cwd)",
        },
    },
    required = { "subcommand" }
}

-- Strictly whitelisted subcommands that are purely read-only.
-- `stash` is intentionally excluded — stash push/pop mutates the working tree.
local ALLOWED_SUBS = {
    diff          = true,
    log           = true,
    show          = true,
    status        = true,
    blame         = true,
    branch        = true,
    remote        = true,
    ["rev-parse"] = true,
    ["ls-files"]  = true,
    ["shortlog"]  = true,
    ["describe"]  = true,
}

-- Destructive flags that must never appear even in whitelisted subcommands.
-- Also blocks git-dir/work-tree/config-env redirection that could escape cwd
-- confinement, and ext-diff/textconv that might invoke external programs.
local BLOCKED_FLAGS = {
    "--force", "-f", "--hard", "--mirror", "--delete", "-D",
    "--push", "--set-upstream", "-u",
    "--git-dir", "--work-tree", "-c", "--config-env",
    "--ext-diff", "--textconv",
}

-- Characters that could break shell quoting or inject commands.
-- Restricted to true command separators/redirects only; braces and parens are
-- valid in git revspecs like HEAD@{1} or main^{} so they must not be blocked.
local SHELL_META = "[;&|`$<>\n\r]"

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    if input and input.subcommand then
        local a = input.args and (" " .. input.args:sub(1, 40)) or ""
        return "Git: " .. input.subcommand .. a
    end
    return "Git"
end

function M.check_permissions(input, ctx)
    local ok_mgr, manager = pcall(require, "permissions.manager")
    if not ok_mgr or not manager or not manager.can_use_tool then
        return { allowed = true }
    end
    local allowed, reason = manager.can_use_tool("Git", input, ctx or {})
    return { allowed = allowed, reason = reason }
end

function M.call(args, context)
    local sub = args.subcommand
    if not sub or sub == "" then
        return { type = "error", error = "subcommand is required (e.g. 'diff', 'log', 'status')" }
    end

    -- Strip accidental "git " prefix
    sub = sub:match("^git%s+(.+)$") or sub
    -- Trim whitespace
    sub = sub:match("^%s*(.-)%s*$")

    -- Reject subcommands that contain embedded whitespace.  Flags and options
    -- must go in `args`, not in `subcommand`.  A value like "log -n 5" passed
    -- as the subcommand would be quoted as a single token and cause git to fail.
    if sub:find("%s") then
        return { type = "error", error =
            "subcommand must be a single word (e.g. 'log'). Put flags in the args field." }
    end

    local base_sub = sub
    if not ALLOWED_SUBS[base_sub] then
        return { type = "error", error = string.format(
            "'%s' is not a permitted subcommand. Allowed: diff, log, show, status, blame, branch, remote, ls-files.",
            base_sub) }
    end

    local extra = (args.args or ""):match("^%s*(.-)%s*$")

    -- Reject shell metacharacters in the combined sub + extra string.
    -- Checking only `extra` allowed injection via a crafted subcommand like
    -- "status; id" whose base_sub passes the allowlist check.
    local combined = sub .. " " .. extra
    if combined:find(SHELL_META) then
        return { type = "error", error = "Shell metacharacters are not allowed in git commands." }
    end

    -- Reject blocked flags: tokenise first to avoid substring false-positives.
    -- e.g. "--cached" contains "-c" but is not a blocked flag;
    -- a path like "/data/delete/foo" contains "-D" but is not a flag at all.
    local tokens = {}
    for tok in (sub .. " " .. extra):gmatch("%S+") do
        tokens[#tokens + 1] = tok
    end
    for _, tok in ipairs(tokens) do
        for _, flag in ipairs(BLOCKED_FLAGS) do
            if tok == flag or tok:sub(1, #flag + 1) == flag .. "=" then
                return { type = "error", error = "Blocked option: " .. flag }
            end
        end
    end

    -- Resolve and validate working directory
    local app_state_ok, app_state = pcall(require, "state.app_state")
    local cwd = args.path
        or (context and context.cwd)
        or (app_state_ok and app_state.get_cwd and app_state.get_cwd())
        or "."
    cwd = paths.resolve(cwd, context and context.cwd)

    if paths.is_restricted(cwd) then
        return { type = "error", error = "Access denied: restricted path " .. cwd }
    end

    -- Verify this is actually a git repo before running anything
    local check = io.popen("git -C " .. shell.quote(cwd) .. " rev-parse --is-inside-work-tree 2>/dev/null")
    local is_repo = check and check:read("*l") == "true"
    if check then check:close() end
    if not is_repo then
        return { type = "error", error = "Not a git repository: " .. cwd }
    end

    -- Sensible defaults when no args supplied
    local defaults = {
        diff   = "--stat -p",
        log    = "--oneline -20",
        status = "--short",
    }
    if extra == "" and defaults[base_sub] then
        extra = defaults[base_sub]
    end

    -- Build command quoting each argument individually.
    -- We cannot use gmatch("%S+") because it would incorrectly split
    -- filenames that contain spaces (e.g. HEAD -- "file with spaces.c").
    -- Instead we use a POSIX-aware shell-word splitter that respects double
    -- and single quotes and backslash escapes.
    local quoted_args = {}
    local i = 1
    local elen = #extra
    while i <= elen do
        -- skip whitespace
        while i <= elen and extra:sub(i,i):match("%s") do i = i + 1 end
        if i > elen then break end
        local ch = extra:sub(i,i)
        local tok
        if ch == '"' then
            -- double-quoted token: consume until closing "
            local j = extra:find('"', i + 1, true)
            if not j then
                return { type = "error", error = "Unterminated double-quoted argument in args" }
            end
            tok = extra:sub(i + 1, j - 1)
            i = j + 1
        elseif ch == "'" then
            -- single-quoted token
            local j = extra:find("'", i + 1, true)
            if not j then
                return { type = "error", error = "Unterminated single-quoted argument in args" }
            end
            tok = extra:sub(i + 1, j - 1)
            i = j + 1
        else
            -- unquoted token: stop at whitespace
            local j = extra:find("%s", i + 1)
            if j then
                tok = extra:sub(i, j - 1)
                i = j
            else
                tok = extra:sub(i)
                i = elen + 1
            end
        end
        table.insert(quoted_args, shell.quote(tok))
    end
    local cmd = string.format(
        "git --no-pager -C %s %s %s 2>&1 | head -600",
        shell.quote(cwd), shell.quote(sub), table.concat(quoted_args, " ")
    )

    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Failed to spawn git" } end
    local output = h:read("*a")
    h:close()

    if not output or #output == 0 then
        return { type = "text", text = "(no output)" }
    end

    return { type = "text", text = output }
end

return M
