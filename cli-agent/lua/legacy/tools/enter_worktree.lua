-- tools/enter_worktree.lua — EnterWorktree: Create and enter a git worktree

local app_state = require("state.app_state")

-- Seed once at module load. The per-call worktree id adds a random suffix
-- so multiple worktrees created within the same second can't collide.
math.randomseed(os.time() + math.floor((os.clock() or 0) * 1e6))

local M = {}
M.name = "EnterWorktree"
M.description = "Create a temporary git worktree for isolated work."

M.parameters = {
    type = "object",
    properties = {
        branch = { type = "string", description = "Branch name for the worktree" },
        base_ref = { type = "string", description = "Base ref to branch from (default: HEAD)" },
        path = { type = "string", description = "Worktree path (auto-generated if omitted)" },
    },
    required = { "branch" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "EnterWorktree" end

function M.check_permissions()
    return { allowed = true }
end

function M.call(args, ctx)
    local branch = args.branch
    if not branch or #branch == 0 then
        return { type = "error", error = "Branch name is required" }
    end

    local base_ref = args.base_ref or "HEAD"

    -- Generate worktree path if not provided. Include a random suffix so
    -- concurrent creates within the same second don't collide.
    local path = args.path
    if not path then
        local tmp_base = os.getenv("TMP") or os.getenv("TEMP") or "/tmp"
        -- Remove trailing slash if present
        tmp_base = tmp_base:gsub("[/\\]$", "")
        path = string.format(
            "%s/jenova-worktree-%s-%d-%04x",
            tmp_base,
            branch:gsub("[^%w_%-]", "_"),
            os.time(),
            math.random(0, 0xffff)
        )
    end

    -- Save original directory
    local original_cwd = app_state.get_cwd()
    app_state.set("worktree_original_cwd", original_cwd)
    app_state.set("worktree_path", path)
    app_state.set("worktree_branch", branch)

    -- Create the worktree
    local shell = require("utils.shell")
    local cmd = string.format("git worktree add -b %s %s %s 2>&1",
        shell.quote(branch),
        shell.quote(path),
        shell.quote(base_ref))

    local handle = io.popen(cmd)
    if not handle then
        return { type = "error", error = "Failed to execute git worktree add" }
    end
    local output = handle:read("*a")
    local success = handle:close()

    if not success then
        -- Branch may already exist, try without -b
        cmd = string.format("git worktree add %s %s 2>&1",
            shell.quote(path),
            shell.quote(branch))
        handle = io.popen(cmd)
        if not handle then
            return { type = "error", error = "Failed to create worktree" }
        end
        output = handle:read("*a")
        handle:close()
    end

    return {
        type = "text",
        text = string.format("Worktree created:\n  Branch: %s\n  Path: %s\n  Base: %s\n%s",
            branch, path, base_ref, output or "")
    }
end

return M
