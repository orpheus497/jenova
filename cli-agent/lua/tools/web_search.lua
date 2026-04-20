-- tools/web_search.lua — WebSearch: Search the web using DuckDuckGo
-- Uses DuckDuckGo Lite (no API key required) as the default engine.
-- Set BRAVE_SEARCH_API_KEY in the environment to use Brave Search instead.

local json = require("utils.json_fallback")

local M = {}
M.name = "WebSearch"
M.description = "Search the web for current information, documentation, or news. Returns titles, URLs, and snippets. Use this only when you need information not available locally — do NOT use it for tasks that only require reading files or running code."

M.parameters = {
    type = "object",
    properties = {
        query = { type = "string", description = "The search query" },
        num_results = { type = "integer", description = "Number of results to return (default: 5, max: 10)" },
    },
    required = { "query" }
}

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    return input and input.query and ("Search: " .. input.query:sub(1, 40)) or "WebSearch"
end

function M.check_permissions() return { allowed = true } end

local function url_encode(s)
    return s:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function http_get(url)
    local _j = rawget(_G, "jenova")
    if type(_j) == "table" and _j.http and _j.http.get then
        return _j.http.get(url, nil)
    end
    local shell = require("utils.shell")
    local h = io.popen(string.format(
        "curl -sL --max-time 10 --user-agent 'Mozilla/5.0' %s 2>/dev/null",
        shell.quote(url)))
    if h then
        local out = h:read("*a"); h:close(); return out
    end
end

local function strip_html(html)
    if not html or #html == 0 then return "" end
    local out = html
    out = out:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]>", " ")
    out = out:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]>", " ")
    out = out:gsub("<[^>]+>", " ")
    out = out:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
             :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    out = out:gsub("%s+", " "):gsub("^ +", ""):gsub(" +$", "")
    return out
end

-- Parse DuckDuckGo Lite HTML into structured results.
local function parse_ddg_lite(html, max)
    local results = {}
    -- DDG Lite wraps each result in an anchor with the external URL.
    for url, title in html:gmatch('<a[^>]+href="(https?://[^"]+)"[^>]*>([^<]+)</a>') do
        if #results >= max then break end
        if not url:find("duckduckgo%.com") and not url:find("duck%.co") then
            title = strip_html(title):match("^%s*(.-)%s*$")
            if title and #title > 2 then
                table.insert(results, { url = url, title = title, snippet = "" })
            end
        end
    end
    if #results == 0 then
        -- Fallback: return raw stripped text so the model still gets something.
        local text = strip_html(html)
        if #text > 50 then
            return nil, text:sub(1, 3000)
        end
    end
    return results, nil
end

function M.call(args, _ctx)
    local query = args.query
    if not query or #query == 0 then
        return { type = "error", error = "No query provided" }
    end
    local num_results = math.min(args.num_results or 5, 10)

    -- Brave Search (only if API key is present)
    local brave_key = os.getenv("BRAVE_SEARCH_API_KEY")
    if brave_key and brave_key ~= "" then
        local _j = rawget(_G, "jenova")
        if type(_j) == "table" and _j.http and _j.http.get then
            local url = string.format(
                "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d",
                url_encode(query), num_results)
            local headers = json.stringify({
                ["Accept"] = "application/json",
                ["X-Subscription-Token"] = brave_key,
            })
            local body = _j.http.get(url, headers)
            if body then
                local ok, data = pcall(json.parse, body)
                if ok and data and data.web and data.web.results then
                    local lines = { "Brave Search results for: " .. query, "" }
                    for i, r in ipairs(data.web.results) do
                        if i > num_results then break end
                        table.insert(lines, string.format("%d. %s", i, r.title or "(no title)"))
                        table.insert(lines, "   " .. (r.url or ""))
                        if r.description and #r.description > 0 then
                            table.insert(lines, "   " .. r.description)
                        end
                        table.insert(lines, "")
                    end
                    return { type = "text", text = table.concat(lines, "\n") }
                end
            end
        end
    end

    -- DuckDuckGo Lite (default — no API key needed)
    local ddg_url = "https://lite.duckduckgo.com/lite/?q=" .. url_encode(query)
    local html = http_get(ddg_url)

    if not html or #html < 50 then
        return {
            type = "text",
            text = string.format(
                "Web search unavailable (no network or search blocked). Query: %s", query),
        }
    end

    local results, fallback_text = parse_ddg_lite(html, num_results)
    if fallback_text then
        return { type = "text", text = "DuckDuckGo results (raw):\n" .. fallback_text }
    end

    if not results or #results == 0 then
        return { type = "text", text = "No results found for: " .. query }
    end

    local lines = { "DuckDuckGo results for: " .. query, "" }
    for i, r in ipairs(results) do
        table.insert(lines, string.format("%d. %s", i, r.title))
        table.insert(lines, "   " .. r.url)
        if r.snippet and #r.snippet > 0 then
            table.insert(lines, "   " .. r.snippet)
        end
        table.insert(lines, "")
    end
    return { type = "text", text = table.concat(lines, "\n") }
end

return M
