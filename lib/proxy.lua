local script_dir = os.getenv("CODER_ROOT") or debug.getinfo(1, "S").source:match("^@(.*/)") and debug.getinfo(1, "S").source:match("^@(.*/)..") or "."
package.path = script_dir .. "/lib/?.lua;" .. script_dir .. "/?.lua;" .. package.path

local ffi = require("ffi")
local _ffi_defs = require("ffi_defs")
local json = require("json")
local search = require("search")
local embed = require("embed")

local HOST = os.getenv("CODER_PROXY_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("CODER_PROXY_PORT")) or 8080
local LLAMA_URL = os.getenv("CODER_LLAMA_URL") or "http://127.0.0.1:8081"
local LLAMA_PORT = tonumber(LLAMA_URL:match(":(%d+)")) or 8081
local EMBED_DEVICES = os.getenv("CODER_EMBED_DEVICES") or "Vulkan1"

local embed_ok = embed.init({ 
  script_dir = script_dir,
  devices = EMBED_DEVICES
})
if embed_ok then search.init_embeddings(embed) end
search.index_dir(".", {
  "lua","sh","c","h","cpp","py","js","ts","go","rs",
  "md","txt","json","yaml","yml","toml","conf","cfg",
  "html","css","Makefile","zig",
})

print("[proxy] Intelligence Proxy loaded on port " .. PORT .. ". Embeddings: " .. tostring(embed_ok))

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 0xffff
local SO_REUSEADDR = 0x0004
local SO_RCVTIMEO = 0x1006

local server_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
if server_fd < 0 then
    print("[proxy] Failed to create socket")
    os.exit(1)
end

local opt = ffi.new("int[1]", 1)
ffi.C.setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, opt, ffi.sizeof("int"))

local addr = ffi.new("struct sockaddr_in")
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

local function proxy_connection(client_fd)
    -- Set 5-second timeout for reading request headers
    local tv = ffi.new("struct timeval", {tv_sec=5, tv_usec=0})
    ffi.C.setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
    
    local buf = ffi.new("char[8192]")
    local headers_raw = ""
    local body_raw = ""
    local content_length = 0
    local is_get = false

    while true do
        local n = ffi.C.recv(client_fd, buf, 8192, 0)
        if n <= 0 then break end
        headers_raw = headers_raw .. ffi.string(buf, n)
        
        local header_end = headers_raw:find("\r\n\r\n")
        if header_end then
            body_raw = headers_raw:sub(header_end + 4)
            headers_raw = headers_raw:sub(1, header_end + 3)
            local cl = headers_raw:lower():match("content%-length:%s*(%d+)")
            if cl then content_length = tonumber(cl) end
            is_get = headers_raw:match("^GET ") ~= nil
            break
        end
    end

    if not is_get then
        while #body_raw < content_length do
            local n = ffi.C.recv(client_fd, buf, 8192, 0)
            if n <= 0 then break end
            body_raw = body_raw .. ffi.string(buf, n)
        end
    end

    local is_chat_completion = headers_raw:find("POST /v1/chat/completions")
    local proxied_req = headers_raw .. body_raw

    -- RAG INJECTION LOGIC
    if is_chat_completion and #body_raw > 0 then
        local ok, req_json = pcall(json.decode, body_raw)
        if ok and req_json and req_json.messages then
            local last_user_msg = ""
            for i = #req_json.messages, 1, -1 do
                if req_json.messages[i].role == "user" then
                    last_user_msg = req_json.messages[i].content or ""
                    break
                end
            end

            -- Automatically pull codebase context, bypassing if 'no_rag' is explicitly passed or already contains context
            if last_user_msg ~= "" and not last_user_msg:find("--- REPOSITORY CONTEXT ---") then
                local rag = search.query(last_user_msg, 3, true)
                if #rag > 0 then
                    local parts = { "\n--- REPOSITORY CONTEXT ---" }
                    for i, r in ipairs(rag) do
                        parts[#parts+1] = string.format("[%d] %s", i, r.path)
                        if r.snippet then parts[#parts+1] = r.snippet:sub(1, 500) end
                    end
                    local rag_context = table.concat(parts, "\n")
                    
                    if req_json.messages[1].role == "system" then
                        req_json.messages[1].content = req_json.messages[1].content .. "\n" .. rag_context
                    else
                        table.insert(req_json.messages, 1, {role = "system", content = rag_context})
                    end

                    local new_body = json.encode(req_json)
                    -- Case-insensitive replacement of Content-Length
                    local new_headers = headers_raw:gsub("([Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][Nn][Gg][Tt][Hh]:%s*)%d+", "%1" .. #new_body)
                    proxied_req = new_headers .. new_body
                    print("[proxy] Injected intelligence context (" .. #rag .. " files)")
                end
            end
        end
    end

    -- Connect to raw C++ backend
    local llama_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    local l_addr = ffi.new("struct sockaddr_in")
    l_addr.sin_family = AF_INET
    l_addr.sin_port = ffi.C.htons(LLAMA_PORT)
    l_addr.sin_addr.s_addr = ffi.C.inet_addr(HOST)

    if ffi.C.connect(llama_fd, ffi.cast("struct sockaddr *", l_addr), ffi.sizeof(l_addr)) < 0 then
        print("[proxy] ERROR: C++ llama-server backend is down on port " .. LLAMA_PORT)
        local err_resp = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"
        ffi.C.send(client_fd, err_resp, #err_resp, 0)
        ffi.C.close(client_fd)
        return
    end

    -- Stream request forward
    local sent = 0
    while sent < #proxied_req do
        local n = ffi.C.send(llama_fd, proxied_req:sub(sent + 1), #proxied_req - sent, 0)
        if n <= 0 then break end
        sent = sent + tonumber(n)
    end

    -- Disable timeout for the response stream (generations can take a while)
    local tv_zero = ffi.new("struct timeval", {tv_sec=0, tv_usec=0})
    ffi.C.setsockopt(llama_fd, SOL_SOCKET, SO_RCVTIMEO, tv_zero, ffi.sizeof(tv_zero))
    
    -- Stream response backward to client (Nvim / terminal)
    while true do
        local n = ffi.C.recv(llama_fd, buf, 8192, 0)
        if n <= 0 then break end
        
        local c_sent = 0
        local to_send = ffi.string(buf, n)
        while c_sent < #to_send do
            local sn = ffi.C.send(client_fd, to_send:sub(c_sent + 1), #to_send - c_sent, 0)
            if sn <= 0 then break end
            c_sent = c_sent + tonumber(sn)
        end
    end

    ffi.C.close(llama_fd)
    ffi.C.close(client_fd)
end

-- Accept loop
while true do
    local client_addr = ffi.new("struct sockaddr_in")
    local addrlen = ffi.new("socklen_t[1]", ffi.sizeof(client_addr))
    local client_fd = ffi.C.accept(server_fd, ffi.cast("struct sockaddr *", client_addr), addrlen)
    
    if client_fd >= 0 then
        proxy_connection(client_fd)
    end
end
