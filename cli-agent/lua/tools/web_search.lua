-- tools/web_search.lua — WebSearchTool: Search the web
-- Uses jenova.http to query a search API or falls back to a web scraping approach.

local json = require("utils.json_fallback")

local M = {}
M.name = "WebSearch"
M.description = "Search the web for information. Returns search results with titles, URLs, and snippets."

M.input_schema = {
    type = "object",
    properties = {
        query = { type = "string", description = "The search query" },
        num_results = { type = "integer", description = "Number of results to return (default: 5)" },
    },
    required = { "query" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    return input and input.query and ("Search: " .. input.query:sub(1, 40)) or "WebSearch"
end

function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local query = args.query
    if not query then return { type = "error", error = "No query provided" } end

    local num_results = args.num_results or 5

    -- Check for Brave Search API key
    local brave_key = os.getenv("BRAVE_SEARCH_API_KEY")
    if brave_key and brave_key ~= "" and jenova and jenova.http then
        local encoded_query = query:gsub(" ", "+"):gsub("[^%w%+%-_%.~]", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        local url = string.format(
            "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d",
            encoded_query, num_results
        )
        local headers = json.stringify({
            ["Accept"] = "application/json",
            ["Accept-Encoding"] = "gzip",
            ["X-Subscription-Token"] = brave_key,
        })
        local body = jenova.http.get(url, headers)
        if body then
            local ok, data = pcall(json.parse, body)
            if ok and data and data.web and data.web.results then
                local lines = {}
                for i, result in ipairs(data.web.results) do
                    if i > num_results then break end
                    table.insert(lines, string.format("%d. %s", i, result.title or ""))
                    table.insert(lines, string.format("   %s", result.url or ""))
                    if result.description then
                        table.insert(lines, string.format("   %s", result.description))
                    end
                    table.insert(lines, "")
                end
                return { type = "text", text = table.concat(lines, "\n") }
            end
        end
    end

    -- Fallback: use DuckDuckGo Lite (text-only, no API key needed)
    local encoded_query = query:gsub(" ", "+"):gsub("[^%w%+%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local url = "https://lite.duckduckgo.com/lite/?q=" .. encoded_query
    local html = ""
    
    if jenova and jenova.http then
        html = jenova.http.get(url, nil) or ""
    else
        local shell = require("utils.shell")
        local cmd = string.format("curl -sL %s 2>nul", shell.quote(url))
        if package.config:sub(1, 1) ~= "\\" then
            cmd = string.format("curl -sL %s 2>/dev/null", shell.quote(url))
        end
        local h = io.popen(cmd)
        if h then
            html = h:read("*a") or ""
            h:close()
        end
    end

    if html and #html > 10 then
        -- Robust HTML tag stripping in pure Lua (cross-platform, no shell injection)
        local out = html
        -- Remove script and style blocks (case insensitive simulation)
        out = out:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]>", " ")
        out = out:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]>", " ")
        -- Remove all other tags
        out = out:gsub("<[^>]+>", " ")
        -- Unescape basic HTML entities
        out = out:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
        -- Condense whitespace
        out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        -- Limit output size
        if #out > 3000 then out = out:sub(1, 3000) .. "..." end
        return { type = "text", text = "DuckDuckGo (Lite) results:\n" .. out }
    end

    return {
        type = "text",
        text = string.format("Web search for '%s' — set BRAVE_SEARCH_API_KEY for full results.", query),
    }
end

return M
