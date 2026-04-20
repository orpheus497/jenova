-- history/manager.lua — Command and conversation history
-- Equivalent to src/history.ts

local json = require("utils.json_fallback")
local app_state = require("state.app_state")

local History = {}

-- History storage
local history_items = {}
local max_history_size = 1000
local history_file = nil

-- ── Initialization ────────────────────────────────────────────────────

function History.init()
    local session_dir = app_state.get("session_dir")
    if not session_dir then
        return
    end

    history_file = session_dir .. "/history.json"

    -- Load existing history
    History.load()
end

-- ── Load History ──────────────────────────────────────────────────────

function History.load()
    if not history_file then
        return
    end

    local file = io.open(history_file, "r")
    if not file then
        return
    end

    local content = file:read("*a")
    file:close()

    local ok, loaded = pcall(json.parse, content)
    if ok and type(loaded) == "table" then
        history_items = loaded
    end
end

-- ── Save History ──────────────────────────────────────────────────────

function History.save()
    if not history_file then
        return
    end

    local ok, json_str = pcall(json.stringify, history_items, { pretty = false })
    if not ok then
        return
    end

    local file = io.open(history_file, "w")
    if not file then
        return
    end

    file:write(json_str)
    file:close()
end

-- ── Add History Item ──────────────────────────────────────────────────

function History.add(item)
    table.insert(history_items, {
        content = item,
        timestamp = os.time(),
        session_id = app_state.get("session_id")
    })

    -- Trim history if too large
    if #history_items > max_history_size then
        table.remove(history_items, 1)
    end

    -- Auto-save
    History.save()
end

-- ── Get History ───────────────────────────────────────────────────────

function History.get_all()
    return history_items
end

function History.get_recent(count)
    count = count or 10
    local start = math.max(1, #history_items - count + 1)
    local recent = {}

    for i = start, #history_items do
        table.insert(recent, history_items[i])
    end

    return recent
end

function History.get_item(index)
    if index < 1 or index > #history_items then
        return nil
    end
    return history_items[index]
end

-- ── Search History ────────────────────────────────────────────────────

function History.search(query)
    local results = {}

    for _, item in ipairs(history_items) do
        if item.content:find(query, 1, true) then
            table.insert(results, item)
        end
    end

    return results
end

-- ── Clear History ─────────────────────────────────────────────────────

function History.clear()
    history_items = {}
    History.save()
end

-- ── History Navigation ────────────────────────────────────────────────

local current_index = 0

function History.navigate_up()
    if current_index < #history_items then
        current_index = current_index + 1
    end
    return History.get_current()
end

function History.navigate_down()
    if current_index > 0 then
        current_index = current_index - 1
    end

    if current_index == 0 then
        return ""
    end

    return History.get_current()
end

function History.get_current()
    if current_index == 0 or current_index > #history_items then
        return ""
    end

    local index = #history_items - current_index + 1
    local item = history_items[index]
    return item and item.content or ""
end

function History.reset_navigation()
    current_index = 0
end

return History
