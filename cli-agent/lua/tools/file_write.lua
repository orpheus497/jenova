-- tools/file_write.lua — FileWriteTool: Write/create files
-- Uses jenova.fs (Rust FFI) for file writing with parent directory creation.

local M = {}
M.name = "Write"

local paths = require("utils.paths")
M.description = "Write content to a file, creating it and parent directories if they don't exist. Overwrites existing files."

M.parameters = {
    type = "object",
    properties = {
        file_path = { type = "string", description = "Absolute path to the file to write" },
        content = { type = "string", description = "The content to write to the file" },
    },
    required = { "file_path", "content" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end

function M.user_facing_name(input)
    return input and input.file_path and ("Write: " .. input.file_path) or "Write"
end

function M.check_permissions(input, ctx) return { allowed = true } end

function M.call(args, context)
    local path = args.file_path
    local content = args.content
    if not path then return { type = "error", error = "No file path provided" } end
    if not content then return { type = "error", error = "No content provided" } end
    if paths.is_restricted(path) then return paths.restricted_error(path) end

    -- Use Rust FFI (preferred — handles mkdir -p)
    if jenova and jenova.fs and jenova.fs.write then
        local ok = jenova.fs.write(path, content)
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
        -- Prefer jenova.fs.mkdir or fs_fallback over raw shell to avoid injection
        local mkdir_ok = false
        if jenova and jenova.fs and jenova.fs.mkdir then
            mkdir_ok = jenova.fs.mkdir(dir)
        else
            local has_fb, fs_fb = pcall(require, "utils.fs_fallback")
            if has_fb and fs_fb and fs_fb.mkdir then
                mkdir_ok = fs_fb.mkdir(dir)
            end
        end
        if not mkdir_ok then
            return { type = "error", error = "Cannot create parent directory: " .. dir }
        end
    end

    local f = io.open(path, "w")
    if not f then return { type = "error", error = "Cannot write: " .. path } end
    f:write(content)
    f:close()

    return {
        type = "text",
        text = string.format("File created successfully at: %s", path),
    }
end

return M
