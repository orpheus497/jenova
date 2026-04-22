-- tools/file_edit.lua — FileEditTool: Search & replace editing
-- Uses jenova.fs (C FFI) for reliable edit operations.
-- Falls back to pure-Lua with whitespace-normalized matching.
-- Fuzzy match logic is shared with multiedit via utils/string.

local json         = require("utils.json_fallback")
local paths        = require("utils.paths")
local string_utils = require("utils.string")

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

-- Delegate fuzzy_find to shared utils/string module so the
-- logic stays identical with multiedit.lua.
local fuzzy_find  = string_utils.fuzzy_find

-- Write helper — extracted to avoid repeating open/write/close boilerplate
-- at every call site within M.call.
local function write_file(path, content)
    local wf = io.open(path, "w")
    if not wf then return false end
    wf:write(content)
    wf:close()
    return true
end
-- Build a diagnostic hint: show lines near the search position (or the head of the file).
local function build_hint(content, old_string)
    -- Common Lua/C keywords that appear too frequently to be useful anchors.
    local KEYWORDS = {
        ["local"]=true,["if"]=true,["then"]=true,["else"]=true,["elseif"]=true,
        ["end"]=true,["do"]=true,["while"]=true,["for"]=true,["in"]=true,
        ["return"]=true,["function"]=true,["and"]=true,["or"]=true,["not"]=true,
        ["true"]=true,["false"]=true,["nil"]=true,["repeat"]=true,["until"]=true,
        ["break"]=true,["goto"]=true,
    }
    -- Skip over common keywords; use the first substantive identifier
    local hint_pos = 1
    for word in old_string:gmatch("[%w_]+") do
        if not KEYWORDS[word:lower()] then
            local p = content:lower():find(word:lower(), 1, true)
            if p then hint_pos = p end
            break
        end
    end

    -- Extract up to 6 lines around hint_pos. Avoid building a full table of
    -- line starts for the entire file — for a multi-MB file that would
    -- allocate one entry per line just to render a 6-line snippet. Instead
    -- scan only the local window: a few lines before hint_pos and a few after.
    local CONTEXT_BEFORE = 2
    local CONTEXT_AFTER  = 3

    -- Find the start of the line containing hint_pos and walk back
    -- CONTEXT_BEFORE newlines.
    local clen = #content
    local from_pos = hint_pos
    local lines_back = 0
    while from_pos > 1 and lines_back <= CONTEXT_BEFORE do
        from_pos = from_pos - 1
        if content:byte(from_pos) == 10 then
            lines_back = lines_back + 1
            if lines_back > CONTEXT_BEFORE then
                from_pos = from_pos + 1
                break
            end
        end
    end
    if from_pos < 1 then from_pos = 1 end

    -- Walk forward CONTEXT_AFTER + 1 newlines past hint_pos to find the end.
    local to_pos = hint_pos
    local lines_fwd = 0
    while to_pos <= clen and lines_fwd <= CONTEXT_AFTER do
        if content:byte(to_pos) == 10 then
            lines_fwd = lines_fwd + 1
            if lines_fwd > CONTEXT_AFTER then
                to_pos = to_pos - 1
                break
            end
        end
        to_pos = to_pos + 1
    end
    if to_pos > clen then to_pos = clen end

    -- Compute the 1-based line number of from_pos by counting newlines in
    -- the prefix [1, from_pos). This is O(from_pos) but only runs once and
    -- is the only unavoidable cost of producing a true line number.
    local from_line = 1
    do
        local pfx = content:sub(1, from_pos - 1)
        for _ in pfx:gmatch("\n") do from_line = from_line + 1 end
    end

    local snippet_lines = {}
    local cur_line = from_line
    local line_start = from_pos
    for p = from_pos, to_pos do
        if content:byte(p) == 10 or p == to_pos then
            local line_end = (content:byte(p) == 10) and (p - 1) or p
            local line_text = content:sub(line_start, line_end)
            table.insert(snippet_lines, string.format("%4d| %s", cur_line, line_text))
            cur_line = cur_line + 1
            line_start = p + 1
        end
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
            local new_content = content:gsub(string_utils.escape_pattern(old), function()
                count = count + 1
                return new
            end)
            if count == 0 then
                local hint = build_hint(content, old)
                return { type = "error", error = string.format(
                    "old_string not found in %s.\n\nYou must Read the file and copy text exactly before calling Edit.\n\nNearest lines in file:\n%s",
                    path, hint) }
            end
            if not write_file(path, new_content) then
                return { type = "error", error = "Cannot write: " .. path }
            end
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
            if not write_file(path, new_content) then
                return { type = "error", error = "Cannot write: " .. path }
            end
            return { type = "text", text = string.format("Edited %s successfully.", path) }
        end

        -- Fuzzy fallback: CRLF + trailing-whitespace normalised match
        local start_orig, end_orig, multi = fuzzy_find(content, old)
        if multi then
            return { type = "error", error = "old_string matches multiple locations (normalised) — add more surrounding lines to make it unique." }
        end
        if start_orig and end_orig then
            local new_content = content:sub(1, start_orig - 1) .. new .. content:sub(end_orig + 1)
            if not write_file(path, new_content) then
                return { type = "error", error = "Cannot write: " .. path }
            end
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
