-- tools/file_read.lua — FileReadTool: Read file contents
-- Pure-Lua implementation: emits "<line_no>\t<line>" for each line, honoring
-- offset (lines to skip, 0-based) and limit (max lines to return, default 2000).

local M = {}
M.name = "Read"
M.description = "Read the contents of a file from the filesystem. Results are returned with line numbers."

M.input_schema = {
    type = "object",
    properties = {
        file_path = { type = "string", description = "The absolute path to the file to read" },
        offset = { type = "integer", description = "Number of lines to skip from the start (0-based)" },
        limit = { type = "integer", description = "Number of lines to read (default: 2000)" },
    },
    required = { "file_path" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    return input and input.file_path and ("Read: " .. input.file_path) or "Read"
end

function M.check_permissions(input, ctx) return { allowed = true } end

function M.call(args, context)
    local path = args.file_path
    if not path then return { type = "error", error = "No file path provided" } end

    -- Pure-Lua reader: keeps the line-number format ("%d\t%s") consistent
    -- regardless of whether the FFI layer is available. The C jenova.fs.read
    -- produces "%6d|%s" output which would diverge from the fallback path.
    local f = io.open(path, "r")
    if not f then return { type = "error", error = "Cannot open: " .. path } end

    local lines = {}
    local n = 0
    local offset = args.offset or 0
    local limit = args.limit or 2000

    -- offset is documented as "lines to skip (0-based)", so with offset=0 we
    -- emit line 1 onward and with offset=1 we skip line 1 and start at
    -- line 2. That means we include a line once its 1-based index `n`
    -- exceeds `offset` (i.e. n >= offset + 1).
    local truncated = false
    for line in f:lines() do
        n = n + 1
        if n >= offset + 1 then
            if #lines < limit then
                table.insert(lines, string.format("%d\t%s", n, line))
            else
                truncated = true
                break
            end
        end
    end
    f:close()

    return {
        type = "text",
        text = table.concat(lines, "\n"),
        num_lines = n,
        truncated = truncated,
    }
end

return M
