-- search.lua: Hybrid BM25 + semantic vector search for coder-agent
-- BM25 always available; vector search when embed module is initialized
-- Vectors persisted to .coder/vectors.json for incremental updates

local _dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
if not package.path:find(_dir, 1, true) then
  package.path = _dir .. "?.lua;" .. package.path
end

local json = require("json")

local search = {}

-------------------------------------------------------------------------------
-- BM25 config
-------------------------------------------------------------------------------
local k1 = 1.5
local b = 0.75

local bm25_index = {}  -- { filepath = { terms = {term=count}, len = N, lines = {...}, size = N } }
local df = {}           -- { term = doc_count }
local total_docs = 0
local avg_dl = 0

-------------------------------------------------------------------------------
-- Vector index config
-------------------------------------------------------------------------------
local embed = nil       -- embed module, set via search.init_embeddings()
local vec_index = {}    -- { filepath = { chunks = { {text=..., vec=..., start_line=N} }, mtime = N } }
local CHUNK_WORDS = 300
local CHUNK_OVERLAP = 50
local BATCH_SIZE = 8
local VECTOR_FILE = ".coder/vectors.json"
local BM25_WEIGHT = 0.4
local SEMANTIC_WEIGHT = 0.6

-------------------------------------------------------------------------------
-- Tokenize text into lowercase terms (for BM25)
-------------------------------------------------------------------------------
local function tokenize(text)
  local terms = {}
  for word in text:lower():gmatch("[%w_]+") do
    if #word > 1 and #word < 60 then
      terms[#terms + 1] = word
    end
  end
  return terms
end

-------------------------------------------------------------------------------
-- Chunk a file's content into overlapping segments
-- Returns { {text=..., start_line=N}, ... }
-------------------------------------------------------------------------------
local function chunk_text(content)
  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  if #lines == 0 then return {} end

  -- Count words to decide if chunking is needed
  local words = tokenize(content)
  if #words <= CHUNK_WORDS then
    return {{ text = content, start_line = 1 }}
  end

  -- Build chunks by accumulating lines until word threshold
  local chunks = {}
  local chunk_lines = {}
  local chunk_word_count = 0
  local chunk_start = 1
  local overlap_lines = {}

  for i, line in ipairs(lines) do
    local line_words = 0
    for _ in line:lower():gmatch("[%w_]+") do
      line_words = line_words + 1
    end

    chunk_lines[#chunk_lines + 1] = line
    chunk_word_count = chunk_word_count + line_words

    if chunk_word_count >= CHUNK_WORDS then
      local text = table.concat(chunk_lines, "\n")
      chunks[#chunks + 1] = { text = text, start_line = chunk_start }

      -- Prepare overlap: keep last few lines for next chunk
      overlap_lines = {}
      local overlap_words = 0
      for j = #chunk_lines, 1, -1 do
        local lw = 0
        for _ in chunk_lines[j]:lower():gmatch("[%w_]+") do lw = lw + 1 end
        overlap_words = overlap_words + lw
        if overlap_words > CHUNK_OVERLAP then break end
        table.insert(overlap_lines, 1, chunk_lines[j])
      end

      chunk_lines = {}
      for _, ol in ipairs(overlap_lines) do
        chunk_lines[#chunk_lines + 1] = ol
      end
      chunk_word_count = 0
      for _, ol in ipairs(chunk_lines) do
        for _ in ol:lower():gmatch("[%w_]+") do
          chunk_word_count = chunk_word_count + 1
        end
      end
      chunk_start = i - #overlap_lines + 1
    end
  end

  -- Remaining lines as final chunk
  if #chunk_lines > 0 then
    local text = table.concat(chunk_lines, "\n")
    if #tokenize(text) > 10 then
      chunks[#chunks + 1] = { text = text, start_line = chunk_start }
    end
  end

  return chunks
end

-------------------------------------------------------------------------------
-- Get file mtime
-------------------------------------------------------------------------------
local function file_mtime(filepath)
  local p = io.popen(string.format("stat -f '%%m' %q 2>/dev/null", filepath))
  if not p then return 0 end
  local mtime = tonumber(p:read("*l")) or 0
  p:close()
  return mtime
end

-------------------------------------------------------------------------------
-- BM25: Index a single file
-------------------------------------------------------------------------------
local function bm25_index_file(filepath)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if #content > 100000 then return nil end
  if content:find("%z") then return nil end

  local terms = tokenize(content)
  if #terms == 0 then return nil end

  local term_counts = {}
  for _, t in ipairs(terms) do
    term_counts[t] = (term_counts[t] or 0) + 1
  end

  local lines = {}
  local count = 0
  for line in content:gmatch("[^\n]+") do
    count = count + 1
    if count <= 200 then
      lines[count] = line
    end
  end

  -- Remove old df counts if re-indexing
  local old = bm25_index[filepath]
  if old then
    local old_seen = {}
    for t, _ in pairs(old.terms) do
      if not old_seen[t] then
        df[t] = (df[t] or 1) - 1
        if df[t] <= 0 then df[t] = nil end
        old_seen[t] = true
      end
    end
    total_docs = total_docs - 1
  end

  bm25_index[filepath] = { terms = term_counts, len = #terms, lines = lines, size = #content }
  total_docs = total_docs + 1

  local seen = {}
  for _, t in ipairs(terms) do
    if not seen[t] then
      df[t] = (df[t] or 0) + 1
      seen[t] = true
    end
  end

  return content
end

-------------------------------------------------------------------------------
-- Vector: Embed chunks for a file (if embed module available)
-- Returns true if new embeddings were computed
-------------------------------------------------------------------------------
local function vec_index_file(filepath, content, mtime)
  if not embed or not embed.is_available() then return false end
  if not content then return false end

  mtime = mtime or file_mtime(filepath)

  -- Skip if already indexed with same mtime
  if vec_index[filepath] and vec_index[filepath].mtime == mtime and mtime > 0 then
    return false
  end

  local chunks = chunk_text(content)
  if #chunks == 0 then return false end

  -- Batch embed all chunks for this file
  local texts = {}
  for _, c in ipairs(chunks) do
    texts[#texts + 1] = c.text:sub(1, 2000) -- cap per-chunk to ~500 tokens
  end

  local vectors, err = embed.batch_encode(texts, "search_document")
  if not vectors then
    -- Fallback to single encoding
    vectors = {}
    for i, text in ipairs(texts) do
      local vec, e = embed.encode(text, "search_document")
      if vec then
        vectors[i] = vec
      else
        vectors[i] = nil
      end
    end
  end

  -- Build chunk entries with vectors
  local indexed_chunks = {}
  for i, c in ipairs(chunks) do
    if vectors[i] then
      embed.normalize(vectors[i])
      indexed_chunks[#indexed_chunks + 1] = {
        text = c.text:sub(1, 1000),
        vec = vectors[i],
        start_line = c.start_line,
      }
    end
  end

  if #indexed_chunks > 0 then
    vec_index[filepath] = { chunks = indexed_chunks, mtime = mtime }
    return true
  end

  return false
end

-------------------------------------------------------------------------------
-- Persistence: Save vector index to disk
-- Format: { filepath: { mtime: N, chunks: [ { vec: [...], start_line: N } ] } }
-- We strip chunk text from saved format to reduce size
-------------------------------------------------------------------------------
function search.save_vectors()
  if not embed or not embed.is_available() then return false end

  local save_data = {}
  for filepath, entry in pairs(vec_index) do
    local chunks_save = {}
    for _, c in ipairs(entry.chunks) do
      chunks_save[#chunks_save + 1] = {
        vec = c.vec,
        start_line = c.start_line,
      }
    end
    save_data[filepath] = { mtime = entry.mtime, chunks = chunks_save }
  end

  os.execute("mkdir -p .coder")
  local f = io.open(VECTOR_FILE, "w")
  if not f then return false end
  f:write(json.encode(save_data))
  f:close()
  return true
end

-------------------------------------------------------------------------------
-- Persistence: Load vector index from disk
-------------------------------------------------------------------------------
function search.load_vectors()
  local f = io.open(VECTOR_FILE, "r")
  if not f then return 0 end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= "table" then return 0 end

  local loaded = 0
  for filepath, entry in pairs(data) do
    if entry.chunks and entry.mtime then
      local chunks = {}
      for _, c in ipairs(entry.chunks) do
        if c.vec and #c.vec > 0 then
          chunks[#chunks + 1] = {
            vec = c.vec,
            start_line = c.start_line or 1,
            text = "", -- text not persisted
          }
        end
      end
      if #chunks > 0 then
        vec_index[filepath] = { chunks = chunks, mtime = entry.mtime }
        loaded = loaded + 1
      end
    end
  end

  return loaded
end

-------------------------------------------------------------------------------
-- Init embedding support
-------------------------------------------------------------------------------
function search.init_embeddings(embed_module)
  embed = embed_module
  if embed and embed.is_available() then
    local loaded = search.load_vectors()
    return loaded
  end
  return 0
end

-------------------------------------------------------------------------------
-- Re-index a single file (called after writes)
-------------------------------------------------------------------------------
function search.reindex_file(filepath)
  local content = bm25_index_file(filepath)

  -- Recompute avg_dl
  if total_docs > 0 then
    local total_len = 0
    for _, doc in pairs(bm25_index) do
      total_len = total_len + doc.len
    end
    avg_dl = total_len / total_docs
  end

  -- Also update vector index if available
  if content and embed and embed.is_available() then
    local changed = vec_index_file(filepath, content)
    if changed then
      search.save_vectors()
    end
  end
end

-------------------------------------------------------------------------------
-- Index a directory tree (BM25 + optionally vectors)
-------------------------------------------------------------------------------
function search.index_dir(root_dir, extensions)
  root_dir = root_dir or "."
  local ext_filter = ""
  if extensions and #extensions > 0 then
    local parts = {}
    for _, ext in ipairs(extensions) do
      parts[#parts + 1] = "-name '*." .. ext .. "'"
    end
    ext_filter = "\\( " .. table.concat(parts, " -o ") .. " \\)"
  end

  -- Use find -exec stat to get mtime and path in one go (FreeBSD compatible)
  local cmd = string.format(
    "find %q -type f %s -not -path '*/.git/*' -not -path '*/.coder/*' -not -path '*/.crush/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -not -path '*/build/*' -not -path '*/backups/*' -not -path '*/llama.cpp/*' -not -name '*.gguf' -not -name '*.bin' -not -name '*.o' -not -name '*.so' -size -100k -exec stat -f '%%m %%p' {} + 2>/dev/null | head -500",
    root_dir, ext_filter
  )
  local p = io.popen(cmd)
  local output = p:read("*a")
  p:close()

  -- Reset BM25 index
  bm25_index = {}
  df = {}
  total_docs = 0
  avg_dl = 0

  -- Collect files that need vector re-indexing
  local files_to_embed = {}

  for line in output:gmatch("[^\n]+") do
    local mtime_str, filepath = line:match("^(%d+)%s+(.+)$")
    if mtime_str and filepath then
      local mtime = tonumber(mtime_str) or 0
      local content = bm25_index_file(filepath)
      if content and embed and embed.is_available() then
        if not vec_index[filepath] or vec_index[filepath].mtime ~= mtime or mtime == 0 then
          files_to_embed[#files_to_embed + 1] = { path = filepath, content = content, mtime = mtime }
        end
      end
    end
  end

  -- Compute avg_dl
  if total_docs > 0 then
    local total_len = 0
    for _, doc in pairs(bm25_index) do
      total_len = total_len + doc.len
    end
    avg_dl = total_len / total_docs
  end

  -- Batch embed files that need updating
  if #files_to_embed > 0 and embed and embed.is_available() then
    io.write(string.format("  [embedding %d files...]\n", #files_to_embed))
    io.flush()
    local embedded = 0
    for i, entry in ipairs(files_to_embed) do
      local ok, err = pcall(vec_index_file, entry.path, entry.content, entry.mtime)
      if ok then
        embedded = embedded + 1
      end
      -- Progress every 10 files
      if i % 10 == 0 then
        io.write(string.format("  [embedded %d/%d]\n", i, #files_to_embed))
        io.flush()
      end
    end
    if embedded > 0 then
      search.save_vectors()
      io.write(string.format("  [embedded %d files, saved to %s]\n", embedded, VECTOR_FILE))
      io.flush()
    end
  end

  -- Remove stale entries from vec_index (files no longer in project)
  if embed and embed.is_available() then
    local stale = {}
    for filepath, _ in pairs(vec_index) do
      if not bm25_index[filepath] then
        stale[#stale + 1] = filepath
      end
    end
    for _, filepath in ipairs(stale) do
      vec_index[filepath] = nil
    end
  end

  return total_docs
end

-------------------------------------------------------------------------------
-- BM25 score
-------------------------------------------------------------------------------
local function bm25_score(doc, query_terms)
  local score = 0
  local dl = doc.len

  for _, qt in ipairs(query_terms) do
    local tf = doc.terms[qt] or 0
    if tf > 0 then
      local doc_freq = df[qt] or 0
      local idf = math.log((total_docs - doc_freq + 0.5) / (doc_freq + 0.5) + 1)
      local tf_norm = (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / avg_dl))
      score = score + idf * tf_norm
    end
  end

  return score
end

-------------------------------------------------------------------------------
-- Semantic score: best cosine similarity across all chunks for a file
-------------------------------------------------------------------------------
local function semantic_score(filepath, query_vec)
  if not query_vec then return 0, nil end
  local entry = vec_index[filepath]
  if not entry or not entry.chunks then return 0, nil end

  local best = 0
  local best_chunk = nil
  for _, chunk in ipairs(entry.chunks) do
    if chunk.vec then
      local sim = embed.cosine(query_vec, chunk.vec)
      if sim > best then
        best = sim
        best_chunk = chunk
      end
    end
  end

  return best, best_chunk
end

-------------------------------------------------------------------------------
-- Extract snippet from BM25 index
-------------------------------------------------------------------------------
local function extract_snippet(doc, query_terms, max_lines)
  max_lines = max_lines or 8
  if not doc.lines or #doc.lines == 0 then return nil end

  -- Score each line by how many query terms it contains
  local line_scores = {}
  for i = 1, #doc.lines do
    local line_lower = doc.lines[i]:lower()
    local line_score = 0
    for _, qt in ipairs(query_terms) do
      if line_lower:find(qt, 1, true) then
        line_score = line_score + 1
      end
    end
    line_scores[i] = line_score
  end

  -- Find the best window of max_lines with highest total score
  local best_start = 1
  local best_score = 0
  for i = 1, math.max(1, #doc.lines - max_lines + 1) do
    local window_score = 0
    for j = i, math.min(i + max_lines - 1, #doc.lines) do
      window_score = window_score + line_scores[j]
    end
    if window_score > best_score then
      best_score = window_score
      best_start = i
    end
  end

  -- Expand context slightly before the match
  local start = math.max(1, best_start - 2)
  local stop = math.min(#doc.lines, start + max_lines - 1)
  local snippet_lines = {}
  for i = start, stop do
    snippet_lines[#snippet_lines + 1] = doc.lines[i]
  end
  return table.concat(snippet_lines, "\n")
end

-------------------------------------------------------------------------------
-- Hybrid query: BM25 + semantic search
-- Scores normalized and combined with configurable weights
-------------------------------------------------------------------------------
function search.query(query_str, top_k, with_snippets)
  top_k = top_k or 5
  if total_docs == 0 then return {} end

  local query_terms = tokenize(query_str)
  if #query_terms == 0 then return {} end

  -- Compute query embedding if available
  local query_vec = nil
  if embed and embed.is_available() then
    local vec, err = embed.encode(query_str, "search_query")
    if vec then
      embed.normalize(vec)
      query_vec = vec
    end
  end

  -- Score all documents
  local raw_results = {}
  local max_bm25 = 0
  local max_sem = 0

  -- Collect all filepaths (union of BM25 + vector indexed)
  local all_files = {}
  for filepath, _ in pairs(bm25_index) do
    all_files[filepath] = true
  end
  if query_vec then
    for filepath, _ in pairs(vec_index) do
      all_files[filepath] = true
    end
  end

  for filepath, _ in pairs(all_files) do
    local bm = 0
    local doc = bm25_index[filepath]
    if doc then
      bm = bm25_score(doc, query_terms)
    end

    local sem = 0
    local best_chunk = nil
    if query_vec then
      sem, best_chunk = semantic_score(filepath, query_vec)
    end

    if bm > 0 or sem > 0.3 then
      raw_results[#raw_results + 1] = {
        path = filepath,
        bm25 = bm,
        semantic = sem,
        best_chunk = best_chunk,
        size = doc and doc.size or 0,
      }
      if bm > max_bm25 then max_bm25 = bm end
      if sem > max_sem then max_sem = sem end
    end
  end

  -- Normalize and combine scores
  for _, r in ipairs(raw_results) do
    local norm_bm25 = max_bm25 > 0 and (r.bm25 / max_bm25) or 0
    local norm_sem = max_sem > 0 and (r.semantic / max_sem) or 0

    if query_vec then
      r.score = BM25_WEIGHT * norm_bm25 + SEMANTIC_WEIGHT * norm_sem
    else
      r.score = norm_bm25
    end
  end

  table.sort(raw_results, function(a, b_) return a.score > b_.score end)

  local top = {}
  for i = 1, math.min(top_k, #raw_results) do
    local r = raw_results[i]
    local entry = {
      path = r.path,
      score = r.score,
      size = r.size,
      bm25 = r.bm25,
      semantic = r.semantic,
    }
    if with_snippets then
      local doc = bm25_index[r.path]
      if doc then
        entry.snippet = extract_snippet(doc, query_terms)
      end
    end
    top[i] = entry
  end

  return top
end

-------------------------------------------------------------------------------
-- Format results
-------------------------------------------------------------------------------
function search.format_results(results)
  if #results == 0 then return "No matching files found." end
  local parts = {}
  for i, r in ipairs(results) do
    local detail = string.format("score: %.2f", r.score)
    if r.bm25 and r.bm25 > 0 then
      detail = detail .. string.format(", bm25: %.2f", r.bm25)
    end
    if r.semantic and r.semantic > 0 then
      detail = detail .. string.format(", sem: %.2f", r.semantic)
    end
    local line = string.format("%d. %s (%s, %d bytes)", i, r.path, detail, r.size or 0)
    if r.snippet then
      line = line .. "\n   " .. r.snippet:gsub("\n", "\n   ")
    end
    parts[i] = line
  end
  return table.concat(parts, "\n")
end

function search.doc_count()
  return total_docs
end

function search.vec_count()
  local count = 0
  for _ in pairs(vec_index) do count = count + 1 end
  return count
end

return search
