-- tools/exit_worktree.lua — ExitWorktree: Leave and clean up a git worktree

local app_state = require("state.app_state")

local M = {}
M.name = "ExitWorktree"
M.description = "Exit and optionally clean up a git worktree."

M.input_schema = {
    type = "object",
    properties = {
        cleanup = { type = "boolean", description = "Remove the worktree directory after exiting (default true)" },
    },
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name() return "ExitWorktree" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local cleanup = args.cleanup ~= false
    local worktree_path = app_state.get("worktree_path")
    local original_cwd = app_state.get("worktree_original_cwd")
    local branch = app_state.get("worktree_branch")

    if not worktree_path then
        return { type = "text", text = "No active worktree to exit." }
    end

    local report = {}

    local shell = require("utils.shell")

    -- Check if worktree has uncommitted changes
    local status_cmd = string.format("git -C %s status --porcelain 2>/dev/null",
        shell.quote(worktree_path))
    local handle = io.popen(status_cmd)
    if handle then
        local status_output = handle:read("*a")
        handle:close()
        if status_output and #status_output > 0 then
            table.insert(report, "Warning: worktree has uncommitted changes")
            if not cleanup then
                table.insert(report, "Preserving worktree at: " .. worktree_path)
            end
        end
    end

    -- Remove worktree if cleanup requested
    if cleanup then
        local remove_cmd = string.format("git worktree remove %s --force 2>&1",
            shell.quote(worktree_path))
        handle = io.popen(remove_cmd)
        if handle then
            local output = handle:read("*a")
            handle:close()
            table.insert(report, "Worktree removed: " .. worktree_path)
        end
    end

    -- Clear worktree state
    app_state.set("worktree_path", nil)
    app_state.set("worktree_original_cwd", nil)
    app_state.set("worktree_branch", nil)

    if original_cwd then
        table.insert(report, "Returned to: " .. original_cwd)
    end

    if #report == 0 then
        return { type = "text", text = "Exited worktree." }
    end

    return { type = "text", text = table.concat(report, "\n") }
end

return M
