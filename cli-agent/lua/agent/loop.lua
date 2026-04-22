-- agent/loop.lua — Unified REPL loop
--
-- The REPL (prompt, slash command dispatch, history, interrupt handling)
-- lives here. All LLM generation and tool execution is delegated to
-- engine/query_engine.lua — the single agentic loop implementation.
--
-- Full polished terminal UI via agent/ui.lua (restored from legacy-agent).

local M = {}

local function try_require(name)
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

function M.run(opts)
    local QueryEngine = try_require("engine.query_engine")
    local memory = try_require("agent.memory")
    local ui = try_require("agent.ui")
    local json = try_require("utils.json_fallback")
    local app_state = try_require("state.app_state")
    local config = try_require("config.loader")

    if not QueryEngine then
        io.stderr:write("Error: query engine not available\n")
        return 1
    end

    -- ── Startup: Full UI dashboard ──────────────────────────────────────
    if ui and ui.draw_header then
        io.write("\n")
        ui.draw_header()

        local info_opts = {
            cwd = os.getenv("JENOVA_CWD") or os.getenv("PWD") or ".",
        }

        if config then
            info_opts.provider = config.get("provider") or "llamacpp"
            info_opts.model = config.get("model") or opts.model or "auto"
        end

        local tool_registry = try_require("tools.registry")
        if tool_registry and tool_registry.list_tools then
            local tools = tool_registry.list_tools()
            info_opts.tools = tostring(#tools)
        end

        info_opts.turns = tostring(opts.max_turns or 100)

        if app_state and app_state.get then
            local sid = app_state.get("session_id")
            if sid then info_opts.session = sid end
        end

        ui.draw_info(info_opts)
        ui.separator("session")
        do
            local ok_reg, reg = pcall(require, "cli.commands.registry")
            local cmd_list
            if ok_reg and reg and reg.list_commands then
                local cmds = reg.list_commands()
                cmd_list = {}
                for _, c in ipairs(cmds) do
                    table.insert(cmd_list, "/" .. c.name)
                end
            else
                cmd_list = {
                    "/clear", "/compact", "/config", "/context", "/cost",
                    "/cwd", "/diag", "/doctor", "/diff", "/files",
                    "/help", "/history", "/mcp", "/model", "/plan",
                    "/provider", "/quit", "/sessions", "/session",
                    "/stats", "/thinking", "/tools", "/version", "/vim",
                }
            end
            ui.draw_commands(cmd_list)
        end
    else
        print("cli-agent 0.2.0 (C + Lua + llama.cpp)")
        print("Type your message or /help. Ctrl+D to exit.\n")
    end

    if memory and memory.init then
        memory.init()
    end

    -- Warm up the embedding model in the background so it is ready when the
    -- first tool failure occurs. Non-blocking: if the server is not running,
    -- embed.init() returns false and all embed calls degrade silently.
    local embed_ok, embed = pcall(require, "utils.embed")
    if embed_ok and embed and embed.init then
        pcall(embed.init)
    end

    -- ── Inject startup filesystem snapshot into system prompt ───────────
    -- Gives the model immediate awareness of the working directory tree
    -- so it can answer questions about files without needing tool calls.
    local context_mod = try_require("context.manager")
    local base_system_prompt = opts.system_prompt or ""
    if context_mod then
        local cwd = (app_state and app_state.get_cwd and app_state.get_cwd())
            or os.getenv("PWD") or "."
        local sys_ctx  = context_mod.get_system_context()
        local user_ctx = context_mod.get_user_context()

        local ctx_parts = {
            "## Environment",
            string.format("Platform: %s (%s)", sys_ctx.platform, sys_ctx.os_version or ""),
            string.format("Working directory: %s", cwd),
            string.format("Shell: %s", user_ctx.shell or "unknown"),
            string.format("User: %s", user_ctx.username or "unknown"),
        }

        if sys_ctx.is_git_repo then
            table.insert(ctx_parts, string.format("Git branch: %s", sys_ctx.git_branch or "unknown"))
            if sys_ctx.git_status and sys_ctx.git_status ~= "(clean)" then
                table.insert(ctx_parts, "Git status (short):\n" .. sys_ctx.git_status)
            else
                table.insert(ctx_parts, "Git status: clean")
            end
            local diff_stat = context_mod.get_git_diff_stat and context_mod.get_git_diff_stat()
            if diff_stat then
                table.insert(ctx_parts, "Git diff --stat HEAD:\n" .. diff_stat)
            end
        end

        -- Toolchain: probe PATH for compilers/build tools so the model
        -- knows what is actually available before attempting to compile.
        local toolchain = context_mod.get_toolchain and context_mod.get_toolchain()
        if toolchain then
            table.insert(ctx_parts, string.format("Available build tools: %s", toolchain))
        end

        local snapshot = context_mod.get_directory_snapshot(cwd, 400)
        if snapshot then
            table.insert(ctx_parts, "\n## Directory tree (cwd)\n" .. snapshot)
        end

        local ctx_block = table.concat(ctx_parts, "\n")
        if #base_system_prompt > 0 then
            base_system_prompt = base_system_prompt .. "\n\n" .. ctx_block
        else
            base_system_prompt = ctx_block
        end
    end

    -- Tool-use mandate: without this, models default to answering in plain text
    -- rather than using the tools they have been given.
    -- Kept deliberately short for 3B models — every token in the system prompt
    -- competes with context for code editing tasks.
    -- Rules are ordered by priority: the most commonly violated constraint first.
    local tool_mandate_lines = {
        "",
        "## Tools available",
        "- Read(file_path): read a file. ALWAYS call this before Edit or MultiEdit.",
        "- Edit(file_path, old_string, new_string): replace exact text. old_string must be copied verbatim from a prior Read. Never guess it.",
        "- MultiEdit(file_path, edits[]): batch several edits to one file. Prefer over multiple Edit calls.",
        "- Write(file_path, content): create or overwrite a file. Only for new files or full rewrites.",
        "- Glob(pattern): find files by name. Use before Read when path is uncertain.",
        "- Grep(pattern, path): search file contents. Use to locate a symbol or string.",
        "- Bash(command): run shell commands for build, compile, test, or install tasks. Not for file reading.",
        "- Brief(response): deliver your final reply to the user. Call this ONLY when the task is fully complete.",
    }

    -- Git tool: only mention it when we're actually in a git repo
    local context_mod2 = context_mod or try_require("context.manager")
    if context_mod2 and context_mod2.is_git_repository and context_mod2.is_git_repository() then
        table.insert(tool_mandate_lines, "- Git(subcommand, args): inspect the repo (diff, log, status, blame). Use to understand recent changes before editing. Only available inside a git repository.")
    end

    table.insert(tool_mandate_lines, "")
    table.insert(tool_mandate_lines, "## Rules (in order of importance)")
    table.insert(tool_mandate_lines, "1. ALWAYS call Read before Edit or MultiEdit. No exceptions. Never assume file content.")
    table.insert(tool_mandate_lines, "2. Copy old_string CHARACTER-FOR-CHARACTER from the Read output. Read returns lines as \"42\\t<content>\" — the old_string must contain ONLY the content after the tab, NOT the line-number prefix. Include every space, newline, and indent. Never reconstruct or guess it.")
    table.insert(tool_mandate_lines, "3. If Edit fails with 'not found': a [System:] message will inject the current file content. Read that injected content, copy exact text, then Edit.")
    table.insert(tool_mandate_lines, "4. Do NOT call Read on the same file twice in a row — the system already cached it. If you need the content again, read the [System:] injection in the conversation.")
    table.insert(tool_mandate_lines, "5. Use MultiEdit when making more than one change to the same file. Do not chain multiple single Edit calls.")
    table.insert(tool_mandate_lines, "6. To build/compile/run tests: use Bash(command). Never use Read to check compiler output.")
    table.insert(tool_mandate_lines, "7. If old_string == new_string the edit is already done — call Brief to confirm it.")
    table.insert(tool_mandate_lines, "8. Do NOT repeat any failed tool call with the same arguments. Read the [System:] hint and change your approach.")
    table.insert(tool_mandate_lines, "9. After two failed Edit attempts on the same file: report what you tried and what failed, then call Brief.")
    table.insert(tool_mandate_lines, "10. Call Brief only when the task is FULLY complete. Never call it mid-task.")

    local tool_mandate = table.concat(tool_mandate_lines, "\n")
    base_system_prompt = base_system_prompt .. tool_mandate

    local thinking_buf = ""
    local thinking_tokens = 0
    -- Tracks whether the agent label has been printed for the current turn.
    -- Must be reset at the start of each agent_turn() call.
    local label_printed = false

    local engine = QueryEngine.new({
        model = opts.model,
        system_prompt = base_system_prompt,
        max_tokens = opts.max_tokens,
        temperature = opts.temperature,
        thinking_enabled = opts.thinking_enabled,

        on_text = function(text)
            -- Stop spinner and print the "jenova │ " label exactly once before
            -- the first streamed token of each turn. This must happen here
            -- (not after query() returns) so the label precedes the text.
            if ui and ui.spinner_stop then ui.spinner_stop() end
            if not label_printed then
                label_printed = true
                if ui and ui.agent_label then ui.agent_label() end
            end
            io.write(text)
            io.flush()
        end,

        on_thinking = function(text)
            thinking_buf = thinking_buf .. text
            thinking_tokens = thinking_tokens + 1
            if ui and ui.thinking_inline then
                ui.thinking_inline(thinking_tokens)
            end
        end,

        on_tool_use = function(tool_name, input, summary)
            if ui and ui.spinner_stop then ui.spinner_stop() end
            -- Show tool name + summary of what it's acting on
            local label = tool_name
            if summary and #summary > 0 then
                label = tool_name .. ": " .. summary
            end
            if ui and ui.tool_badge then
                ui.tool_badge(label, "running")
            elseif ui and ui.status_info then
                ui.status_info(label .. " …")
            end
            -- For action tools, show extra detail so the user knows exactly what will run
            if ui and ui.status_info then
                local mgr_ok, mgr = pcall(require, "permissions.manager")
                if mgr_ok and mgr and mgr.is_action_tool and mgr.is_action_tool(tool_name) then
                    if type(input) == "table" then
                        if input.command then
                            ui.status_info("  $ " .. input.command:sub(1, 120))
                        elseif input.file_path then
                            ui.status_info("  " .. input.file_path)
                        end
                    end
                end
            end
        end,

        on_tool_result = function(tool_name, result)
            -- Determine success/failure from the result table
            local status = "done"
            local detail = nil
            if type(result) == "table" then
                if result.type == "error" then
                    status = "failed"
                    detail = result.error
                elseif result.exit_code and result.exit_code ~= 0 then
                    status = "failed"
                    detail = "exit " .. tostring(result.exit_code)
                elseif result.num_lines then
                    detail = tostring(result.num_lines) .. " lines"
                elseif result.num_files then
                    detail = tostring(result.num_files) .. " files"
                end
            end
            if ui and ui.tool_badge then
                ui.tool_badge(tool_name, status)
            elseif ui and ui.status_info then
                ui.status_info(tool_name .. " " .. status)
            end
            if detail and ui and ui.status_info then
                ui.status_info("  " .. detail)
            end
        end,

        on_error = function(err)
            if ui and ui.status_err then
                ui.status_err(tostring(err))
            else
                io.stderr:write("Error: " .. tostring(err) .. "\n")
            end
        end,
    })

    local turn_count = 0
    local max_turns = opts.max_turns or 100

    local cmd_registry = nil
    local function get_cmd_registry()
        if cmd_registry == nil then
            local ok_reg, reg = pcall(require, "cli.commands.registry")
            cmd_registry = ok_reg and reg or false
        end
        return cmd_registry
    end

    local function agent_turn(user_input)
        turn_count = turn_count + 1
        if turn_count > max_turns then
            if ui then ui.status_warn("max turns reached — use /clear to reset") end
            return "Max turns reached. Use /clear to reset."
        end

        -- Turn indicator
        if ui and ui.status_turn then
            ui.status_turn(turn_count, max_turns, "thinking")
        end

        -- Reset thinking buffer
        thinking_buf = ""
        thinking_tokens = 0

        -- Inject memory context on top of the rich base system prompt
        local system_prompt = base_system_prompt
        if memory and memory.build_context then
            local ctx = memory.build_context()
            if ctx and #ctx > 0 then
                system_prompt = system_prompt .. "\n\n" .. ctx
            end
        end
        engine.system_prompt = system_prompt

        -- Reset the label flag so agent_label fires again on first token
        label_printed = false

        -- Start spinner
        if ui and ui.spinner_start then
            ui.spinner_start("cognizing")
        end

        local result, err = engine:query(user_input, {
            max_turns = opts.agent_max_turns or 25,
        })

        -- Stop spinner (idempotent — on_text may have already stopped it)
        if ui and ui.spinner_stop then
            ui.spinner_stop()
        end
        -- If no text was ever streamed (e.g. pure Brief response), print label now
        if not label_printed then
            label_printed = true
            if ui and ui.agent_label then ui.agent_label() end
        end

        -- Clear inline thinking indicator and show a brief snippet of what was concluded
        if ui and ui.thinking_inline_done and thinking_tokens > 0 then
            ui.thinking_inline_done()
            if #thinking_buf > 0 and ui.think_summary then
                -- Extract the last meaningful sentence from the thinking buffer
                -- as a summary of what the model concluded before acting.
                local snippet = thinking_buf
                -- Strip leading/trailing whitespace
                snippet = snippet:match("^%s*(.-)%s*$") or snippet
                -- Prefer last non-empty sentence (after final period/newline cluster)
                local last_sent = snippet:match("[%.!?]%s*([^%.!?\n][^\n%.!?]+)%s*$")
                    or snippet:match("\n([^\n]+)%s*$")
                if last_sent and #last_sent > 15 then
                    snippet = last_sent:match("^%s*(.-)%s*$") or last_sent
                else
                    -- Fall back to first 120 chars
                    snippet = snippet:sub(1, 120)
                end
                ui.think_summary(snippet)
            end
        end

        if not result then
            if ui then
                ui.status_err("query failed: " .. tostring(err))
                ui.diagnostic("Check backend with /diag or /backend status")
            end
            return nil
        end

        -- Update cost tracking
        if app_state and app_state.update_usage then
            local usage = engine:get_usage()
            local prev_in = app_state.get("_last_input_tokens") or 0
            local prev_out = app_state.get("_last_output_tokens") or 0
            local prev_cost = app_state.get("_last_cost") or 0
            app_state.update_usage(
                usage.input_tokens - prev_in,
                usage.output_tokens - prev_out,
                usage.total_cost_usd - prev_cost
            )
            app_state.set("_last_input_tokens", usage.input_tokens)
            app_state.set("_last_output_tokens", usage.output_tokens)
            app_state.set("_last_cost", usage.total_cost_usd)
        end

        -- Show token usage if config says so
        if config and config.get("show_cost") and ui and ui.token_usage then
            local usage = engine:get_usage()
            ui.token_usage(usage.input_tokens, usage.output_tokens, usage.total_cost_usd)
        end

        return result.text or ""
    end

    -- Check for interrupt: the C host may expose a global, or we no-op
    local _is_interrupted = rawget(_G, "is_interrupted")
    local function check_interrupted()
        if type(_is_interrupted) == "function" then
            return _is_interrupted()
        end
        return false
    end

    -- ── Main REPL loop ──────────────────────────────────────────────────
    while true do
        if check_interrupted() then
            if ui and ui.status_warn then
                ui.status_warn("interrupted")
            else
                print("\nInterrupted.")
            end
            break
        end

        -- Write prompt
        if ui and ui.write_prompt then
            ui.write_prompt()
        elseif ui and ui.prompt then
            io.write(ui.prompt())
            io.flush()
        else
            io.write("> ")
            io.flush()
        end

        local line = io.read("*l")
        if not line then
            if ui and ui.goodbye then
                ui.goodbye()
            else
                print("\nGoodbye!")
            end
            break
        end

        -- Trim
        line = line:match("^%s*(.-)%s*$")
        if #line == 0 then goto continue end

        -- Multi-line input (backslash continuation)
        while line:sub(-1) == "\\" do
            line = line:sub(1, -2) .. "\n"
            if ui and ui.continuation_prompt then
                ui.continuation_prompt()
            else
                io.write("... "); io.flush()
            end
            local nl = io.read("*l")
            if not nl then break end
            line = line .. nl
        end

        -- Commands
        if line == "/exit" or line == "/quit" or line == "/q" or line == "\3" then
            if ui and ui.goodbye then ui.goodbye()
            else print("Goodbye!") end
            break
        elseif line == "/clear" then
            engine.messages = {}
            turn_count = 0
            if memory and memory.clear then memory.clear() end
            if app_state then
                if app_state.clear_messages then app_state.clear_messages() end
                if app_state.reset_usage then app_state.reset_usage() end
            end
            if ui then ui.status_ok("cleared (session + history)")
            else print("Session cleared.") end
        elseif line == "/history" then
            if ui and ui.dimtext then
                for i, m in ipairs(engine.messages) do
                    ui.dimtext(string.format("  [%d] %s: %s\n", i, m.role, tostring(m.content):sub(1, 80)))
                end
            else
                print(string.format("Turns: %d, Messages: %d", turn_count, #engine.messages))
            end
        elseif line == "/debug" then
            if json then
                print(json.stringify({
                    turns = turn_count,
                    messages = #engine.messages,
                    usage = engine:get_usage(),
                }))
            end
        elseif line == "/context" then
            if memory and memory.build_context then
                if ui and ui.dimtext then
                    ui.dimtext("=== Context ===\n" .. memory.build_context() .. "\n=== End ===\n")
                else
                    print(memory.build_context())
                end
            end
        elseif line:sub(1, 1) == "/" then
            local cmd_name = line:match("^/(%S+)")
            local cmd_args = line:match("^/%S+%s+(.*)") or ""
            local reg = get_cmd_registry()
            local handler = reg and reg.get_command(cmd_name) or nil
            if handler then
                pcall(handler, cmd_args)
            else
                if ui and ui.status_err then
                    ui.status_err("unknown command: " .. line .. " — try /help")
                else
                    print("Unknown command: " .. line)
                end
            end
        else
            -- Agent query
            local response = agent_turn(line)
            if response and #response > 0 then
                -- Response was already streamed via on_text callback
                if ui and ui.stream_end then
                    ui.stream_end()
                else
                    print("")
                end
            else
                print("")
            end
        end

        ::continue::
    end

    -- ── Shutdown ────────────────────────────────────────────────────────
    if memory and memory.save then
        memory.save()
    end

    if app_state and app_state.save_session then
        pcall(app_state.save_session)
    end

    local _jenova = rawget(_G, "jenova")
    if type(_jenova) == "table" and _jenova.agent and _jenova.agent.shutdown then
        _jenova.agent.shutdown()
    end
    return 0
end

return M
