-- lua/utils/trio.lua — Helper for "trio" environment (jenova, jvim, cli-agent)
local M = {}

-- Detect JENOVA_ROOT
function M.get_root()
    local root = os.getenv("JENOVA_ROOT")
    if root and root ~= "" and root ~= "$JENOVA_ROOT" then
        return root
    end

    -- Try common locations
    local home = os.getenv("HOME")
    if home then
        local paths = {
            home .. "/Projects/jenova",
            home .. "/jenova",
            home .. "/.config/jvim",
            home .. "/.config/nvim",
        }
        for _, p in ipairs(paths) do
            local f = io.open(p .. "/etc/jenova.conf", "r")
            if f then
                f:close()
                return p
            end
        end
    end
    return nil
end

-- Load shell-style config from etc/jenova.conf
-- Handles KEY=VALUE, KEY="VALUE", KEY='VALUE', and optional whitespace around =.
-- Inline comments after the value are stripped.  Escaped quotes inside values
-- are not supported (shell-eval is out of scope for a pure-Lua parser).
function M.load_jenova_conf()
    local root = M.get_root()
    if not root then return {} end

    local conf_path = root .. "/etc/jenova.conf"
    local local_conf_path = root .. "/etc/jenova.local.conf"

    local config = { JENOVA_ROOT = root }

    local function parse_file(path)
        local f = io.open(path, "r")
        if not f then return end
        for line in f:lines() do
            -- Strip inline comments and leading/trailing whitespace
            line = line:gsub("%s*#[^\n]*$", ""):match("^%s*(.-)%s*$")
            if line and line ~= "" then
                -- Match: KEY = "value", KEY = 'value', or KEY = value
                -- The optional whitespace around '=' is handled by %s* in the pattern.
                local k, quote, v = line:match("^([%w_]+)%s*=%s*([\"']?)(.-)%2%s*$")
                if k and v then
                    _ = quote  -- consumed to strip matching surrounding quotes
                    -- Basic shell expansion for $JENOVA_ROOT
                    v = v:gsub("%$JENOVA_ROOT", root)
                    config[k] = v
                end
            end
        end
        f:close()
    end

    parse_file(conf_path)
    parse_file(local_conf_path)

    return config
end

-- Resolve connection endpoints following jvim/endpoints.lua logic
function M.get_endpoints()
    local conf = M.load_jenova_conf()

    local host = os.getenv("JENOVA_CONNECT_HOST") or os.getenv("JENOVA_HOST") or conf.HOST or "127.0.0.1"
    if host == "0.0.0.0" or host == "::" or host == "*" then
        host = "127.0.0.1"
    end

    local port = tonumber(os.getenv("JENOVA_PROXY_PORT") or os.getenv("JENOVA_PORT") or conf.PORT) or 8080
    local llama_port = tonumber(os.getenv("JENOVA_LLAMA_PORT") or conf.LLAMA_PORT) or 8081
    local embed_port = tonumber(os.getenv("JENOVA_LLAMA_EMBED_PORT") or os.getenv("LLAMA_EMBED_PORT") or conf.LLAMA_EMBED_PORT) or 8082

    return {
        host = host,
        port = port,
        llama_port = llama_port,
        embed_port = embed_port,
        root = conf.JENOVA_ROOT,
        proxy_url = string.format("http://%s:%d/v1/chat/completions", host, port),
        health_url = string.format("http://%s:%d/v1/health", host, port),
    }
end

return M
