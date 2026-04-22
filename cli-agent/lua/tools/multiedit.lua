-- tools/multiedit.lua — MultiEditTool: Apply several sequential edits to one file
-- Lets the model batch all edits for a file into one call instead of repeated
-- single-Edit calls (which create a retry-loop hazard on small models).
-- Each edit in the array is applied in order on the result of the previous one.
-- Fuzzy whitespace matching is shared with file_edit via utils/string.

local paths       = require("utils.paths")
local string_utils = require("utils.string")

local M = {}
M.name = "MultiEdit"
M.description = "Apply multiple sequential find-and-replace edits to a single file in one operation. You MUST Read the file first. Each edit's old_string is matched against the current file state after prior edits."

M.parameters = {
    type = "object",
    properties = {
        file_path = {
            type = "string",
            description = "Path to the file to edit (absolute or relative to working directory)",
        },
        edits = {
            type = "array",
            description = "Array of edit operations applied in order",
            items = {
                type = "object",
                properties = {
                    old_string  = { type = "string", description = "Exact text to find (must be unique at time of replacement)" },
                    new_string  = { type = "string", description = "Replacement text" },
                    replace_all = { type = "boolean", description = "Replace all occurrences (default: false)" },
                },
                required = { "old_string", "new_string" },
            },
        },
    },
    required = { "file_path", "edits" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
    local n  = type(input) == "table" and type(input.edits) == "table" and #input.edits or "?"
    local fp = type(input) == "table" and input.file_path or ""
    return string.format("MultiEdit(%s): %s edits", fp, tostring(n))
end

function M.check_permissions(input, ctx)
    local ok_mgr, manager = pcall(require, "permissions.manager")
    if not ok_mgr or not manager or not manager.can_use_tool then
        return { allowed = true }
    end
    local allowed, reason = manager.can_use_tool("MultiEdit", input, ctx or {})
    return { allowed = allowed, reason = reason }
end

-- Apply a single edit to `content`.  Returns (new_content, err, count).
local function apply_one(content, old, new, replace_all)
    -- 1. Exact byte match
    local pos = content:find(old, 1, true)
    if pos then
        if replace_all then
            local count = 0
            local new_content = content:gsub(string_utils.escape_pattern(old), function()
                count = count + 1; return new
            end)
            return new_content, nil, count
        end
        local second = content:find(old, pos + 1, true)
        if second then
            return nil, "old_string matches multiple locations — add more context to make it unique"
        end
        return content:sub(1, pos - 1) .. new .. content:sub(pos + #old), nil, 1
    end

    -- 2. Normalised fallback (shared logic with file_edit)
    local start_orig, end_orig, multi = string_utils.fuzzy_find(content, old)
    if multi then
        return nil, "old_string matches multiple locations (normalised) — add more context to make it unique"
    end
    if not start_orig then
        return nil, "old_string not found — Read the file and copy the exact text"
    end
    return content:sub(1, start_orig - 1) .. new .. content:sub(end_orig + 1), nil, 1
end

function M.call(args, context)
    local path = args.file_path
    if not path then return { type = "error", error = "No file_path provided" } end
    local edits = args.edits
    if type(edits) ~= "table" or #edits == 0 then
        return { type = "error", error = "edits array is empty or missing" }
    end

    path = paths.resolve(path, context and context.cwd)
    if paths.is_restricted(path) then
        return { type = "error", error = "Access denied: " .. path }
    end

    local f = io.open(path, "r")
    if not f then
        return { type = "error", error = "Cannot read file: " .. path .. " — use Glob to verify it exists" }
    end
    local content = f:read("*a")
    f:close()

    local applied = 0
    local failed  = {}

    -- Dry-run pass: validate ALL edits against the current content before
    -- writing anything. This makes the operation atomic — either all edits
    -- succeed and the file is written once, or none are applied.
    local dry_content = content
    for i, edit in ipairs(edits) do
        local old = edit.old_string
        local new = edit.new_string
        if type(old) ~= "string" or type(new) ~= "string" then
            table.insert(failed, string.format("edit[%d]: old_string and new_string must be strings", i))
        elseif old == new then
            table.insert(failed, string.format("edit[%d]: old_string == new_string, skipped", i))
        else
            local result, err = apply_one(dry_content, old, new, edit.replace_all)
            if err then
                table.insert(failed, string.format("edit[%d]: %s", i, err))
            else
                dry_content = result
                applied = applied + 1
            end
        end
    end

    if #failed > 0 then
        local msg = string.format("%d/%d edits failed — file NOT modified (atomic):\n", #failed, #edits)
            .. table.concat(failed, "\n")
        return { type = "error", error = msg }
    end

    if applied == 0 then
        return { type = "error", error = "No edits applied." }
    end

    -- All edits validated — write the result once.
    content = dry_content

    local wf = io.open(path, "w")
    if not wf then
        return { type = "error", error = "Cannot write: " .. path }
    end
    wf:write(content)
    wf:close()

    return { type = "text", text = string.format("MultiEdit %s: %d/%d edits applied.", path, applied, #edits) }
end

return M
