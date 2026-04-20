-- tools/glob.lua — GlobTool: Find files by pattern
-- Uses jenova.fs.glob (Rust FFI) for fast globbing with globset.

local json = require("utils.json_fallback")
local paths = require("utils.paths")

local M = {}
M.name = "Glob"
M.description = "Fast file pattern matching tool. Supports glob patterns like '**/*.lua' or 'src/**/*.rs'. Returns matching file paths sorted lexicographically."

M.input_schema = {
    type = "object",
    properties = {
        pattern = { type = "string", description = "The glob pattern to match files against" },
        path = { type = "string", description = "The directory to search in (default: current directory)" },
    },
    required = { "pattern" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    return input and input.pattern and ("Glob: " .. input.pattern) or "Glob"
end

function M.check_permissions(input, ctx) return { allowed = true } end

function M.call(args, context)
    local pattern = args.pattern
    if not pattern then return { type = "error", error = "No pattern provided" } end

    local dir = args.path or (context and context.cwd) or "."
    if paths.is_restricted(dir) then return paths.restricted_error(dir) end

    -- Use Rust FFI (preferred)
    if jenova and jenova.fs and jenova.fs.glob then
        local result_json = jenova.fs.glob(pattern, dir, 500)
        if result_json then
            local ok, files = pcall(json.parse, result_json)
            if ok then
                if type(files) == "table" and files.error then
                    return { type = "error", error = files.error }
                end
                if type(files) == "table" then
                    return {
                        type = "text",
                        text = table.concat(files, "\n"),
                        num_files = #files,
                    }
                end
            end
        end
    end

    -- Fallback: use find command
    -- Convert glob pattern to find-compatible pattern
    local shell = require("utils.shell")
    local find_pattern = pattern:gsub("%*%*", "*")
    local cmd = string.format(
        "find %s -path %s -not -path '*/.jenova/*' -not -path '*/.claude/*' -type f 2>/dev/null | sort | head -500",
        shell.quote(dir),
        shell.quote(find_pattern)
    )
    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Glob failed" } end
    local output = h:read("*a")
    h:close()

    local files = {}
    for line in output:gmatch("[^\n]+") do table.insert(files, line) end

    return {
        type = "text",
        text = table.concat(files, "\n"),
        num_files = #files,
    }
end

return M
