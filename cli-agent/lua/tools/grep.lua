-- tools/grep.lua — GrepTool: Search file contents
-- Uses jenova.fs.grep (Rust FFI) or falls back to ripgrep/grep.

local json = require("utils.json_fallback")

local M = {}
M.name = "Grep"
M.description = "Search for a pattern in file contents. Supports regex patterns. Returns matching lines with file paths and line numbers."

M.input_schema = {
    type = "object",
    properties = {
        pattern = { type = "string", description = "The regular expression pattern to search for" },
        path = { type = "string", description = "File or directory to search in (default: current directory)" },
        glob = { type = "string", description = "Glob pattern to filter files (e.g., '*.lua', '*.rs')" },
        output_mode = {
            type = "string",
            description = "Output mode: 'content' (matching lines), 'files_with_matches' (file paths only), 'count'",
        },
        ["-i"] = { type = "boolean", description = "Case insensitive search" },
    },
    required = { "pattern" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    return input and input.pattern and ("Grep: " .. input.pattern) or "Grep"
end

function M.check_permissions(input, ctx) return { allowed = true } end

function M.call(args, context)
    local pattern = args.pattern
    if not pattern then return { type = "error", error = "No pattern provided" } end

    -- Handle case-insensitive flag by prepending (?i) to the regex —
    -- Rust's `regex` crate supports inline flags, as do ripgrep and grep.
    if args["-i"] then
        pattern = "(?i)" .. pattern
    end

    local dir = args.path or (context and context.cwd) or "."
    local file_glob = args.glob or args.include

    -- Use Rust FFI (preferred)
    if jenova and jenova.fs and jenova.fs.grep then
        local result_json = jenova.fs.grep(pattern, dir, file_glob, 200)
        if result_json then
            local ok, matches = pcall(json.parse, result_json)
            if ok then
                if type(matches) == "table" and matches.error then
                    return { type = "error", error = matches.error }
                end
                if type(matches) == "table" then
                    local mode = args.output_mode or "content"
                    if mode == "files_with_matches" then
                        local seen = {}
                        local files = {}
                        for _, m in ipairs(matches) do
                            if not seen[m.file] then
                                seen[m.file] = true
                                table.insert(files, m.file)
                            end
                        end
                        return { type = "text", text = table.concat(files, "\n") }
                    elseif mode == "count" then
                        return { type = "text", text = tostring(#matches) }
                    else
                        local lines = {}
                        for _, m in ipairs(matches) do
                            table.insert(lines, string.format("%s:%d:%s", m.file, m.line_number, m.content))
                        end
                        return { type = "text", text = table.concat(lines, "\n") }
                    end
                end
            end
        end
    end

    -- Fallback: use ripgrep or grep
    -- Pattern already has (?i) prefix if -i was set, so don't pass -i again.
    local shell = require("utils.shell")
    local cmd
    if os.execute("command -v rg >/dev/null 2>&1") then
        cmd = string.format("rg --line-number --no-heading -- %s %s",
            shell.quote(pattern), shell.quote(dir))
        if file_glob then
            cmd = cmd .. " --glob " .. shell.quote(file_glob)
        end
    else
        cmd = string.format("grep -Prn -- %s %s",
            shell.quote(pattern), shell.quote(dir))
    end
    cmd = cmd .. " 2>/dev/null"

    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Grep failed" } end
    local lines = {}
    for line in h:lines() do
        table.insert(lines, line)
        if #lines >= 200 then break end
    end
    h:close()

    local output = table.concat(lines, "\n")
    return { type = "text", text = output }
end

return M
