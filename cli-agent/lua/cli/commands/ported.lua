-- cli/commands/ported.lua — Additional Jenova CLI slash commands
-- Git workflow helpers, session management, and convenience utilities
-- focused on the Jenova cognitive architecture use-case.

local M = {}

local registry = require("cli.commands.registry")

-- ── Helpers ───────────────────────────────────────────────────────────

local function trim(s)
    if not s then return "" end
    return (s:match("^%s*(.-)%s*$")) or ""
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

-- ── /copy ─────────────────────────────────────────────────────────────

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

return M
