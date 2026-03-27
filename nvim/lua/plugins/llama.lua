-- ##Script function and purpose: Configures llama.vim for FIM (fill-in-the-middle)
-- inline completions, pointing at the Jenova llama-server backend on the infill port.

return {
  -- ##Section purpose: llama.vim — FIM completions from local llama-server
  {
    "ggml-org/llama.vim",
    -- ##Step purpose: Load on insert entry so it only activates when editing
    event = "InsertEnter",
    init = function()
      -- ##Action purpose: Point llama.vim at the Jenova infill endpoint (default http://127.0.0.1:8081)
      -- LLAMA_PORT (and optionally LLAMA_HOST) may be set in the environment; fall back to 127.0.0.1:8081 if unset
      local llama_host = vim.env.LLAMA_HOST or "127.0.0.1"
      local llama_port = vim.env.LLAMA_PORT or "8081"
      vim.g.llama_config = {
        endpoint = string.format("http://%s:%s", llama_host, llama_port),
        -- ##Step purpose: Model name as recognised by the running llama-server
        model = "",   -- empty = use whatever model the server has loaded
        -- ##Step purpose: Token budget for prefix + suffix context fed to FIM
        n_prefix = 256,
        n_suffix = 64,
        -- ##Step purpose: Max new tokens to generate per completion
        n_predict = 128,
        -- ##Step purpose: Show a ghost-text preview before accepting
        show_info = 1,
        -- ##Step purpose: Auto-accept after this many milliseconds of idle
        t_max_prompt_ms = 500,
        t_max_predict_ms = 3000,
      }
    end,
  },
}
