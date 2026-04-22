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
--
-- Note: `-u` is intentionally NOT blocked globally because it is the standard
-- short form of `--unified` for `git diff -u` (unified diff format) and would
-- false-positive on legitimate inspection commands. We block `--set-upstream`
-- explicitly to prevent the upstream-tracking mutation, and `push` is not in
-- the allowlist anyway.
local BLOCKED_FLAGS = {
    "--force", "-f", "--hard", "--mirror", "--delete", "-D",
    "--push", "--set-upstream",
    "--git-dir", "--work-tree", "-c", "--config-env",
    "--ext-diff", "--textconv",
}

-- Per-subcommand mutation guards.
-- `branch` and `remote` accept read-only and mutating invocations through the
-- same subcommand. Block the mutating forms (flags AND positional verbs)
-- explicitly so that AUTO/BYPASS permission modes cannot be tricked into
-- mutating repo state. Read-only invocations (e.g. `branch --list`,
-- `branch -v`, `remote -v`, `remote show origin`, `remote get-url origin`) are
-- unaffected.
local SUBCOMMAND_BLOCKED_FLAGS = {
    branch = {
        ["-d"] = true, ["-D"] = true, ["--delete"] = true,
        ["-m"] = true, ["-M"] = true, ["--move"] = true,
        ["-c"] = true, ["-C"] = true, ["--copy"] = true,
        ["--set-upstream-to"] = true, ["--unset-upstream"] = true,
        ["--edit-description"] = true,
        ["--track"] = true, ["--no-track"] = true,
        ["-t"] = true, ["-u"] = true,
    },
    remote = {
        -- remote uses positional verbs; treat them as mutating tokens.
        ["add"] = true, ["remove"] = true, ["rm"] = true,
        ["rename"] = true, ["set-url"] = true, ["set-head"] = true,
        ["set-branches"] = true, ["prune"] = true, ["update"] = true,
    },
}

-- Characters that could break shell quoting or inject commands.
-- Includes newlines (\n, \r) to prevent multi-line injection where a crafted
-- subcommand like "status\nid" would pass base_sub validation then execute id.
-- Notes:
--   • [ ] are intentionally permitted — valid in pathspecs/globs and log
--     search patterns; every parsed token is shell.quote()'d before the shell
--     sees it.
--   • backslash is also permitted because the shell-word splitter below
--     interprets it as an escape (e.g. "file\ name.txt"), and parsed tokens
--     are likewise shell.quote()'d.
local SHELL_META = "[;&|`$<>%(%){}!\n\r]"

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
    -- and single quotes and backslash escapes (both inside double quotes
    -- and outside, mirroring standard /bin/sh word-splitting semantics).
    local raw_tokens = {}
    local i = 1
    local elen = #extra
    while i <= elen do
        -- skip whitespace
        while i <= elen and extra:sub(i,i):match("%s") do i = i + 1 end
        if i > elen then break end
        local ch = extra:sub(i,i)
        local tok_buf = {}
        if ch == '"' then
            -- double-quoted token: handle \" and \\ escapes; consume to closing "
            i = i + 1
            local closed = false
            while i <= elen do
                local c = extra:sub(i,i)
                if c == "\\" and i < elen then
                    local nxt = extra:sub(i+1, i+1)
                    -- POSIX: inside double quotes, backslash only escapes
                    -- $, `, ", \, and newline. Other backslashes are literal.
                    if nxt == '"' or nxt == "\\" or nxt == "$" or nxt == "`" then
                        table.insert(tok_buf, nxt)
                        i = i + 2
                    else
                        table.insert(tok_buf, c)
                        i = i + 1
                    end
                elseif c == '"' then
                    closed = true
                    i = i + 1
                    break
                else
                    table.insert(tok_buf, c)
                    i = i + 1
                end
            end
            if not closed then
                return { type = "error", error = "Unterminated double-quoted argument in args" }
            end
        elseif ch == "'" then
            -- single-quoted token: no escapes inside
            local j = extra:find("'", i + 1, true)
            if not j then
                return { type = "error", error = "Unterminated single-quoted argument in args" }
            end
            table.insert(tok_buf, extra:sub(i + 1, j - 1))
            i = j + 1
        else
            -- unquoted token: stop at whitespace; honor backslash escapes for
            -- spaces and other shell metas (e.g. file\ name.txt)
            while i <= elen do
                local c = extra:sub(i,i)
                if c:match("%s") then break end
                if c == "\\" and i < elen then
                    table.insert(tok_buf, extra:sub(i+1, i+1))
                    i = i + 2
                else
                    table.insert(tok_buf, c)
                    i = i + 1
                end
            end
        end
        table.insert(raw_tokens, table.concat(tok_buf))
    end

    -- Reject blocked flags by exact token match. Substring search on the
    -- combined string would false-positive on filenames containing the flag
    -- text (e.g. a path like "config-env.txt" matches "--config-env").
    local BLOCKED_SET = {}
    for _, flag in ipairs(BLOCKED_FLAGS) do BLOCKED_SET[flag] = true end
    for _, tok in ipairs(raw_tokens) do
        -- Match exact token, or "--flag=value" form
        if BLOCKED_SET[tok] then
            return { type = "error", error = "Blocked option: " .. tok }
        end
        local prefix = tok:match("^([^=]+)=")
        if prefix and BLOCKED_SET[prefix] then
            return { type = "error", error = "Blocked option: " .. prefix }
        end
    end

    -- Per-subcommand mutation guards (e.g. `branch -d`, `remote add`).
    local sub_blocked = SUBCOMMAND_BLOCKED_FLAGS[base_sub]
    if sub_blocked then
        for _, tok in ipairs(raw_tokens) do
            if sub_blocked[tok] then
                return { type = "error", error = string.format(
                    "'git %s %s' would mutate the repository — Git tool is read-only.",
                    base_sub, tok) }
            end
            local prefix = tok:match("^([^=]+)=")
            if prefix and sub_blocked[prefix] then
                return { type = "error", error = string.format(
                    "'git %s %s' would mutate the repository — Git tool is read-only.",
                    base_sub, prefix) }
            end
        end
    end

    local quoted_args = {}
    for _, tok in ipairs(raw_tokens) do
        table.insert(quoted_args, shell.quote(tok))
    end

    -- Cap output by piping through `head -N+1` so the OS terminates git
    -- early and doesn't materialise multi-MB output for nothing. We read
    -- one extra line (MAX_LINES + 1) so we can detect truncation: if it
    -- exists, we know there was more, even if we don't know how much.
    local MAX_LINES = 600
    local cmd = string.format(
        "git --no-pager -C %s %s %s 2>&1 | head -%d",
        shell.quote(cwd), shell.quote(sub), table.concat(quoted_args, " "), MAX_LINES + 1
    )

    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Failed to spawn git" } end

    local lines = {}
    while true do
        local line = h:read("*l")
        if not line then break end
        table.insert(lines, line)
    end
    h:close()

    local truncated = #lines > MAX_LINES
    if truncated then
        -- Drop the +1 probe line so output ends at a real boundary
        lines[#lines] = nil
    end

    if #lines == 0 and not truncated then
        return { type = "text", text = "(no output)" }
    end

    local output = table.concat(lines, "\n")
    if truncated then
        output = output .. string.format(
            "\n\n[output truncated at %d lines — narrow the command (e.g. add a path, use -n, --since, or -- <path>) for the full result]",
            MAX_LINES)
    end

    return { type = "text", text = output }
end

return M
