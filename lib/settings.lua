local settings = {}

-- Parses jenova.conf into an ordered list of lines and a key-value map
function settings.parse_config(path)
    local lines = {}
    local config = {}
    local file = io.open(path, "r")
    if not file then return nil end

    for line in file:lines() do
        table.insert(lines, line)
        -- Match: VAR="${ENV_VAR:-DEFAULT}"
        local k, default_val = line:match("^([A-Z_]+)=\"%${[A-Z_]+:-(.-)}\"")
        if k then
            config[k] = default_val
        else
            -- Match: VAR="VALUE"
            local k2, val2 = line:match("^([A-Z_]+)=\"(.-)\"")
            if k2 then
                config[k2] = val2
            end
        end
    end
    file:close()
    return { lines = lines, map = config }
end

-- Saves updates back to the config file preserving comments and structure
function settings.save_config(path, config_obj, updates)
    -- Apply updates to the map
    for k, v in pairs(updates) do
        config_obj.map[k] = tostring(v)
    end

    local file = io.open(path, "w")
    if not file then return false end

    for _, line in ipairs(config_obj.lines) do
        -- Try to replace VAR="${ENV_VAR:-DEFAULT}"
        local k1 = line:match("^([A-Z_]+)=\"%${[A-Z_]+:-.-}\"")
        if k1 and updates[k1] then
            line = line:gsub("^("..k1.."=\"%${[A-Z_]+:-).-(}\")", "%1" .. updates[k1] .. "%2")
        else
            -- Try to replace VAR="VALUE"
            local k2 = line:match("^([A-Z_]+)=\".-\"")
            if k2 and updates[k2] then
                line = line:gsub("^("..k2.."=\").-(\")", "%1" .. updates[k2] .. "%2")
            end
        end
        file:write(line .. "\n")
    end
    file:close()
    return true
end

-- Invokes the hardware detection script
function settings.detect_hardware(root)
    local cmd = root .. "/hardware-profiles/detect-hardware.sh"
    local f = io.popen(cmd, "r")
    if not f then return nil end
    local output = f:read("*a")
    f:close()
    return output
end

return settings
