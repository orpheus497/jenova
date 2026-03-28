-- ##Script function and purpose: Configures gp.nvim AI chat integration with the
-- Jenova backend (llama.cpp via proxy). All keybinds use the <leader>a* namespace
-- (AI) to avoid collisions with <leader>g* (git) and <leader>c* (code/LSP).
-- FIX B3-B5: All keybinds moved from <leader>g* to <leader>a*.
-- FIX F2: Fresh-context chat deletion uses vim.fn.delete() instead of os.execute rm -rf.

return {
  {
    "robitx/gp.nvim",
    -- ##Step purpose: Load after UI so noice and notify are already registered
    event = "VeryLazy",
    config = function()
      -- ##Function purpose: Generate keymap options table with a consistent description prefix
      local function opts(desc)
        return { noremap = true, silent = true, nowait = true, desc = "GP: " .. desc }
      end

      -- ##Action purpose: Read proxy host/port from environment (set by jvim) or defaults.
      -- JENOVA_CONNECT_HOST takes priority over JENOVA_HOST; wildcard binds
      -- (0.0.0.0 / :: / *) are mapped to 127.0.0.1 for client connect.
      local jenova_host = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
      if jenova_host == "0.0.0.0" or jenova_host == "::" or jenova_host == "*" then
        jenova_host = "127.0.0.1"
      end
      local jenova_port = vim.env.JENOVA_PORT or "8080"
      local endpoint_url = string.format("http://%s:%s/v1/chat/completions", jenova_host, jenova_port)

      -- ##Action purpose: Warn if JENOVA_CONNECT_HOST/JENOVA_ROOT not set (user launched nvim directly)
      if not vim.env.JENOVA_CONNECT_HOST and not vim.env.JENOVA_ROOT then
        vim.notify(
          "⚠️  Jenova environment not detected!\n\n" ..
          "Launch Neovim using 'bin/jvim' instead of 'nvim' directly.\n" ..
          "Without the jvim wrapper, plugins cannot connect to the local backend.",
          vim.log.levels.WARN,
          { title = "Jenova Setup Warning" }
        )
      end

      -- ##Step purpose: Core gp.nvim setup — point at local Jenova backend
      require("gp").setup({
        -- ##Action purpose: Configure providers - new gp.nvim format
        providers = {
          openai = {
            endpoint = endpoint_url,
            secret = "jenova-local",
          },
        },

        agents = {
          {
            name = "Jenova",
            provider = "openai",
            chat = true,
            command = true,
            model = { model = "jenova", temperature = 0.7, top_p = 0.9 },
            system_prompt = "You are Jenova, an expert coding assistant running fully locally on FreeBSD. "
              .. "Prefer concise, correct answers. Use shell, Lua, and C idioms appropriate for FreeBSD.",
          },
        },

        -- ##Step purpose: Store chat files inside Neovim state dir to keep home clean
        chat_dir = vim.fn.stdpath("state") .. "/gp/chats",

        -- ##Step purpose: Open chat in a vertical split by default
        chat_window = { style = "vsplit", width = 60 },

        hooks = {
          -- ##Action purpose: Visual rewrite hook — constrained, surgical edits only
          -- Sends "Visual Rewrite:" prefix to signal visual intent to proxy
          VisualRewrite = function(gp, params)
            local agent = gp.get_command_agent()
            -- Prepend visual marker so proxy applies surgical constraints
            local template = "Visual Rewrite: {{selection}}"
            gp.Prompt(params, gp.Target.rewrite, agent, template, nil)
          end,

          -- ##Action purpose: Chat with full buffer context
          -- Opens chat with entire current buffer as context so AI understands the file
          ChatWithContext = function(gp, params)
            local agent = gp.get_chat_agent()
            -- Get current buffer content
            local buf = vim.api.nvim_get_current_buf()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local filename = vim.fn.expand("%:t")
            local filepath = vim.fn.expand("%:p")
            local content = table.concat(lines, "\n")

            -- Create context message with file info as system prompt
            local chat_system_prompt = string.format(
              "Chatbot: I'm working on file: %s\nPath: %s\n\n```\n%s\n```\n\nQuestion: ",
              filename,
              filepath,
              content
            )

            -- Open chat with buffer context using new signature: (params, system_prompt, agent)
            gp.cmd.ChatNew(params, chat_system_prompt, agent)
          end,
        },
      })

      -- -----------------------------------------------------------------------
      -- Keybinds — <leader>a* (AI namespace)
      -- -----------------------------------------------------------------------

      -- ##Step purpose: Visual-mode: open chat with selected text as context
      vim.keymap.set("v", "<leader>ae", ":<C-u>'<,'>GpChatNew vsplit<CR>", opts("Visual Chat"))

      -- ##Step purpose: Normal-mode: open chat with full buffer context
      vim.keymap.set("n", "<leader>ac", "<cmd>GpChatWithContext<CR>", opts("Chat with Buffer Context"))

      -- ##Step purpose: Normal-mode: open new chat with empty/fresh context
      -- FIX F2: Use vim.fn.delete() to wipe stale chats — avoids os.execute rm -rf
      vim.keymap.set("n", "<leader>aF", function()
        local chat_dir = vim.fn.stdpath("state") .. "/gp/chats"
        -- ##Condition purpose: Only attempt deletion if the directory actually exists
        if vim.fn.isdirectory(chat_dir) == 1 then
          vim.fn.delete(chat_dir, "rf")
          vim.fn.mkdir(chat_dir, "p")
        end
        vim.cmd("GpChatNew vsplit")
      end, opts("New Chat (Fresh Context)"))

      -- ##Step purpose: Toggle the most-recent chat window open/closed
      vim.keymap.set("n", "<leader>at", "<cmd>GpChatToggle vsplit<CR>", opts("Toggle Chat"))

      -- ##Step purpose: Trigger AI response in an open chat buffer
      vim.keymap.set("n", "<leader>ar", "<cmd>GpChatRespond<CR>", opts("Chat Respond"))

      -- ##Step purpose: Delete the current chat file from disk
      vim.keymap.set("n", "<leader>ad", "<cmd>GpChatDelete<CR>", opts("Delete Chat"))

      -- ##Step purpose: Visual-mode: surgical rewrite (constrained to selection only)
      vim.keymap.set("v", "<leader>aw", ":<C-u>'<,'>GpVisualRewrite<CR>", opts("Visual Rewrite (Surgical)"))

      -- ##Step purpose: Normal-mode: inline rewrite via InlineRewrite hook
      vim.keymap.set("n", "<leader>ai", "<cmd>GpInlineRewrite<CR>", opts("Inline Rewrite"))
    end,
  },
}
