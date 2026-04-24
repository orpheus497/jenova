-- utils/string.lua — String utility functions

local M = {}

function M.trim(s)
    return s:match("^%s*(.-)%s*$")
end

function M.split(s, sep)
    local parts = {}
    for part in s:gmatch("([^" .. (sep or "%s") .. "]+)") do
        table.insert(parts, part)
    end
    return parts
end

function M.starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

function M.ends_with(s, suffix)
    return s:sub(-#suffix) == suffix
end

function M.pad_right(s, width, char)
    char = char or " "
    if #s >= width then return s end
    return s .. string.rep(char, width - #s)
end

function M.pad_left(s, width, char)
    char = char or " "
    if #s >= width then return s end
    return string.rep(char, width - #s) .. s
end

function M.truncate(s, max_len, suffix)
    suffix = suffix or "..."
    if #s <= max_len then return s end
    return s:sub(1, max_len - #suffix) .. suffix
end

function M.wrap(s, width)
    local lines = {}
    local line = ""
    for word in s:gmatch("%S+") do
        if #line + #word + 1 > width then
            table.insert(lines, line)
            line = word
        else
            line = #line > 0 and (line .. " " .. word) or word
        end
    end
    if #line > 0 then table.insert(lines, line) end
    return lines
end

function M.escape_pattern(s)
    return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

-- ── Edit helpers (shared by file_edit and multiedit) ─────────────────────────

-- Normalize a string for fuzzy edit comparison:
--   • CRLF / bare CR  →  LF
--   • trailing spaces/tabs stripped per line
function M.normalize_ws(s)
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    -- Iterate without appending a trailing "\n" copy of `s` (which would
    -- double the memory footprint on multi-MB files).  Walk newline
    -- positions with string.find and slice each line in place.
    local lines = {}
    local count = 0
    local pos = 1
    local slen = #s
    while pos <= slen + 1 do
        local nl = s:find("\n", pos, true)
        local ending = nl or (slen + 1)
        local line = s:sub(pos, ending - 1)
        -- Strip only spaces and tabs (not \v/\f) so the matcher's behaviour
        -- matches the comment above and so vertical-tab/form-feed bytes are
        -- preserved as-is in the file.
        count = count + 1
        lines[count] = (line:gsub("[ \t]+$", ""))
        if not nl then break end
        pos = nl + 1
    end
    -- if lines[#lines] == "" then table.remove(lines) end
    return table.concat(lines, "\n")
end

-- Try to find `old_string` inside `content` using whitespace-normalised
-- comparison. Returns (start_orig, end_orig, multi) where:
--   start_orig, end_orig  — byte offsets in the *original* content string
--   multi                 — true when the match is not unique (normalised)
-- Returns nil when no match is found at all.
function M.fuzzy_find(content, old_string)
    local nc = M.normalize_ws(content)
    local no = M.normalize_ws(old_string)
    if #no == 0 then return nil end

    local pos = nc:find(no, 1, true)
    if not pos then return nil end

    -- Uniqueness check in normalised space
    if nc:find(no, pos + 1, true) then
        return nil, nil, true
    end

    -- Walk both strings in lockstep, but only record the two orig offsets we
    -- actually need (start and end of the match) instead of building a full
    -- normalized→original byte map.  The previous implementation allocated
    -- one table entry per normalized byte, which is wasteful for large files.
    local end_norm   = pos + #no - 1
    local start_orig = nil
    local end_orig   = nil

    local ni = 1
    local oi = 1
    local olen = #content
    local nlen = #nc

    while oi <= olen and ni <= nlen do
        if ni == pos then start_orig = oi end

        local ob = content:byte(oi)
        local mapped_oi = oi  -- the original byte that this norm byte maps to

        if ob == 13 and content:byte(oi + 1) == 10 then
            -- \r\n → \n in normalized form. Cover both bytes when the match
            -- includes this newline:
            --   • start_orig must point to the \r (oi) so the prefix doesn't
            --     leave a stray \r before the replacement.
            --   • end_orig must point to the \n (oi+1) so the suffix begins
            --     after both bytes.
            if ni == pos then start_orig = oi end
            if ni == end_norm then end_orig = oi + 1 end
            oi = oi + 2
            ni = ni + 1
        elseif ob == 32 or ob == 9 then
            -- Possibly trailing whitespace stripped by normaliser.
            local oi2 = oi
            while oi2 <= olen and (content:byte(oi2) == 32 or content:byte(oi2) == 9) do
                oi2 = oi2 + 1
            end
            local next_ob = content:byte(oi2)
            if next_ob == nil or next_ob == 10 or next_ob == 13 then
                -- Trailing whitespace: skip in original without advancing norm.
                -- Loop will re-enter at same ni and reassign start_orig if needed.
                oi = oi2
            else
                if ni == end_norm then end_orig = mapped_oi end
                oi = oi + 1
                ni = ni + 1
            end
        else
            if ni == end_norm then end_orig = mapped_oi end
            oi = oi + 1
            ni = ni + 1
        end

        -- Stop once we've finalized end_orig (and start_orig must already be set
        -- because pos <= end_norm).
        if end_orig then break end
    end

    if not start_orig or not end_orig then return nil end

    -- Extend end_orig to cover any trailing spaces before newline that the
    -- normaliser stripped but belong to the matched span.
    local eo2 = end_orig
    if eo2 + 1 <= olen then
        local probe = eo2 + 1
        while probe <= olen and (content:byte(probe) == 32 or content:byte(probe) == 9) do
            probe = probe + 1
        end
        if content:byte(probe) == 10 or content:byte(probe) == 13 then
            eo2 = probe - 1
        end
    end

    return start_orig, eo2, false
end

function M.count(s, sub)
    local count = 0
    local start = 1
    while true do
        local pos = s:find(sub, start, true)
        if not pos then break end
        count = count + 1
        start = pos + 1
    end
    return count
end

return M
