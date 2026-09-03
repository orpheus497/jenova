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
      -- ##Step purpose: Protected require — jvim is a standalone editor; the
      -- jenova.endpoints module is only present inside the Jenova environment.
      -- Without pcall, every startup outside Jenova would error here.
      local ok, ep = pcall(require, "jenova.endpoints")
      if not ok then return end

      vim.g.llama_config = {
        endpoint_fim  = ep.fim_url(),
        endpoint_inst = ep.proxy_url(),
        -- ##Step purpose: show_info=2 displays model name and timing
        show_info     = 2,
        -- ##Step purpose: Auto-trigger FIM on typing pause (debounced by t_max_prompt_ms)
        auto_fim      = false,
        -- ##Step purpose: Token context budget — reduced from 256 to 128 to cut per-request
        -- GPU slot time on the constrained 16 GiB system (2 KV-cache slots shared with Jenova chat)
        n_prefix  = 128,
        n_suffix  = 64,
        -- ##Step purpose: Max new tokens — reduced from 128 to 64 for faster completions
        -- and lower slot pressure when Jenova chat is active concurrently.
        -- Set to 128 or higher on systems where slot contention is not a concern.
        n_predict = 64,
        -- ##Step purpose: Timing limits — 500ms typing pause before FIM fires
        t_max_prompt_ms  = 500,
        t_max_predict_ms = 1000,
      }
      -- Track FIM enabled state globally for dashboard/toggle/statusline
      vim.g.jenova_fim_enabled = false
    end,
  },
}

