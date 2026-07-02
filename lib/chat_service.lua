local json = require("json")
local database = require("services.database")
local workspace = require("services.workspace")

local chat_service = {}

function chat_service.sendMessage(text, msg_id, conv_id, store, on_chunk, on_reasoning_chunk, on_complete)
    store.setLoading(msg_id, true)
    
    local messages = database.load_conversation(conv_id)
    table.insert(messages, { role = "user", content = text })
    
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
    local shell_payload = payload_json:gsub("'", "'\\''")
    local cmd = "curl -N -s --connect-timeout 2 -X POST http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '" .. shell_payload .. "'"
    
    local buffer = ""
    local has_received_data = false
    local assistant_reply = ""
    local is_thinking = false
    local is_finished = false
    
    sys_exec_stream(cmd, function(chunk)
        if is_finished then return end
        
        if not chunk then
            is_finished = true
            if not has_received_data then
                store.setError(msg_id, "Connection Refused: Ensure Jenova Server is running (Port 8080).")
            else
                store.isStreamingActive = false
                table.insert(messages, { role = "assistant", content = assistant_reply })
                database.save_conversation(conv_id, messages)
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
                if data:match("%[DONE%]") then
                    is_finished = true
                    store.isStreamingActive = false
                    table.insert(messages, { role = "assistant", content = assistant_reply })
                    database.save_conversation(conv_id, messages)
                    if on_complete then on_complete() end
                else
                    local ok, parsed = pcall(json.decode, data)
                    if ok and parsed and parsed.choices and parsed.choices[1] and parsed.choices[1].delta then
                        local content = parsed.choices[1].delta.content or ""
                        local reasoning = parsed.choices[1].delta.reasoning_content or ""
                        
                        if reasoning ~= "" then
                            on_reasoning_chunk(reasoning)
                        else
                            -- Fallback parsing if model outputs <think> inline
                            if content:match("<think>") then is_thinking = true; content = content:gsub("<think>", "") end
                            if content:match("</think>") then is_thinking = false; content = content:gsub("</think>", "") end
                            
                            if is_thinking then
                                on_reasoning_chunk(content)
                            else
                                assistant_reply = assistant_reply .. content
                                on_chunk(content)
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
