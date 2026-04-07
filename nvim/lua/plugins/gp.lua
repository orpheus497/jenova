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
      if not vim.env.JENOVA_CONNECT_HOST and not vim.env.JENOVA_ROOT and vim.env.JENOVA_LAN_MODE ~= "1" then
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
          -- ##Action purpose: Inline rewrite hook — streams replacement in-place
          InlineRewrite = function(gp, params)
            local agent = gp.get_command_agent()
            gp.Prompt(params, gp.Target.rewrite, agent, nil, nil)
          end,

          -- ##Action purpose: Visual rewrite hook — prompts user for instruction after
          -- selecting text, then rewrites the selection based on user input.
          -- Previously auto-sent a fixed template which caused the model to rewrite
          -- without knowing the user's intent. Now the user provides direction.
          -- The "Visual Rewrite:" prefix is preserved so the proxy detects intent
          -- (lib/proxy.lua:259 matches ^Visual Rewrite: to set RAG limit=1 and
          -- disable tools for surgical edits).
          VisualRewrite = function(gp, params)
            local agent = gp.get_command_agent()
            local ft = vim.bo.filetype or ""
            local template = string.format(
              "Visual Rewrite: {{command}}\n\nI have the following code:\n```%s\n{{selection}}\n```", ft)
            gp.Prompt(params, gp.Target.rewrite, agent, template, "Rewrite instruction: ")
          end,

          -- ##Action purpose: Web search hook — prompts user for a query, opens a chat
          -- with "Web Search:" prefix, and auto-sends. The proxy detects the prefix,
          -- fetches DuckDuckGo results, and injects them for the model to synthesize.
          WebSearch = function(gp, params)
            vim.ui.input({ prompt = "Web search: " }, function(query)
              if not query or query == "" then return end
              local agent = gp.get_chat_agent()
              gp.cmd.ChatNew(params, nil, agent)

              vim.defer_fn(function()
                local chat_buf = vim.api.nvim_get_current_buf()
                if not vim.api.nvim_buf_is_valid(chat_buf) then return end

                local chat_lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
                local user_prefix = require("gp").config.chat_user_prefix or "💬:"

                local insert_after = -1
                for i, line in ipairs(chat_lines) do
                  if line:sub(1, #user_prefix) == user_prefix then
                    insert_after = i
                  end
                end

                if insert_after < 0 then return end

                vim.api.nvim_buf_set_lines(chat_buf, insert_after, insert_after, false,
                  { "Web Search: " .. query })

                vim.defer_fn(function()
                  vim.cmd("GpChatRespond")
                end, 50)
              end, 50)
            end)
          end,

          ChatWithContext = function(gp, params)
            local agent = gp.get_chat_agent()
            local buf = vim.api.nvim_get_current_buf()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local filename = vim.fn.expand("%:t")
            local filepath = vim.fn.expand("%:p")
            local content = table.concat(lines, "\n")

            local context_msg = string.format(
              "Chatbot: I'm working on file: %s\nPath: %s\n\n```\n%s\n```\n\nPlease review this file and help me with it.",
              filename,
              filepath,
              content
            )

            gp.cmd.ChatNew(params, nil, agent)

            vim.defer_fn(function()
              local chat_buf = vim.api.nvim_get_current_buf()
              if not vim.api.nvim_buf_is_valid(chat_buf) then return end

              local chat_lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
              local user_prefix = require("gp").config.chat_user_prefix or "💬:"

              local insert_after = -1
              for i, line in ipairs(chat_lines) do
                if line:sub(1, #user_prefix) == user_prefix then
                  insert_after = i
                end
              end

              if insert_after < 0 then return end

              local context_lines = vim.split(context_msg, "\n")
              vim.api.nvim_buf_set_lines(chat_buf, insert_after, insert_after, false, context_lines)

              local total = vim.api.nvim_buf_line_count(chat_buf)
              vim.api.nvim_win_set_cursor(0, { total, 0 })
            end, 50)
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

      -- ##Step purpose: Visual-mode: rewrite selection with user-provided instruction
      vim.keymap.set("v", "<leader>aw", ":<C-u>'<,'>GpVisualRewrite<CR>", opts("Visual Rewrite (Prompted)"))

      -- ##Step purpose: Normal-mode: web search — prompts for query, synthesizes from results
      vim.keymap.set("n", "<leader>as", "<cmd>GpWebSearch<CR>", opts("Web Search"))

      -- ##Step purpose: Normal-mode: inline rewrite via InlineRewrite hook
      vim.keymap.set("n", "<leader>ai", "<cmd>GpInlineRewrite<CR>", opts("Inline Rewrite"))
    end,
  },
}
