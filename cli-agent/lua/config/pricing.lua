-- config/pricing.lua — Model pricing data
-- All inference is local/free. Entries kept for token-display compatibility.

local M = {}

M.models = {
    ["local"]         = { input = 0, output = 0 },
    ["llamacpp"]      = { input = 0, output = 0 },
    ["jenova_backend"]= { input = 0, output = 0 },
    ["auto"]          = { input = 0, output = 0 },
}

function M.get(_model)
    return M.models["local"]
end

return M
