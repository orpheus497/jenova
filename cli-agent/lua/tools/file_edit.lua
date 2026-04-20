-- tools/file_edit.lua — FileEditTool: Search & replace editing
-- Uses jenova.fs (Rust FFI) for reliable edit operations.

local json = require("utils.json_fallback")
local paths = require("utils.paths")

local M = {}
M.name = "Edit"
M.description = "Edit a file by replacing an exact string match with new content. Supports both absolute and relative paths. The old_string must be unique in the file."

M.parameters = {
    type = "object",
    properties = {
        file_path = { type = "string", description = "Path to the file to edit (absolute or relative to working directory)" },
        old_string = { type = "string", description = "The exact text to find and replace (must be unique)" },
        new_string = { type = "string", description = "The replacement text" },
        replace_all = { type = "boolean", description = "Replace all occurrences (default: false)" },
    },
    required = { "file_path", "old_string", "new_string" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
    return input and input.file_path and ("Edit: " .. input.file_path) or "Edit"
end

function M.check_permissions(input, ctx)
    local ok_mgr, manager = pcall(require, "permissions.manager")
    if not ok_mgr or not manager or not manager.can_use_tool then
        -- Fail open if manager unavailable — the registry will still ask via
        -- request_permission on the next load attempt; don't silently block.
        return { allowed = true }
    end
    local allowed, reason = manager.can_use_tool("Edit", input, ctx or {})
    return { allowed = allowed, reason = reason }
end

function M.call(args, context)
    local path = args.file_path
    if not path then return { type = "error", error = "No file path provided" } end
    if not args.old_string then return { type = "error", error = "No old_string provided" } end
    if not args.new_string then return { type = "error", error = "No new_string provided" } end
    if args.old_string == args.new_string then
        return { type = "error", error = "old_string and new_string are identical" }
    end
    -- Resolve relative paths against the session working directory
    path = paths.resolve(path, context and context.cwd)

    -- Use Rust FFI (preferred)
    if jenova and jenova.fs and jenova.fs.edit then
        local replace_all = args.replace_all and 1 or 0
        local result_json = jenova.fs.edit(path, args.old_string, args.new_string, replace_all)
        if result_json then
            local ok, result = pcall(json.parse, result_json)
            if ok and result then
                if result.error then
                    return { type = "error", error = result.error }
                end
                return {
                    type = "text",
                    text = string.format("The file %s has been updated successfully.", path),
                }
            end
        end
    end

    -- Fallback: pure Lua
    local f = io.open(path, "r")
    if not f then return { type = "error", error = "Cannot read: " .. path } end
    local content = f:read("*a")
    f:close()

    if args.replace_all then
        local count = 0
        local escape_pattern = require("utils.string").escape_pattern
        local new_content = content:gsub(escape_pattern(args.old_string), function()
            count = count + 1
            return args.new_string
        end)
        if count == 0 then
            return { type = "error", error = "old_string not found in file" }
        end
        f = io.open(path, "w")
        if not f then return { type = "error", error = "Cannot write: " .. path } end
        f:write(new_content)
        f:close()
        return { type = "text", text = string.format("The file %s has been updated successfully.", path) }
    end

    local pos = content:find(args.old_string, 1, true)
    if not pos then return { type = "error", error = "old_string not found in file" } end

    local second = content:find(args.old_string, pos + 1, true)
    if second then return { type = "error", error = "old_string matches multiple locations — provide more context to make it unique" } end

    local new_content = content:sub(1, pos - 1) .. args.new_string .. content:sub(pos + #args.old_string)
    f = io.open(path, "w")
    if not f then return { type = "error", error = "Cannot write: " .. path } end
    f:write(new_content)
    f:close()
    return { type = "text", text = string.format("The file %s has been updated successfully.", path) }
end

return M
