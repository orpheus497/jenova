-- tools/grep.lua — GrepTool: Search file contents
-- Uses jenova.fs.grep (Rust FFI) or falls back to ripgrep/grep.

local json = require("utils.json_fallback")
local paths = require("utils.paths")

local M = {}
M.name = "Grep"
M.description = "Search for a pattern in file contents. Supports regex patterns. Returns matching lines with file paths and line numbers."

M.parameters = {
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

    local dir = paths.resolve(args.path or ".", context and context.cwd)
    if not args.path then dir = (context and context.cwd) or "." end
    local file_glob = args.glob or args.include
    if paths.is_restricted(dir) then return paths.restricted_error(dir) end

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
                            local lnum = tonumber(m.line_number) or 0
                            table.insert(lines, string.format("%s:%d:%s", m.file or "?", lnum, m.content or ""))
                        end
                        return { type = "text", text = table.concat(lines, "\n") }
                    end
                end
            end
        end
    end

    -- Fallback: use ripgrep or POSIX grep (BSD/FreeBSD compatible)
    -- Pattern already has (?i) prefix if -i was set, so don't pass -i again.
    local shell = require("utils.shell")
    local cmd
    -- Probe for rg portably via sh (os.execute return semantics differ by platform)
    local rg_probe = io.popen("command -v rg 2>/dev/null")
    local has_rg = rg_probe and (rg_probe:read("*l") or "") ~= ""
    if rg_probe then rg_probe:close() end
    if has_rg then
        cmd = string.format("rg --line-number --no-heading -- %s %s",
            shell.quote(pattern), shell.quote(dir))
        if file_glob then
            cmd = cmd .. " --glob " .. shell.quote(file_glob)
        end
        cmd = cmd .. " 2>/dev/null"
    else
        -- POSIX grep via find+xargs: avoids GNU-only --exclude-dir
        local include_filter = ""
        if file_glob then
            include_filter = " -name " .. shell.quote(file_glob)
        end
        cmd = string.format(
            "find %s%s -not -path '*/.git/*' -not -path '*/.jenova/*' -not -path '*/.claude/*'" ..
            " -type f 2>/dev/null | xargs grep -En -- %s 2>/dev/null",
            shell.quote(dir), include_filter, shell.quote(pattern))
    end

    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Grep failed" } end
    local lines = {}
    for line in h:lines() do
        table.insert(lines, line)
        if #lines >= 200 then break end
    end
    h:close()

    local output = table.concat(lines, "\n")
    if #output == 0 then
        return { type = "text", text = "No matches found for pattern: " .. (args.pattern or "") }
    end
    return { type = "text", text = output }
end

return M
