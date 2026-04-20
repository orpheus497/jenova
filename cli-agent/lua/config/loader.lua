-- config/loader.lua — Configuration loader and manager
-- Equivalent to src/utils/config.ts and src/schemas/config.ts

local json = jenova.json or require("utils.json_fallback")
local fs = jenova.fs or require("utils.fs_fallback")

local Config = {}

-- Default configuration
local DEFAULT_CONFIG = {
    -- Provider selection
    -- Default: jenova_backend (routes through proxy.lua → Jenova's own llama-server)
    -- Alternatives: llamacpp (in-process), anthropic, openai, gemini, openrouter
    provider = "jenova_backend",
    fallback_enabled = true,

    -- Model configuration
    model = nil, -- Auto-select based on provider
    llamacpp_model = nil, -- Specific llama.cpp model name (auto-select if nil)
    anthropic_model = "claude-sonnet-4-5-20250929",
    openai_model = "gpt-4o-mini",
    gemini_model = "gemini-2.0-flash-exp",
    openrouter_model = "anthropic/claude-3.5-sonnet",

    -- llama.cpp specific settings
    llamacpp_context_size = 8192,
    llamacpp_threads = nil, -- nil = auto-detect
    llamacpp_gpu_layers = 99, -- Offload all layers to GPU if available

    -- Generation parameters
    thinking_enabled = false,
    max_tokens = 8192,
    temperature = 0.7,

    -- Permission system
    permission_mode = "default", -- "default", "auto", "plan", "bypassPermissions"

    -- UI settings
    vim_mode = false,
    theme = "auto", -- "auto", "light", "dark"
    compact_mode = false,
    show_cost = true,

    -- History and state
    history_enabled = true,
    max_history_size = 1000,
    auto_save = true,

    -- Extensibility
    mcp_servers = {},
    plugins = {},
    skills_dir = nil,
    session_dir = nil,
    memory_dir = nil,

    -- Model directories (searched in order; first match wins)
    models_dir = nil, -- Resolved at runtime: $JENOVA_ROOT/models/ → ~/.local/share/cli-agent/models

    -- Jenova-specific paths (auto-resolved from JENOVA_ROOT or etc/jenova.conf)
    jenova_root = nil,
    llama_server_path = nil, -- e.g. $JENOVA_ROOT/llama.cpp/build/bin/llama-server
}

-- Global config instance
local global_config = nil

-- ── Config File Paths ─────────────────────────────────────────────────

local function get_config_dir()
    local home = os.getenv("HOME")
    if not home then
        return nil, "Cannot determine home directory"
    end

    local config_dir = home .. "/.config/cli-agent"
    return config_dir
end

local function get_config_path()
    local config_dir, err = get_config_dir()
    if not config_dir then
        return nil, err
    end
    return config_dir .. "/config.json"
end

local function resolve_trio_config(cfg)
    local trio_ok, trio = pcall(require, "utils.trio")
    if not trio_ok then return end

    local endpoints = trio.get_endpoints()
    local root = endpoints.root
    if not root then return end

    cfg.jenova_root = root

    local conf = trio.load_jenova_conf()

    cfg.llama_server_path = cfg.llama_server_path
        or os.getenv("JENOVA_LLAMA_SERVER")
        or conf.LLAMA_SERVER
        or (root .. "/llama.cpp/build/bin/llama-server")

    if not cfg.models_dir then
        local model_dir = conf.MODEL_DIR or (root .. "/models")
        local f = io.open(model_dir, "r")
        if f then
            f:close()
            cfg.models_dir = model_dir
        end
    end

    if cfg.provider == "jenova_backend" then
        local http = jenova and jenova.http
        if http then
            local ok = pcall(http.get, endpoints.health_url, nil)
            if not ok then
                cfg.provider = "llamacpp"
            end
        end
    end
end

Config.get_config_dir = get_config_dir

-- ── Load Configuration ────────────────────────────────────────────────

function Config.load()
    local config_path, err = get_config_path()
    if not config_path then
        io.stderr:write("Warning: " .. err .. "\n")
        global_config = Config.deep_copy(DEFAULT_CONFIG)
        resolve_trio_config(global_config)
        return global_config
    end

    -- Check if config file exists
    local file = io.open(config_path, "r")
    if not file then
        -- Create default config
        global_config = Config.deep_copy(DEFAULT_CONFIG)
        resolve_trio_config(global_config)
        Config.save()
        return global_config
    end

    -- Read and parse config
    local content = file:read("*a")
    file:close()

    local ok, user_config = pcall(json.parse, content)
    if not ok then
        io.stderr:write("Warning: Failed to parse config file, using defaults\n")
        global_config = Config.deep_copy(DEFAULT_CONFIG)
        resolve_trio_config(global_config)
        return global_config
    end

    -- Merge with defaults
    global_config = Config.merge(DEFAULT_CONFIG, user_config)
    resolve_trio_config(global_config)
    return global_config
end

-- ── Save Configuration ────────────────────────────────────────────────

function Config.save()
    if not global_config then
        return nil, "No config to save"
    end

    local config_path, err = get_config_path()
    if not config_path then
        return nil, err
    end

    -- Ensure config directory exists
    local config_dir, err_dir = get_config_dir()
    if not config_dir then return nil, err_dir end
    
    local ok_fs, fs_mod = pcall(require, "utils.fs_fallback")
    if ok_fs and fs_mod and fs_mod.mkdir then
        fs_mod.mkdir(config_dir)
    else
        local shell = require("utils.shell")
        os.execute("mkdir -p " .. shell.quote(config_dir))
    end

    -- Write config
    local ok, json_str = pcall(json.stringify, global_config, { pretty = true })
    if not ok then
        return nil, "Failed to serialize config"
    end

    local file = io.open(config_path, "w")
    if not file then
        return nil, "Failed to open config file for writing"
    end

    file:write(json_str)
    file:close()

    return true
end

-- ── Get/Set Configuration ─────────────────────────────────────────────

function Config.get(key)
    if not global_config then
        Config.load()
    end

    if key then
        return global_config[key]
    else
        return global_config
    end
end

function Config.set(key, value)
    if not global_config then
        Config.load()
    end

    global_config[key] = value
    return Config.save()
end

function Config.update(updates)
    if not global_config then
        Config.load()
    end

    for key, value in pairs(updates) do
        global_config[key] = value
    end

    return Config.save()
end

-- ── Utility Functions ─────────────────────────────────────────────────

function Config.deep_copy(obj)
    if type(obj) ~= "table" then
        return obj
    end

    local copy = {}
    for k, v in pairs(obj) do
        copy[k] = Config.deep_copy(v)
    end

    return copy
end

function Config.merge(default, user)
    local merged = Config.deep_copy(default)

    for k, v in pairs(user) do
        if type(v) == "table" and type(merged[k]) == "table" then
            merged[k] = Config.merge(merged[k], v)
        else
            merged[k] = v
        end
    end

    return merged
end

return Config
