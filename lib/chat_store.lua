local chat_store = {
    isLoading = false,
    isStreamingActive = false,
    currentResponse = "",
    errorDialogState = nil
}

function chat_store.setLoading(msg_id, is_loading)
    chat_store.isLoading = is_loading
    if _G.bedrock_set_message_loading then
        _G.bedrock_set_message_loading(msg_id, is_loading)
    end
end

function chat_store.setError(msg_id, err_text)
    chat_store.errorDialogState = err_text
    chat_store.isLoading = false
    chat_store.isStreamingActive = false
    if _G.bedrock_show_error then
        _G.bedrock_show_error(msg_id, err_text)
    end
    if _G.bedrock_set_message_loading then
        _G.bedrock_set_message_loading(msg_id, false)
    end
end

return chat_store
