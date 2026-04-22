-- tools/git.lua — GitTool: Git repository inspection (read-only)
-- Exposes a safe subset of git subcommands for repo inspection.
-- Security: all user arguments are passed via shell.quote(); destructive
-- options and shell metacharacters are rejected before execution.

local paths = require("utils.paths")
local shell = require("utils.shell")
local json = require("utils.json_fallback")

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
--
-- Note: `-c` is also intentionally NOT blocked globally. This tool always
-- places user-supplied args AFTER the subcommand, so a `-c` token in args is
-- parsed by git as a subcommand flag (e.g. `git show -c` for combined-merge
-- diff, `git log -c`), never as the global config override (`git -c k=v sub`)
-- which would have to come BEFORE the subcommand. Blocking it here would
-- false-positive on legitimate read-only inspection commands. We still block
-- `--git-dir/--work-tree/--config-env` to prevent any redirection escapes,
-- and `--ext-diff/--textconv` to prevent triggering external programs.
local BLOCKED_FLAGS = {
    "--force", "-f", "--hard", "--mirror", "--delete", "-D",
    "--push", "--set-upstream",
    "--git-dir", "--work-tree", "--config-env",
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

-- Pre-tokenisation safety check.  We rely on the POSIX-aware shell-word
-- splitter below combined with shell.quote() on every parsed token to
-- neutralise per-character shell metas (`;`, `&`, `|`, `` ` ``, `$`, `<`,
-- `>`, parens/braces, `!`, `[`, `]`, `\`) when they appear inside legitimate
-- quoted args (e.g. `git log --grep='fix!'`, pathspecs containing `[`,
-- filenames with `;` or `$`).  The only characters that the tokeniser
-- cannot make safe are raw line terminators, which would let a crafted
-- subcommand like "status\nid" inject a second command.  Block ONLY those.
local SHELL_META = "[\n\r]"

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
            "'%s' is not a permitted subcommand. Allowed: diff, log, show, status, blame, branch, remote, ls-files, rev-parse, shortlog, describe.",
            base_sub) }
    end

    local extra = (args.args or ""):match("^%s*(.-)%s*$")

    -- Reject raw line terminators in the combined sub + extra string.
    -- All other shell metas are handled per-token by shell.quote() below,
    -- which makes them safe even when present in legitimate args
    -- (e.g. `git log --grep='fix!'`, pathspecs containing `;` or `$`).
    local combined = sub .. " " .. extra
    if combined:find(SHELL_META) then
        return { type = "error", error = "Newlines are not allowed in git commands." }
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

    -- For diff-producing subcommands, force git to use its built-in diff
    -- machinery and skip user-defined external diff drivers / textconv
    -- filters.  These can be configured globally (gitconfig) or per repo
    -- (.gitattributes) and would otherwise let a hostile repository run
    -- arbitrary external programs through what we advertise as a read-only
    -- inspection tool.  The `--no-ext-diff` and `--no-textconv` flags must
    -- precede the subcommand args so git applies them before any pathspec.
    local DIFF_SAFE_SUBS = { diff = true, show = true, log = true, blame = true }
    local extra_git_flags = {}
    if DIFF_SAFE_SUBS[base_sub] then
        table.insert(extra_git_flags, "--no-ext-diff")
        table.insert(extra_git_flags, "--no-textconv")
    end

    -- Output cap and total wall-clock timeout.  A slow `git` (large diff,
    -- pathological blame) or any subcommand that touches a hung remote
    -- could otherwise wedge the agent loop indefinitely.  Use the C FFI
    -- subprocess runner (preferred — argv-based, hard timeout, no shell)
    -- when available, with in-process line capping; fall back to io.popen
    -- with a `head` pipe when the FFI helper is unavailable.
    local MAX_LINES = 600
    local TIMEOUT_MS = 30000

    local function build_argv()
        local argv = { "--no-pager", "-C", cwd }
        for _, f in ipairs(extra_git_flags) do table.insert(argv, f) end
        table.insert(argv, sub)
        for _, tok in ipairs(raw_tokens) do table.insert(argv, tok) end
        return argv
    end

    local function cap_lines(text)
        -- Split into at most MAX_LINES + 1 lines so we can detect overflow.
        local lines, count, pos, slen = {}, 0, 1, #text
        while pos <= slen + 1 do
            local nl = text:find("\n", pos, true)
            local ending = nl or (slen + 1)
            count = count + 1
            lines[count] = text:sub(pos, ending - 1)
            if count > MAX_LINES then break end
            if not nl then break end
            pos = nl + 1
        end
        if lines[#lines] == "" and not (count > MAX_LINES) then
            table.remove(lines)
        end
        return lines
    end

    local lines, truncated, timed_out
    local _jenova = rawget(_G, "jenova")
    if type(_jenova) == "table" and _jenova.process and _jenova.process.spawn_json then
        local argv = build_argv()
        -- Combine stdout+stderr (git prints diagnostics on stderr).
        local config = json.stringify({
            command = "git",
            args = argv,
            timeout_ms = TIMEOUT_MS,
            capture_stdout = true,
            capture_stderr = true,
        })
        local result_json = _jenova.process.spawn_json(config)
        if not result_json then
            return { type = "error", error = "Failed to spawn git" }
        end
        local ok, result = pcall(json.parse, result_json)
        if not ok or type(result) ~= "table" then
            return { type = "error", error = "Failed to parse git result" }
        end
        local out = (result.stdout or "")
        if result.stderr and #result.stderr > 0 then
            out = (#out > 0) and (out .. "\n" .. result.stderr) or result.stderr
        end
        timed_out = result.timed_out or false
        lines = cap_lines(out)
        truncated = #lines > MAX_LINES
        if truncated then lines[#lines] = nil end
    else
        -- Fallback path: cap output via `head -N+1` shell pipeline, and
        -- defend against runaway runtime with `timeout` if available.
        local head_cmd = "head -" .. (MAX_LINES + 1)
        local quoted_args = {}
        for _, tok in ipairs(raw_tokens) do
            table.insert(quoted_args, shell.quote(tok))
        end
        local fixed_flags = ""
        if #extra_git_flags > 0 then
            local qf = {}
            for _, f in ipairs(extra_git_flags) do table.insert(qf, shell.quote(f)) end
            fixed_flags = table.concat(qf, " ") .. " "
        end
        local timeout_secs = math.floor(TIMEOUT_MS / 1000)
        local cmd = string.format(
            "command -v timeout >/dev/null 2>&1 && TO='timeout %d' || TO=''; $TO git --no-pager -C %s %s %s%s 2>&1 | %s",
            timeout_secs,
            shell.quote(cwd), shell.quote(sub), fixed_flags,
            table.concat(quoted_args, " "), head_cmd
        )
        local h = io.popen(cmd)
        if not h then return { type = "error", error = "Failed to spawn git" } end
        lines = {}
        while true do
            local line = h:read("*l")
            if not line then break end
            table.insert(lines, line)
        end
        h:close()
        truncated = #lines > MAX_LINES
        if truncated then lines[#lines] = nil end
    end

    if timed_out then
        local prefix = (#lines > 0) and (table.concat(lines, "\n") .. "\n\n") or ""
        return { type = "error", error = string.format(
            "%s[git timed out after %dms — narrow the command (add a path, --since, -n) and retry]",
            prefix, TIMEOUT_MS) }
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
