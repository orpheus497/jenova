-- tools/local_search.lua — LocalSearchTool: Ranked BM25 search for local files
-- Ported from jenova/lib/search.lua for the Jenova CLI "trio" integration.

local json = require("utils.json_fallback")
local shell = require("utils.shell")
local embed = require("utils.embed")

local M = {}
M.name = "LocalSearch"
M.description = "Search local files using hybrid BM25 + semantic vector ranking. Better than grep for finding relevant code/docs by relevance."

M.input_schema = {
    type = "object",
    properties = {
        query = { type = "string", description = "The search query" },
        path = { type = "string", description = "Directory to search in (default: current directory)" },
        top_k = { type = "integer", description = "Number of results to return (default: 5)" },
        extensions = { type = "array", items = { type = "string" }, description = "Filter by file extensions" },
    },
    required = { "query" }
}

-- BM25 configuration
local k1 = 1.5
local b = 0.75
local BM25_WEIGHT = 0.4
local SEMANTIC_WEIGHT = 0.6

function M.is_enabled() return true end
function M.is_read_only() return true end

function M.user_facing_name(input)
    return input and input.query and ("Search: " .. input.query:sub(1, 40)) or "LocalSearch"
end

function M.check_permissions() return { allowed = true } end

local function tokenize(text)
    local terms = {}
    for word in text:lower():gmatch("[%w_]+") do
        if #word > 1 and #word < 60 then
            table.insert(terms, word)
        end
    end
    return terms
end

function M.call(args, context)
    local query = args.query
    if not query then return { type = "error", error = "No query provided" } end

    local root_dir = args.path or (context and context.cwd) or "."
    local top_k = args.top_k or 5
    local extensions = args.extensions

    local ext_filter = ""
    if extensions and #extensions > 0 then
        local parts = {}
        for _, ext in ipairs(extensions) do
            if ext:match("^[%w%.]+$") then
                table.insert(parts, "-name '*." .. ext .. "'")
            end
        end
        if #parts > 0 then
            ext_filter = "\\( " .. table.concat(parts, " -o ") .. " \\)"
        end
    end

    -- Find files to index
    local is_windows = package.config:sub(1, 1) == "\\"
    local cmd
    if is_windows then
        cmd = string.format('dir /s /b /a-d %s 2>nul', shell.quote(root_dir))
    else
        cmd = string.format(
            "find %s -type f %s -not -path '*/.git/*' -not -path '*/.jenova/*' -not -path '*/node_modules/*' -size -100k 2>/dev/null | head -300",
            shell.quote(root_dir), ext_filter
        )
    end

    local h = io.popen(cmd)
    if not h then return { type = "error", error = "Failed to list files" } end
    
    local files = {}
    for line in h:lines() do
        table.insert(files, line)
    end
    h:close()

    if #files == 0 then
        return { type = "text", text = "No files found to search." }
    end

    -- Check if embedding is available
    local use_semantic = embed.init()
    local query_vec = nil
    if use_semantic then
        query_vec = embed.encode(query, "search_query")
        if query_vec then embed.normalize(query_vec) end
    end

    -- Indexing and scoring
    local bm25_index = {}
    local df = {}
    local total_docs = 0
    local total_len = 0

    for _, path in ipairs(files) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and not content:find("%z") and #content > 0 then
                local terms = tokenize(content)
                if #terms > 0 then
                    local term_counts = {}
                    local seen = {}
                    for _, t in ipairs(terms) do
                        term_counts[t] = (term_counts[t] or 0) + 1
                        if not seen[t] then
                            df[t] = (df[t] or 0) + 1
                            seen[t] = true
                        end
                    end
                    
                    local sem_score = 0
                    if query_vec then
                        -- For simplicity in the CLI tool (which doesn't persist vectors),
                        -- we just embed the whole file content once if it fits.
                        local text_to_embed = content
                        if #text_to_embed > 4000 then
                            local trunc_len = 4000
                            -- Backtrack if we land on a UTF-8 continuation byte (10xxxxxx)
                            while trunc_len > 0 and text_to_embed:byte(trunc_len) >= 128 and text_to_embed:byte(trunc_len) <= 191 do
                                trunc_len = trunc_len - 1
                            end
                            -- Backtrack one more to drop the start byte of the incomplete character
                            if trunc_len > 0 and text_to_embed:byte(trunc_len) >= 192 then
                                trunc_len = trunc_len - 1
                            end
                            text_to_embed = text_to_embed:sub(1, trunc_len)
                        end
                        
                        local doc_vec = embed.encode(text_to_embed, "search_document")
                        if doc_vec then
                            embed.normalize(doc_vec)
                            sem_score = embed.cosine(query_vec, doc_vec)
                        end
                    end

                    bm25_index[path] = { 
                        terms = term_counts, 
                        len = #terms, 
                        size = #content,
                        sem_score = sem_score
                    }
                    total_docs = total_docs + 1
                    total_len = total_len + #terms
                end
            end
        end
    end

    if total_docs == 0 then
        return { type = "text", text = "No searchable content found." }
    end

    local avg_dl = total_len / total_docs
    local query_terms = tokenize(query)
    
    local results = {}
    local max_bm25 = 0
    for path, doc in pairs(bm25_index) do
        local bm_score = 0
        for _, qt in ipairs(query_terms) do
            local tf = doc.terms[qt] or 0
            if tf > 0 then
                local doc_freq = df[qt] or 0
                local idf = math.log((total_docs - doc_freq + 0.5) / (doc_freq + 0.5) + 1)
                local tf_norm = (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * doc.len / avg_dl))
                bm_score = bm_score + idf * tf_norm
            end
        end
        doc.bm_score = bm_score
        if bm_score > max_bm25 then max_bm25 = bm_score end
    end

    for path, doc in pairs(bm25_index) do
        local norm_bm25 = max_bm25 > 0 and (doc.bm_score / max_bm25) or 0
        local final_score
        if query_vec then
            final_score = BM25_WEIGHT * norm_bm25 + SEMANTIC_WEIGHT * doc.sem_score
        else
            final_score = norm_bm25
        end

        if final_score > 0.1 then
            table.insert(results, { 
                path = path, 
                score = final_score, 
                size = doc.size,
                bm25 = doc.bm_score,
                sem = doc.sem_score
            })
        end
    end

    table.sort(results, function(a, b_) return a.score > b_.score end)

    local out = { "Search results for: " .. query }
    if use_semantic and query_vec then
        table.insert(out, "(Hybrid search: BM25 + Semantic)\n")
    else
        table.insert(out, "(BM25 search only - embedding server offline)\n")
    end

    for i = 1, math.min(top_k, #results) do
        local r = results[i]
        local detail = string.format("score: %.2f", r.score)
        if query_vec then
            detail = detail .. string.format(" (bm25: %.2f, sem: %.2f)", r.bm25, r.sem)
        end
        table.insert(out, string.format("%d. %s (%s, %d bytes)", i, r.path, detail, r.size))
    end

    if #results == 0 then
        return { type = "text", text = "No matches found for '" .. query .. "'." }
    end

    return { type = "text", text = table.concat(out, "\n") }
end

return M
