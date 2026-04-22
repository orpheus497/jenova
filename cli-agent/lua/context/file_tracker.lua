-- context/file_tracker.lua — Git-like file state awareness
--
-- Tracks files the agent has touched during a session using mtime + size as a
-- cheap "has this changed?" signal (same approach git uses for its index before
-- doing a full hash). A CRC32/djb2 content hash is added on first read so that
-- cache invalidation on subsequent reads is reliable even when mtime resolution
-- is coarse (FAT32: 2s, some NFS mounts: various).
--
-- The tracker is intentionally lightweight:
--   • No background threads — everything is synchronous and on-demand.
--   • No persistent storage — lives only for the duration of one agent session.
--   • No recursive directory watching — tracks individual files as they are
--     read/written by the tool execution layer.
--
-- Usage:
--   local ft = require("context.file_tracker")
--   ft.record_read("/abs/path/file.lua", content_string)
--   ft.record_write("/abs/path/file.lua", new_content_string)
--   if ft.is_stale("/abs/path/file.lua") then ... end
--   local entry = ft.get("/abs/path/file.lua")
--   -- entry: { path, mtime, size, hash, last_op, ts }

local M = {}

-- ── Internal store ──────────────────────────────────────────────────────────

-- Map: absolute_path → { path, mtime, size, hash, last_op, ts }
local _entries = {}

-- ── Hash helper (djb2 — fast, no C dependency) ──────────────────────────────

local function djb2(s)
    local h = 5381
    for i = 1, #s do
        -- h = h * 33 + byte(i), kept within 32-bit range via modulo
        h = (h * 33 + s:byte(i)) % 0x100000000
    end
    return h
end

-- ── Stat helper (mtime + size via sh stat) ───────────────────────────────────
-- Returns mtime_unix (integer), size_bytes (integer), or nil, nil on failure.
-- Uses POSIX stat(1) syntax common to BSD and Linux with a portable format.

local function stat_file(path)
    -- Try BSD stat first (FreeBSD/macOS), then GNU/Linux stat
    -- BSD:   stat -f "%m %z" <path>
    -- Linux: stat -c "%Y %s" <path>
    -- We probe both and take whichever succeeds.
    local function try(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if not h then return nil, nil end
        local line = h:read("*l")
        h:close()
        if not line or line == "" then return nil, nil end
        local mt, sz = line:match("^(%d+)%s+(%d+)$")
        if mt then return tonumber(mt), tonumber(sz) end
        return nil, nil
    end

    -- Build path quoted for shell
    local q = "'" .. path:gsub("'", "'\\''") .. "'"

    local mt, sz = try("stat -f '%m %z' " .. q)
    if mt then return mt, sz end
    mt, sz = try("stat -c '%Y %s' " .. q)
    return mt, sz
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Record that the agent read `path` and got `content`.
--- Stores mtime, size, hash and marks last_op = "read".
function M.record_read(path, content)
    if not path then return end
    local mtime, size = stat_file(path)
    local hash = content and djb2(content) or nil
    _entries[path] = {
        path     = path,
        mtime    = mtime,
        size     = size,
        hash     = hash,
        last_op  = "read",
        ts       = os.time(),
    }
end

--- Record that the agent wrote `path` with `content`.
--- Refreshes stat info so subsequent is_stale() calls work correctly.
function M.record_write(path, content)
    if not path then return end
    local mtime, size = stat_file(path)
    local hash = content and djb2(content) or nil
    _entries[path] = {
        path     = path,
        mtime    = mtime,
        size     = size,
        hash     = hash,
        last_op  = "write",
        ts       = os.time(),
    }
end

--- Invalidate a tracked file (removes its entry so next read is treated as fresh).
function M.invalidate(path)
    if path then _entries[path] = nil end
end

--- Get the tracked entry for `path`, or nil if not tracked.
function M.get(path)
    return path and _entries[path] or nil
end

--- Check whether `path` has changed on disk since it was last recorded.
--- Returns true if:
---   • The file is not tracked (never read — conservatively stale).
---   • mtime changed.
---   • size changed.
--- Returns false (not stale) when mtime AND size are identical.
--- Callers that want content-level accuracy can compare hashes after re-reading.
function M.is_stale(path)
    if not path then return true end
    local entry = _entries[path]
    if not entry then return true end
    if not entry.mtime then return true end

    local cur_mt, cur_sz = stat_file(path)
    if not cur_mt then return true end

    return (cur_mt ~= entry.mtime) or (cur_sz ~= entry.size)
end

--- Compare the given `content` against the stored hash for `path`.
--- Returns true if content differs from what was last recorded (or not tracked).
function M.content_changed(path, content)
    if not path or not content then return true end
    local entry = _entries[path]
    if not entry or not entry.hash then return true end
    return djb2(content) ~= entry.hash
end

--- Return all tracked paths as a sorted list.
function M.tracked_paths()
    local paths = {}
    for p in pairs(_entries) do
        table.insert(paths, p)
    end
    table.sort(paths)
    return paths
end

--- Return a compact summary string for diagnostic use (e.g. /diag, /context).
function M.summary()
    local parts = {}
    for path, e in pairs(_entries) do
        local stale = M.is_stale(path) and " [STALE]" or ""
        table.insert(parts, string.format("  %s  op=%s  ts=%s%s",
            path, e.last_op or "?", os.date("%H:%M:%S", e.ts or 0), stale))
    end
    table.sort(parts)
    if #parts == 0 then return "(no files tracked)" end
    return table.concat(parts, "\n")
end

--- Clear all tracked state (called on /clear).
function M.reset()
    _entries = {}
end

return M
