-- utils/array.lua — Array/table utility functions

local M = {}

function M.map(t, fn)
    local result = {}
    for i, v in ipairs(t) do
        result[i] = fn(v, i)
    end
    return result
end

function M.filter(t, fn)
    local result = {}
    for i, v in ipairs(t) do
        if fn(v, i) then table.insert(result, v) end
    end
    return result
end

function M.reduce(t, fn, init)
    local acc = init
    for i, v in ipairs(t) do
        acc = fn(acc, v, i)
    end
    return acc
end

function M.find(t, fn)
    for i, v in ipairs(t) do
        if fn(v, i) then return v, i end
    end
    return nil
end

function M.contains(t, value)
    for _, v in ipairs(t) do
        if v == value then return true end
    end
    return false
end

function M.flatten(t)
    local result = {}
    for _, v in ipairs(t) do
        if type(v) == "table" then
            for _, inner in ipairs(v) do
                table.insert(result, inner)
            end
        else
            table.insert(result, v)
        end
    end
    return result
end

function M.slice(t, start, stop)
    local result = {}
    stop = stop or #t
    for i = start, stop do
        table.insert(result, t[i])
    end
    return result
end

function M.reverse(t)
    local result = {}
    for i = #t, 1, -1 do
        table.insert(result, t[i])
    end
    return result
end

function M.keys(t)
    local result = {}
    for k in pairs(t) do table.insert(result, k) end
    return result
end

function M.values(t)
    local result = {}
    for _, v in pairs(t) do table.insert(result, v) end
    return result
end

function M.merge(...)
    local result = {}
    for _, t in ipairs({...}) do
        for k, v in pairs(t) do result[k] = v end
    end
    return result
end

function M.deep_copy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[M.deep_copy(k)] = M.deep_copy(v)
    end
    return setmetatable(copy, getmetatable(t))
end

function M.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function M.is_empty(t)
    return next(t) == nil
end

function M.uniq(t)
    local seen = {}
    local result = {}
    for _, v in ipairs(t) do
        if not seen[v] then
            seen[v] = true
            table.insert(result, v)
        end
    end
    return result
end

return M
