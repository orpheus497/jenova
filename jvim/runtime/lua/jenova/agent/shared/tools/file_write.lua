-- tools/file_write.lua — FileWriteTool: Write/create files
-- Uses jenova.fs (C FFI) for file writing with parent directory creation.

local M = {}
M.name = "Write"

local paths = require("utils.paths")
M.description = "Write content to a file, creating it and parent directories if they don't exist. Supports both absolute and relative paths. Overwrites existing files."

M.parameters = {
    type = "object",
    properties = {
        file_path = { type = "string", description = "Path to the file to write (absolute or relative to working directory)" },
        content = { type = "string", description = "The content to write to the file" },
    },
    required = { "file_path", "content" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
    return input and input.file_path and ("Write: " .. input.file_path) or "Write"
end

function M.check_permissions(input, ctx)
    local ok_mgr, manager = pcall(require, "permissions.manager")
    if not ok_mgr or not manager or not manager.can_use_tool then
        return { allowed = true }
    end
    local allowed, reason = manager.can_use_tool("Write", input, ctx or {})
    return { allowed = allowed, reason = reason }
end

function M.call(args, context)
    local path = args.file_path
    local content = args.content
    if not path then return { type = "error", error = "No file path provided" } end
    if not content then return { type = "error", error = "No content provided" } end
    -- Resolve relative paths against the session working directory
    path = paths.resolve(path, context and context.cwd)
    if paths.is_restricted(path) then return paths.restricted_error(path) end

    -- Use C FFI (preferred — handles mkdir -p)
    local _jenova_ffi = rawget(_G, "jenova")
    if type(_jenova_ffi) == "table" and _jenova_ffi.fs and _jenova_ffi.fs.write then
        local ok = _jenova_ffi.fs.write(path, content)
        if ok then
            return {
                type = "text",
                text = string.format("File created successfully at: %s", path),
            }
        end
    end

    -- Fallback: ensure parent dir and write. Match either forward or back
    -- slashes as separators so Windows paths like `C:\foo\bar.txt` resolve
    -- their parent directory correctly.
    local dir = path:match("^(.*)[/\\][^/\\]+$")
    if dir and #dir > 0 then
        -- Prefer jenova.fs.mkdir or fs_fallback over raw shell to avoid injection.
        -- Ignore mkdir failure: directory may already exist. The io.open below
        -- will surface a real error if the path is truly inaccessible.
        local _jenova = rawget(_G, "jenova")
        if type(_jenova) == "table" and _jenova.fs and _jenova.fs.mkdir then
            _jenova.fs.mkdir(dir)
        else
            local has_fb, fs_fb = pcall(require, "utils.fs_fallback")
            if has_fb and fs_fb and fs_fb.mkdir then
                fs_fb.mkdir(dir)
            else
                local shell = require("utils.shell")
                os.execute("mkdir -p " .. shell.quote(dir) .. " 2>/dev/null")
            end
        end
    end

    local f = io.open(path, "w")
    if not f then return { type = "error", error = "Cannot write to: " .. path .. " — check the path and parent directory exist." } end
    f:write(content)
    f:close()

    return {
        type = "text",
        text = string.format("File created successfully at: %s", path),
    }
end

return M
