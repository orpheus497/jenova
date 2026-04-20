-- assistant/session_history.lua — Paginated session event history

local M = {}

M.HISTORY_PAGE_SIZE = 100

-- Create an auth/base-URL context reused across page fetches.
-- `oauth` must expose: access_token (string), org_uuid (string), base_api_url (string).
function M.create_auth_ctx(session_id, oauth)
    return {
        base_url = oauth.base_api_url .. "/v1/sessions/" .. session_id .. "/events",
        headers = {
            ["Authorization"] = "Bearer " .. oauth.access_token,
            ["anthropic-beta"] = "ccr-byoc-2025-07-29",
            ["x-organization-uuid"] = oauth.org_uuid,
            ["Content-Type"] = "application/json",
        },
    }
end

local function url_encode(str)
    return tostring(str):gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function encode_query(params)
    local parts = {}
    for k, v in pairs(params) do
        table.insert(parts, url_encode(tostring(k)) .. "=" .. url_encode(tostring(v)))
    end
    return table.concat(parts, "&")
end

local function fetch_page(ctx, params, label)
    local http = jenova and jenova.http or nil
    local json = jenova and jenova.json or nil
    if not http or not json then
        return nil, label .. ": jenova.http/jenova.json unavailable"
    end
    local url = ctx.base_url .. "?" .. encode_query(params)
    local headers_json = json.stringify(ctx.headers)
    local resp, err = http.get(url, headers_json)
    if not resp then
        return nil, label .. ": " .. tostring(err)
    end
    local ok, body = pcall(json.parse, resp)
    if not ok or type(body) ~= "table" then
        return nil, label .. ": invalid JSON response"
    end
    return {
        events = type(body.data) == "table" and body.data or {},
        first_id = body.first_id,
        has_more = body.has_more == true,
    }
end

-- Newest page: last `limit` events, chronological, anchored to latest.
function M.fetch_latest_events(ctx, limit)
    limit = limit or M.HISTORY_PAGE_SIZE
    return fetch_page(ctx, {
        limit = limit,
        anchor_to_latest = "true",
    }, "fetchLatestEvents")
end

-- Older page: events immediately before `before_id` cursor.
function M.fetch_older_events(ctx, before_id, limit)
    limit = limit or M.HISTORY_PAGE_SIZE
    return fetch_page(ctx, {
        limit = limit,
        before_id = before_id,
    }, "fetchOlderEvents")
end

return M
