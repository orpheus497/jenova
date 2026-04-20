-- plugins/loader.lua — Plugin loading and management system
-- Equivalent to src/plugins/ and src/utils/plugins/pluginLoader.ts

local json = require("utils.json_fallback")
local fs = require("utils.fs_fallback")
local config = require("config.loader")

local Plugins = {}

-- Loaded plugins registry
local loaded_plugins = {}

-- ── Plugins Directory ─────────────────────────────────────────────────

function Plugins.get_plugins_dir()
    local plugins_dir = config.get("plugins_dir")

    if not plugins_dir then
        local config_dir = config.get_config_dir()
        if config_dir then
            plugins_dir = config_dir .. "/plugins"
        else
            local home = os.getenv("HOME")
            plugins_dir = home .. "/.config/cli-agent/plugins"
        end
    end

    return plugins_dir
end

-- ── Load Plugins ──────────────────────────────────────────────────────

function Plugins.load_all()
    local plugins_dir = Plugins.get_plugins_dir()

    -- Check if directory exists using safe fs module
    if not fs.is_directory(plugins_dir) then
        -- Create plugins directory
        fs.mkdir(plugins_dir)
        return {}
    end

    -- Find all plugin directories using safe directory listing
    local entries = fs.list_dir(plugins_dir)
    if not entries then
        return {}
    end

    local plugin_dirs = {}
    for _, entry in ipairs(entries) do
        local full_path = plugins_dir .. "/" .. entry
        if fs.is_directory(full_path) then
            table.insert(plugin_dirs, full_path)
        end
    end

    -- Load each plugin
    for _, plugin_dir in ipairs(plugin_dirs) do
        local plugin = Plugins.load_plugin(plugin_dir)
        if plugin then
            loaded_plugins[plugin.name] = plugin
        end
    end

    return loaded_plugins
end

-- ── Load Single Plugin ────────────────────────────────────────────────

function Plugins.load_plugin(plugin_dir)
    local manifest_path = plugin_dir .. "/plugin.json"

    -- Read manifest
    local file = io.open(manifest_path, "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()

    local ok, manifest = pcall(json.parse, content)
    if not ok or type(manifest) ~= "table" then
        io.stderr:write(string.format("Failed to parse plugin manifest: %s\n", manifest_path))
        return nil
    end

    -- Validate manifest
    if not manifest.name or not manifest.version then
        io.stderr:write(string.format("Invalid plugin manifest: %s\n", manifest_path))
        return nil
    end

    -- Load plugin entry point
    local entry_point = manifest.main or "init.lua"
    local entry_path = plugin_dir .. "/" .. entry_point

    local ok, plugin_module = pcall(dofile, entry_path)
    if not ok or type(plugin_module) ~= "table" then
        io.stderr:write(string.format("Failed to load plugin: %s\n", entry_path))
        return nil
    end

    -- Merge manifest and module
    plugin_module.manifest = manifest
    plugin_module.dir = plugin_dir

    -- Call plugin init if available
    if plugin_module.init then
        local ok, err = pcall(plugin_module.init)
        if not ok then
            io.stderr:write(string.format("Plugin init failed for %s: %s\n", manifest.name, err))
            return nil
        end
    end

    return plugin_module
end

-- ── Execute Plugin Hook ───────────────────────────────────────────────

function Plugins.execute_hook(hook_name, ...)
    local results = {}

    for name, plugin in pairs(loaded_plugins) do
        if plugin.hooks and plugin.hooks[hook_name] then
            local ok, result = pcall(plugin.hooks[hook_name], ...)
            if ok then
                results[name] = result
            else
                io.stderr:write(string.format("Plugin hook failed for %s.%s: %s\n", name, hook_name, result))
            end
        end
    end

    return results
end

-- ── List Plugins ──────────────────────────────────────────────────────

function Plugins.list()
    local result = {}

    for name, plugin in pairs(loaded_plugins) do
        table.insert(result, {
            name = plugin.manifest.name,
            version = plugin.manifest.version,
            description = plugin.manifest.description or "",
            author = plugin.manifest.author or "",
            dir = plugin.dir,
        })
    end

    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

function Plugins.get(name)
    return loaded_plugins[name]
end

-- ── Plugin Lifecycle ──────────────────────────────────────────────────

function Plugins.enable(name)
    local plugin = loaded_plugins[name]
    if not plugin then
        return false, "Plugin not found"
    end

    if plugin.enable then
        local ok, err = pcall(plugin.enable)
        if not ok then
            return false, err
        end
    end

    plugin.enabled = true
    return true
end

function Plugins.disable(name)
    local plugin = loaded_plugins[name]
    if not plugin then
        return false, "Plugin not found"
    end

    if plugin.disable then
        local ok, err = pcall(plugin.disable)
        if not ok then
            return false, err
        end
    end

    plugin.enabled = false
    return true
end

function Plugins.reload(name)
    local plugin = loaded_plugins[name]
    if not plugin then
        return false, "Plugin not found"
    end

    -- Disable first
    Plugins.disable(name)

    -- Reload
    local reloaded = Plugins.load_plugin(plugin.dir)
    if reloaded then
        loaded_plugins[name] = reloaded
        return true
    end

    return false, "Failed to reload plugin"
end

-- Reset all loaded plugins. Disables each first so plugin-side state is
-- torn down, then clears the registry so the next load_all() starts fresh.
function Plugins.reset()
    for name, _ in pairs(loaded_plugins) do
        pcall(Plugins.disable, name)
    end
    loaded_plugins = {}
end

return Plugins
