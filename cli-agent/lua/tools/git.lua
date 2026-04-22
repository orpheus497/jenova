-- tools/git.lua — GitTool: Git repository operations
-- Exposes git diff, log, show, status, blame and stash to the model.
-- Uses the Shell fallback (io.popen) — no C FFI dependency.

local paths = require("utils.paths")
local shell = require("utils.shell")

local M = {}
M.name = "Git"
M.description = "Run git commands to inspect repository state: diff, log, show, status, blame, stash. Use this to understand recent changes before editing files."

M.parameters = {
    type = "object",
    properties = {
        subcommand = {
            type = "string",
            description = "git subcommand: 'diff', 'log', 'show', 'status', 'blame', 'stash', 'branch', 'remote'",
        },
        args = {
            type = "string",
            description = "Extra arguments passed verbatim to git (e.g. '--stat HEAD~3', 'HEAD -- src/foo.c')",
        },
        path = {
            type = "string",
            description = "Working directory for the git command (default: session cwd)",
        },
    },
    required = { "subcommand" }
}

-- Allowed subcommands (read-only inspection only — no push/reset/force)
local ALLOWED = {
    diff    = true,
    log     = true,
    show    = true,
    status  = true,
    blame   = true,
    stash   = true,
    branch  = true,
    remote  = true,
    ["rev-parse"] = true,
    ["ls-files"]  = true,
    ["shortlog"]  = true,
    ["describe"]  = true,
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    if input and input.subcommand then
        return "Git: " .. input.subcommand .. (input.args and (" " .. input.args:sub(1, 40)) or "")
    end
    return "Git"
end

function M.check_permissions() return { allowed = true } end

function M.call(args, context)
    local sub = args.subcommand
    if not sub or sub == "" then
        return { type = "error", error = "subcommand is required (e.g. 'diff', 'log', 'status')" }
    end

    -- Strip leading "git " if user accidentally included it
    sub = sub:match("^git%s+(.+)$") or sub

    -- Validate
    local base_sub = sub:match("^(%S+)")
    if not ALLOWED[base_sub] then
        return { type = "error", error = string.format(
            "Git subcommand '%s' is not allowed. Permitted: diff, log, show, status, blame, stash, branch, remote, ls-files.",
            base_sub) }
    end

    local extra = args.args or ""
    local cwd   = args.path
                  or (context and context.cwd)
                  or (require("state.app_state").get_cwd and require("state.app_state").get_cwd())
                  or "."
    cwd = paths.resolve(cwd, context and context.cwd)

    -- Safety: never allow options that rewrite history
    local combined = sub .. " " .. extra
    for _, dangerous in ipairs({ "--force", "-f", "--hard", "--mirror", "--delete", "-D", "--push" }) do
        if combined:find(dangerous, 1, true) then
            return { type = "error", error = "Destructive git option not allowed: " .. dangerous }
        end
    end

    -- Add useful defaults when none supplied
    local defaults = {
        diff   = "--stat -p",
        log    = "--oneline -20",
        status = "--short",
    }
    if extra == "" and defaults[base_sub] then
        extra = defaults[base_sub]
    end

    local cmd = string.format(
        "cd %s && git %s %s 2>&1 | head -600",
        shell.quote(cwd), sub, extra
    )

    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Failed to run git" } end
    local output = h:read("*a")
    h:close()

    if not output or #output == 0 then
        return { type = "text", text = "(no output)" }
    end

    return { type = "text", text = output }
end

return M
