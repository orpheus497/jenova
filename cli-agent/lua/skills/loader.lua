-- skills/loader.lua — Skills loading and execution system
-- Equivalent to src/skills/ and src/tools/SkillTool/

local json = require("utils.json_fallback")
local fs = require("utils.fs_fallback")
local config = require("config.loader")

local Skills = {}

-- Loaded skills registry
local loaded_skills = {}

-- ── Skills Directory ──────────────────────────────────────────────────

function Skills.get_skills_dir()
    local skills_dir = config.get("skills_dir")

    if not skills_dir then
        local config_dir = config.get_config_dir()
        if config_dir then
            skills_dir = config_dir .. "/skills"
        else
            local home = os.getenv("HOME")
            skills_dir = home .. "/.config/cli-agent/skills"
        end
    end

    return skills_dir
end

-- ── Load Skills ───────────────────────────────────────────────────────

function Skills.load_all()
    local skills_dir = Skills.get_skills_dir()

    -- Check if directory exists using safe fs module
    if not fs.is_directory(skills_dir) then
        -- Create skills directory
        fs.mkdir(skills_dir)
        return {}
    end

    -- Find all skill files (*.lua or *.json) using safe directory listing
    local files = fs.list_dir(skills_dir)
    if not files then
        return {}
    end

    local skill_files = {}
    for _, file in ipairs(files) do
        if file:match("%.lua$") or file:match("%.json$") then
            table.insert(skill_files, skills_dir .. "/" .. file)
        end
    end

    -- Load each skill
    for _, file_path in ipairs(skill_files) do
        local skill = Skills.load_skill(file_path)
        if skill then
            loaded_skills[skill.name] = skill
        end
    end

    return loaded_skills
end

-- ── Load Single Skill ─────────────────────────────────────────────────

function Skills.load_skill(file_path)
    local file_ext = file_path:match("%.([^.]+)$")

    if file_ext == "lua" then
        return Skills.load_lua_skill(file_path)
    elseif file_ext == "json" then
        return Skills.load_json_skill(file_path)
    end

    return nil
end

function Skills.load_lua_skill(file_path)
    local ok, skill_module = pcall(dofile, file_path)

    if not ok or type(skill_module) ~= "table" then
        io.stderr:write(string.format("Failed to load Lua skill: %s\n", file_path))
        return nil
    end

    -- Validate skill structure
    if not skill_module.name or not skill_module.execute then
        io.stderr:write(string.format("Invalid skill structure: %s\n", file_path))
        return nil
    end

    skill_module.type = "lua"
    skill_module.file_path = file_path

    return skill_module
end

function Skills.load_json_skill(file_path)
    local file = io.open(file_path, "r")
    if not file then
        io.stderr:write(string.format("Failed to open JSON skill: %s\n", file_path))
        return nil
    end

    local content = file:read("*a")
    file:close()

    local ok, skill_def = pcall(json.parse, content)
    if not ok or type(skill_def) ~= "table" then
        io.stderr:write(string.format("Failed to parse JSON skill: %s\n", file_path))
        return nil
    end

    -- Validate skill structure
    if not skill_def.name or not skill_def.prompt then
        io.stderr:write(string.format("Invalid JSON skill structure: %s\n", file_path))
        return nil
    end

    skill_def.type = "prompt"
    skill_def.file_path = file_path

    return skill_def
end

-- ── Execute Skill ─────────────────────────────────────────────────────

function Skills.execute(skill_name, input, query_engine)
    local skill = loaded_skills[skill_name]

    if not skill then
        return nil, string.format("Skill not found: %s", skill_name)
    end

    if skill.type == "lua" then
        return Skills.execute_lua_skill(skill, input)
    elseif skill.type == "prompt" then
        return Skills.execute_prompt_skill(skill, input, query_engine)
    end

    return nil, "Unknown skill type"
end

function Skills.execute_lua_skill(skill, input)
    local ok, result = pcall(skill.execute, input)

    if not ok then
        return nil, string.format("Skill execution failed: %s", tostring(result))
    end

    return result, nil
end

function Skills.execute_prompt_skill(skill, input, query_engine)
    if not query_engine then
        return nil, "Query engine required for prompt-based skills"
    end

    -- Substitute variables in prompt
    local prompt = skill.prompt
    if type(input) == "table" then
        for k, v in pairs(input) do
            prompt = prompt:gsub("{{" .. k .. "}}", tostring(v))
        end
    end

    -- Execute via query engine
    local response, err = query_engine:query(prompt)

    if err then
        return nil, err
    end

    return response.text, nil
end

-- ── List Skills ───────────────────────────────────────────────────────

function Skills.list()
    local result = {}

    for name, skill in pairs(loaded_skills) do
        table.insert(result, {
            name = name,
            description = skill.description or "",
            type = skill.type,
            file_path = skill.file_path,
        })
    end

    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

function Skills.get(name)
    return loaded_skills[name]
end

-- ── Create Skill ──────────────────────────────────────────────────────

function Skills.create(name, skill_def)
    local skills_dir = Skills.get_skills_dir()

    -- Ensure directory exists
    fs.mkdir(skills_dir)

    local file_path
    if skill_def.type == "lua" then
        file_path = skills_dir .. "/" .. name .. ".lua"
        local file = io.open(file_path, "w")
        if not file then
            return nil, "Failed to create skill file"
        end

        file:write("-- Skill: " .. name .. "\n")
        file:write("return {\n")
        file:write(string.format('  name = "%s",\n', name))
        file:write(string.format('  description = "%s",\n', skill_def.description or ""))
        file:write("  execute = function(input)\n")
        file:write("    -- Skill implementation\n")
        file:write(skill_def.code or "    return {}")
        file:write("\n  end\n")
        file:write("}\n")
        file:close()

    elseif skill_def.type == "prompt" then
        file_path = skills_dir .. "/" .. name .. ".json"
        local ok, json_str = pcall(json.stringify, skill_def, { pretty = true })
        if not ok then
            return nil, "Failed to serialize skill"
        end

        local file = io.open(file_path, "w")
        if not file then
            return nil, "Failed to create skill file"
        end

        file:write(json_str)
        file:close()
    else
        return nil, "Unknown skill type"
    end

    -- Load the new skill
    local skill = Skills.load_skill(file_path)
    if skill then
        loaded_skills[name] = skill
    end

    return file_path, nil
end

return Skills
