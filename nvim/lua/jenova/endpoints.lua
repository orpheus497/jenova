local M = {}

function M.host()
  local h = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
  if h == "0.0.0.0" or h == "::" or h == "*" then
    return "127.0.0.1"
  end
  return h
end

function M.proxy_port()
  return tonumber(vim.env.JENOVA_PORT) or 8080
end

function M.llama_port()
  return tonumber(vim.env.JENOVA_LLAMA_PORT) or 8081
end

function M.embed_port()
  return tonumber(vim.env.JENOVA_LLAMA_EMBED_PORT or vim.env.LLAMA_EMBED_PORT) or 8082
end

function M.proxy_url()
  return M.url(M.proxy_port(), "/v1/chat/completions")
end

function M.fim_url()
  if M.is_lan_mode() then
    return M.url(M.proxy_port(), "/infill")
  end
  return M.url(M.llama_port(), "/infill")
end

function M.llama_api_port()
  if M.is_lan_mode() then return M.proxy_port() end
  return M.llama_port()
end

function M.embed_url()
  -- Always use embed_port directly — the proxy does not multiplex
  -- embedding requests to the separate embedding server
  return M.url(M.embed_port(), "/v1/embeddings")
end

function M.url(port, path)
  local h = M.host()
  if h:find(":", 1, true) and not h:match("^%[.*%]$") then
    h = string.format("[%s]", h)
  end
  return string.format("http://%s:%d%s", h, port, path)
end

function M.all()
  return {
    host = M.host(),
    proxy_port = M.proxy_port(),
    llama_port = M.llama_port(),
    embed_port = M.embed_port(),
  }
end

function M.is_lan_mode()
  return vim.env.JENOVA_LAN_MODE == "1"
end

function M.has_jvim_env()
  local r = vim.env.JENOVA_ROOT
  return r ~= nil and r ~= "" and r ~= "$JENOVA_ROOT"
end

function M.reconfigure_plugins()
  local fim_url = M.fim_url()
  local proxy_url = M.proxy_url()

  local cfg = vim.g.llama_config
  if cfg then
    cfg.endpoint_fim = fim_url
    cfg.endpoint_inst = proxy_url
    vim.g.llama_config = cfg
  end

  package.loaded["jenova.endpoints"] = nil
  package.loaded["jenova.endpoints"] = M

  vim.g.jenova_connected = true
end

return M
