-- agent/memory.lua — Session-aware memory system (from legacy-agent)
--
-- Provides:
--   - Action tracking with deduplication (prevents repeated failures)
--   - TTL-based garbage collection
--   - Plan/checklist tracking for multi-step tasks
--   - Persistent learning from successful patterns
--   - User preferences
--   - Project tree cache
--   - Context builder for prompt injection

local M = {}

local json = nil
pcall(function() json = require("utils.json_fallback") end)

local session_id = nil
local actions = {}
local errors = {}
local plan = nil
local learned = {}
local preferences = {}
local project_tree = nil

local TTL = {
    error = 3600,
    action = 1800,
    learned = 604800,
}

function M.init()
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    session_id = os.time() .. "-" .. math.random(10000, 99999)
    actions = {}
    errors = {}
    plan = nil
end

function M.clear()
    actions = {}
    errors = {}
    plan = nil
end

function M.record_action(key, success)
    actions[key] = {
        success = success,
        timestamp = os.time(),
        count = (actions[key] and actions[key].count or 0) + 1,
    }

    if #errors > 100 then
        table.remove(errors, 1)
    end

    if not success then
        table.insert(errors, { key = key, timestamp = os.time() })
    end
end

function M.was_action_tried(key)
    local entry = actions[key]
    if not entry then return false end
    if os.time() - entry.timestamp > TTL.action then
        actions[key] = nil
        return false
    end
    return not entry.success and entry.count >= 2
end

function M.set_plan(steps)
    plan = {
        steps = steps,
        current = 1,
        started = os.time(),
    }
end

function M.advance_plan()
    if plan and plan.current < #plan.steps then
        plan.current = plan.current + 1
        return plan.steps[plan.current]
    end
    return nil
end

function M.format_plan()
    if not plan then return "" end
    local lines = { "Current plan:" }
    for i, step in ipairs(plan.steps) do
        local marker = i < plan.current and "✓" or (i == plan.current and "→" or " ")
        table.insert(lines, string.format("  %s %d. %s", marker, i, step))
    end
    return table.concat(lines, "\n")
end

function M.learn(category, pattern)
    if not learned[category] then learned[category] = {} end
    table.insert(learned[category], {
        pattern = pattern,
        timestamp = os.time(),
    })
end

function M.set_preference(key, value)
    preferences[key] = value
end

function M.get_preference(key)
    return preferences[key]
end

function M.set_project_tree(tree)
    project_tree = tree
end

function M.build_context()
    local parts = {}

    local now = os.time()
    local recent_errors = {}
    for _, err in ipairs(errors) do
        if now - err.timestamp < TTL.error then
            table.insert(recent_errors, err.key)
        end
    end
    if #recent_errors > 0 then
        table.insert(parts, "Recent errors: " .. table.concat(recent_errors, ", "))
    end

    if plan then
        table.insert(parts, M.format_plan())
    end

    local recent_actions = {}
    for key, entry in pairs(actions) do
        if now - entry.timestamp < 300 then
            table.insert(recent_actions, key .. (entry.success and " ✓" or " ✗"))
        end
    end
    if #recent_actions > 0 then
        table.insert(parts, "Recent actions: " .. table.concat(recent_actions, "; "))
    end

    return table.concat(parts, "\n")
end

function M.save()
    local home = os.getenv("HOME") or "/tmp"
    local path = home .. "/.config/cli-agent/memory.json"

    local dir = path:match("^(.*)/")
    if dir then
        local quoted_dir = "'" .. dir:gsub("'", "'\\'") .. "'"
        os.execute("mkdir -p " .. quoted_dir)
    end

    if json then
        local data = json.stringify({
            session_id = session_id,
            learned = learned,
            preferences = preferences,
        })
        if data then
            local f = io.open(path, "w")
            if f then
                f:write(data)
                f:close()
            end
        end
    end
end

function M.load()
    local home = os.getenv("HOME") or "/tmp"
    local path = home .. "/.config/cli-agent/memory.json"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if json and content then
            local data = json.parse(content)
            if data then
                learned = data.learned or {}
                preferences = data.preferences or {}
            end
        end
    end
end

return M
