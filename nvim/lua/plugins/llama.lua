-- ##Script function and purpose: Configures llama.vim for FIM (fill-in-the-middle)
-- inline completions, pointing at Jenova llama-server on the infill port and the
-- intelligence proxy for instruction completions. Ports are configurable via
-- JENOVA_LLAMA_PORT and JENOVA_PORT environment variables (set by jvim).

return {
  -- ##Section purpose: llama.vim — FIM completions from local llama-server
  {
    "ggml-org/llama.vim",
    -- ##Step purpose: Load on insert so it only activates when editing
    event = "InsertEnter",
    init = function()
      -- ##Action purpose: Read ports from environment (set by jvim) or defaults.
      -- JENOVA_CONNECT_HOST takes priority over JENOVA_HOST; wildcard binds
      -- (0.0.0.0 / :: / *) are mapped to 127.0.0.1 for client connect.
      local _raw_host  = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
      local host
      if _raw_host == "0.0.0.0" or _raw_host == "::" or _raw_host == "*" then
        host = "127.0.0.1"
      else
        host = _raw_host
      end
      local fim_port   = vim.env.JENOVA_LLAMA_PORT or "8081"
      local proxy_port = vim.env.JENOVA_PORT       or "8080"

      -- ##Action purpose: Warn if JENOVA_CONNECT_HOST/JENOVA_ROOT not set (user launched nvim directly)
      if not vim.env.JENOVA_CONNECT_HOST and not vim.env.JENOVA_ROOT and vim.env.JENOVA_LAN_MODE ~= "1" then
        vim.notify(
          "⚠️  Jenova environment not detected!\n\n" ..
          "Launch Neovim using 'bin/jvim' instead of 'nvim' directly.\n" ..
          "Without the jvim wrapper, llama.vim FIM completions will not work.",
          vim.log.levels.WARN,
          { title = "Jenova Setup Warning" }
        )
      end

      vim.g.llama_config = {
        -- ##Step purpose: FIM endpoint direct to llama-server (bypasses proxy)
        endpoint_fim  = string.format("http://%s:%s/infill", host, fim_port),
        -- ##Step purpose: Instruction endpoint through Jenova proxy (RAG injection)
        endpoint_inst = string.format("http://%s:%s/v1/chat/completions", host, proxy_port),
        -- ##Step purpose: show_info=2 displays model name and timing
        show_info     = 2,
        -- ##Step purpose: Auto-trigger FIM on typing pause (debounced by t_max_prompt_ms)
        auto_fim      = true,
        -- ##Step purpose: Token context budget — reduced from 256 to 128 to cut per-request
        -- GPU slot time on the constrained 16 GiB system (2 KV-cache slots shared with gp.nvim)
        n_prefix  = 128,
        n_suffix  = 64,
        -- ##Step purpose: Max new tokens — reduced from 128 to 64 for faster completions
        -- and lower slot pressure when gp.nvim chat is active concurrently.
        -- Set to 128 or higher on systems where slot contention is not a concern.
        n_predict = 64,
        -- ##Step purpose: Timing limits — 500ms typing pause before FIM fires
        t_max_prompt_ms  = 500,
        t_max_predict_ms = 1000,
      }
    end,
  },
}
