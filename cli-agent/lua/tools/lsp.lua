-- tools/lsp.lua — LSP Tool: Language Server Protocol diagnostics & actions

local json = require("utils.json_fallback")

local M = {}
M.name = "LSP"
M.description = "Get diagnostics, definitions, or references from a language server."

-- ── Argv-based execution helpers ─────────────────────────────────────
-- The fallback paths used to build shell command strings via string.format
-- with %q, which only escapes for *Lua* string literals — not for shells.
-- Filenames containing $(...), backticks, semicolons or newlines could
-- inject arbitrary commands. The helpers below avoid the shell entirely:
--   * `_run_argv` prefers jenova.process.spawn with an explicit args array
--     (cmd + args, no shell), which works on both POSIX and Windows.
--   * On hosts without the FFI we fall back to a strict POSIX
--     single-quote escape just for io.popen, which is still safer than %q
--     and only used when the FFI bridge isn't compiled in.

local shell = require("utils.shell")

local function _shell_quote(s)
    return shell.quote(s)
end

-- Run an executable with an argv array and return its combined output.
-- Returns (output_string, exit_code). When the FFI bridge is unavailable
-- we fall back to io.popen with a properly quoted command line.
local function _run_argv(cmd, args)
    args = args or {}

    if jenova and jenova.process and jenova.process.spawn then
        local config = json.stringify({
            cmd = cmd,
            args = args,
            timeout_ms = 30000,
            capture_output = true,
        })
        local result_json = jenova.process.spawn(config)
        if result_json then
            local ok, result = pcall(json.parse, result_json)
            if ok and result then
                local out = (result.stdout or "") .. (result.stderr or "")
                return out, result.exit_code or 0
            end
        end
    end

    -- io.popen fallback — quote each arg for the platform shell.
    local parts = { _shell_quote(cmd) }
    for _, a in ipairs(args) do
        parts[#parts + 1] = _shell_quote(a)
    end
    parts[#parts + 1] = "2>&1"
    local handle = io.popen(table.concat(parts, " "))
    if not handle then return nil, -1 end
    local output = handle:read("*a") or ""
    local _, _, status = handle:close()
    return output, status or 0
end

M.input_schema = {
    type = "object",
    properties = {
        action = { type = "string", description = "Action: 'diagnostics', 'definition', 'references', 'hover', 'symbols'" },
        file_path = { type = "string", description = "File to query" },
        line = { type = "integer", description = "Line number (1-based)" },
        character = { type = "integer", description = "Column number (0-based)" },
        query = { type = "string", description = "Symbol or query string (for 'symbols' action)" },
    },
    required = { "action" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name() return "LSP" end
function M.check_permissions() return { allowed = true } end

-- Attempt to talk to a running LSP server via jenova.lsp or fall back to
-- simple grep/ctags-based heuristics.
function M.call(args, ctx)
    local action = args.action or "diagnostics"

    -- If the host exposes an LSP bridge, use it.
    if jenova and jenova.lsp then
        local result, err = jenova.lsp.request(json.stringify(args))
        if result then
            return { type = "text", text = result }
        end
        return { type = "error", error = "LSP request failed: " .. tostring(err) }
    end

    -- Fallback: shell-based heuristics
    if action == "diagnostics" then
        return M._diagnostics_fallback(args)
    elseif action == "definition" then
        return M._definition_fallback(args)
    elseif action == "references" then
        return M._references_fallback(args)
    elseif action == "hover" then
        return { type = "text", text = "Hover information requires a running language server." }
    elseif action == "symbols" then
        return M._symbols_fallback(args)
    end

    return { type = "error", error = "Unknown LSP action: " .. tostring(action) }
end

function M._diagnostics_fallback(args)
    local file = args.file_path
    if not file then
        return { type = "error", error = "file_path required for diagnostics" }
    end

    -- Try common linters. Each entry is { command, argv } where argv is
    -- passed to the process *without* a shell, so filenames containing
    -- shell metacharacters cannot inject commands.
    local ext = file:match("%.([^.]+)$") or ""
    local cmd, argv
    if ext == "py" then
        cmd, argv = "python3", { "-m", "py_compile", file }
    elseif ext == "lua" then
        cmd, argv = "luac", { "-p", file }
    elseif ext == "rs" then
        cmd, argv = "cargo", { "check", "--message-format=short" }
    elseif ext == "go" then
        cmd, argv = "go", { "vet", file }
    elseif ext == "js" or ext == "ts" or ext == "tsx" or ext == "jsx" then
        cmd, argv = "npx", { "tsc", "--noEmit", file }
    else
        return { type = "text", text = "No diagnostic tool available for ." .. ext .. " files." }
    end

    local output, _ = _run_argv(cmd, argv)
    if not output then
        return { type = "text", text = "Could not run diagnostics." }
    end
    -- Cap the output to keep cargo/tsc spew bounded — equivalent to the
    -- old `head -30` shell pipeline but in pure Lua.
    if cmd == "cargo" or cmd == "npx" then
        local lines, capped = {}, {}
        for line in output:gmatch("[^\n]+") do lines[#lines + 1] = line end
        for i = 1, math.min(30, #lines) do capped[i] = lines[i] end
        output = table.concat(capped, "\n")
    end

    if not output or #output == 0 then
        return { type = "text", text = "No diagnostics found." }
    end
    return { type = "text", text = output }
end

-- File globs we restrict definition / reference searches to. Kept here so
-- both fallbacks share the same list and so the argv builder reads
-- straightforwardly.
local SOURCE_INCLUDES = {
    "--include=*.lua", "--include=*.rs", "--include=*.py",
    "--include=*.go",  "--include=*.ts", "--include=*.js",
}

-- Patterns we filter symbol lines by, used in pure Lua so we don't have
-- to pipe through a second grep process.
local DEF_PATTERNS = {
    "function", "def ", "fn ", "func ", "class ",
    "struct ", "enum ", "trait ", "interface ",
}

local function _line_matches_def(line)
    line = line:lower()
    for _, p in ipairs(DEF_PATTERNS) do
        if line:find(p, 1, true) then return true end
    end
    return false
end

function M._definition_fallback(args)
    if not args.file_path or not args.query then
        return { type = "error", error = "file_path and query (or line/character) required" }
    end
    local query = args.query

    local argv = { "-rn", query }
    for _, inc in ipairs(SOURCE_INCLUDES) do argv[#argv + 1] = inc end
    argv[#argv + 1] = "."
    local output, _ = _run_argv("grep", argv)
    if not output then
        return { type = "text", text = "Could not search for definition." }
    end

    -- Filter to definition-shaped lines and cap at 10 results in Lua
    -- (replaces the old `| grep ... | head -10` shell pipeline).
    local kept = {}
    for line in output:gmatch("[^\n]+") do
        if _line_matches_def(line) then
            kept[#kept + 1] = line
            if #kept >= 10 then break end
        end
    end

    if #kept == 0 then
        return { type = "text", text = "No definition found for: " .. query }
    end
    return { type = "text", text = "Possible definitions:\n" .. table.concat(kept, "\n") }
end

function M._references_fallback(args)
    local query = args.query
    if not query then
        return { type = "error", error = "query required for references" }
    end

    local argv = { "-rn", query }
    for _, inc in ipairs(SOURCE_INCLUDES) do argv[#argv + 1] = inc end
    argv[#argv + 1] = "."
    local output, _ = _run_argv("grep", argv)
    if not output then
        return { type = "text", text = "Could not search for references." }
    end

    -- Cap at 20 lines in Lua (replaces the old `| head -20`).
    local kept = {}
    for line in output:gmatch("[^\n]+") do
        kept[#kept + 1] = line
        if #kept >= 20 then break end
    end

    if #kept == 0 then
        return { type = "text", text = "No references found for: " .. query }
    end
    return { type = "text", text = "References:\n" .. table.concat(kept, "\n") }
end

function M._symbols_fallback(args)
    local file = args.file_path or "."
    -- Pass the symbol-shaped pattern as a literal argv element so the file
    -- name (which may contain shell metacharacters) is never interpreted.
    local pattern = "function\\|def \\|fn \\|func \\|class \\|struct \\|enum \\|trait \\|interface "
    local output, _ = _run_argv("grep", { "-n", pattern, file })
    if not output then
        return { type = "text", text = "Could not list symbols." }
    end

    local kept = {}
    for line in output:gmatch("[^\n]+") do
        kept[#kept + 1] = line
        if #kept >= 30 then break end
    end

    if #kept == 0 then
        return { type = "text", text = "No symbols found." }
    end
    return { type = "text", text = "Symbols:\n" .. table.concat(kept, "\n") }
end

return M
