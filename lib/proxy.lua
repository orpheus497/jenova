local script_dir = os.getenv("JENOVA_ROOT") or (debug.getinfo(1, "S").source:match("^@(.*/)" ) or "./")
package.path = script_dir .. "/lib/?.lua;" .. script_dir .. "/?.lua;" .. package.path

local ffi = require("ffi")
local _ffi_defs = require("ffi_defs")
local json = require("json")
local search = require("search")
local embed = require("embed")
local prompts = require("prompts")

local HOST = os.getenv("JENOVA_PROXY_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("JENOVA_PROXY_PORT")) or 8080
local LLAMA_URL = os.getenv("JENOVA_LLAMA_URL") or "http://127.0.0.1:8081"
local LLAMA_PORT = tonumber(LLAMA_URL:match(":(%d+)")) or 8081

local embed_ok, embed_err = pcall(function()
  return embed.init({ 
    script_dir = script_dir,
  })
end)
if not embed_ok then
  io.write("[proxy] WARNING: embed.init failed: " .. tostring(embed_err) .. "\n")
  embed_ok = false
else
  embed_ok = embed_err
end
if embed_ok then search.init_embeddings(embed) end
search.index_dir(".", {
  "lua","sh","c","h","cpp","py","js","ts","go","rs",
  "md","txt","json","yaml","yml","toml","conf","cfg",
  "html","css","Makefile","zig",
})

print("[proxy] Jenova Signal Proxy loaded on port " .. PORT .. ". Embeddings: " .. tostring(embed_ok))

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 0xffff
local SO_REUSEADDR = 0x0004
local SO_ERROR = 0x1007

local EAGAIN = 35
local EWOULDBLOCK = 35
local EINPROGRESS = 36

local function set_nonblocking(fd)
    ffi.C.fcntl(fd, _ffi_defs.F_SETFL, _ffi_defs.O_NONBLOCK)
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

-- Async helper: yield until readable/writable
local function async_recv(fd, buf, len)
    while true do
        local n = ffi.C.recv(fd, buf, len, 0)
        if n >= 0 then return tonumber(n) end
        local err = ffi.errno()
        if err ~= EAGAIN and err ~= EWOULDBLOCK then return -1, err end
        coroutine.yield("read", fd)
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

local function async_connect(fd, addr)
    local ret = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
    if ret == 0 then return true end
    local err = ffi.errno()
    if err ~= EINPROGRESS then return false, err end
    coroutine.yield("write", fd)
    -- After yield, check connection status
    local opt = ffi.new("int[1]")
    local len = ffi.new("socklen_t[1]", ffi.sizeof("int"))
    ffi.C.getsockopt(fd, SOL_SOCKET, SO_ERROR, opt, len)
    if opt[0] == 0 then return true else return false, opt[0] end
end

local function proxy_connection(client_fd)
    set_nonblocking(client_fd)
    local llama_fd = -1

    local function safe_close()
        if llama_fd >= 0 then pcall(ffi.C.close, llama_fd); llama_fd = -1 end
        pcall(ffi.C.close, client_fd)
    end

    local buf = ffi.new("char[8192]")
    local headers_raw = ""
    local body_raw = ""
    local content_length = 0
    local is_chunked = false
    local is_get = false

    -- Read headers
    while true do
        local n = async_recv(client_fd, buf, 8192)
        if n <= 0 then safe_close(); return end
        headers_raw = headers_raw .. ffi.string(buf, n)
        
        local header_end = headers_raw:find("\r\n\r\n")
        if header_end then
            body_raw = headers_raw:sub(header_end + 4)
            headers_raw = headers_raw:sub(1, header_end + 3)
            local cl = headers_raw:lower():match("content%-length:%s*(%d+)")
            if cl then content_length = tonumber(cl) end
            is_chunked = headers_raw:lower():find("transfer%-encoding:%s*chunked") ~= nil
            is_get = headers_raw:match("^GET ") ~= nil
            break
        end
    end

    -- Read body
    if not is_get then
        if is_chunked then
            while not body_raw:find("0\r\n\r\n$") do
                local n = async_recv(client_fd, buf, 8192)
                if n <= 0 then break end
                body_raw = body_raw .. ffi.string(buf, n)
            end
            body_raw = decode_chunked_body(body_raw)
        else
            while #body_raw < content_length do
                local n = async_recv(client_fd, buf, 8192)
                if n <= 0 then break end
                body_raw = body_raw .. ffi.string(buf, n)
            end
        end
    end

    local is_chat_completion = headers_raw:find("POST /v1/chat/completions")
    local intent = headers_raw:match("[Xx]%-Intent:%s*(%w+)")
    local proxied_req = headers_raw .. body_raw

    -- RAG INJECTION & PROMPT LOGIC
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

            if last_user_msg:match("^%s*Visual Rewrite:%s*") then
                intent = "visual"
                req_json.messages[last_user_idx].content = last_user_msg:gsub("^%s*Visual Rewrite:%s*", "")
                last_user_msg = req_json.messages[last_user_idx].content
            elseif last_user_msg:match("^%s*Chatbot:%s*") then
                intent = "chat"
                req_json.messages[last_user_idx].content = last_user_msg:gsub("^%s*Chatbot:%s*", "")
                last_user_msg = req_json.messages[last_user_idx].content
            end

            if last_user_msg ~= "" and not last_user_msg:find("--- REPOSITORY CONTEXT ---") then
                local rag_limit = (intent == "visual") and 1 or 3
                local rag = search.query(last_user_msg, rag_limit, true)
                local rag_context = ""

                if #rag > 0 then
                    local parts = { "\n--- REPOSITORY CONTEXT ---" }
                    for i, r in ipairs(rag) do
                        parts[#parts+1] = string.format("[%d] %s", i, r.path)
                        if r.snippet then parts[#parts+1] = r.snippet:sub(1, 1000) end -- Increased snippet context
                    end
                    rag_context = table.concat(parts, "\n")
                end

                if intent then
                    local system_p = prompts[intent] or prompts.chat
                    if rag_context ~= "" then system_p = system_p .. "\n" .. rag_context end
                    if intent == "visual" then
                        req_json.tools = nil
                        req_json.tool_choice = "none"
                    end
                    if req_json.messages[1].role == "system" then
                        if req_json.tools then
                            req_json.messages[1].content = system_p .. "\n\n" .. req_json.messages[1].content
                        else
                            req_json.messages[1].content = system_p
                        end
                    else
                        table.insert(req_json.messages, 1, {role = "system", content = system_p})
                    end
                elseif rag_context ~= "" then
                    if req_json.messages[1].role == "system" then
                        req_json.messages[1].content = req_json.messages[1].content .. "\n" .. rag_context
                    else
                        table.insert(req_json.messages, 1, {role = "system", content = rag_context})
                    end
                end

                local new_body = json.encode(req_json)
                local new_headers = headers_raw:gsub("([Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][Nn][Gg][Tt][Hh]:%s*)%d+", "%1" .. #new_body)
                -- If it was chunked, we convert to content-length for the backend
                new_headers = new_headers:gsub("[Tt][Rr][Aa][Nn][Ss][Ff][Ee][Rr]%-[Ee][Nn][Cc][Oo][Dd][Ii][Nn][Gg]:%s*[Cc][Hh][Uu][Nn][Kk][Ee][Dd]\r\n", "")
                if not new_headers:find("[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][Nn][Gg][Tt][Hh]:") then
                    new_headers = new_headers:gsub("\r\n\r\n", "\r\nContent-Length: " .. #new_body .. "\r\n\r\n")
                end
                proxied_req = new_headers .. new_body
                if intent then print("[proxy] Intent: " .. intent .. " | Injected intelligence (" .. #rag .. " files)") end
            end
        end
    end

    -- Connect to llama-server
    llama_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if llama_fd < 0 then
        local err_resp = "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n"
        async_send(client_fd, err_resp)
        llama_fd = -1
        safe_close()
        return
    end
    set_nonblocking(llama_fd)

    local l_addr = ffi.new("struct sockaddr_in")
    l_addr.sin_len = ffi.sizeof(l_addr)
    l_addr.sin_family = AF_INET
    l_addr.sin_port = ffi.C.htons(LLAMA_PORT)
    l_addr.sin_addr.s_addr = ffi.C.inet_addr(HOST)

    local connected, err = async_connect(llama_fd, l_addr)
    if not connected then
        print("[proxy] ERROR: C++ llama-server backend is down on port " .. LLAMA_PORT .. " (err: " .. tostring(err) .. ")")
        local err_resp = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"
        async_send(client_fd, err_resp)
        safe_close()
        return
    end

    -- Forward request
    async_send(llama_fd, proxied_req)

    -- Backward response
    while true do
        local n = async_recv(llama_fd, buf, 8192)
        if n <= 0 then break end
        local to_send = ffi.string(buf, n)
        if async_send(client_fd, to_send) < 0 then break end
    end

    safe_close()
end

-- Server Setup
ffi.C.signal(_ffi_defs.SIGPIPE, _ffi_defs.SIG_IGN)

local server_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
if server_fd < 0 then
    print("[proxy] Failed to create socket")
    os.exit(1)
end

local opt = ffi.new("int[1]", 1)
ffi.C.setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, opt, ffi.sizeof("int"))
set_nonblocking(server_fd)

local addr = ffi.new("struct sockaddr_in")
addr.sin_len = ffi.sizeof(addr)
addr.sin_family = AF_INET
addr.sin_port = ffi.C.htons(PORT)
addr.sin_addr.s_addr = ffi.C.inet_addr(HOST)

if ffi.C.bind(server_fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) < 0 then
    print("[proxy] Failed to bind to " .. HOST .. ":" .. PORT)
    os.exit(1)
end

if ffi.C.listen(server_fd, 100) < 0 then
    print("[proxy] Failed to listen")
    os.exit(1)
end

-- Main Select Loop
local clients = {} -- fd -> {co = co, type = "read"|"write", watch_fd = fd, created = time}
local COROUTINE_TIMEOUT = 600
local read_fds = _ffi_defs.fd_set_new()
local write_fds = _ffi_defs.fd_set_new()

local running = true
local function shutdown_handler()
    running = false
end
local shutdown_cb = ffi.cast("sighandler_t", shutdown_handler)
ffi.C.signal(_ffi_defs.SIGTERM, shutdown_cb)
ffi.C.signal(_ffi_defs.SIGINT, shutdown_cb)

while running do
    _ffi_defs.FD_ZERO(read_fds)
    _ffi_defs.FD_ZERO(write_fds)
    _ffi_defs.FD_SET(server_fd, read_fds)
    
    local max_fd = server_fd
    for fd, info in pairs(clients) do
        if info.type == "read" then
            _ffi_defs.FD_SET(info.watch_fd, read_fds)
        elseif info.type == "write" then
            _ffi_defs.FD_SET(info.watch_fd, write_fds)
        end
        if info.watch_fd > max_fd then max_fd = info.watch_fd end
    end

    local tv = ffi.new("struct timeval", {tv_sec=1, tv_usec=0}) -- 1s timeout for safety
    local n = ffi.C.select(max_fd + 1, read_fds, write_fds, nil, tv)

    if n > 0 then
        if _ffi_defs.FD_ISSET(server_fd, read_fds) then
            local client_addr = ffi.new("struct sockaddr_in")
            local addrlen = ffi.new("socklen_t[1]", ffi.sizeof(client_addr))
            local client_fd = ffi.C.accept(server_fd, ffi.cast("struct sockaddr *", client_addr), addrlen)
            if client_fd >= 0 then
                local co = coroutine.create(function()
                    local ok, err = pcall(proxy_connection, client_fd)
                    if not ok then
                        io.write("[proxy] connection error: " .. tostring(err) .. "\n")
                        ffi.C.close(client_fd)
                    end
                end)
                local _ok, type, watch_fd = coroutine.resume(co)
                if coroutine.status(co) ~= "dead" then
                    clients[client_fd] = {co = co, type = type, watch_fd = watch_fd, created = os.time()}
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
                else
                    info.type = type
                    info.watch_fd = watch_fd
                end
            end
        end
    end

    -- Sweep stale coroutines that exceeded timeout
    local now = os.time()
    for fd, info in pairs(clients) do
        if now - (info.created or now) > COROUTINE_TIMEOUT then
            pcall(ffi.C.close, fd)
            if info.watch_fd and info.watch_fd ~= fd then
                pcall(ffi.C.close, info.watch_fd)
            end
            clients[fd] = nil
        end
    end
end

print("[proxy] Shutting down...")
for fd, info in pairs(clients) do
    pcall(ffi.C.close, fd)
    if info.watch_fd and info.watch_fd ~= fd then
        pcall(ffi.C.close, info.watch_fd)
    end
end
ffi.C.close(server_fd)
shutdown_cb:free()
