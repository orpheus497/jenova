-- tools/skill.lua — SkillTool: Load and execute named skills
-- Skills are pre-defined prompts/workflows loaded from the skills directory.

local M = {}
M.name = "Skill"
M.description = "Execute a named skill. Skills are pre-defined prompts or workflows."

M.input_schema = {
    type = "object",
    properties = {
        skill = { type = "string", description = "The skill name to execute" },
        args = { type = "string", description = "Optional arguments for the skill" },
    },
    required = { "skill" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name(input)
    return input and input.skill and ("Skill: " .. input.skill) or "Skill"
end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local skill_name = args.skill
    if not skill_name then return { type = "error", error = "No skill name provided" } end

    -- Try loading skill from skills directory
    local ok, skills_loader = pcall(require, "skills.loader")
    if ok and skills_loader then
        local skill = skills_loader.get(skill_name)
        if skill then
            local result = skill.execute(args.args or "", ctx)
            if result then
                return { type = "text", text = result }
            end
        end
    end

    return {
        type = "text",
        text = string.format("Skill '%s' not found. Available skills can be listed with /skills.", skill_name),
    }
end

return M
