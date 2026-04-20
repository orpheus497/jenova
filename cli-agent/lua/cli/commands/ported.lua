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

-- ── /advisor ──────────────────────────────────────────────────────────
-- Configure the advisor model — an auxiliary model used for planning/review.

registry.register("advisor", function(args)
    local cfg = get_config()
    local arg = trim(args):lower()

    if arg == "" then
        local current = cfg.get("advisor_model")
        if not current or current == "" then
            print("Advisor: not set")
            print('Use "/advisor <model>" to enable (e.g. "/advisor claude-opus-4-5-20251101").')
        else
            print(string.format("Advisor: %s", current))
            print('Use "/advisor unset" to disable or "/advisor <model>" to change.')
        end
        return
    end

    if arg == "unset" or arg == "off" or arg == "disable" then
        cfg.set("advisor_model", nil)
        print("Advisor disabled.")
        return
    end

    cfg.set("advisor_model", arg)
    print(string.format("Advisor set to: %s", arg))
end, {
    description = "Configure the advisor (auxiliary) model",
    usage = "/advisor [model|unset]",
})

-- ── /agents ───────────────────────────────────────────────────────────
-- Manage named agent configurations stored in config.agents.

registry.register("agents", function(args)
    local cfg = get_config()
    local sub, rest = first_word(args)
    local agents = cfg.get("agents")
    if type(agents) ~= "table" then
        -- Repair any non-table value that somehow made it into config.
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
    -- Brief mode is read by BriefTool and the query engine via AppState.
    -- We also mirror the flag into config so it survives a restart.
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
-- Ask a quick side question. In TS this opens a side-conversation dialog;
-- here we simply forward the prompt to the assistant with a framing hint
-- so the main conversation context is not disturbed in the user's mind.

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

-- ── /bridge ───────────────────────────────────────────────────────────
-- Minimal bridge status / toggle. The full TS bridge integrates with the
-- Jenova remote-control server; here we expose its on/off state and URL.

registry.register("bridge", function(args)
    local cfg = get_config()
    local sub, rest = first_word(args)

    if not sub or sub == "status" then
        local enabled = cfg.get("bridge_enabled") and true or false
        local url = cfg.get("bridge_url") or "(not set)"
        print(string.format("Bridge: %s", enabled and "enabled" or "disabled"))
        print(string.format("Bridge URL: %s", url))
    elseif sub == "on" or sub == "enable" then
        cfg.set("bridge_enabled", true)
        print("Bridge enabled. Set URL with /bridge url <url>.")
    elseif sub == "off" or sub == "disable" then
        cfg.set("bridge_enabled", false)
        print("Bridge disabled.")
    elseif sub == "url" then
        local url = rest and trim(rest) or ""
        if url == "" then
            print(string.format("Bridge URL: %s", cfg.get("bridge_url") or "(not set)"))
        else
            cfg.set("bridge_url", url)
            print(string.format("Bridge URL set to %s", url))
        end
    else
        print("Bridge commands:")
        print("  /bridge            Show status")
        print("  /bridge on|off     Enable/disable")
        print("  /bridge url <url>  Set the remote-control URL")
    end
end, {
    description = "Manage remote-control bridge session",
    usage = "/bridge [status|on|off|url]",
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
    description = "Set the prompt accent color (stored in config; read by REPL on next prompt)",
    usage = "/color [name]",
})

-- ── /copy ─────────────────────────────────────────────────────────────
-- Copy the assistant's last response text to the clipboard.

registry.register("copy", function(args)
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
-- Hand an engineered prompt to the assistant to stage/commit/push and open
-- a PR. Mirrors the flow from the TS command.

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

-- ── /extra-usage ──────────────────────────────────────────────────────

registry.register("extra-usage", function(args)
    local cfg = get_config()
    local arg = trim(args):lower()
    if arg == "on" or arg == "enable" then
        cfg.set("extra_usage_enabled", true)
        print("Extra usage: enabled (will continue after rate limits using fallback)")
    elseif arg == "off" or arg == "disable" then
        cfg.set("extra_usage_enabled", false)
        print("Extra usage: disabled")
    elseif arg == "" then
        local enabled = cfg.get("extra_usage_enabled") and true or false
        print(string.format("Extra usage: %s", enabled and "enabled" or "disabled"))
        print("When enabled, the CLI auto-falls-back to a secondary provider on 429/quota errors.")
    else
        print("Usage: /extra-usage [on|off]")
    end
end, {
    description = "Configure fallback usage after hitting rate limits",
    usage = "/extra-usage [on|off]",
})

-- ── /fast ─────────────────────────────────────────────────────────────
-- Toggle "fast" mode: swap to a lower-latency model for this session.

registry.register("fast", function(args)
    local cfg = get_config()
    local arg = trim(args):lower()
    local fast_model = cfg.get("fast_model") or cfg.get("model")

    local function enable()
        cfg.set("fast_mode", true)
        cfg.set("previous_model", cfg.get("model"))
        cfg.set("model", fast_model)
        print(string.format("Fast mode: enabled (model=%s)", tostring(fast_model)))
        print("Note: restart the REPL for the change to take effect in the active session.")
    end
    local function disable()
        cfg.set("fast_mode", false)
        local prev = cfg.get("previous_model")
        cfg.set("model", prev)
        cfg.set("previous_model", nil)
        print(string.format("Fast mode: disabled (model=%s)", tostring(prev)))
        print("Note: restart the REPL for the change to take effect in the active session.")
    end

    if arg == "on" or arg == "enable" then
        enable()
    elseif arg == "off" or arg == "disable" then
        disable()
    elseif arg == "" then
        if cfg.get("fast_mode") then disable() else enable() end
    else
        print("Usage: /fast [on|off]")
    end
end, {
    description = "Toggle fast (low-latency) model mode (REPL restart required to take effect)",
    usage = "/fast [on|off]",
})

-- ── /ide ──────────────────────────────────────────────────────────────

registry.register("ide", function(args)
    local sub = first_word(args)
    if not sub or sub == "status" then
        local ide_env = os.getenv("TERM_PROGRAM") or os.getenv("TERMINAL_EMULATOR") or "(unknown)"
        print("IDE integration status:")
        print(string.format("  Terminal:         %s", ide_env))
        print(string.format("  VSCode env:       %s", os.getenv("VSCODE_INJECTION") and "detected" or "not detected"))
        print(string.format("  Cursor env:       %s", os.getenv("CURSOR_TRACE_ID") and "detected" or "not detected"))
        print(string.format("  JetBrains env:    %s", os.getenv("TERMINAL_EMULATOR") == "JetBrains-JediTerm" and "detected" or "not detected"))
    elseif sub == "install" then
        print("IDE extension installation is not wired up in this build.")
        print("Install the cli-agent extension from your IDE marketplace manually.")
    else
        print("IDE commands:")
        print("  /ide status   Show detected IDE/terminal")
        print("  /ide install  Install/refresh IDE extension (manual)")
    end
end, {
    description = "Show IDE integration status",
    usage = "/ide [status|install]",
})

-- ── /insights ─────────────────────────────────────────────────────────

registry.register("insights", function(args)
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
    print(string.format("  Cost:               $%.4f", usage.total_cost_usd))
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

-- ── /remote-env ───────────────────────────────────────────────────────

registry.register("remote-env", function(args)
    local cfg = get_config()
    local sub, rest = first_word(args)
    local function get_env()
        local e = cfg.get("remote_env")
        if type(e) ~= "table" then e = {} end
        return e
    end
    if not sub or sub == "show" then
        local env = get_env()
        local count = 0
        for _ in pairs(env) do count = count + 1 end
        if count == 0 then
            print("No remote env vars set.")
            print('Use "/remote-env set KEY=VALUE" to add one.')
            return
        end
        print(string.format("Remote environment (%d):", count))
        for k, v in pairs(env) do
            local val = tostring(v)
            if k:match("KEY$") or k:match("TOKEN$") or k:match("SECRET$") then
                val = val:sub(1, 4) .. "..." .. val:sub(-2)
            end
            print(string.format("  %s=%s", k, val))
        end
    elseif sub == "set" then
        local kv = rest and trim(rest) or ""
        local k, v = kv:match("^([^=]+)=(.*)$")
        if not k then
            print("Usage: /remote-env set KEY=VALUE")
            return
        end
        local env = get_env()
        env[k] = v
        cfg.set("remote_env", env)
        print(string.format("Set remote env %s", k))
    elseif sub == "unset" then
        local key = rest and trim(rest) or ""
        if key == "" then
            print("Usage: /remote-env unset <KEY>")
            return
        end
        local env = get_env()
        env[key] = nil
        cfg.set("remote_env", env)
        print(string.format("Unset remote env %s", key))
    else
        print("Remote-env commands:")
        print("  /remote-env show            List remote env vars")
        print("  /remote-env set KEY=VALUE   Set a remote env var")
        print("  /remote-env unset KEY       Remove a remote env var")
    end
end, {
    description = "Configure the default environment for remote (teleport) sessions",
    usage = "/remote-env [show|set|unset]",
})

-- ── /remote-setup ─────────────────────────────────────────────────────

registry.register("remote-setup", function(_)
    print("Jenova CLI — Remote Setup")
    print(string.rep("-", 40))
    print("Remote mode delegates inference to a Jenova backend host.")
    print("Configure it with:")
    print("  /config remote_host=<host>")
    print("  /config remote_port=<port>")
    print("  /remote-env set JENOVA_API_KEY=<key>")
    print("")
    print("Then enable with:")
    print("  /provider set jenova_backend")
    print("  /bridge on")
end, {
    description = "Instructions for setting up a remote Jenova backend",
    usage = "/remote-setup",
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

-- ── /sandbox-toggle ───────────────────────────────────────────────────
-- Alias for /sandbox on|off (the full /sandbox command exists in extended.lua).

registry.register("sandbox-toggle", function(_)
    local cfg = get_config()
    local cur = cfg.get("sandbox_enabled") and true or false
    cfg.set("sandbox_enabled", not cur)
    print(string.format("Sandbox: %s", (not cur) and "enabled" or "disabled"))
end, {
    description = "Quick-toggle the filesystem sandbox",
    usage = "/sandbox-toggle",
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
    -- Normalize: strip leading # and spaces.
    tag = tag:gsub("^#+", ""):gsub("%s+", "-")
    app_state.set("session_tag", tag)
    print(string.format("Session tagged #%s", tag))
end, {
    description = "Add, show, or remove an in-memory tag on the current session (not persisted across restarts)",
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

-- ── /voice ────────────────────────────────────────────────────────────

registry.register("voice", function(args)
    local cfg = get_config()
    local arg = trim(args):lower()
    if arg == "on" or arg == "enable" then
        cfg.set("voice_enabled", true)
        print("Voice mode: enabled (requires voice backend to be configured)")
    elseif arg == "off" or arg == "disable" then
        cfg.set("voice_enabled", false)
        print("Voice mode: disabled")
    elseif arg == "" then
        local cur = cfg.get("voice_enabled") and true or false
        cfg.set("voice_enabled", not cur)
        print(string.format("Voice mode: %s", (not cur) and "enabled" or "disabled"))
    else
        print("Usage: /voice [on|off]")
    end
end, {
    description = "Toggle voice input/output mode",
    usage = "/voice [on|off]",
})

-- ── /x402 ─────────────────────────────────────────────────────────────
-- Configure x402 USDC-on-Base payments. We only store config; actual
-- payment execution belongs in a dedicated service.

registry.register("x402", function(args)
    local cfg = get_config()
    local sub, rest = first_word(args)

    if not sub or sub == "status" then
        local enabled = cfg.get("x402_enabled") and true or false
        local addr = cfg.get("x402_wallet_address") or "(not set)"
        local max = cfg.get("x402_max_spend_usd")
        print(string.format("x402: %s", enabled and "enabled" or "disabled"))
        print(string.format("Wallet: %s", addr))
        print(string.format("Max spend: $%s USD", max and tostring(max) or "unlimited"))
    elseif sub == "on" or sub == "enable" then
        cfg.set("x402_enabled", true)
        print("x402 payments: enabled")
    elseif sub == "off" or sub == "disable" then
        cfg.set("x402_enabled", false)
        print("x402 payments: disabled")
    elseif sub == "wallet" then
        local addr = rest and trim(rest) or ""
        if addr == "" then
            print(string.format("Wallet: %s", cfg.get("x402_wallet_address") or "(not set)"))
        else
            cfg.set("x402_wallet_address", addr)
            print("Wallet set.")
        end
    elseif sub == "limit" then
        local v = tonumber(trim(rest or ""))
        if not v then
            print("Usage: /x402 limit <usd-amount>")
            return
        end
        cfg.set("x402_max_spend_usd", v)
        print(string.format("Max spend set to $%.2f.", v))
    else
        print("x402 commands:")
        print("  /x402              Show status")
        print("  /x402 on|off       Enable/disable")
        print("  /x402 wallet <addr> Set wallet address")
        print("  /x402 limit <usd>  Set max spend in USD")
    end
end, {
    description = "Configure x402 USDC-on-Base payment settings",
    usage = "/x402 [status|on|off|wallet|limit]",
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
        -- Try to extract just the requested version's section.
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

-- ── Plugin-moved stubs ────────────────────────────────────────────────

local function moved_to_plugin(plugin_name)
    return function(_)
        print(string.format(
            "This command has moved to a plugin. Install it with:\n  /plugins install %s",
            plugin_name))
    end
end

registry.register("pr-comments",
    moved_to_plugin("pr-comments"),
    { description = "(moved) Fetch and reply to pull request review comments",
      usage = "/pr-comments", aliases = { "pr_comments" } })

registry.register("security-review",
    moved_to_plugin("security-review"),
    { description = "(moved) Run a security review of pending changes",
      usage = "/security-review" })

return M
