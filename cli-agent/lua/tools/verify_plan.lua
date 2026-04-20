-- tools/verify_plan.lua — VerifyPlanExecution: Verify a plan's steps are completed

local app_state = require("state.app_state")

local M = {}
M.name = "VerifyPlanExecution"
M.description = "Verify that planned steps have been executed and check for remaining work."

M.input_schema = {
    type = "object",
    properties = {
        plan_id = { type = "string", description = "ID of the plan to verify (optional, uses active plan)" },
        check_files = { type = "boolean", description = "Whether to verify that referenced files exist" },
    },
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "VerifyPlanExecution" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local plan_id = args.plan_id
    local check_files = args.check_files ~= false

    -- Look up the plan from app_state todos
    local todos = app_state.get("todos") or {}

    if #todos == 0 then
        return { type = "text", text = "No plan or todo items found to verify." }
    end

    local completed = 0
    local pending = 0
    local in_progress = 0
    local lines = {}

    for _, todo in ipairs(todos) do
        local status = todo.status or "pending"
        if status == "completed" or status == "done" then
            completed = completed + 1
            table.insert(lines, string.format("  [x] %s", todo.content or todo.text or ""))
        elseif status == "in_progress" or status == "in-progress" then
            in_progress = in_progress + 1
            table.insert(lines, string.format("  [~] %s", todo.content or todo.text or ""))
        else
            pending = pending + 1
            table.insert(lines, string.format("  [ ] %s", todo.content or todo.text or ""))
        end
    end

    -- Optionally verify referenced files. The extraction pattern is kept
    -- broad, but we filter the matches through a "looks like a file path"
    -- test so strings like version numbers (`1.0`, `v2.3`) or commit hashes
    -- aren't misreported as "MISSING" files. A real path either contains a
    -- directory separator or ends in a textual extension.
    local file_checks = {}
    if check_files then
        for _, todo in ipairs(todos) do
            local text = todo.content or todo.text or ""
            for path in text:gmatch("[%w_/%\\%-%.]+%.%w+") do
                local looks_like_path =
                    path:find("/", 1, true)
                    or path:find("\\", 1, true)
                    or path:match("%.[%a][%w]*$")
                if looks_like_path and not file_checks[path] then
                    local f = io.open(path, "r")
                    if f then
                        f:close()
                        file_checks[path] = true
                    else
                        file_checks[path] = false
                    end
                end
            end
        end
    end

    local total = completed + pending + in_progress
    local summary = string.format(
        "Plan verification: %d/%d completed, %d in-progress, %d pending",
        completed, total, in_progress, pending
    )

    local report = { summary, "", "Tasks:" }
    for _, line in ipairs(lines) do
        table.insert(report, line)
    end

    if next(file_checks) then
        table.insert(report, "")
        table.insert(report, "File checks:")
        -- Sort paths so the report is deterministic across runs. `pairs`
        -- yields a table's keys in unspecified order, which produced
        -- different output on every invocation.
        local sorted_paths = {}
        for path in pairs(file_checks) do
            table.insert(sorted_paths, path)
        end
        table.sort(sorted_paths)
        for _, path in ipairs(sorted_paths) do
            local exists = file_checks[path]
            local status_sym = exists and "exists" or "MISSING"
            table.insert(report, string.format("  %s: %s", path, status_sym))
        end
    end

    return { type = "text", text = table.concat(report, "\n") }
end

return M
