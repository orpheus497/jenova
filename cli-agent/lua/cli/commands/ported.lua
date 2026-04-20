-- cli/commands/ported.lua — CLI commands ported from the legacy TS CLI.
-- These are the remaining user-facing slash commands that were not yet
-- present in registry.lua or extended.lua. Each command is registered via
-- the same CommandRegistry module used by the other command files so they
-- appear in /help and dispatch through the standard REPL routing.

local M = {}

local registry = require("cli.commands.registry")

-- ── Helpers ───────────────────────────────────────────────────────────

local function trim(s)
    if not s then return "" end
    return (s:match("^%s*(.-)%s*$")) or ""
end

local function first_word(s)
    if not s then return nil, nil end
    local w, rest = s:match("^(%S+)%s*(.*)$")
    return w, rest
end

local function get_state()
    return require("state.app_state")
end

local function get_config()
    return require("config.loader")
end

local function copy_to_clipboard(text)
    local shell = require("utils.shell")

    local temp_dir = os.getenv("TMPDIR") or "/tmp"
    local tmp = string.format("%s/jenova_clip_%d_%d", temp_dir, os.time(), math.random(10000, 99999))

    local f = io.open(tmp, "w")
    if not f then return false, "tmpfile" end
    f:write(text or "")
    f:close()

    local q = shell.quote(tmp)
    local cmd
    if os.getenv("WAYLAND_DISPLAY") then
        cmd = "wl-copy < " .. q
    elseif os.getenv("DISPLAY") then
        cmd = "xclip -selection clipboard < " .. q
            .. " 2>/dev/null || xsel --clipboard --input < " .. q .. " 2>/dev/null"
    else
        cmd = "pbcopy < " .. q
    end

    local ok = os.execute(cmd)
    os.remove(tmp)
    if ok == true or ok == 0 then return true end
    return false, "clipboard command failed"
end

-- ── /agents ───────────────────────────────────────────────────────────
-- Manage named agent configurations stored in config.agents.

registry.register("agents", function(args)
    local cfg = get_config()
    local sub, rest = first_word(args)
    local agents = cfg.get("agents")
    if type(agents) ~= "table" then
        agents = {}
        cfg.set("agents", agents)
    end

    if not sub or sub == "list" then
        local count = 0
        for _ in pairs(agents) do count = count + 1 end
        if count == 0 then
            print("No agents configured.")
            print("Create one with: /agents create <name>")
            return
        end
        print(string.format("Configured agents (%d):", count))
        for name, spec in pairs(agents) do
            local model = (spec and spec.model) or "(default)"
            local desc  = (spec and spec.description) or ""
            print(string.format("  %-20s  model=%s  %s", name, model, desc))
        end
    elseif sub == "create" then
        local name = rest and trim(rest) or ""
        if name == "" then
            print("Usage: /agents create <name>")
            return
        end
        if agents[name] then
            print(string.format("Agent '%s' already exists.", name))
            return
        end
        agents[name] = { model = nil, description = "", tools = {} }
        cfg.set("agents", agents)
        print(string.format("Created agent '%s'.", name))
    elseif sub == "remove" or sub == "delete" then
        local name = rest and trim(rest) or ""
        if name == "" or not agents[name] then
            print("Usage: /agents remove <name>")
            return
        end
        agents[name] = nil
        cfg.set("agents", agents)
        print(string.format("Removed agent '%s'.", name))
    elseif sub == "show" then
        local name = rest and trim(rest) or ""
        local spec = agents[name]
        if not spec then
            print(string.format("No such agent: %s", name))
            return
        end
        local json = require("utils.json_fallback")
        local ok, s = pcall(json.stringify, spec, { pretty = true })
        print(ok and s or tostring(spec))
    else
        print("Agent commands:")
        print("  /agents              List agents")
        print("  /agents create <n>   Create a new agent")
        print("  /agents show <n>     Show agent config")
        print("  /agents remove <n>   Delete an agent")
    end
end, {
    description = "Manage agent configurations",
    usage = "/agents [list|create|show|remove] [name]",
})

-- ── /brief ────────────────────────────────────────────────────────────

registry.register("brief", function(args)
    local cfg = get_config()
    local app_state = get_state()
    local arg = trim(args):lower()

    local function set_brief(value)
        app_state.set("brief_mode", value)
        cfg.set("brief_mode", value)
    end
    local function get_brief()
        local v = app_state.get("brief_mode")
        if v == nil then v = cfg.get("brief_mode") end
        return v and true or false
    end

    if arg == "on" or arg == "enable" then
        set_brief(true)
        print("Brief mode: enabled")
    elseif arg == "off" or arg == "disable" then
        set_brief(false)
        print("Brief mode: disabled")
    elseif arg == "" then
        local cur = get_brief()
        set_brief(not cur)
        print(string.format("Brief mode: %s", (not cur) and "enabled" or "disabled"))
    else
        print("Usage: /brief [on|off]")
    end
end, {
    description = "Toggle brief-only response mode",
    usage = "/brief [on|off]",
})

-- ── /btw ──────────────────────────────────────────────────────────────
-- Ask a quick side question without disturbing the main conversation.

registry.register("btw", function(args)
    local prompt = trim(args)
    if prompt == "" then
        print("Usage: /btw <your side question>")
        return
    end
    local ok_qe, query_engine = pcall(require, "engine.query_engine")
    if not ok_qe then
        print("(query engine not available)")
        return
    end
    local engine = query_engine.new({
        on_text = function(t) io.write(t); io.flush() end,
        on_error = function(err) io.stderr:write(tostring(err) .. "\n") end,
    })
    local wrapped = "SIDE QUESTION (do not change the main task): " .. prompt
    local _, err = engine:query(wrapped, { max_turns = 3 })
    if err then io.stderr:write("Query failed: " .. tostring(err) .. "\n") end
    print("")
end, {
    description = "Ask a quick side question without losing main-task context",
    usage = "/btw <question>",
})

-- ── /color ────────────────────────────────────────────────────────────
-- Set the prompt accent color for the session.

registry.register("color", function(args)
    local cfg = get_config()
    local arg = trim(args):lower()
    local palette = {
        default=true, red=true, green=true, yellow=true, blue=true,
        magenta=true, cyan=true, white=true, gray=true,
    }
    if arg == "" then
        local current = cfg.get("prompt_color") or "default"
        print(string.format("Current prompt color: %s", current))
        print("Available colors:")
        for name in pairs(palette) do io.write("  " .. name .. "\n") end
    elseif palette[arg] then
        cfg.set("prompt_color", arg)
        print(string.format("Prompt color set to %s.", arg))
    else
        print(string.format("Unknown color: %s", arg))
        print("Valid colors: default, red, green, yellow, blue, magenta, cyan, white, gray")
    end
end, {
    description = "Set the prompt accent color",
    usage = "/color [name]",
})

-- ── /copy ─────────────────────────────────────────────────────────────
-- Copy the assistant's last response text to the clipboard.

registry.register("copy", function(_)
    local app_state = get_state()
    local messages = app_state.get_messages() or {}
    local last_text
    for i = #messages, 1, -1 do
        local m = messages[i]
        if m and m.role == "assistant" then
            if type(m.content) == "string" then
                last_text = m.content
            elseif type(m.content) == "table" then
                local parts = {}
                for _, block in ipairs(m.content) do
                    if type(block) == "string" then
                        parts[#parts + 1] = block
                    elseif type(block) == "table" and block.type == "text" and block.text then
                        parts[#parts + 1] = block.text
                    end
                end
                last_text = table.concat(parts, "")
            end
            if last_text and #last_text > 0 then break end
        end
    end
    if not last_text or last_text == "" then
        print("Nothing to copy — no assistant response yet.")
        return
    end
    local ok, err = copy_to_clipboard(last_text)
    if ok then
        print(string.format("Copied %d characters to clipboard.", #last_text))
    else
        print("Clipboard copy failed: " .. (err or "unknown"))
        print("Falling back to stdout:\n")
        print(last_text)
    end
end, {
    description = "Copy the last assistant response to the clipboard",
    usage = "/copy",
})

-- ── /commit-push-pr ───────────────────────────────────────────────────
-- Hand an engineered prompt to the assistant to stage/commit/push and open a PR.

registry.register("commit-push-pr", function(args)
    local ok_qe, query_engine = pcall(require, "engine.query_engine")
    if not ok_qe then
        print("(query engine not available)")
        return
    end
    local engine = query_engine.new({
        on_text = function(t) io.write(t); io.flush() end,
        on_error = function(err) io.stderr:write(tostring(err) .. "\n") end,
    })

    local extra = trim(args)
    local prompt = [[
Perform the following in order:
1. Check git status; if there are unstaged or untracked changes, stage them.
2. Write a Conventional Commits message (<=72 char subject + body if needed).
3. Create the commit.
4. Push the current branch to origin, setting upstream if missing.
5. Open a pull request using `gh pr create` targeting the repo default branch.
Cite file:line for any notable changes in the PR body. Stop and ask if the
working tree is dirty in a way that needs human judgement.
]]
    if extra ~= "" then
        prompt = prompt .. "\nAdditional instructions: " .. extra .. "\n"
    end

    local _, err = engine:query(prompt, { max_turns = 20 })
    if err then io.stderr:write("Query failed: " .. tostring(err) .. "\n") end
    print("")
end, {
    description = "Commit staged work, push the branch, and open a PR",
    usage = "/commit-push-pr [extra instructions]",
})

-- ── /insights ─────────────────────────────────────────────────────────

registry.register("insights", function(_)
    local app_state = get_state()
    local messages = app_state.get_messages() or {}
    local usage = app_state.get_usage()

    local user_msgs, assistant_msgs, tool_uses = 0, 0, 0
    local total_chars = 0
    for _, m in ipairs(messages) do
        if m.role == "user" then user_msgs = user_msgs + 1 end
        if m.role == "assistant" then assistant_msgs = assistant_msgs + 1 end
        if type(m.content) == "table" then
            for _, b in ipairs(m.content) do
                if type(b) == "table" and b.type == "tool_use" then tool_uses = tool_uses + 1 end
                if type(b) == "table" and b.type == "text" and b.text then
                    total_chars = total_chars + #b.text
                end
            end
        elseif type(m.content) == "string" then
            total_chars = total_chars + #m.content
        end
    end

    print("Session insights:")
    print(string.format("  User messages:      %d", user_msgs))
    print(string.format("  Assistant messages: %d", assistant_msgs))
    print(string.format("  Tool uses:          %d", tool_uses))
    print(string.format("  Total text length:  %d chars", total_chars))
    print(string.format("  Input tokens:       %d", usage.input_tokens))
    print(string.format("  Output tokens:      %d", usage.output_tokens))
    if user_msgs > 0 then
        print(string.format("  Avg tokens/turn:    %.1f",
            (usage.input_tokens + usage.output_tokens) / user_msgs))
    end
end, {
    description = "Analyze the current session (message and tool stats)",
    usage = "/insights",
})

-- ── /reload-plugins ───────────────────────────────────────────────────

registry.register("reload-plugins", function(_)
    local ok, plugins = pcall(require, "plugins.loader")
    if not ok or not plugins or not plugins.load_all then
        print("Plugin loader not available.")
        return
    end
    if plugins.reset then plugins.reset() end
    plugins.load_all()
    local list = (plugins.list and plugins.list()) or {}
    print(string.format("Plugins reloaded (%d active).", #list))
end, {
    description = "Reset and reload all plugins in the current session",
    usage = "/reload-plugins",
})

-- ── /rewind ───────────────────────────────────────────────────────────

registry.register("rewind", function(args)
    local app_state = get_state()
    local n = tonumber(trim(args)) or 1
    local messages = app_state.get_messages() or {}
    if #messages == 0 then
        print("Nothing to rewind: conversation is empty.")
        return
    end

    local removed = 0
    while removed < n and #messages > 0 do
        table.remove(messages)
        removed = removed + 1
    end
    if app_state.set_messages then
        app_state.set_messages(messages)
    else
        app_state.set("messages", messages)
    end
    print(string.format("Rewound %d message(s). %d remaining.", removed, #messages))
end, {
    description = "Remove the last N messages from the conversation",
    usage = "/rewind [n]",
})

-- ── /tag ──────────────────────────────────────────────────────────────

registry.register("tag", function(args)
    local app_state = get_state()
    local tag = trim(args)
    if tag == "" then
        local cur = app_state.get("session_tag")
        if not cur or cur == "" then
            print("No tag on the current session.")
            print("Usage: /tag <name>   (or /tag remove)")
        else
            print(string.format("Current session tag: #%s", cur))
        end
        return
    end
    if tag:lower() == "remove" or tag:lower() == "unset" then
        app_state.set("session_tag", nil)
        print("Session tag removed.")
        return
    end
    tag = tag:gsub("^#+", ""):gsub("%s+", "-")
    app_state.set("session_tag", tag)
    print(string.format("Session tagged #%s", tag))
end, {
    description = "Add, show, or remove a tag on the current session",
    usage = "/tag [name|remove]",
})

-- ── /terminal-setup ───────────────────────────────────────────────────

registry.register("terminal-setup", function(_)
    print("Terminal setup diagnostics:")
    print(string.format("  TERM:         %s", os.getenv("TERM") or "(unset)"))
    print(string.format("  COLORTERM:    %s", os.getenv("COLORTERM") or "(unset)"))
    print(string.format("  TERM_PROGRAM: %s", os.getenv("TERM_PROGRAM") or "(unset)"))
    print("")
    print("Recommended: TERM=xterm-256color and a Nerd Font with ligatures.")
    print("For keyboard protocol support (Shift+Enter, etc.), use a terminal")
    print("with the Kitty keyboard protocol: kitty, ghostty, wezterm, foot, alacritty.")
end, {
    description = "Show terminal capabilities and setup tips",
    usage = "/terminal-setup",
    aliases = { "terminalsetup", "terminalSetup" },
})

-- ── /statusline ───────────────────────────────────────────────────────

registry.register("statusline", function(args)
    local cfg = get_config()
    local arg = trim(args)
    if arg == "" then
        local current = cfg.get("statusline") or "(default)"
        print(string.format("Status line: %s", current))
        print("Set with:   /statusline \"<format>\"")
        print("Reset with: /statusline reset")
        print("")
        print("Format tokens: {cwd} {branch} {model} {provider} {usage}")
        return
    end
    if arg:lower() == "reset" or arg:lower() == "default" then
        cfg.set("statusline", nil)
        print("Status line reset to default.")
        return
    end
    cfg.set("statusline", arg)
    print(string.format("Status line set to: %s", arg))
end, {
    description = "Configure the REPL status line format",
    usage = "/statusline [<format>|reset]",
})

-- ── /upgrade ──────────────────────────────────────────────────────────

registry.register("upgrade", function(_)
    print("cli-agent upgrade instructions")
    print(string.rep("-", 40))
    print("This CLI is distributed from source. To upgrade:")
    print("")
    print("  cd <path-to-cloda-codey-lua>")
    print("  git pull")
    print("  make release")
    print("  sudo make install")
    print("")
    print("For the backend services, see:")
    print("  https://github.com/orpheus497/jenova")
end, {
    description = "Show upgrade instructions for cli-agent",
    usage = "/upgrade",
})

-- ── /release-notes ────────────────────────────────────────────────────
-- Show a local CHANGELOG if present, otherwise point to the repo.

registry.register("release-notes", function(args)
    local version = trim(args)
    local candidates = { "CHANGELOG.md", "CHANGES.md", "HISTORY.md" }
    local path
    for _, name in ipairs(candidates) do
        local f = io.open(name, "r")
        if f then f:close(); path = name; break end
    end
    if not path then
        print("No local changelog found.")
        print("See: https://github.com/orpheus497/cloda-codey-lua/releases")
        return
    end
    local f = io.open(path, "r")
    if not f then
        print("Failed to open " .. path)
        return
    end
    local content = f:read("*a") or ""
    f:close()
    if version ~= "" then
        local pat = "(#+%s*[vV]?" .. version:gsub("%.", "%%.") .. "[^\n]*\n.-)\n#+%s"
        local section = content:match(pat)
        if section then print(section) else print(content) end
    else
        print(content)
    end
end, {
    description = "Show release notes / changelog",
    usage = "/release-notes [version]",
})

return M
