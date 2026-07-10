local json = require("json")
local database = require("services.database")
local workspace = require("services.workspace")

local chat_service = {}

function chat_service.sendMessage(text, msg_id, conv_id, chat_path, store, on_chunk, on_reasoning_chunk, on_complete)
    store.setLoading(msg_id, true)
    
    local messages = database.load_conversation_from_path(chat_path)
    table.insert(messages, { role = "user", content = text })
    database.save_conversation_to_path(chat_path, conv_id, messages)
    
    local context = workspace.get_workspace_context()
    local system_prompt = workspace.INITIAL_IDENTITY
    if context ~= "" then
        system_prompt = system_prompt .. "\n\n[CURRENT WORKSPACE ARTIFACTS]:\n" .. context
    end
    
    local api_messages = { { role = "system", content = system_prompt } }
    for _, msg in ipairs(messages) do
        api_messages[#api_messages + 1] = { role = msg.role, content = msg.content }
    end
    
    local payload_obj = { messages = api_messages, stream = true }
    local payload_json = json.encode(payload_obj)
    local port = tonumber(os.getenv("JENOVA_PROXY_PORT") or os.getenv("JENOVA_PORT")) or 8080
    local p = io.popen("mktemp /tmp/jenova_payload.XXXXXX 2>/dev/null")
    local tmp_file = p and p:read("*l")
    if p then p:close() end
    if not tmp_file or tmp_file == "" then
        store.setLoading(msg_id, false)
        store.setError(msg_id, "Failed to create payload file")
        if on_complete then on_complete() end
        return
    end
    local f = io.open(tmp_file, "w")
    if not f then
        os.remove(tmp_file)
        store.setLoading(msg_id, false)
        store.setError(msg_id, "Failed to write payload file")
        if on_complete then on_complete() end
        return
    end
    f:write(payload_json)
    f:close()
    local cmd = "curl -N -s --connect-timeout 2 --max-time 3600 -X POST http://127.0.0.1:" .. port .. "/v1/chat/completions -H 'Content-Type: application/json' -H 'Origin: app://jenova' -d @" .. tmp_file
    
    local buffer = ""
    local has_received_data = false
    local assistant_reply = ""
    local is_thinking = false
    local is_finished = false
    local think_buffer = ""
    
    sys_exec_stream(cmd, function(chunk)
        if is_finished then return end
        
        if not chunk then
            if not is_finished then
                if think_buffer ~= "" then
                    if is_thinking then on_reasoning_chunk(think_buffer)
                    else 
                        assistant_reply = assistant_reply .. think_buffer
                        on_chunk(think_buffer) 
                    end
                    think_buffer = ""
                end
                is_finished = true
                os.remove(tmp_file)
                if not has_received_data then
                    store.setLoading(msg_id, false)
                    store.setError(msg_id, "Connection Refused: Ensure Jenova Server is running (Port " .. port .. ").")
                else
                    store.isStreamingActive = false
                    store.setError(msg_id, "Stream disconnected unexpectedly before completion.")
                end
                if on_complete then on_complete() end
            end
            return
        end
        
        if not has_received_data and #chunk > 0 then
            has_received_data = true
            store.setLoading(msg_id, false)
            store.isStreamingActive = true
        end
        
        buffer = buffer .. chunk
        while true do
            local line_end = buffer:find("\n")
            if not line_end then break end
            
            local line = buffer:sub(1, line_end - 1)
            buffer = buffer:sub(line_end + 1)
            
            if line:byte(-1) == 13 then line = line:sub(1, -2) end
            
            if line:match("^data: ") then
                local data = line:sub(7)
                if data == "[DONE]" then
                    if think_buffer ~= "" then
                        if is_thinking then on_reasoning_chunk(think_buffer)
                        else 
                            assistant_reply = assistant_reply .. think_buffer
                            on_chunk(think_buffer) 
                        end
                        think_buffer = ""
                    end
                    is_finished = true
                    os.remove(tmp_file)
                    store.isStreamingActive = false
                    table.insert(messages, { role = "assistant", content = assistant_reply })
                    database.save_conversation_to_path(chat_path, conv_id, messages)
                    if on_complete then on_complete() end
                else
                    local ok, parsed = pcall(json.decode, data)
                    if ok and type(parsed) == "table" then
                        if parsed.error then
                            is_finished = true
                            os.remove(tmp_file)
                            store.isStreamingActive = false
                            local err_msg = type(parsed.error) == "string" and parsed.error or (parsed.error.message or json.encode(parsed.error))
                            store.setError(msg_id, "API Error: " .. err_msg)
                            if on_complete then on_complete() end
                        elseif parsed.choices and parsed.choices[1] and parsed.choices[1].delta then
                            local content = parsed.choices[1].delta.content or ""
                            local reasoning = parsed.choices[1].delta.reasoning_content or ""
                            
                            if reasoning ~= "" then
                                on_reasoning_chunk(reasoning)
                            else
                                local content_to_process = think_buffer .. content
                                think_buffer = ""
                                local i = 1
                                while i <= #content_to_process do
                                    if not is_thinking then
                                        local start_idx = content_to_process:find("<think>", i, true)
                                        if start_idx then
                                            local text = content_to_process:sub(i, start_idx - 1)
                                            if text ~= "" then
                                                assistant_reply = assistant_reply .. text
                                                on_chunk(text)
                                            end
                                            is_thinking = true
                                            i = start_idx + 7
                                        else
                                            local text = content_to_process:sub(i)
                                            for p = 1, 6 do
                                                if text:sub(-p) == ("<think>"):sub(1, p) then
                                                    think_buffer = text:sub(-p)
                                                    text = text:sub(1, -(p + 1))
                                                    break
                                                end
                                            end
                                            if text ~= "" then
                                                assistant_reply = assistant_reply .. text
                                                on_chunk(text)
                                            end
                                            break
                                        end
                                    else
                                        local end_idx = content_to_process:find("</think>", i, true)
                                        if end_idx then
                                            local text = content_to_process:sub(i, end_idx - 1)
                                            if text ~= "" then
                                                on_reasoning_chunk(text)
                                            end
                                            is_thinking = false
                                            i = end_idx + 8
                                        else
                                            local text = content_to_process:sub(i)
                                            for p = 1, 7 do
                                                if text:sub(-p) == ("</think>"):sub(1, p) then
                                                    think_buffer = text:sub(-p)
                                                    text = text:sub(1, -(p + 1))
                                                    break
                                                end
                                            end
                                            if text ~= "" then
                                                on_reasoning_chunk(text)
                                            end
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            elseif line:match('"error"') then
                store.setError(msg_id, "API Error: " .. line)
            end
        end
    end)
end

return chat_service
