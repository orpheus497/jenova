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
        auto_fim      = true,
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
      vim.g.jenova_fim_enabled = true
    end,
    -- ##Step purpose: Warn the user — but only once a real UI is attached and
    -- only when the plugin actually loads on InsertEnter — that no Jenova
    -- endpoint is reachable. Running this from `init` (eager) instead spammed
    -- every headless / scripted / `:Lazy load all` invocation.
    config = function()
      if #vim.api.nvim_list_uis() == 0 then
        return
      end
      -- ##Step purpose: Protected require for the same reason as in `init` —
      -- jenova.endpoints is optional and absent in standalone installs.
      local ok, ep = pcall(require, "jenova.endpoints")
      if not ok then return end
      if vim.env.JENOVA_CONNECT_HOST or ep.has_jvim_env() or ep.is_lan_mode() then
        return
      end
      -- ##Step purpose: When no Jenova environment is detected, disable auto_fim
      -- to prevent the constant FIM failure notifications that spam the user.
      -- The user can re-enable via SPC a f or the dashboard [A] toggle.
      local cfg = vim.g.llama_config
      if cfg then
        cfg.auto_fim = false
        vim.g.llama_config = cfg
        vim.g.jenova_fim_enabled = false
        pcall(function() vim.fn["llama#setup_autocmds"]() end)
      end
      vim.notify(
        "Jenova environment not detected — FIM autocomplete disabled.\n" ..
        "Launch via 'jvim' or set JENOVA_CONNECT_HOST for LAN mode.\n" ..
        "Re-enable with SPC a f or dashboard [A] toggle.",
        vim.log.levels.WARN,
        { title = "Jenova" }
      )
    end,
  },
}

