local script_dir = os.getenv("JENOVA_ROOT") or (debug.getinfo(1, "S").source:match("^@(.*/)" ) or "./")
local root_dir = script_dir
-- If script_dir points at the lib/ directory (e.g., when running lib/proxy.lua directly),
-- strip the trailing "lib/" so root_dir becomes the project root.
if root_dir:match("/lib/$") then
  root_dir = root_dir:sub(1, #root_dir - #"lib/")
end
package.path = root_dir .. "/lib/?.lua;" .. script_dir .. "/?.lua;" .. package.path

local ffi = require("ffi")
local bit = require("bit")
local _ffi_defs = require("ffi_defs")
local json = require("json")
local search = require("search")
local embed = require("embed")
local prompts = require("prompts")

-- MIME types for static file serving
local MIME_TYPES = {
    html = "text/html",
    js = "application/javascript",
    css = "text/css",
    svg = "image/svg+xml",
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    json = "application/json",
    pdf = "application/pdf",
    md = "text/markdown",
    mp3 = "audio/mpeg",
    mp4 = "video/mp4",
    xml = "application/xml",
    gif = "image/gif",
    webp = "image/webp",
    txt = "text/plain"
}

-- Filesystem API for WebUI persistence
local home_dir = os.getenv("HOME") or "/tmp"
local jca_home = os.getenv("JCA_HOME") or (home_dir .. "/Jenova")
local workspaces_dir = os.getenv("JENOVA_WORKSPACES") or (jca_home .. "/Workspaces")

local HOST = os.getenv("JENOVA_PROXY_HOST") or os.getenv("JENOVA_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("JENOVA_PROXY_PORT") or os.getenv("JENOVA_PORT")) or 8080
local LLAMA_URL = os.getenv("JENOVA_LLAMA_URL") or "http://127.0.0.1:" .. (os.getenv("JENOVA_LLAMA_PORT") or "8081")
local LLAMA_PORT = tonumber(LLAMA_URL:match(":(%d+)/?$") or LLAMA_URL:match(":(%d+):") or LLAMA_URL:match(":(%d+)")) or 8081
local LLAMA_HOST = LLAMA_URL:match("//%[([^%]]+)%]") or LLAMA_URL:match("//([^:/]+)") or "127.0.0.1"
local LLAMA_CONNECT_HOST = LLAMA_HOST
if LLAMA_CONNECT_HOST == "0.0.0.0" or LLAMA_CONNECT_HOST == "::" or LLAMA_CONNECT_HOST == "*" or LLAMA_CONNECT_HOST == "localhost" then
    LLAMA_CONNECT_HOST = "127.0.0.1"
end

local embed_ok, embed_res = pcall(function()
  return embed.init({
    script_dir = script_dir,
  })
end)
if not embed_ok then
  io.write("[proxy] WARNING: embed.init failed: " .. tostring(embed_res) .. "\n")
  embed_ok = false
else
  embed_ok = embed_res
end
-- Indexing moved to after server listen


print("[proxy] Jenova Signal Proxy loaded on port " .. PORT .. ". Embeddings: " .. tostring(embed_ok))

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = _ffi_defs.SOL_SOCKET
local SO_REUSEADDR = _ffi_defs.SO_REUSEADDR
local SO_ERROR = _ffi_defs.SO_ERROR

local EAGAIN = _ffi_defs.EAGAIN
local EWOULDBLOCK = _ffi_defs.EWOULDBLOCK
local EINPROGRESS = _ffi_defs.EINPROGRESS

local MAX_ACTIVE_CONNECTIONS = 32
local MAX_HEADER_SIZE = 65536
local MAX_BODY_SIZE = 100 * 1024 * 1024

local function set_nonblocking(fd)
    local flags = ffi.C.fcntl(fd, _ffi_defs.F_GETFL, 0)
    if flags < 0 then
        io.write("[proxy] WARNING: fcntl(F_GETFL) failed for fd=" .. fd .. "\n")
        flags = 0
    end
    ffi.C.fcntl(fd, _ffi_defs.F_SETFL, bit.bor(flags, _ffi_defs.O_NONBLOCK))
end

local function set_socket_opts(fd)
    local one = ffi.new("int[1]", 1)
    ffi.C.setsockopt(fd, _ffi_defs.IPPROTO_TCP, _ffi_defs.TCP_NODELAY, one, ffi.sizeof("int"))
    ffi.C.setsockopt(fd, SOL_SOCKET, _ffi_defs.SO_KEEPALIVE, one, ffi.sizeof("int"))
end

-- Prevent socket fds from leaking into child processes spawned by io.popen
local function set_cloexec(fd)
    local flags = ffi.C.fcntl(fd, _ffi_defs.F_GETFD, 0)
    if flags < 0 then flags = 0 end
    ffi.C.fcntl(fd, _ffi_defs.F_SETFD, bit.bor(flags, _ffi_defs.FD_CLOEXEC))
end

local function decode_chunked_body(after_headers)
    local decoded = {}
    local pos = 1
    while pos <= #after_headers do
        local chunk_end = after_headers:find("\r\n", pos)
        if not chunk_end then break end
        local size_str = after_headers:sub(pos, chunk_end - 1)
        local chunk_size = tonumber(size_str, 16)
        if not chunk_size then break end
        if chunk_size == 0 then break end
        local chunk_data = after_headers:sub(chunk_end + 2, chunk_end + 1 + chunk_size)
        decoded[#decoded + 1] = chunk_data
        pos = chunk_end + 2 + chunk_size + 2
    end
    return table.concat(decoded)
end

local EINTR = 4
local function async_recv(fd, buf, len, deadline)
    while true do
        local n = ffi.C.recv(fd, buf, len, 0)
        if n >= 0 then return tonumber(n) end
        local err = ffi.errno()
        if err == EINTR then goto retry end
        if err ~= EAGAIN and err ~= EWOULDBLOCK then return -1, err end
        if deadline and os.time() > deadline then return -2, "timeout" end
        coroutine.yield("read", fd, deadline)
        ::retry::
    end
end

local function async_send(fd, data)
    local sent = 0
    while sent < #data do
        local n = ffi.C.send(fd, data:sub(sent + 1), #data - sent, 0)
        if n >= 0 then
            sent = sent + tonumber(n)
        else
            local err = ffi.errno()
            if err ~= EAGAIN and err ~= EWOULDBLOCK then return -1, err end
            coroutine.yield("write", fd)
        end
    end
    return sent
end

local function async_connect(fd, addr, addrlen)
    addrlen = addrlen or ffi.sizeof(addr)
    local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), addrlen)
    if ret == 0 then return true end
    local err = ffi.errno()
    if err ~= EINPROGRESS then return false, err end
    coroutine.yield("write", fd)
    local opt = ffi.new("int[1]")
    local len = ffi.new("socklen_t[1]", ffi.sizeof("int"))
    ffi.C.getsockopt(fd, SOL_SOCKET, SO_ERROR, opt, len)
    if opt[0] == 0 then return true else return false, opt[0] end
end

local function async_popen_read(cmd)
    local pipe_fds = ffi.new("int[2]")
    if ffi.C.pipe(pipe_fds) < 0 then return nil, "pipe failed" end
    local pid = ffi.C.fork()
    if pid == 0 then
        ffi.C.close(pipe_fds[0])
        ffi.C.dup2(pipe_fds[1], 1)
        ffi.C.dup2(pipe_fds[1], 2)
        ffi.C.close(pipe_fds[1])
        local argv = ffi.new("const char *[4]")
        argv[0] = "/bin/sh"
        argv[1] = "-c"
        argv[2] = cmd
        argv[3] = nil
        ffi.C.execvp("/bin/sh", ffi.cast("char *const *", argv))
        ffi.C._exit(1)
    end
    ffi.C.close(pipe_fds[1])
    local fd = pipe_fds[0]
    set_nonblocking(fd)
    set_cloexec(fd)
    
    local chunks = {}
    local buf = ffi.new("char[4096]")
    while true do
        local n = ffi.C.read(fd, buf, 4096)
        if n > 0 then
            chunks[#chunks + 1] = ffi.string(buf, n)
        elseif n == 0 then
            break
        else
            local err = ffi.errno()
            if err == _ffi_defs.EAGAIN or err == _ffi_defs.EWOULDBLOCK then
                coroutine.yield("read", fd)
            else
                break
            end
        end
    end
    ffi.C.close(fd)
    ffi.C.waitpid(pid, nil, 0)
    return table.concat(chunks)
end

-- Detect available HTTPS-capable command-line tool (once at startup).
-- FreeBSD: 'fetch' is in base. Linux/other: fall back to 'curl'.
local HTTPS_CMD
do
    local function cmd_exists(name)
        local h = io.popen("command -v " .. name .. " 2>/dev/null")
        if not h then return false end
        local out = h:read("*l")
        h:close()
        return out and #out > 0
    end
    if cmd_exists("fetch") then
        HTTPS_CMD = "fetch"
    elseif cmd_exists("curl") then
        HTTPS_CMD = "curl"
    end
    if HTTPS_CMD then
        print("[proxy] Web search HTTP client: " .. HTTPS_CMD)
    else
        print("[proxy] WARNING: No HTTPS client found (fetch/curl). Web search disabled.")
    end
end

-- Build a shell command to fetch a URL to stdout, with a timeout.
local function https_fetch_cmd(url, timeout)
    timeout = timeout or 5
    if HTTPS_CMD == "fetch" then
        return string.format("fetch -T %d -qo - '%s' 2>/dev/null", timeout, url)
    elseif HTTPS_CMD == "curl" then
        return string.format("curl -sL --max-time %d '%s' 2>/dev/null", timeout, url)
    end
    return nil
end

local function strip_html(s)
    return s:gsub("<[^>]+>", "")
        :gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#x27;", "'"):gsub("&#039;", "'")
        :gsub("&nbsp;", " "):gsub("\\n", " "):gsub("\r", " "):gsub("\n", " ")
        :match("^%s*(.-)%s*$")
end

-- URL-encode a query string for use in search URLs.
local function url_encode(query)
    return query:gsub("([^%w%-%._~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+")
end

-- URL-decode a string.
local function url_decode(str)
    return str:gsub("+", " "):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
end

-- DuckDuckGo Instant Answer API: returns JSON, no scraping needed.
-- Good for factual queries (definitions, summaries, related topics).
-- Does NOT return full web results for every query — supplementary source.
local function ddg_instant_answer(query)
    if not HTTPS_CMD then return nil end
    local encoded = url_encode(query)
    local url = "https://api.duckduckgo.com/?q=" .. encoded .. "&format=json&no_html=1&skip_disambig=1"
    local cmd = https_fetch_cmd(url, 5)
    if not cmd then return nil end

    local raw = async_popen_read(cmd)
    if not raw or #raw < 10 then return nil end

    local ok, data = pcall(json.decode, raw)
    if not ok or not data then return nil end

    local results = {}

    -- AbstractText: direct answer (e.g. Wikipedia summary)
    if data.AbstractText and #data.AbstractText > 20 then
        results[#results + 1] = string.format("[1] %s\n    %s",
            data.AbstractSource or "Summary",
            data.AbstractText:sub(1, 500))
    end

    -- RelatedTopics: list of related items with text and URLs
    if data.RelatedTopics then
        for _, topic in ipairs(data.RelatedTopics) do
            if #results >= 5 then break end
            if topic.Text and #topic.Text > 10 then
                local title = topic.Text:match("^(.-)%s+%-") or topic.Text:sub(1, 80)
                results[#results + 1] = string.format("[%d] %s\n    %s",
                    #results + 1, title, topic.Text:sub(1, 300))
            end
        end
    end

    if #results > 0 then
        print("[proxy] Web search: DuckDuckGo Instant Answer returned " .. #results .. " result(s)")
        return results
    end
    return nil
end

-- DuckDuckGo HTML scraping: returns full web search results.
-- Parses titles and snippets from the HTML endpoint.
local function ddg_html_search(query)
    if not HTTPS_CMD then return nil end
    local encoded = url_encode(query)
    local url = "https://html.duckduckgo.com/html/?q=" .. encoded
    local cmd = https_fetch_cmd(url, 8)
    if not cmd then return nil end

    local html = async_popen_read(cmd)
    if not html or #html < 100 then return nil end

    local titles, snippets = {}, {}
    for t in html:gmatch('class="result__a"[^>]*>(.-)</a>') do
        local clean = strip_html(t)
        if clean and #clean > 0 then titles[#titles + 1] = clean end
    end
    for s in html:gmatch('class="result__snippet"[^>]*>(.-)</a>') do
        local clean = strip_html(s)
        if clean and #clean > 10 then snippets[#snippets + 1] = clean end
    end

    local count = math.min(#titles, #snippets, 5)
    if count == 0 then return nil end
    local results = {}
    for i = 1, count do
        results[i] = string.format("[%d] %s\n    %s", i, titles[i], snippets[i])
    end
    print("[proxy] Web search: DuckDuckGo HTML returned " .. count .. " result(s)")
    return results
end

-- Web search: combines DuckDuckGo Instant Answer API + HTML scraping.
-- Strategy: try HTML scraping first (full web results), fall back to
-- Instant Answer API (JSON, good for factual/definition queries).
-- Called only on explicit "Web Search:" intent from the user.
-- Blocks the calling coroutine for up to ~13 seconds worst case.
-- Acceptable: single-user system, user-initiated, short timeout.
local function exec_web_search(query)
    if not HTTPS_CMD then
        print("[proxy] Web search FAILED: no HTTPS client available (install curl or use FreeBSD fetch)")
        return nil
    end

    -- Try full HTML results first (most useful for general queries)
    local results = ddg_html_search(query)
    if results then return results end

    -- Fall back to Instant Answer API (good for factual queries)
    results = ddg_instant_answer(query)
    if results then return results end

    print("[proxy] Web search: no results found for query: " .. query:sub(1, 80))
    return nil
end

local active_connection_count = 0

local function recursive_mkdir(path)
    local segments = {}
    for segment in path:gmatch("[^/]+") do
        table.insert(segments, segment)
    end
    local current = path:sub(1, 1) == "/" and "/" or ""
    for i, segment in ipairs(segments) do
        current = current .. segment
        local res = ffi.C.mkdir(current, 493) -- 0755
        if res ~= 0 then
            local err = ffi.errno()
            -- EEXIST (17 on many platforms) is fine, others might be worth logging
            if err ~= 17 and err ~= 20 then -- 20 is ENOTDIR, also handled by OS
                -- Silently continue, as we'll fail later on io.open if it's fatal
            end
        end
        current = current .. "/"
    end
end

-- Pure Lua path normalization
local function normalize_path(path)
    -- Handle multiple consecutive slashes and trailing slashes explicitly
    path = path:gsub("//+", "/")
    if path ~= "/" and path:sub(-1) == "/" then
        path = path:sub(1, -2)
    end

    local is_absolute = path:sub(1, 1) == "/"
    local segments = {}
    for segment in path:gmatch("[^/]+") do
        if segment == "." then
            -- skip
        elseif segment == ".." then
            if #segments > 0 and segments[#segments] ~= ".." then
                table.remove(segments)
            elseif is_absolute then
                return nil -- escape attempted on absolute path
            else
                table.insert(segments, "..")
            end
        else
            table.insert(segments, segment)
        end
    end
    local res = table.concat(segments, "/")
    if is_absolute then
        return "/" .. res
    end
    return res == "" and "." or res
end

-- Resolve a path and verify it stays within the allowed base directory.
local function resolve_safe_path(base_dir, relative_path)
    local norm_base = normalize_path(base_dir)
    if not norm_base then return nil end
    
    local candidate = base_dir .. "/" .. relative_path
    local norm_candidate = normalize_path(candidate)
    if not norm_candidate then return nil end
    
    -- Verify the resolved path starts with the base directory and aligns with a directory boundary
    if norm_candidate:sub(1, #norm_base) == norm_base then
        if #norm_candidate == #norm_base or norm_candidate:sub(#norm_base + 1, #norm_base + 1) == "/" then
            return norm_candidate
        end
    end
    return nil
end

local function proxy_connection(client_fd, conn_fds)
    local start_time = os.time()
    set_nonblocking(client_fd)
    set_socket_opts(client_fd)
    conn_fds.client = client_fd
    conn_fds.llama = -1

    local function safe_close()
        if conn_fds.llama >= 0 then pcall(ffi.C.close, conn_fds.llama); conn_fds.llama = -1 end
        if conn_fds.client >= 0 then pcall(ffi.C.close, conn_fds.client); conn_fds.client = -1 end
    end

    local buf = ffi.new("char[8192]")
    local header_chunks = {}
    local header_total = 0
    local body_chunks = {}
    local body_total = 0
    local headers_raw = ""
    local body_raw = ""
    local content_length = 0
    local is_chunked = false
    local is_get = false

    while true do
        local n, err = async_recv(client_fd, buf, 8192, start_time + 10)
        if n <= 0 then 
            if err == "timeout" or os.time() - start_time > 10 then
                io.write("[proxy] header timeout from client\n")
            elseif n < 0 then 
                io.write("[proxy] client recv error: " .. tostring(err) .. "\n") 
            end
            safe_close(); return 
        end

        header_chunks[#header_chunks + 1] = ffi.string(buf, n)
        header_total = header_total + n
        if header_total > MAX_HEADER_SIZE then
            local err_resp = "HTTP/1.1 431 Request Header Fields Too Large\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            async_send(client_fd, err_resp)
            safe_close(); return
        end
        headers_raw = table.concat(header_chunks)

        local header_end = headers_raw:find("\r\n\r\n")
        if header_end then
            body_raw = headers_raw:sub(header_end + 4)
            headers_raw = headers_raw:sub(1, header_end + 3)
            header_chunks = nil
            local cl = headers_raw:lower():match("content%-length:%s*(%d+)")
            if cl then content_length = tonumber(cl) end
            is_chunked = headers_raw:lower():find("transfer%-encoding:%s*chunked") ~= nil
            is_get = headers_raw:match("^GET ") ~= nil
            break
        end
        
    end


        local origin = headers_raw:match("\r\n[Oo][Rr][Ii][Gg][Ii][Nn]:%s*([^\r\n]+)")
        local allow_origin = origin or "http://localhost:8080"
        if origin then
            local is_safe = origin == "null" or origin:match("^file://") or origin:match("^https?://127%.0%.0%.1$") or origin:match("^https?://127%.0%.0%.1:%d+$") or origin:match("^https?://localhost$") or origin:match("^https?://localhost:%d+$")
            if not is_safe then
                local err = "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n"
                async_send(client_fd, err); safe_close(); return
            end
        end

        if headers_raw:match("^OPTIONS ") then
            local cors_resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS, PUT, DELETE\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n"
            async_send(client_fd, cors_resp)
            safe_close(); return
        end
    -- Native /health endpoint
    local is_health = is_get and (headers_raw:match("^GET /health[ %?]") or headers_raw:match("^GET /v1/health[ %?]"))
    if is_health then
        local backend_ok = false
        local health_fd = -1
        
        -- Optimized health probe: skip getaddrinfo for 127.0.0.1
        if LLAMA_CONNECT_HOST == "127.0.0.1" then
            health_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
            if health_fd >= 0 then
                set_cloexec(health_fd)
                set_nonblocking(health_fd)
                local h_addr = ffi.new("struct sockaddr_in")
                if not _ffi_defs.IS_LINUX then h_addr.sin_len = ffi.sizeof(h_addr) end
                h_addr.sin_family = AF_INET
                h_addr.sin_port   = ffi.C.htons(LLAMA_PORT)
                h_addr.sin_addr.s_addr = ffi.C.inet_addr("127.0.0.1")
                
                -- Shorter timeout for health connect (5s)
                local ok, err = async_connect(health_fd, h_addr)
                backend_ok = ok
                ffi.C.close(health_fd)
            end
        else
            local hints = ffi.new("struct addrinfo")
            hints.ai_family = 0 -- AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            local res = ffi.new("struct addrinfo *[1]")
            local rc = ffi.C.getaddrinfo(LLAMA_CONNECT_HOST, tostring(LLAMA_PORT), hints, res)
            if rc == 0 then
                local ai = res[0]
                health_fd = ffi.C.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
                if health_fd >= 0 then
                    set_cloexec(health_fd)
                    set_nonblocking(health_fd)
                    local ok, err = async_connect(health_fd, ai.ai_addr, ai.ai_addrlen)
                    backend_ok = ok
                    ffi.C.close(health_fd)
                end
                ffi.C.freeaddrinfo(ai)
            end
        end

        local status_str  = backend_ok and "ok" or "degraded"
        local http_status = backend_ok and "200 OK" or "503 Service Unavailable"
        local health_body = json.encode({
            status     = status_str,
            proxy      = "running",
            backend    = string.format("%s:%d", LLAMA_HOST, LLAMA_PORT),
            embed      = embed_ok,
            backend_ok = backend_ok,
            jenova     = true,
        })
        local health_resp = string.format(
            "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s",
            http_status, #health_body, health_body)
        async_send(client_fd, health_resp)
        safe_close()
        return
    end

    if not is_get then
        if content_length > MAX_BODY_SIZE then
            local err_resp = "HTTP/1.1 413 Content Too Large\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            async_send(client_fd, err_resp)
            safe_close(); return
        end
        if is_chunked then
            body_chunks[1] = body_raw
            body_total = #body_raw
            local tail = body_raw:sub(-5)
            while tail ~= "0\r\n\r\n" do
                local n = async_recv(client_fd, buf, 8192)
                if n <= 0 then break end
                local chunk = ffi.string(buf, n)
                body_chunks[#body_chunks + 1] = chunk
                body_total = body_total + n
                if body_total > MAX_BODY_SIZE then break end
                local combined = table.concat(body_chunks)
                tail = combined:sub(-5)
            end
            body_raw = decode_chunked_body(table.concat(body_chunks))
            body_chunks = nil
        else
            body_chunks[1] = body_raw
            body_total = #body_raw
            while body_total < content_length do
                local n = async_recv(client_fd, buf, 8192)
                if n <= 0 then break end
                body_chunks[#body_chunks + 1] = ffi.string(buf, n)
                body_total = body_total + n
            end
            body_raw = table.concat(body_chunks)
            body_chunks = nil
        end
    end

    local is_chat_completion = headers_raw:find("POST /v1/chat/completions")
    local is_fim = headers_raw:find("POST /infill")
    
    local storage_path = headers_raw:match("^POST /api/storage/([^ %?]+)")
    if storage_path and #body_raw > 0 then
        storage_path = url_decode(storage_path)
        recursive_mkdir(workspaces_dir)
        
        -- Security: prevent directory traversal (literal check + canonical validation)
        if storage_path:find("%.%.") then
            local err = "HTTP/1.1 403 Forbidden\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n"
            async_send(client_fd, err); safe_close(); return
        end

        local full_path = resolve_safe_path(workspaces_dir, storage_path)
        if not full_path then
            local err = "HTTP/1.1 403 Forbidden\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n"
            async_send(client_fd, err); safe_close(); return
        end
        local dir_part = full_path:match("(.+)/[^/]+$")
        if dir_part then recursive_mkdir(dir_part) end

        local f = io.open(full_path, "wb")
        if f then
            f:write(body_raw)
            f:close()

            local resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}"
            async_send(client_fd, resp)
        else
            local resp = "HTTP/1.1 500 Internal Server Error\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n"
            async_send(client_fd, resp)
        end
        safe_close(); return
    end

    local is_storage_list = is_get and (headers_raw:match("^GET /api/storage/[ %?]") or headers_raw:match("^GET /api/storage "))
    if is_storage_list then
        recursive_mkdir(workspaces_dir)
        local files = {}
        local escaped_dir = workspaces_dir:gsub("'", "'\\''")
        local cmd = "find '" .. escaped_dir .. "' -maxdepth 3 -not -path '*/.*' -not -path '*/node_modules/*' -not -path '*/build/*'"
        local output = async_popen_read(cmd)
        if output then
            for line in output:gmatch("[^\r\n]+") do
                local rel = line:sub(#workspaces_dir + 2)
                if #rel > 0 then table.insert(files, json.encode(rel)) end
            end
        end
        local content = "[" .. table.concat(files, ",") .. "]"
        local resp = string.format("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: %s\r\nVary: Origin\r\nConnection: close\r\n\r\n", #content, allow_origin)
        async_send(client_fd, resp .. content)
        safe_close(); return
    end

    local is_workspaces_list = is_get and headers_raw:match("^GET /api/workspaces")
    if is_workspaces_list then
        recursive_mkdir(workspaces_dir)
        local ws = {}
        local escaped_dir = workspaces_dir:gsub("'", "'\\''")
        local cmd = "find '" .. escaped_dir .. "' -maxdepth 1 -type d -not -path '*/.*'"
        local output = async_popen_read(cmd)
        if output then
            for line in output:gmatch("[^\r\n]+") do
                local name = line:sub(#workspaces_dir + 2)
                if #name > 0 then table.insert(ws, json.encode(name)) end
            end
        end
        local content = "[" .. table.concat(ws, ",") .. "]"
        local resp = string.format("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: %s\r\nVary: Origin\r\nConnection: close\r\n\r\n", #content, allow_origin)
        async_send(client_fd, resp .. content)
        safe_close(); return
    end

    local is_storage_get = is_get and headers_raw:match("^GET /api/storage/([^ %?]+)")
    if is_storage_get then
        is_storage_get = url_decode(is_storage_get)
        if is_storage_get:find("%.%.") then
            local err = "HTTP/1.1 403 Forbidden\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n"
            async_send(client_fd, err); safe_close(); return
        end
        local full_path = resolve_safe_path(workspaces_dir, is_storage_get)
        if not full_path then
            local err = "HTTP/1.1 403 Forbidden\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n"
            async_send(client_fd, err); safe_close(); return
        end
        local f = io.open(full_path, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            
            if not content then
                local resp = "HTTP/1.1 500 Internal Server Error\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n"
                async_send(client_fd, resp)
                safe_close()
                return
            end
            
            local resp = string.format("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: %s\r\nVary: Origin\r\nConnection: close\r\n\r\n", #content, allow_origin)
            async_send(client_fd, resp)
            async_send(client_fd, content)
        else
            local resp = "HTTP/1.1 404 Not Found\r\nAccess-Control-Allow-Origin: " .. allow_origin .. "\r\nVary: Origin\r\nConnection: close\r\n\r\n"
            async_send(client_fd, resp)
        end
        safe_close(); return
    end

    -- Static file serving for Web UI
    if is_get then
        local path = headers_raw:match("^GET ([^ %?]+)")
        if path then
            path = url_decode(path)
            if path == "/" then path = "/index.html" end
            -- Security: prevent directory traversal (literal check + canonical validation)
            if not path:find("%.%.") then
                local local_path = resolve_safe_path(root_dir .. "/public", path:sub(2))
                if local_path then
                    local ext = path:match("%.([^%.]+)$")
                    local is_static_asset = ext and MIME_TYPES[ext:lower()]
                    
                    local f = io.open(local_path, "rb")
                    if f then
                        local content = f:read("*a")
                        f:close()
                        
                        if not content then
                            local resp = "HTTP/1.1 500 Internal Server Error\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                            async_send(client_fd, resp)
                            safe_close()
                            return
                        end
                        
                        local mime = is_static_asset or "application/octet-stream"
                        local resp = string.format(
                            "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                            mime, #content)
                        async_send(client_fd, resp)
                        async_send(client_fd, content)
                        safe_close()
                        return
                    elseif is_static_asset then
                        local resp = "HTTP/1.1 404 Not Found\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                        async_send(client_fd, resp)
                        safe_close()
                        return
                    end
                end
            end
        end
    end

    local intent = headers_raw:match("[Xx]%-Intent:%s*(%w+)")
    headers_raw = headers_raw:gsub("(\r\n[Hh][Oo][Ss][Tt]:%s*)[^\r\n]+", "%1" .. LLAMA_HOST .. ":" .. LLAMA_PORT)
    headers_raw = headers_raw:gsub("\r\n[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ii][Oo][Nn]:%s*[^\r\n]*\r\n", "\r\n")
    headers_raw = headers_raw:gsub("\r\n\r\n", "\r\nConnection: close\r\n\r\n")
    local proxied_req = headers_raw .. body_raw

    if is_chat_completion and #body_raw > 0 then
        local ok, req_json = pcall(json.decode, body_raw)
        if ok and req_json and req_json.messages then
            local last_user_msg = ""
            local last_user_idx = -1
            for i = #req_json.messages, 1, -1 do
                if req_json.messages[i].role == "user" then
                    last_user_msg = req_json.messages[i].content or ""
                    last_user_idx = i
                    break
                end
            end

            -- Detect project root (passive only, no auto-indexing in proxy)
            local project_root = body_raw:match("project_root: ([^\n\r]+)")
            if project_root then
                project_root = project_root:gsub("\r", ""):gsub("\"", ""):gsub("\\n", ""):gsub("\\r", ""):gsub("}$", ""):gsub(",$", ""):match("^%s*(.-)%s*$")
                if project_root == "web_workspace" then
                    project_root = workspaces_dir
                elseif project_root ~= "" and not project_root:match("^/") and not project_root:match("^~") then
                    project_root = workspaces_dir .. "/" .. project_root
                end
                _G._last_project_root = project_root
            end

            -- Intent detection: each entry maps a prefix pattern to an intent name.
            -- The same pattern is used both to detect the intent and to strip the prefix.
            local intent_prefixes = {
                { pattern = "^%s*Visual Rewrite:%s*",  intent = "visual"    },
                { pattern = "^%s*Open File Chat:%s*",  intent = "filechat"  },
                { pattern = "^%s*Chatbot:%s*",         intent = "filechat"  },
                { pattern = "^%s*Web Search:%s*",      intent = "websearch" },
            }
            for _, entry in ipairs(intent_prefixes) do
                if last_user_msg:match(entry.pattern) then
                    intent = entry.intent
                    req_json.messages[last_user_idx].content = last_user_msg:gsub(entry.pattern, "")
                    last_user_msg = req_json.messages[last_user_idx].content
                    break
                end
            end

            if last_user_msg ~= "" and not last_user_msg:find("--- REPOSITORY CONTEXT ---") then
                local rag_limit = (intent == "visual") and 1 or (intent == "websearch") and 0 or 3
                local rag_query = last_user_msg
                local embedded_path = last_user_msg:match("Path:%s*(%S+)")
                if embedded_path and #last_user_msg > 2000 then
                    local basename = embedded_path:match("([^/]+)$") or embedded_path
                    local after_code = last_user_msg:match("```\n\n(.+)$")
                    if after_code and #after_code > 10 then
                        rag_query = basename .. " " .. after_code
                    else
                        rag_query = basename
                    end
                    rag_limit = 5
                end
                local rag = search.query(rag_query, rag_limit, true)
                local rag_context = ""

                if #rag > 0 then
                    local parts = { "\n--- REPOSITORY CONTEXT ---" }
                    for i, r in ipairs(rag) do
                        parts[#parts+1] = string.format("[%d] %s", i, r.path)
                        if r.snippet then parts[#parts+1] = r.snippet:sub(1, 1000) end
                    end
                    rag_context = table.concat(parts, "\n")
                end

                local web_context = ""
                if intent == "websearch" and last_user_msg ~= "" then
                    local web_results = exec_web_search(last_user_msg)
                    if web_results then
                        web_context = "\n--- WEB SEARCH RESULTS ---\n" .. table.concat(web_results, "\n")
                    else
                        web_context = "\n--- WEB SEARCH RESULTS ---\nWeb search returned no results. "
                            .. (HTTPS_CMD
                                and "The search engine did not return matching results for this query. "
                                    .. "Answer the user's question using your own knowledge and clearly state that web search did not find any relevant results for this query."
                                or "No HTTPS client available (install curl or use FreeBSD). Cannot perform web searches. "
                                    .. "Answer the user's question using your own knowledge and clearly state that web search was unavailable.")
                    end
                end

                local has_tools = type(req_json.tools) == "table" and #req_json.tools > 0

                if intent then
                    if intent == "visual" or intent == "websearch" then
                        -- These intents do not benefit from tool calling; strip them.
                        req_json.tools = nil
                        req_json.tool_choice = "none"
                        has_tools = false
                    end

                    local has_system = req_json.messages[1].role == "system"
                    local persona = prompts.freechat

                    if has_tools then
                        -- Agent mode: Do NOT override the client's system prompt if it exists.
                        -- Only inject the CORE MANDATE if no system prompt is present.
                        if not has_system then
                            local agent_persona = "CORE MANDATE: You are Jenova, an autonomous agent. " .. persona
                            table.insert(req_json.messages, 1, {role = "system", content = agent_persona})
                            has_system = true
                        end
                        
                        -- Append contexts to the system prompt (which is now guaranteed to exist at index 1)
                        if web_context ~= "" then req_json.messages[1].content = req_json.messages[1].content .. "\n" .. web_context end
                        if rag_context ~= "" then req_json.messages[1].content = req_json.messages[1].content .. "\n" .. rag_context end
                    else
                        -- Conversational mode (WebUI, etc.): Use persona-first system prompt
                        local system_p = prompts[intent] or persona
                        if web_context ~= "" then system_p = system_p .. "\n" .. web_context end
                        if rag_context ~= "" then system_p = system_p .. "\n" .. rag_context end

                        if has_system then
                            req_json.messages[1].content = system_p .. "\n\n" .. req_json.messages[1].content
                        else
                            table.insert(req_json.messages, 1, {role = "system", content = system_p})
                        end
                    end
                else
                    -- No intent: Apply persona and RAG to any existing system prompt
                    local has_system = req_json.messages[1].role == "system"
                    local persona = prompts.freechat
                    
                    if has_system then
                        req_json.messages[1].content = persona .. "\n\n" .. req_json.messages[1].content
                        if rag_context ~= "" then
                            req_json.messages[1].content = req_json.messages[1].content .. "\n" .. rag_context
                        end
                    else
                        local content = persona
                        if rag_context ~= "" then content = content .. "\n" .. rag_context end
                        table.insert(req_json.messages, 1, {role = "system", content = content})
                    end
                end

                -- Enforce tool_choice for ALL paths: if the request carries tools,
                -- llama-server must be told it is allowed (or required) to call them.
                -- This must run after intent handling so the visual/websearch nil-out above
                -- is respected via the has_tools flag.
                if has_tools then
                    req_json.tool_choice = req_json.tool_choice or "auto"
                end

                local new_body = json.encode(req_json)
                
                -- Robust header update: replace existing Content-Length or append if missing
                local new_headers = headers_raw
                local cl_pattern = "(\r\n[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][Nn][Gg][Tt][Hh]:%s*)%d+"
                if new_headers:find(cl_pattern) then
                    new_headers = new_headers:gsub(cl_pattern, "%1" .. #new_body)
                else
                    new_headers = new_headers:gsub("\r\n\r\n", "\r\nContent-Length: " .. #new_body .. "\r\n\r\n")
                end
                
                -- Ensure Connection: close and strip Chunked encoding for llama-server compatibility
                new_headers = new_headers:gsub("\r\n[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ii][Oo][Nn]:%s*[^\r\n]*\r\n", "\r\n")
                new_headers = new_headers:gsub("[Tt][Rr][Aa][Nn][Ss][Ff][Ee][Rr]%-[Ee][Nn][Cc][Oo][Dd][Ii][Nn][Gg]:%s*[Cc][Hh][Uu][Nn][Kk][Ee][Dd]\r\n", "")
                if not new_headers:find("\r\n[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ii][Oo][Nn]:") then
                    new_headers = new_headers:gsub("\r\n\r\n", "\r\nConnection: close\r\n\r\n")
                end

                proxied_req = new_headers .. new_body
                
                -- Enhanced logging for dispatch
                local dispatch_msg = "[proxy] Dispatch: " .. (intent or "freechat")
                if #rag > 0 then dispatch_msg = dispatch_msg .. " | RAG: " .. #rag .. " hits" end
                if web_context ~= "" then dispatch_msg = dispatch_msg .. " | Web: OK" end
                if has_tools then dispatch_msg = dispatch_msg .. " | Tools: " .. #req_json.tools end
                print(dispatch_msg)
            end
        end
    end

    if is_fim and #body_raw > 0 then
        -- Simply forward FIM requests to llama-server for now.
        -- In the future, we can inject RAG context here too.
        proxied_req = headers_raw .. body_raw
    end

    local llama_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if llama_fd < 0 then
        local err_resp = "HTTP/1.1 500 Internal Server Error\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        async_send(client_fd, err_resp)
        safe_close()
        return
    end
    conn_fds.llama = llama_fd
    set_cloexec(llama_fd)
    set_nonblocking(llama_fd)
    set_socket_opts(llama_fd)

    local l_addr = ffi.new("struct sockaddr_in")
    if not _ffi_defs.IS_LINUX then
        l_addr.sin_len = ffi.sizeof(l_addr)
    end
    l_addr.sin_family = AF_INET
    l_addr.sin_port = ffi.C.htons(LLAMA_PORT)
    l_addr.sin_addr.s_addr = ffi.C.inet_addr(LLAMA_CONNECT_HOST)

    local connected, conn_err = async_connect(llama_fd, l_addr)
    if not connected then
        print("[proxy] ERROR: C++ llama-server backend is down on " .. LLAMA_CONNECT_HOST .. ":" .. LLAMA_PORT .. " (err: " .. tostring(conn_err) .. ")")
        local err_resp = "HTTP/1.1 502 Bad Gateway\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        async_send(client_fd, err_resp)
        safe_close()
        return
    end

    local send_result = async_send(llama_fd, proxied_req)
    proxied_req = nil
    if send_result < 0 then
        io.write("[proxy] ERROR: async_send to llama_fd=" .. llama_fd .. " failed\n")
        safe_close()
        return
    end

    while true do
        local n = async_recv(llama_fd, buf, 8192)
        if n <= 0 then break end
        local to_send = ffi.string(buf, n)
        if async_send(client_fd, to_send) < 0 then break end
    end

    safe_close()
end

ffi.C.signal(_ffi_defs.SIGPIPE, _ffi_defs.SIG_IGN)

local server_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
if server_fd < 0 then
    local err = ffi.errno()
    print("[proxy] Failed to create socket: errno=" .. tostring(err) .. " " .. ffi.string(ffi.C.strerror(err)))
    os.exit(1)
end
set_cloexec(server_fd)
set_nonblocking(server_fd)

local opt = ffi.new("int[1]", 1)
ffi.C.setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, opt, ffi.sizeof("int"))

local addr = ffi.new("struct sockaddr_in")
if not _ffi_defs.IS_LINUX then
    addr.sin_len = ffi.sizeof(addr)
end
addr.sin_family = AF_INET
addr.sin_port = ffi.C.htons(PORT)
addr.sin_addr.s_addr = ffi.C.inet_addr(HOST)

if ffi.C.bind(server_fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) < 0 then
    local err = ffi.errno()
    print("[proxy] Failed to bind to " .. HOST .. ":" .. PORT .. ": errno=" .. tostring(err) .. " " .. ffi.string(ffi.C.strerror(err)))
    os.exit(1)
end

if ffi.C.listen(server_fd, 16) < 0 then
    local err = ffi.errno()
    print("[proxy] Failed to listen: errno=" .. tostring(err) .. " " .. ffi.string(ffi.C.strerror(err)))
    os.exit(1)
end

-- Perform initial indexing only when a project root is detected.
-- Disabled for startup to prevent blocking the main loop or indexing the repository itself.
print("[proxy] Search index deferred until project root is detected.")

-- Main Select Loop
-- conn_fds_map: client_fd -> {client=N, llama=N} tracks all fds owned by each connection
local clients = {}
local background_tasks = {}
local conn_fds_map = {}
local COROUTINE_TIMEOUT = tonumber(os.getenv("JENOVA_CONN_TIMEOUT")) or 600
local read_fds = _ffi_defs.fd_set_new()
local write_fds = _ffi_defs.fd_set_new()

local running = true
local watch_stdin = false
for _, v in ipairs(arg or {}) do
    if v == "--watch-stdin" then
        watch_stdin = true
        break
    end
end
local function shutdown_handler(sig)
    io.write("[proxy] received signal " .. tostring(sig) .. ", shutting down...\n")
    running = false
end
local shutdown_cb = ffi.cast("sighandler_t", shutdown_handler)
_G._jenova_shutdown_cb = shutdown_cb
ffi.C.signal(_ffi_defs.SIGTERM, shutdown_cb)
ffi.C.signal(_ffi_defs.SIGINT, shutdown_cb)

while running do
    _ffi_defs.FD_ZERO(read_fds)
    _ffi_defs.FD_ZERO(write_fds)
    _ffi_defs.FD_SET(server_fd, read_fds)

    local max_fd = server_fd

    if watch_stdin then
        _ffi_defs.FD_SET(0, read_fds)
    end
    for _fd, info in pairs(clients) do
        if info.type == "read" then
            _ffi_defs.FD_SET(info.watch_fd, read_fds)
        elseif info.type == "write" then
            _ffi_defs.FD_SET(info.watch_fd, write_fds)
        end
        if info.watch_fd > max_fd then max_fd = info.watch_fd end
    end

    -- Add background tasks to select sets
    for i = #background_tasks, 1, -1 do
        local task = background_tasks[i]
        if task.type == "read" then
            _ffi_defs.FD_SET(task.watch_fd, read_fds)
            if task.watch_fd > max_fd then max_fd = task.watch_fd end
        elseif task.type == "write" then
            _ffi_defs.FD_SET(task.watch_fd, write_fds)
            if task.watch_fd > max_fd then max_fd = task.watch_fd end
        end
    end

    local tv = ffi.new("struct timeval", {tv_sec=1, tv_usec=0})
    local n = ffi.C.select(max_fd + 1, read_fds, write_fds, nil, tv)

    if n > 0 then
        if watch_stdin and _ffi_defs.FD_ISSET(0, read_fds) then
            local tmp_buf = ffi.new("char[1]")
            local r = ffi.C.read(0, tmp_buf, 1)
            if r <= 0 then
                print("[proxy] EOF on stdin, parent process died. Shutting down...")
                running = false
                break
            end
        end
        if _ffi_defs.FD_ISSET(server_fd, read_fds) then
            local client_addr = ffi.new("struct sockaddr_in")
            local addrlen = ffi.new("socklen_t[1]", ffi.sizeof(client_addr))
            local client_fd = ffi.C.accept(server_fd, ffi.cast("struct sockaddr *", client_addr), addrlen)
            if client_fd >= 0 then
                if active_connection_count >= MAX_ACTIVE_CONNECTIONS then
                    local err_resp = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 5\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                    ffi.C.send(client_fd, err_resp, #err_resp, 0)
                    ffi.C.close(client_fd)
                else
                    active_connection_count = active_connection_count + 1
                    local conn_fds = { client = client_fd, llama = -1 }
                    conn_fds_map[client_fd] = conn_fds
                    local co = coroutine.create(function()
                        local ok, err = pcall(proxy_connection, client_fd, conn_fds)
                        if not ok then
                            io.write("[proxy] connection error: " .. tostring(err) .. "\n")
                            if conn_fds.llama >= 0 then pcall(ffi.C.close, conn_fds.llama); conn_fds.llama = -1 end
                            if conn_fds.client >= 0 then pcall(ffi.C.close, conn_fds.client); conn_fds.client = -1 end
                        end
                        active_connection_count = active_connection_count - 1
                    end)
                    local _ok, type, watch_fd = coroutine.resume(co)
                    if coroutine.status(co) ~= "dead" then
                        clients[client_fd] = {co = co, type = type, watch_fd = watch_fd, created = os.time()}
                    else
                        conn_fds_map[client_fd] = nil
                    end
                end
            end
        end

        for cfd, info in pairs(clients) do
            local ready = false
            if info.type == "read" and _ffi_defs.FD_ISSET(info.watch_fd, read_fds) then
                ready = true
            elseif info.type == "write" and _ffi_defs.FD_ISSET(info.watch_fd, write_fds) then
                ready = true
            end

            if ready then
                local _ok, type, watch_fd = coroutine.resume(info.co)
                if coroutine.status(info.co) == "dead" then
                    clients[cfd] = nil
                    conn_fds_map[cfd] = nil
                else
                    info.type = type
                    info.watch_fd = watch_fd
                end
            end
        end

        -- Handle background tasks
        for i = #background_tasks, 1, -1 do
            local task = background_tasks[i]
            local ready = false
            if task.type == "read" and _ffi_defs.FD_ISSET(task.watch_fd, read_fds) then
                ready = true
            elseif task.type == "write" and _ffi_defs.FD_ISSET(task.watch_fd, write_fds) then
                ready = true
            elseif task.type == nil then
                ready = true -- Immediate execution
            end

            if ready then
                local ok, type, watch_fd = coroutine.resume(task.co)
                if coroutine.status(task.co) == "dead" then
                    table.remove(background_tasks, i)
                else
                    task.type = type
                    task.watch_fd = watch_fd
                end
            end
        end
    end

    local now = os.time()
    for fd, info in pairs(clients) do
        if now - (info.created or now) > COROUTINE_TIMEOUT then
            local age = now - (info.created or now)
            io.write(string.format("[proxy] timeout: closing fd=%d age=%ds (limit=%ds)\n",
                fd, age, COROUTINE_TIMEOUT))
            local fds = conn_fds_map[fd]
            local closed_set = {}
            if fds then
                if fds.llama >= 0 then pcall(ffi.C.close, fds.llama); closed_set[fds.llama] = true; fds.llama = -1 end
                if fds.client >= 0 then pcall(ffi.C.close, fds.client); closed_set[fds.client] = true; fds.client = -1 end
            end
            if not closed_set[fd] then pcall(ffi.C.close, fd) end
            if info.watch_fd and info.watch_fd ~= fd and not closed_set[info.watch_fd] then
                pcall(ffi.C.close, info.watch_fd)
            end
            active_connection_count = math.max(0, active_connection_count - 1)
            clients[fd] = nil
            conn_fds_map[fd] = nil
        end
    end
end

print("[proxy] Shutting down...")
for fd, info in pairs(clients) do
    local fds = conn_fds_map[fd]
    local closed_set = {}
    if fds then
        if fds.llama >= 0 then pcall(ffi.C.close, fds.llama); closed_set[fds.llama] = true end
        if fds.client >= 0 then pcall(ffi.C.close, fds.client); closed_set[fds.client] = true end
    end
    if not closed_set[fd] then pcall(ffi.C.close, fd) end
    if info.watch_fd and info.watch_fd ~= fd and not closed_set[info.watch_fd] then
        pcall(ffi.C.close, info.watch_fd)
    end
end
clients = nil
conn_fds_map = nil
ffi.C.close(server_fd)
ffi.C.signal(_ffi_defs.SIGTERM, ffi.cast("sighandler_t", 0))
ffi.C.signal(_ffi_defs.SIGINT, ffi.cast("sighandler_t", 0))
shutdown_cb:free()
_G._jenova_shutdown_cb = nil
