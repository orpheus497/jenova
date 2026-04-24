-- tools/agent.lua — AgentTool: Spawn sub-agents for independent tasks
-- Sub-agents run with their own context and can use a subset of tools.

local json = require("utils.json_fallback")

-- Seed the RNG once at module load. Reseeding on every call() would reset
-- the sequence each invocation and make IDs predictable when multiple
-- agents are spawned in the same second. os.clock() contributes fractional
-- entropy so repeated module reloads in a single process still differ.
math.randomseed(os.time() + math.floor((os.clock() or 0) * 1e6))

local M = {}
M.name = "Agent"
M.description = "Launch a new agent to handle complex, multi-step tasks independently."

M.parameters = {
    type = "object",
    properties = {
        description = { type = "string", description = "Short (3-5 word) description of the task" },
        prompt = { type = "string", description = "The task for the agent to perform" },
        subagent_type = { type = "string", description = "Agent type (general-purpose, Explore, Plan)" },
        run_in_background = { type = "boolean", description = "Run agent in background" },
    },
    required = { "description", "prompt" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name(input)
    return input and input.description and ("Agent: " .. input.description) or "Agent"
end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local prompt = args.prompt
    if not prompt then return { type = "error", error = "No prompt provided" } end

    local description = args.description or "sub-agent"
    local run_in_background = args.run_in_background == true

    -- RNG is seeded once at module load (see top of file). Compose a short
    -- id from the current timestamp plus a random suffix to avoid collisions
    -- when multiple agents are spawned in the same second.
    local agent_id = string.format("agent-%d-%04x", os.time(), math.random(0, 65535))

    local ok_qe, query_engine_mod = pcall(require, "engine.query_engine")
    if not ok_qe then
        return {
            type = "text",
            text = string.format("[Agent '%s' would process: %s]", description, prompt:sub(1, 200)),
        }
    end

    -- Background mode: register the task and return immediately.
    -- The task can be polled via TaskGet/TaskOutput.
    if run_in_background then
        local app_state = require("state.app_state")
        local tasks = app_state.get("active_tasks") or {}
        table.insert(tasks, {
            id = agent_id,
            description = description,
            prompt = prompt,
            status = "pending",
            started_at = os.time(),
            background = true,
        })
        app_state.set("active_tasks", tasks)

        return {
            type = "text",
            text = string.format(
                "Agent '%s' (id: %s) queued in background. Poll with TaskGet/TaskOutput.",
                description, agent_id
            ),
            task_id = agent_id,
        }
    end

    -- Collect agent output
    local output_parts = {}

    local agent_engine = query_engine_mod.new({
        system_prompt = "You are a sub-agent. Complete the assigned task efficiently.",
        on_text = function(text)
            table.insert(output_parts, text)
        end,
        on_error = function(err)
            table.insert(output_parts, "[Error: " .. tostring(err) .. "]")
        end,
    })

    local result, err = agent_engine:query(prompt, { max_turns = 10 })

    if err then
        return {
            type = "text",
            text = string.format("Agent '%s' failed: %s", description, err),
        }
    end

    local agent_output = result and result.text or table.concat(output_parts)

    -- Register completed task in app state
    local app_state = require("state.app_state")
    local tasks = app_state.get("active_tasks") or {}
    table.insert(tasks, {
        id = agent_id,
        description = description,
        status = "completed",
        output = agent_output,
        completed_at = os.time(),
    })
    app_state.set("active_tasks", tasks)

    return {
        type = "text",
        text = agent_output,
    }
end

return M
