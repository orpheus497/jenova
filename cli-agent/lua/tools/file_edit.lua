-- tools/file_edit.lua — FileEditTool: Search & replace editing
-- Uses jenova.fs (C FFI) for reliable edit operations.
-- Falls back to pure-Lua with whitespace-normalized matching.

local json = require("utils.json_fallback")
local paths = require("utils.paths")

local M = {}
M.name = "Edit"
M.description = "Edit a file by replacing an exact string match with new content. You MUST Read the file before calling Edit so your old_string matches exactly. The old_string must be unique in the file."

M.parameters = {
    type = "object",
    properties = {
        file_path = { type = "string", description = "Path to the file to edit (absolute or relative to working directory)" },
        old_string = { type = "string", description = "The exact text to find and replace. Must match the file byte-for-byte. Read the file first." },
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
        return { allowed = true }
    end
    local allowed, reason = manager.can_use_tool("Edit", input, ctx or {})
    return { allowed = allowed, reason = reason }
end

-- Normalize a string for fuzzy comparison:
--   • CRLF → LF
--   • trailing spaces stripped per line
local function normalize(s)
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, (line:gsub("%s+$", "")))
    end
    -- Remove trailing empty line added by the loop sentinel
    if lines[#lines] == "" then table.remove(lines) end
    return table.concat(lines, "\n")
end

-- Try to find old_string in content with CRLF + trailing-space normalisation.
-- Returns the start/end byte offsets in the *original* content, or nil.
local function fuzzy_find(content, old_string)
    local nc = normalize(content)
    local no = normalize(old_string)
    local pos = nc:find(no, 1, true)
    if not pos then return nil end

    -- Map byte position in normalised string back to original content.
    -- Build a cumulative map: normalised_pos[i] = original_pos[i]
    -- This is O(n) and only runs on mismatch, so it's acceptable.
    local orig_pos = {}  -- orig_pos[norm_byte] = orig_byte
    local ni = 1
    local oi = 1
    local olen = #content
    local nlen = #nc
    while oi <= olen and ni <= nlen do
        local ob = content:byte(oi)
        local nb = nc:byte(ni)
        orig_pos[ni] = oi
        if ob == 13 and content:byte(oi + 1) == 10 then
            -- CRLF in original maps to LF in normalised
            oi = oi + 2
        elseif ob == 32 or ob == 9 then
            -- Possible trailing space — check if normalised consumed it
            if nb == 10 then
                -- normalised moved to newline, skip spaces in original
                while oi <= olen and (content:byte(oi) == 32 or content:byte(oi) == 9) do
                    oi = oi + 1
                end
            else
                oi = oi + 1
            end
        else
            oi = oi + 1
        end
        ni = ni + 1
    end

    local start_orig = orig_pos[pos]
    if not start_orig then return nil end

    -- The replacement span in original ends where normalised match ends.
    local end_norm = pos + #no - 1
    local end_orig = orig_pos[end_norm]
    if not end_orig then return nil end

    return start_orig, end_orig
end

-- Build a diagnostic hint: show lines near the search position (or the head of the file).
local function build_hint(content, old_string)
    -- Find the first word of old_string in the file for context
    local first_word = old_string:match("[%w_]+")
    local hint_pos = 1
    if first_word then
        local p = content:lower():find(first_word:lower(), 1, true)
        if p then hint_pos = p end
    end

    -- Extract up to 6 lines around hint_pos
    local line_starts = {1}
    for pos in content:gmatch("()\n") do
        table.insert(line_starts, pos + 1)
    end

    -- Find which line hint_pos is on
    local target_line = 1
    for i, ls in ipairs(line_starts) do
        if ls <= hint_pos then target_line = i end
    end

    local from_line = math.max(1, target_line - 2)
    local to_line   = math.min(#line_starts, target_line + 3)

    local snippet_lines = {}
    for li = from_line, to_line do
        local ls = line_starts[li]
        local le = (line_starts[li + 1] or (#content + 2)) - 2
        local line_text = content:sub(ls, le)
        table.insert(snippet_lines, string.format("%4d| %s", li, line_text))
    end

    return table.concat(snippet_lines, "\n")
end

function M.call(args, context)
    local path = args.file_path
    if not path then return { type = "error", error = "No file_path provided" } end
    if args.old_string == nil then return { type = "error", error = "No old_string provided" } end
    if args.new_string == nil then return { type = "error", error = "No new_string provided" } end
    if args.old_string == args.new_string then
        return { type = "error", error = "old_string and new_string are identical — no change needed" }
    end

    path = paths.resolve(path, context and context.cwd)
    if paths.is_restricted(path) then
        return { type = "error", error = "Access denied: cannot edit restricted path " .. path }
    end

    -- Attempt C FFI edit first (fast, handles mkdir, OS-native)
    if jenova and jenova.fs and jenova.fs.edit then
        local replace_all = args.replace_all and 1 or 0
        local result_json = jenova.fs.edit(path, args.old_string, args.new_string, replace_all)
        if result_json then
            local ok, result = pcall(json.parse, result_json)
            if ok and result then
                if result.error then
                    -- Fall through to Lua fallback on any FFI error
                    goto lua_fallback
                end
                return {
                    type = "text",
                    text = string.format("Edited %s successfully.", path),
                }
            end
        end
    end

    ::lua_fallback::
    do
        local f = io.open(path, "r")
        if not f then
            return { type = "error", error = string.format(
                "Cannot read file: %s\nUse Glob to confirm the path exists.", path) }
        end
        local content = f:read("*a")
        f:close()

        local old = args.old_string
        local new = args.new_string

        if args.replace_all then
            local count = 0
            local escape_pattern = require("utils.string").escape_pattern
            local new_content = content:gsub(escape_pattern(old), function()
                count = count + 1
                return new
            end)
            if count == 0 then
                local hint = build_hint(content, old)
                return { type = "error", error = string.format(
                    "old_string not found in %s.\n\nYou must Read the file and copy text exactly before calling Edit.\n\nNearest lines in file:\n%s",
                    path, hint) }
            end
            local wf = io.open(path, "w")
            if not wf then return { type = "error", error = "Cannot write: " .. path } end
            wf:write(new_content)
            wf:close()
            return { type = "text", text = string.format("Edited %s — replaced %d occurrence(s).", path, count) }
        end

        -- Single replacement: exact match first
        local pos = content:find(old, 1, true)
        if pos then
            local second = content:find(old, pos + 1, true)
            if second then
                return { type = "error", error = "old_string matches multiple locations — add more surrounding lines to make it unique." }
            end
            local new_content = content:sub(1, pos - 1) .. new .. content:sub(pos + #old)
            local wf = io.open(path, "w")
            if not wf then return { type = "error", error = "Cannot write: " .. path } end
            wf:write(new_content)
            wf:close()
            return { type = "text", text = string.format("Edited %s successfully.", path) }
        end

        -- Fuzzy fallback: CRLF + trailing-whitespace normalised match
        local start_orig, end_orig = fuzzy_find(content, old)
        if start_orig and end_orig then
            local new_content = content:sub(1, start_orig - 1) .. new .. content:sub(end_orig + 1)
            local wf = io.open(path, "w")
            if not wf then return { type = "error", error = "Cannot write: " .. path } end
            wf:write(new_content)
            wf:close()
            return { type = "text", text = string.format("Edited %s (whitespace-normalised match).", path) }
        end

        -- Total failure: give a rich diagnostic
        local hint = build_hint(content, old)
        return { type = "error", error = string.format(
            "old_string not found in %s.\n\nRead the file first, then copy the exact text you want to replace.\n\nNearest matching region:\n%s",
            path, hint) }
    end
end

return M
