#!/usr/bin/env luajit
local _dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _dir .. "?.lua;" .. package.path

local http = require("http")
local json = require("json")

local function spinner_start(msg) io.write("\27[36m" .. msg .. "...\27[0m"); io.flush() end
local function spinner_stop() io.write("\r\27[K"); io.flush() end

local API_URL = os.getenv("CODER_API_URL") or "http://127.0.0.1:8080/v1/chat/completions"
local SYS_PROMPT = os.getenv("CODER_SYSTEM_PROMPT") or "You are an expert coder."

local messages = {
    { role = "system", content = SYS_PROMPT }
}

print("\n\27[1;34m=== Coder Chat (Intelligence Proxy Connected) ===\27[0m")
print("\27[90mType /quit or /clear to manage the session.\27[0m\n")

while true do
    io.write("\27[1;32m>\27[0m ")
    io.flush()
    local input = io.read("*l")
    if not input then break end
    input = input:match("^%s*(.-)%s*$")
    
    if input == "/quit" or input == "/exit" or input == "/q" then
        break
    elseif input == "/clear" then
        messages = { { role = "system", content = SYS_PROMPT } }
        print("\n\27[33m[Session cleared]\27[0m\n")
        goto continue
    elseif input == "" then
        goto continue
    end

    table.insert(messages, { role = "user", content = input })

    local payload = {
        model = "qwen2.5-coder",
        messages = messages,
        temperature = 0.6,
        max_tokens = 4096,
        stream = false
    }

    local body = json.encode(payload)
    
    spinner_start("Thinking")
    local status, resp = http.post(API_URL, body, 600)
    spinner_stop()

    if status == 200 then
        local ok, data = pcall(json.decode, resp)
        if ok and data.choices and data.choices[1].message then
            local reply = data.choices[1].message.content or ""
            table.insert(messages, { role = "assistant", content = reply })
            print("\n\27[36mcoder:\27[0m\n" .. reply .. "\n")
        else
            local safe_body = (resp or ""):gsub("\n", " "):gsub("[%c]", ""):sub(1, 200)
            if #(resp or "") > 200 then safe_body = safe_body .. "..." end
            print("\n\27[31m[error]\27[0m Failed to parse response data. Preview: " .. safe_body .. "\n")
        end
    else
        local safe_body = (resp or ""):gsub("\n", " "):gsub("[%c]", ""):sub(1, 200)
        if #(resp or "") > 200 then safe_body = safe_body .. "..." end
        print("\n\27[31m[error]\27[0m Server returned HTTP " .. tostring(status) .. ". Preview: " .. safe_body .. "\n")
    end

    ::continue::
end
print("\nGoodbye.\n")
