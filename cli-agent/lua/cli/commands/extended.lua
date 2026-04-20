-- cli/commands/extended.lua — Extended slash commands
-- Additional commands beyond the core set in registry.lua

local extended = {}

-- Load the registry
local registry = require("cli.commands.registry")

-- ── Memory Commands ───────────────────────────────────────────────────

registry.register("memory", function(args)
    local memory = require("services.memory.manager")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local items = memory.get_recent(20)
        print(string.format("Recent memory items (%d):\n", #items))
        for i, item in ipairs(items) do
            print(string.format("%d. [%s] %s", i, item.subject, item.fact))
            if item.citations then
                print(string.format("   Citations: %s", item.citations))
            end
        end
    elseif subcommand == "search" then
        local query = args:match("^%S+%s+(.+)")
        if not query then
            print("Usage: /memory search <query>")
            return
        end
        local results = memory.search(query)
        print(string.format("Found %d results:\n", #results))
        for i, item in ipairs(results) do
            print(string.format("%d. [%s] %s", i, item.subject, item.fact))
        end
    elseif subcommand == "clear" then
        memory.clear()
        print("Memory cleared")
    else
        print("Memory commands:")
        print("  /memory list           List recent memory items")
        print("  /memory search <query> Search memory")
        print("  /memory clear          Clear all memory")
    end
end, {
    description = "Manage persistent memory",
    usage = "/memory [list|search|clear]"
})

-- ── Skills Commands ───────────────────────────────────────────────────

registry.register("skills", function(args)
    local skills = require("skills.loader")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local items = skills.list()
        print(string.format("Available skills (%d):\n", #items))
        for i, skill in ipairs(items) do
            print(string.format("%d. %s (%s)", i, skill.name, skill.type))
            if skill.description and #skill.description > 0 then
                print(string.format("   %s", skill.description))
            end
        end
    elseif subcommand == "reload" then
        skills.load_all()
        print("Skills reloaded")
    else
        print("Skills commands:")
        print("  /skills list    List available skills")
        print("  /skills reload  Reload all skills")
    end
end, {
    description = "Manage skills",
    usage = "/skills [list|reload]"
})

-- ── Plugins Commands ──────────────────────────────────────────────────

registry.register("plugins", function(args)
    local plugins = require("plugins.loader")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local items = plugins.list()
        print(string.format("Loaded plugins (%d):\n", #items))
        for i, plugin in ipairs(items) do
            print(string.format("%d. %s v%s", i, plugin.name, plugin.version))
            if plugin.description and #plugin.description > 0 then
                print(string.format("   %s", plugin.description))
            end
        end
    elseif subcommand == "reload" then
        local name = args:match("^%S+%s+(%S+)")
        if not name then
            print("Usage: /plugins reload <name>")
            return
        end
        local ok, err = plugins.reload(name)
        if ok then
            print(string.format("Plugin '%s' reloaded", name))
        else
            print(string.format("Failed to reload plugin: %s", err or "unknown error"))
        end
    else
        print("Plugins commands:")
        print("  /plugins list         List loaded plugins")
        print("  /plugins reload <name> Reload a plugin")
    end
end, {
    description = "Manage plugins",
    usage = "/plugins [list|reload]",
    aliases = { "plugin" },
})

-- ── Context Commands ──────────────────────────────────────────────────

registry.register("context", function(args)
    local context = require("context.manager")

    print("System context:\n")
    print(context.build_context_string())
    print("")

    local user_ctx = context.get_user_context()
    print("User context:")
    print(string.format("  Username: %s", user_ctx.username))
    print(string.format("  Home: %s", user_ctx.home_directory))
    print(string.format("  Shell: %s", user_ctx.shell))
    print(string.format("  Editor: %s", user_ctx.editor))
end, {
    description = "Show system and user context",
})

-- ── History Commands ──────────────────────────────────────────────────

registry.register("history", function(args)
    local history = require("history.manager")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local count = tonumber(args:match("^%S+%s+(%d+)")) or 20
        local items = history.get_recent(count)
        print(string.format("Recent history (%d items):\n", #items))
        for i, item in ipairs(items) do
            local timestamp = os.date("%Y-%m-%d %H:%M:%S", item.timestamp)
            print(string.format("%d. [%s] %s", i, timestamp, item.content))
        end
    elseif subcommand == "search" then
        local query = args:match("^%S+%s+(.+)")
        if not query then
            print("Usage: /history search <query>")
            return
        end
        local results = history.search(query)
        print(string.format("Found %d results:\n", #results))
        for i, item in ipairs(results) do
            print(string.format("%d. %s", i, item.content))
        end
    elseif subcommand == "clear" then
        history.clear()
        print("History cleared")
    else
        print("History commands:")
        print("  /history list [count]  List recent history")
        print("  /history search <query> Search history")
        print("  /history clear         Clear history")
    end
end, {
    description = "Manage command history",
    usage = "/history [list|search|clear]"
})

-- ── Permissions Commands ──────────────────────────────────────────────

registry.register("permissions", function(args)
    local permissions = require("permissions.manager")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "mode" then
        local mode = args:match("^%S+%s+(%S+)")
        if mode then
            local config = require("config.loader")
            config.set("permission_mode", mode)
            print(string.format("Permission mode set to: %s", mode))
        else
            local config = require("config.loader")
            local current = config.get("permission_mode")
            print(string.format("Current permission mode: %s", current))
            print("\nAvailable modes:")
            print("  default             - Ask for each tool")
            print("  auto                - Auto-approve all")
            print("  bypassPermissions   - Bypass all checks")
            print("  plan                - Plan mode (limited tools)")
        end
    elseif subcommand == "clear" then
        permissions.clear_cache()
        print("Permission cache cleared")
    elseif subcommand == "history" then
        local items = permissions.get_history()
        print(string.format("Permission history (%d items):\n", #items))
        for i, item in ipairs(items) do
            local status = item.allowed and "✓" or "✗"
            print(string.format("%d. %s %s", i, status, item.tool_name))
        end
    else
        print("Permissions commands:")
        print("  /permissions mode [mode]  View or set permission mode")
        print("  /permissions clear        Clear permission cache")
        print("  /permissions history      Show permission history")
    end
end, {
    description = "Manage tool permissions",
    usage = "/permissions [mode|clear|history]"
})

-- ── Helpers ───────────────────────────────────────────────────────────

local shell = require("utils.shell")

-- Run git with a list of arguments. We strongly prefer the FFI's cmd+args
-- form (no shell), which is both safer and works identically on Windows
-- and POSIX. The io.popen fallback is only used on builds without the
-- FFI bridge, and uses shell.quote() above. Returns (stdout, exit_status).
local function run_git(args)
    if jenova and jenova.process and jenova.process.spawn_json then
        local json = require("utils.json_fallback")
        local argv = {}
        if type(args) == "table" then
            for i, a in ipairs(args) do argv[i] = tostring(a) end
        elseif type(args) == "string" then
            -- Legacy string form: split on whitespace. Only safe for
            -- caller-controlled constants — no callers in this file pass
            -- user input through the string form.
            for token in args:gmatch("%S+") do argv[#argv + 1] = token end
        end
        local config = json.stringify({
            cmd = "git",
            args = argv,
            timeout_ms = 30000,
            capture_stdout = true,
            capture_stderr = true,
        })
        local result = jenova.process.spawn_json(config)
        if result and type(result) == "table" then
            local out = (result.stdout or "") .. (result.stderr or "")
            return out, result.exit_code or 0
        end
        -- fall through to io.popen if FFI returned nothing
    end

    local cmd = "git"
    if type(args) == "table" then
        for _, a in ipairs(args) do
            cmd = cmd .. " " .. shell.quote(a)
        end
    elseif type(args) == "string" then
        -- Legacy string form — only safe for caller-controlled constants.
        cmd = cmd .. " " .. args
    end
    cmd = cmd .. " 2>&1"

    local handle = io.popen(cmd)
    if not handle then return nil, "failed to spawn git" end
    local out = handle:read("*a") or ""
    local _, _, status = handle:close()
    return out, status
end

-- Hand an engineered prompt to the query engine and let the assistant
-- do the work. Returns nothing — output streams through the REPL callbacks.
local function ask_assistant(prompt)
    local ok_qe, query_engine = pcall(require, "engine.query_engine")
    if not ok_qe then
        print("(query engine not available)")
        return
    end

    local engine = query_engine.new({
        on_text = function(t) io.write(t); io.flush() end,
        on_error = function(err) io.stderr:write(tostring(err) .. "\n") end,
    })

    local _, err = engine:query(prompt, { max_turns = 15 })
    if err then
        io.stderr:write("Query failed: " .. tostring(err) .. "\n")
    end
    print("")
end

-- ── Review Commands ───────────────────────────────────────────────────

registry.register("review", function(args)
    -- /review           -> review uncommitted changes
    -- /review <ref>     -> review a specific commit/range
    -- /review <file>    -> review a specific file

    local target = args and args:match("^%s*(.-)%s*$") or ""
    local diff, context_desc

    if target == "" then
        local staged, _ = run_git({ "diff", "--cached" })
        local unstaged, _ = run_git({ "diff" })
        diff = ((staged or "") .. "\n" .. (unstaged or "")):match("^%s*(.-)%s*$")
        context_desc = "uncommitted changes (staged + unstaged)"
    else
        -- The argument could be a path or a git ref. Check the filesystem
        -- first: if it exists as a real file we always treat it as such.
        -- This avoids the previous ambiguity where a valid ref with no
        -- changes silently fell through to opening a (likely nonexistent)
        -- file with the ref's name. Argv is quoted via the FFI inside
        -- run_git so user input cannot inject shell.
        local is_dir = false
        local ok_fs, fs = pcall(require, "utils.fs_fallback")
        if ok_fs and fs and fs.is_directory then
            is_dir = fs.is_directory(target)
        end

        local f = not is_dir and io.open(target, "r") or nil
        if f then
            local content = f:read("*a")
            f:close()
            diff = content
            context_desc = "file " .. target
        else
            local as_ref, _ = run_git({ "diff", target })
            if as_ref and #as_ref > 0 then
                diff = as_ref
                context_desc = "changes in " .. target
            else
                print("Nothing to review for: " .. target)
                return
            end
        end
    end

    if not diff or #diff == 0 then
        print("No changes to review.")
        return
    end

    local prompt = string.format([[
Review the following %s. Look for:
- Bugs, logic errors, race conditions
- Security issues (injection, auth, data leaks)
- Performance problems
- Code clarity and maintainability
- Missing tests or error handling

Be concrete: cite file:line where possible. Flag only real issues — do not
nit-pick style. End with a one-line overall verdict (LGTM / Needs changes / Block).

```
%s
```
]], context_desc, diff)

    ask_assistant(prompt)
end, {
    description = "Review uncommitted changes, a commit/ref, or a file",
    usage = "/review [ref|file]",
})

-- ── Commit Commands ───────────────────────────────────────────────────

registry.register("commit", function(args)
    -- Stage everything that's tracked + new, inspect the diff, and ask the
    -- assistant to propose a commit message following Conventional Commits.
    -- If args is "--push" also push after committing.

    local status, _ = run_git({ "status", "--porcelain" })
    if not status or #status == 0 then
        print("Nothing to commit: working tree clean.")
        return
    end

    local diff, _ = run_git({ "diff", "--cached" })
    if not diff or #diff == 0 then
        print("No staged changes. Run `git add <file>` first before using /commit.")
        return
    end

    -- Cap the diff we feed to the model — commit prompts don't need 100k
    -- lines of unrelated context.
    local truncated = diff
    if #diff > 12000 then
        local trunc_len = 12000
        while trunc_len > 0 and diff:byte(trunc_len) >= 128 and diff:byte(trunc_len) <= 191 do
            trunc_len = trunc_len - 1
        end
        if trunc_len > 0 and diff:byte(trunc_len) >= 192 then
            trunc_len = trunc_len - 1
        end
        truncated = diff:sub(1, trunc_len) .. "\n...[truncated]"
    end

    local prompt = string.format([[
You are helping write a git commit message. Analyze the staged diff below
and produce a single commit message that follows these rules:

- First line: imperative mood, <= 72 chars, prefixed with one of
  feat:|fix:|refactor:|docs:|test:|chore:|perf:|build:
- Blank line.
- Optional body: 2-6 short bullet lines explaining the *why*, not the *what*.
- No trailers, no emoji, no quotation marks around the message.

Output ONLY the commit message — no preamble, no code fences.

Staged diff:
```
%s
```
]], truncated)

    print("Drafting commit message...\n")
    ask_assistant(prompt)

    print("\nProceed with this commit? [y/N] ")
    local answer = io.read("*l")
    if answer and (answer:lower() == "y" or answer:lower() == "yes") then
        -- The assistant's message streamed to stdout, not to a variable we
        -- can pass to `git commit -F`. Re-prompt the user to commit manually
        -- or let them copy/paste the message. This keeps us honest about
        -- where the content actually lives.
        print("\nRun: git commit -F- and paste the message above.")
    else
        print("Commit aborted. Staged changes remain in the index.")
    end
end, {
    description = "Draft a conventional-commits message for staged changes",
    usage = "/commit",
})

-- ── /init ─────────────────────────────────────────────────────────────
-- Scaffold a cli-agent workspace: create .jenova/ dir with a stub
-- CLAUDE.md / JENOVA.md and initialize config if missing.

registry.register("init", function(args)
    local cfg = require("config.loader")
    cfg.load() -- ensures ~/.config/cli-agent/config.json exists

    local cwd = os.getenv("PWD") or "."
    local project_dir = cwd .. "/.jenova"

    local ok_fs, fs = pcall(require, "utils.fs_fallback")
    if ok_fs and fs and fs.mkdir then
        fs.mkdir(project_dir)
    elseif jenova and jenova.process and jenova.process.spawn then
        -- Prefer the FFI argv form so the project path never touches a
        -- shell. This is both safer (no injection via directory names
        -- containing metacharacters) and works on Windows.
        local json = require("utils.json_fallback")
        local cmd, argv = "mkdir", { "-p", project_dir }
        jenova.process.spawn(json.stringify({
            cmd = cmd,
            args = argv,
            timeout_ms = 10000,
            capture_stdout = false,
            capture_stderr = false,
        }))
    else
        os.execute("mkdir -p " .. shell.quote(project_dir))
    end

    local jenova_md_path = cwd .. "/JENOVA.md"
    local f = io.open(jenova_md_path, "r")
    if f then
        f:close()
        print("JENOVA.md already exists at " .. jenova_md_path)
    else
        local contents = [[
# JENOVA.md

Project-level instructions for Jenova CLI. This file is loaded into the
assistant's context at the start of each session.

## Project overview
(Describe what this project does and its key directories.)

## Conventions
- Language:
- Build command:
- Test command:
- Formatter:

## Important notes
(Anything the assistant should know — e.g. "never touch the migrations/ dir",
"prefer X over Y", "run `just test` after any code change".)
]]
        local w = io.open(jenova_md_path, "w")
        if w then
            w:write(contents)
            w:close()
            print("Created " .. jenova_md_path)
        else
            io.stderr:write("Failed to write " .. jenova_md_path .. "\n")
        end
    end

    print("Initialized cli-agent workspace at " .. project_dir)
end, {
    description = "Initialize cli-agent in the current project",
    usage = "/init",
})

-- ── /resume ───────────────────────────────────────────────────────────
-- List saved sessions (no arg) or rehydrate one into the running REPL.

registry.register("resume", function(args)
    local app_state = require("state.app_state")
    local target = args and args:match("^%s*(.-)%s*$") or ""

    if target == "" then
        local sessions = app_state.list_sessions()
        if #sessions == 0 then
            print("No saved sessions. Use /session to see the current one.")
            return
        end
        print(string.format("Saved sessions (%d):\n", #sessions))
        for i, s in ipairs(sessions) do
            print(string.format("  %d. %s", i, s.session_id))
        end
        print("\nRun /resume <session_id> to rehydrate a session.")
        return
    end

    local ok, err = app_state.load_session(target)
    if not ok then
        io.stderr:write("Failed to resume: " .. tostring(err) .. "\n")
        return
    end
    print("Resumed session: " .. target)
    print(string.format("  Messages: %d", #(app_state.get("messages") or {})))
    print(string.format("  Working dir: %s", app_state.get_cwd()))
end, {
    description = "List or resume a saved session",
    usage = "/resume [session_id]",
})

-- ── /status ───────────────────────────────────────────────────────────

registry.register("status", function(args)
    local app_state = require("state.app_state")
    local cfg = require("config.loader")

    local session = app_state.get("session_id") or "(none)"
    local cwd = app_state.get_cwd()
    local mode = cfg.get("permission_mode") or "default"
    local model = cfg.get("model") or "(auto)"
    local provider = cfg.get("provider") or "(default)"

    print("Jenova CLI status")
    print("─────────────────")
    print(string.format("  Session:        %s", session))
    print(string.format("  Working dir:    %s", cwd))
    print(string.format("  Provider:       %s", provider))
    print(string.format("  Model:          %s", model))
    print(string.format("  Permission mode: %s", mode))

    local tool_registry = require("tools.registry")
    print(string.format("  Tools loaded:   %d", #tool_registry.list_tools()))

    local messages = app_state.get("messages") or {}
    print(string.format("  Messages:       %d", #messages))

    local usage = app_state.get_usage()
    print(string.format("  Tokens:         %d in / %d out", usage.input_tokens, usage.output_tokens))
end, {
    description = "Show current CLI status summary",
    usage = "/status",
})

-- ── /add-dir ──────────────────────────────────────────────────────────

registry.register("add-dir", function(args)
    local app_state = require("state.app_state")
    local path = args and args:match("^%s*(.-)%s*$") or ""
    if path == "" then
        local dirs = app_state.get("additional_dirs") or {}
        if #dirs == 0 then
            print("No additional directories. Usage: /add-dir <path>")
            return
        end
        print("Additional directories:")
        for _, d in ipairs(dirs) do
            print("  " .. d)
        end
        return
    end

    -- Expand ~ and resolve
    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME") or ""
        path = home .. path:sub(2)
    end

    -- Verify it exists
    local ok_fs, fs = pcall(require, "utils.fs_fallback")
    local probe
    if ok_fs and fs and fs.is_directory then
        probe = fs.is_directory(path)
    else
        probe = io.open(path, "r")
    end
    
    if not probe then
        io.stderr:write("Path not found or not a directory: " .. path .. "\n")
        return
    end
    if type(probe) == "userdata" then probe:close() end

    local dirs = app_state.get("additional_dirs") or {}
    for _, d in ipairs(dirs) do
        if d == path then
            print("Already tracked: " .. path)
            return
        end
    end
    table.insert(dirs, path)
    app_state.set("additional_dirs", dirs)
    print("Added directory: " .. path)
end, {
    description = "Add an additional working directory to the session",
    usage = "/add-dir <path>",
})

-- ── /hooks ────────────────────────────────────────────────────────────

registry.register("hooks", function(args)
    local ok, hooks = pcall(require, "hooks.manager")
    if not ok or not hooks then
        print("Hooks system not available.")
        return
    end

    local sub = args and args:match("^(%S+)") or "list"
    if sub == "list" then
        local all = hooks.list and hooks.list() or {}
        if #all == 0 then
            print("No hooks registered.")
            return
        end
        print(string.format("Registered hooks (%d):", #all))
        for _, h in ipairs(all) do
            print(string.format("  [%s] %s -> %s", h.event or "?", h.matcher or "*", h.command or h.name or "?"))
        end
    elseif sub == "reload" then
        if hooks.reload then
            hooks.reload()
            print("Hooks reloaded.")
        else
            print("Reload not supported by the hooks manager.")
        end
    else
        print("Hooks commands:")
        print("  /hooks list    List registered hooks")
        print("  /hooks reload  Reload hooks from config")
    end
end, {
    description = "Inspect and manage lifecycle hooks",
    usage = "/hooks [list|reload]",
})

-- ── /backend ──────────────────────────────────────────────────────────

registry.register("backend", function(args)
    local trio = require("utils.trio")
    local endpoints = trio.get_endpoints()
    local sub = args:match("^(%S+)")

    if not sub or sub == "status" then
        print("Jenova Backend Status:")
        print(string.format("  JENOVA_ROOT:  %s", endpoints.root or "(not found)"))
        print(string.format("  Proxy URL:    %s", endpoints.proxy_url))
        print(string.format("  Llama Port:   %d", endpoints.llama_port))
        print(string.format("  Embed Port:   %d", endpoints.embed_port))

        local http = jenova and jenova.http
        if http then
            local ok, resp = pcall(http.get, endpoints.health_url, nil)
            if ok and resp then
                print("  Service:      ONLINE (Healthy)")
            else
                print("  Service:      OFFLINE")
            end
        else
            print("  Service:      UNKNOWN (jenova.http missing)")
        end
    elseif sub == "start" then
        local root = trio.get_root()
        if not root then
            print("Error: JENOVA_ROOT not found. Cannot start backend.")
            return
        end
        
        local endpoints = trio.get_endpoints()
        local health_url = string.format("http://%s:%d/v1/health", endpoints.host, endpoints.port)
        -- Quick health check via TCP probe (non-blocking if possible, but simple here)
        local probe = io.popen(string.format("curl -sf --max-time 1 %s 2>/dev/null", shell.quote(health_url)))
        if probe then
            local res = probe:read("*a")
            probe:close()
            if res and res ~= "" then
                print("Jenova backend already running at " .. endpoints.proxy_url)
                return
            end
        end

        print("Starting Jenova backend (jenova-ca)...")
        local cmd = string.format("%s &", shell.quote(root .. "/bin/jenova-ca"))
        os.execute(cmd)
        
        -- Wait for ready
        print("Waiting for Jenova CA...")
        local ready = false
        for i = 1, 30 do
            local p = io.popen(string.format("curl -sf --max-time 1 %s 2>/dev/null", shell.quote(health_url)))
            if p then
                local r = p:read("*a")
                p:close()
                if r and r ~= "" then
                    ready = true
                    break
                end
            end
            io.write(".")
            io.flush()
            os.execute("sleep 1")
        end
        if ready then
            print("\nBackend ready!")
        else
            print("\nBackend start timed out. Check logs in JENOVA_ROOT/.jenova/jenova-ca.log")
        end
    elseif sub == "monitor" or sub == "status" then
        local endpoints = trio.get_endpoints()
        print("Jenova Trio Status:")
        print(string.format("  JENOVA_ROOT: %s", endpoints.root or "not found"))
        print(string.format("  Connect Host: %s", endpoints.host))
        
        local function check(url, name)
            local p = io.popen(string.format("curl -sf --max-time 2 %s 2>/dev/null", shell.quote(url)))
            local res = p and p:read("*a")
            if p then p:close() end
            if res and res ~= "" then
                print(string.format("  %-15s ONLINE", name))
                return true
            else
                print(string.format("  %-15s OFFLINE", name))
                return false
            end
        end

        check(endpoints.proxy_url:gsub("/chat/completions", "/health"), "Proxy (:" .. endpoints.port .. ")")
        check(string.format("http://%s:%d/health", endpoints.host, endpoints.llama_port), "llama (:" .. endpoints.llama_port .. ")")
        check(string.format("http://%s:%d/health", endpoints.host, endpoints.embed_port), "Embed (:" .. endpoints.embed_port .. ")")
    elseif sub == "trio" then
        print("Jenova Trio — Cognitive Engineering Environment")
        print(string.rep("=", 50))
        print("1. Jenova (Backend): The cognitive architecture and model serving.")
        print("2. jvim (Editor): Neovim fork optimized for AI integration.")
        print("3. cli-agent (Agent): The terminal-based agent (this tool).")
        print(string.rep("-", 50))
        
        local endpoints = trio.get_endpoints()
        print(string.format("Connect Host: %s", endpoints.host))
        print(string.format("JENOVA_ROOT:  %s", endpoints.root or "MISSING"))
        
        local jvim_path = os.execute("command -v jvim >/dev/null 2>&1") == 0 and "FOUND" or "MISSING"
        print(string.format("jvim binary:   %s", jvim_path))
        
        print("\nUse /backend start to launch the backend daemon.")
        print("Use /backend status to check service health.")
    elseif sub == "stop" then
        local root = trio.get_root()
        if not root then
            print("Error: JENOVA_ROOT not found.")
            return
        end
        print("Stopping Jenova backend...")
        os.execute("pkill -f llama-server")
        os.execute("pkill -f jenova-ca")
        print("Stop commands issued.")
    elseif sub == "config" then
        local conf = trio.load_jenova_conf()
        print("Current Jenova Configuration (from etc/jenova.conf):")
        for k, v in pairs(conf) do
            print(string.format("  %s=%s", k, v))
        end
    else
        print("Usage: /backend [status|start|stop|config]")
    end
end, {
    description = "Manage and inspect the Jenova backend daemon",
    usage = "/backend [status|start|stop|config|monitor]"
})

-- ── /provider ─────────────────────────────────────────────────────────

registry.register("provider", function(args)
    local config = require("config.loader")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "show" then
        local current = config.get("provider") or "llamacpp"
        print(string.format("Current provider: %s", current))
        print("\nAvailable providers:")
        print("  jenova_backend  Jenova cognitive architecture (proxy.lua :8080)")
        print("  llamacpp        Local in-process llama.cpp inference")
    elseif subcommand == "set" then
        local name = args:match("^%S+%s+(%S+)")
        if not name then
            print("Usage: /provider set <provider-name>")
            return
        end
        local valid = { llamacpp=true, jenova_backend=true }
        if valid[name] then
            config.set("provider", name)
            print(string.format("Provider set to: %s", name))
        else
            print(string.format("Unknown provider: %s", name))
        end
    elseif subcommand == "test" then
        local provider_name = args:match("^%S+%s+(%S+)") or config.get("provider") or "llamacpp"
        print(string.format("Testing provider: %s ...", provider_name))
        local ok, prov = pcall(require, "providers." .. provider_name)
        if ok and prov and prov.test then
            local result, err = pcall(prov.test)
            if result then
                print("✓ Provider is working")
            else
                print(string.format("✗ Provider test failed: %s", tostring(err)))
            end
        else
            print(string.format("⚠ Provider %s has no test function", provider_name))
        end
    else
        print("Provider commands:")
        print("  /provider              Show current provider")
        print("  /provider set <name>   Switch active provider")
        print("  /provider test [name]  Test a provider connection")
    end
end, {
    description = "Manage LLM providers",
    usage = "/provider [show|set|test] [name]"
})

-- ── /plan ────────────────────────────────────────────────────────────

registry.register("plan", function(args)
    local config = require("config.loader")
    local permissions = require("permissions.manager")

    local current = config.get("permission_mode")

    if not args or #args == 0 then
        if current == "plan" then
            -- Toggle off plan mode
            config.set("permission_mode", "default")
            print("Plan mode: disabled (switched to default)")
        else
            config.set("permission_mode", "plan")
            print("Plan mode: enabled")
            print("  Only read-only tools are auto-approved")
            print("  Write tools require explicit permission")
        end
    elseif args == "on" then
        config.set("permission_mode", "plan")
        print("Plan mode: enabled")
    elseif args == "off" then
        config.set("permission_mode", "default")
        print("Plan mode: disabled")
    else
        print("Plan mode: toggle read-only exploration mode")
        print("Usage: /plan [on|off]")
        print(string.format("Current: %s", current == "plan" and "enabled" or "disabled"))
    end
end, {
    description = "Toggle plan/exploration mode (read-only tools auto-approved)",
    usage = "/plan [on|off]"
})

-- ── /sandbox ─────────────────────────────────────────────────────────

registry.register("sandbox", function(args)
    local config = require("config.loader")
    local subcommand = args:match("^(%S+)")

    if not subcommand then
        local enabled = config.get("sandbox_enabled")
        print(string.format("Sandbox: %s", enabled and "enabled" or "disabled"))
        print("\nSandbox restricts tool access to the working directory")
        print("and blocks dangerous commands.")
    elseif subcommand == "on" or subcommand == "enable" then
        config.set("sandbox_enabled", true)
        print("Sandbox: enabled")
    elseif subcommand == "off" or subcommand == "disable" then
        config.set("sandbox_enabled", false)
        print("Sandbox: disabled")
    elseif subcommand == "status" then
        local enabled = config.get("sandbox_enabled")
        print(string.format("Sandbox: %s", enabled and "enabled" or "disabled"))
        local app_state = require("state.app_state")
        print(string.format("Working directory: %s", app_state.get_cwd()))
        if jenova and jenova.sandbox and jenova.sandbox.validate_path then
            print("✓ Path validation available (Rust FFI)")
        else
            print("⚠ Path validation not available")
        end
    else
        print("Sandbox commands:")
        print("  /sandbox              Show sandbox status")
        print("  /sandbox on           Enable sandbox")
        print("  /sandbox off          Disable sandbox")
        print("  /sandbox status       Detailed sandbox status")
    end
end, {
    description = "Toggle filesystem sandbox mode",
    usage = "/sandbox [on|off|status]"
})

-- ── /diff ────────────────────────────────────────────────────────────

registry.register("diff", function(args)
    local app_state = require("state.app_state")
    local shell = require("utils.shell")

    local cwd = app_state.get_cwd()
    local target = args and #args > 0 and args or nil

    -- Use jenova.process.spawn if available for safe execution
    if jenova and jenova.process and jenova.process.spawn then
        local json = require("utils.json_fallback")
        local cmd_args = { "diff", "--stat" }
        if target then
            table.insert(cmd_args, target)
        end
        local proc_config = json.stringify({
            cmd = "git",
            args = cmd_args,
            cwd = cwd,
            timeout_ms = 10000,
            capture_stdout = true,
            capture_stderr = true,
        })
        local result = jenova.process.spawn(proc_config)
        if result then
            local ok, parsed = pcall(json.parse, result)
            if ok and parsed then
                if parsed.stdout and #parsed.stdout > 0 then
                    print(parsed.stdout)
                else
                    print("No changes detected")
                end
                if parsed.stderr and #parsed.stderr > 0 then
                    io.stderr:write(parsed.stderr .. "\n")
                end
            end
        end
    else
        -- Fallback to fs_fallback process helper
        print("git diff not available without process FFI")
    end
end, {
    description = "Show git diff summary",
    usage = "/diff [file-or-branch]"
})

-- ── /branch ──────────────────────────────────────────────────────────

registry.register("branch", function(args)
    local app_state = require("state.app_state")
    local cwd = app_state.get_cwd()

    if jenova and jenova.process and jenova.process.spawn then
        local json = require("utils.json_fallback")
        local subcommand = args:match("^(%S+)")

        local cmd_args
        if not subcommand or subcommand == "list" then
            cmd_args = { "branch", "-a", "--no-color" }
        elseif subcommand == "current" then
            cmd_args = { "rev-parse", "--abbrev-ref", "HEAD" }
        elseif subcommand == "create" then
            local name = args:match("^%S+%s+(%S+)")
            if not name then
                print("Usage: /branch create <name>")
                return
            end
            cmd_args = { "checkout", "-b", name }
        elseif subcommand == "switch" then
            local name = args:match("^%S+%s+(%S+)")
            if not name then
                print("Usage: /branch switch <name>")
                return
            end
            cmd_args = { "checkout", name }
        else
            print("Branch commands:")
            print("  /branch             List all branches")
            print("  /branch current     Show current branch")
            print("  /branch create <n>  Create and switch to new branch")
            print("  /branch switch <n>  Switch to existing branch")
            return
        end

        local proc_config = json.stringify({
            cmd = "git",
            args = cmd_args,
            cwd = cwd,
            timeout_ms = 10000,
            capture_stdout = true,
            capture_stderr = true,
        })
        local result = jenova.process.spawn(proc_config)
        if result then
            local ok, parsed = pcall(json.parse, result)
            if ok and parsed then
                if parsed.stdout and #parsed.stdout > 0 then
                    print(parsed.stdout)
                end
                if parsed.stderr and #parsed.stderr > 0 then
                    io.stderr:write(parsed.stderr .. "\n")
                end
            end
        end
    else
        print("git commands not available without process FFI")
    end
end, {
    description = "Manage git branches",
    usage = "/branch [list|current|create|switch] [name]"
})

-- ── /files ───────────────────────────────────────────────────────────

registry.register("files", function(args)
    local app_state = require("state.app_state")
    local cwd = app_state.get_cwd()

    if jenova and jenova.fs and jenova.fs.glob then
        local json = require("utils.json_fallback")
        local pattern = (args and #args > 0) and args or "**/*"
        local result = jenova.fs.glob(pattern, cwd, 50)
        if result then
            local ok, files = pcall(json.parse, result)
            if ok and type(files) == "table" then
                print(string.format("Files matching '%s' (%d results):\n", pattern, #files))
                for _, f in ipairs(files) do
                    print("  " .. tostring(f))
                end
            else
                print("No files found")
            end
        else
            print("No files found")
        end
    else
        print("File listing not available without FS FFI")
    end
end, {
    description = "List files in working directory",
    usage = "/files [pattern]"
})

-- ── /env ─────────────────────────────────────────────────────────────

registry.register("env", function(args)
    if args and #args > 0 then
        local val = os.getenv(args)
        if val then
            print(string.format("%s=%s", args, val))
        else
            print(string.format("%s is not set", args))
        end
    else
        print("Environment check:")
        local vars = {
            "HOME", "USER", "SHELL", "TERM",
            "JENOVA_MODEL", "JENOVA_PROVIDER",
        }
        for _, name in ipairs(vars) do
            local val = os.getenv(name)
            if val then
                -- Mask API keys
                if name:match("KEY$") then
                    val = val:sub(1, 4) .. "..." .. val:sub(-2)
                end
                print(string.format("  %s=%s", name, val))
            end
        end
    end
end, {
    description = "Show environment variables",
    usage = "/env [variable-name]"
})

-- ── /export ──────────────────────────────────────────────────────────

registry.register("export", function(args)
    local app_state = require("state.app_state")
    local json = require("utils.json_fallback")

    local format = (args and args:match("^(%S+)")) or "json"

    local messages = app_state.get_messages()
    if #messages == 0 then
        print("No messages to export")
        return
    end

    if format == "json" then
        local ok, json_str = pcall(json.stringify, messages, { pretty = true })
        if ok then
            print(json_str)
        else
            print("Failed to serialize messages")
        end
    elseif format == "markdown" or format == "md" then
        for _, msg in ipairs(messages) do
            if msg.role == "user" then
                print(string.format("## User\n\n%s\n", tostring(msg.content)))
            elseif msg.role == "assistant" then
                print(string.format("## Assistant\n\n%s\n", tostring(msg.content)))
            end
        end
    elseif format == "text" then
        for _, msg in ipairs(messages) do
            print(string.format("[%s]: %s\n", msg.role or "?", tostring(msg.content)))
        end
    else
        print("Export formats: json, markdown (md), text")
        print("Usage: /export [format]")
    end
end, {
    description = "Export conversation in various formats",
    usage = "/export [json|markdown|text]"
})

-- ── /summary ─────────────────────────────────────────────────────────

registry.register("summary", function(args)
    local app_state = require("state.app_state")
    local messages = app_state.get_messages()
    local usage = app_state.get_usage()

    print("Session Summary:")
    print(string.format("  Session: %s", app_state.get("session_id") or "none"))
    print(string.format("  Messages: %d", #messages))
    print(string.format("  Working dir: %s", app_state.get_cwd()))
    print(string.format("  Input tokens: %d", usage.input_tokens))
    print(string.format("  Output tokens: %d", usage.output_tokens))

    -- Count tool uses
    local tool_count = 0
    for _, msg in ipairs(messages) do
        if type(msg.content) == "table" then
            for _, block in ipairs(msg.content) do
                if type(block) == "table" and block.type == "tool_use" then
                    tool_count = tool_count + 1
                end
            end
        end
    end
    print(string.format("  Tool uses: %d", tool_count))
end, {
    description = "Show conversation summary and statistics",
})

-- ── /theme ───────────────────────────────────────────────────────────

registry.register("theme", function(args)
    local config = require("config.loader")
    local subcommand = args:match("^(%S+)")

    if not subcommand then
        local current = config.get("theme") or "default"
        print(string.format("Current theme: %s", current))
        print("\nAvailable themes:")
        print("  default     Standard terminal colors")
        print("  dark        Optimized for dark backgrounds")
        print("  light       Optimized for light backgrounds")
        print("  minimal     Minimal decoration")
    else
        config.set("theme", subcommand)
        print(string.format("Theme set to: %s", subcommand))
    end
end, {
    description = "Change color theme",
    usage = "/theme [name]"
})

-- ── /tasks ───────────────────────────────────────────────────────────

registry.register("tasks", function(args)
    local app_state = require("state.app_state")
    local subcommand = args:match("^(%S+)")

    -- Task tracking is maintained in app_state
    local tasks = app_state.get("active_tasks") or {}

    if not subcommand or subcommand == "list" then
        if #tasks == 0 then
            print("No active tasks")
        else
            print(string.format("Active tasks (%d):\n", #tasks))
            for i, task in ipairs(tasks) do
                local status_icon = task.status == "running" and "▶" or
                                   task.status == "done" and "✓" or
                                   task.status == "failed" and "✗" or "○"
                print(string.format("  %s %d. %s [%s]", status_icon, i, task.description or "unnamed", task.status or "pending"))
            end
        end
    elseif subcommand == "clear" then
        app_state.set("active_tasks", {})
        print("Tasks cleared")
    else
        print("Task commands:")
        print("  /tasks         List active tasks")
        print("  /tasks clear   Clear all tasks")
    end
end, {
    description = "Manage background tasks",
    usage = "/tasks [list|clear]"
})

-- ── /tools ───────────────────────────────────────────────────────────

registry.register("tools", function(args)
    local tool_registry = require("tools.registry")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local tools = tool_registry.get_all()
        print(string.format("Registered tools (%d):\n", #tools))
        for _, tool in ipairs(tools) do
            local desc = type(tool.description) == "function"
                and tool.description({}) or (tool.description or "")
            -- Truncate long descriptions
            if #desc > 60 then desc = desc:sub(1, 57) .. "..." end
            print(string.format("  %-20s %s", tool.name, desc))
        end
    elseif subcommand == "info" then
        local name = args:match("^%S+%s+(%S+)")
        if not name then
            print("Usage: /tools info <tool-name>")
            return
        end
        local tool = tool_registry.get(name)
        if tool then
            print(string.format("Tool: %s", tool.name))
            local desc = type(tool.description) == "function"
                and tool.description({}) or (tool.description or "")
            print(string.format("Description: %s", desc))
            if tool.input_schema then
                local json = require("utils.json_fallback")
                local ok, schema_str = pcall(json.stringify, tool.input_schema, { pretty = true })
                if ok then
                    print(string.format("Input schema:\n%s", schema_str))
                end
            end
        else
            print(string.format("Tool not found: %s", name))
        end
    else
        print("Tool commands:")
        print("  /tools              List all registered tools")
        print("  /tools info <name>  Show tool details and schema")
    end
end, {
    description = "List and inspect registered tools",
    usage = "/tools [list|info] [name]"
})

-- ── /rename ──────────────────────────────────────────────────────────

registry.register("rename", function(args)
    if not args or #args == 0 then
        local app_state = require("state.app_state")
        local current = app_state.get("session_name")
        print(string.format("Current session name: %s", current or "(unnamed)"))
        print("Usage: /rename <new-name>")
        return
    end
    local app_state = require("state.app_state")
    app_state.set("session_name", args)
    print(string.format("Session renamed to: %s", args))
end, {
    description = "Rename the current session",
    usage = "/rename <name>"
})

-- ── /keybindings ─────────────────────────────────────────────────────

registry.register("keybindings", function(args)
    print("Keybindings:")
    print("")
    print("  Navigation:")
    print("    Ctrl+D        Exit / EOF")
    print("    Ctrl+C        Cancel current operation")
    print("    Up/Down       Navigate command history")
    print("")
    print("  Commands:")
    print("    /help         Show available commands")
    print("    /exit         Exit the CLI")
    print("    /clear        Clear conversation")
    print("")
    if require("config.loader").get("vim_mode") then
        print("  Vim mode (enabled):")
        local ok, keybindings = pcall(require, "vim.keybindings")
        if ok and keybindings and keybindings.list then
            local binds = keybindings.list()
            for _, bind in ipairs(binds) do
                print(string.format("    %-14s %s", bind.key, bind.description))
            end
        else
            print("    (vim keybinding module not loaded)")
        end
    end
end, {
    description = "Show keyboard shortcuts",
    aliases = { "keys" }
})

-- ── /stats ───────────────────────────────────────────────────────────

registry.register("stats", function(args)
    local app_state = require("state.app_state")
    local config = require("config.loader")
    local tool_registry = require("tools.registry")

    print("Jenova CLI Statistics:")
    print("")
    print("  System:")
    if jenova and jenova.system then
        if jenova.system.platform then
            print(string.format("    Platform: %s", jenova.system.platform()))
        end
        if jenova.system.version then
            print(string.format("    Version: %s", jenova.system.version()))
        end
    end

    print(string.format("    Provider: %s", config.get("provider") or "llamacpp"))
    print(string.format("    Model: %s", config.get("model") or "auto"))

    local tools = tool_registry.get_names()
    print(string.format("    Tools: %d registered", #tools))

    -- FFI status
    print("\n  FFI Bindings:")
    local bindings = { "http", "json", "crypto", "sandbox", "process", "fs", "mcp", "llama", "system" }
    for _, name in ipairs(bindings) do
        local available = jenova and jenova[name] ~= nil
        print(string.format("    jenova.%s: %s", name, available and "✓" or "✗"))
    end

    -- Session stats
    local usage = app_state.get_usage()
    print("\n  Session:")
    print(string.format("    Messages: %d", #(app_state.get_messages() or {})))
    print(string.format("    Input tokens: %d", usage.input_tokens))
    print(string.format("    Output tokens: %d", usage.output_tokens))
end, {
    description = "Show detailed CLI statistics",
})

-- ── /effort ──────────────────────────────────────────────────────────

registry.register("effort", function(args)
    local config = require("config.loader")

    if not args or #args == 0 then
        local current = config.get("effort") or "normal"
        print(string.format("Current effort level: %s", current))
        print("\nEffort levels control response thoroughness:")
        print("  low       Quick answers, minimal tool use")
        print("  normal    Balanced (default)")
        print("  high      Thorough, extensive tool use and verification")
        return
    end

    local valid = { low = true, normal = true, high = true }
    if valid[args] then
        config.set("effort", args)
        print(string.format("Effort level set to: %s", args))
    else
        print(string.format("Invalid effort level: %s (use low/normal/high)", args))
    end
end, {
    description = "Set response effort level",
    usage = "/effort [low|normal|high]"
})

-- ── /output-style ────────────────────────────────────────────────────

registry.register("output-style", function(args)
    local config = require("config.loader")

    if not args or #args == 0 then
        local current = config.get("output_style") or "normal"
        print(string.format("Current output style: %s", current))
        print("\nAvailable styles:")
        print("  normal      Standard output")
        print("  concise     Shorter, more direct responses")
        print("  verbose     Detailed explanations")
        print("  code-only   Only output code blocks")
        return
    end

    config.set("output_style", args)
    print(string.format("Output style set to: %s", args))
end, {
    description = "Change response output style",
    usage = "/output-style [normal|concise|verbose|code-only]",
    aliases = { "style" }
})

-- ── /sessions ────────────────────────────────────────────────────────

registry.register("sessions", function(args)
    local app_state = require("state.app_state")
    local subcommand = args:match("^(%S+)")

    if not subcommand or subcommand == "list" then
        local sessions = app_state.list_sessions()
        if #sessions == 0 then
            print("No saved sessions found")
        else
            print(string.format("Saved sessions (%d):\n", #sessions))
            for i, s in ipairs(sessions) do
                local current = s.session_id == app_state.get("session_id") and " (current)" or ""
                print(string.format("  %d. %s%s", i, s.session_id, current))
            end
            print("\nResume with: cli-agent --resume <session-id>")
        end
    elseif subcommand == "save" then
        local path, err = app_state.save_session()
        if path then
            print(string.format("✓ Session saved to: %s", path))
        else
            print(string.format("✗ Failed to save session: %s", tostring(err)))
        end
    else
        print("Sessions commands:")
        print("  /sessions           List saved sessions")
        print("  /sessions save      Save current session")
    end
end, {
    description = "List and manage saved sessions",
    usage = "/sessions [list|save]"
})

-- ── /exit /quit ───────────────────────────────────────────────────────
-- The REPL loop already catches /exit and /quit directly to save state
-- before exiting. Register these as visible commands so /help lists them.

registry.register("exit", function(args)
    -- Normally intercepted by the REPL loop; if a handler runs, fall back.
    print("Goodbye!")
    os.exit(0)
end, {
    description = "Exit the CLI",
    aliases = { "quit" },
})

return extended
