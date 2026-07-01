local chat = {}

chat.init = function()
    -- Initialize the native C bedrock components
    if _G.bedrock_create_chat_feed then
        _G.bedrock_create_chat_feed()
        _G.bedrock_create_chat_input()
        
        -- Add initial system greeting
        _G.bedrock_create_message_bubble("assistant", "Hello! I am Jenova, your local Cognitive Architecture. How can I assist you today?")
    else
        print("Warning: Native Chat Bedrock API not found.")
    end
end

return chat
