-- coordinator/coordinator_mode.lua
--
-- Decides whether the CLI is running in "coordinator mode" (delegates work to
-- worker agents) and produces the system prompt and user-context injection
-- used by the query engine when it is.

local M = {}

local ENV_FLAG = "JENOVA_COORDINATOR_MODE"
local SIMPLE_FLAG = "JENOVA_SIMPLE"

local TOOL_NAMES = {
    AGENT = "Agent",
    BASH = "Bash",
    FILE_READ = "Read",
    FILE_EDIT = "Edit",
    SEND_MESSAGE = "SendMessage",
    SYNTHETIC_OUTPUT = "SyntheticOutput",
    TASK_STOP = "TaskStop",
    TEAM_CREATE = "TeamCreate",
    TEAM_DELETE = "TeamDelete",
}

-- Tools that only exist inside the worker → coordinator channel and should
-- not appear in the user-visible worker tool list.
local INTERNAL_WORKER_TOOLS = {
    [TOOL_NAMES.TEAM_CREATE] = true,
    [TOOL_NAMES.TEAM_DELETE] = true,
    [TOOL_NAMES.SEND_MESSAGE] = true,
    [TOOL_NAMES.SYNTHETIC_OUTPUT] = true,
}

-- Matches the TS isEnvTruthy helper: any non-empty non-"0"/"false" value.
local function env_truthy(name)
    local v = os.getenv(name)
    if not v or v == "" then return false end
    local lower = v:lower()
    return lower ~= "0" and lower ~= "false" and lower ~= "no"
end

function M.is_coordinator_mode()
    return env_truthy(ENV_FLAG)
end

--- Align coordinator mode with a resumed session's stored mode.
--- Returns a user-facing message when the mode was switched, or nil.
function M.match_session_mode(session_mode)
    if not session_mode then return nil end

    local current = M.is_coordinator_mode()
    local session_is_coord = session_mode == "coordinator"
    if current == session_is_coord then return nil end

    -- NOTE: os.setenv exists on some Lua ports but not the stdlib. Callers
    -- running on vanilla Lua should shell out or use an FFI helper; here we
    -- best-effort call a jenova.system.setenv if the host exposes one.
    if jenova and jenova.system and jenova.system.setenv then
        if session_is_coord then
            jenova.system.setenv(ENV_FLAG, "1")
        else
            jenova.system.setenv(ENV_FLAG, "")
        end
    end

    if session_is_coord then
        return "Entered coordinator mode to match resumed session."
    else
        return "Exited coordinator mode to match resumed session."
    end
end

local function sort_copy(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    table.sort(out)
    return out
end

--- Build the user-context injection that tells the coordinator LLM what
--- tools its workers have. `mcp_clients` is a list of { name = ... } tables.
function M.get_coordinator_user_context(mcp_clients, scratchpad_dir, async_agent_allowed_tools, scratchpad_gate_enabled)
    if not M.is_coordinator_mode() then return {} end

    local worker_tools
    if env_truthy(SIMPLE_FLAG) then
        worker_tools = table.concat(sort_copy({
            TOOL_NAMES.BASH, TOOL_NAMES.FILE_READ, TOOL_NAMES.FILE_EDIT,
        }), ", ")
    else
        local filtered = {}
        for _, name in ipairs(async_agent_allowed_tools or {}) do
            if not INTERNAL_WORKER_TOOLS[name] then
                table.insert(filtered, name)
            end
        end
        worker_tools = table.concat(sort_copy(filtered), ", ")
    end

    local content = "Workers spawned via the " .. TOOL_NAMES.AGENT ..
        " tool have access to these tools: " .. worker_tools

    if mcp_clients and #mcp_clients > 0 then
        local names = {}
        for _, c in ipairs(mcp_clients) do table.insert(names, c.name) end
        content = content ..
            "\n\nWorkers also have access to MCP tools from connected MCP servers: " ..
            table.concat(names, ", ")
    end

    if scratchpad_dir and scratchpad_gate_enabled then
        content = content ..
            "\n\nScratchpad directory: " .. scratchpad_dir ..
            "\nWorkers can read and write here without permission prompts. " ..
            "Use this for durable cross-worker knowledge — structure files however fits the work."
    end

    return { worker_tools_context = content }
end

--- Return the coordinator system prompt.
function M.get_coordinator_system_prompt()
    local worker_capabilities
    if env_truthy(SIMPLE_FLAG) then
        worker_capabilities =
            "Workers have access to Bash, Read, and Edit tools, plus MCP tools from configured MCP servers."
    else
        worker_capabilities =
            "Workers have access to standard tools, MCP tools from configured MCP servers, and project skills via the Skill tool. Delegate skill invocations (e.g. /commit, /verify) to workers."
    end

    local T = TOOL_NAMES
    return table.concat({
        "You are cli-agent, the Jenova Cognitive Architecture's terminal agent that orchestrates software engineering tasks across multiple workers.",
        "",
        "## 1. Your Role",
        "",
        "You are a **coordinator**. Your job is to:",
        "- Help the user achieve their goal",
        "- Direct workers to research, implement and verify code changes",
        "- Synthesize results and communicate with the user",
        "- Answer questions directly when possible — don't delegate work that you can handle without tools",
        "",
        "## 2. Your Tools",
        "",
        "- **" .. T.AGENT .. "** — Spawn a new worker",
        "- **" .. T.SEND_MESSAGE .. "** — Continue an existing worker",
        "- **" .. T.TASK_STOP .. "** — Stop a running worker",
        "",
        "## 3. Workers",
        "",
        worker_capabilities,
        "",
        "## 4. Task Workflow",
        "",
        "| Phase | Who | Purpose |",
        "|-------|-----|---------|",
        "| Research | Workers (parallel) | Investigate codebase, find files, understand problem |",
        "| Synthesis | You (coordinator) | Read findings, understand the problem, craft implementation specs |",
        "| Implementation | Workers | Make targeted changes per spec, commit |",
        "| Verification | Workers | Test changes work |",
        "",
        "Parallelism is your superpower. Launch independent workers concurrently whenever possible.",
        "",
        "## 5. Writing Worker Prompts",
        "",
        "Workers can't see your conversation. Every prompt must be self-contained with file paths, line numbers, error messages, and a clear definition of done. Never write \"based on your findings\" — synthesize the findings yourself and hand the worker a concrete spec.",
    }, "\n")
end

M.TOOL_NAMES = TOOL_NAMES
M.INTERNAL_WORKER_TOOLS = INTERNAL_WORKER_TOOLS

return M
