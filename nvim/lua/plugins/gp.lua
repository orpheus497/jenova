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

      -- ##Step purpose: Core gp.nvim setup — point at local Jenova backend
      require("gp").setup({
        -- ##Action purpose: Use the Jenova LuaJIT proxy as the OpenAI-compatible endpoint
        openai_api_key = "jenova-local",
        openai_api_endpoint = "http://127.0.0.1:8080/v1/chat/completions",

        agents = {
          {
            name = "Jenova",
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
          -- ##Action purpose: Inline code rewrite hook — streams replacement in-place
          InlineRewrite = function(gp, params)
            local agent = gp.get_command_agent()
            gp.Prompt(params, gp.Target.rewrite, agent, nil, nil)
          end,
        },
      })

      -- -----------------------------------------------------------------------
      -- Keybinds — <leader>a* (AI namespace)
      -- -----------------------------------------------------------------------

      -- ##Step purpose: Visual-mode: open chat with selected text as context
      vim.keymap.set("v", "<leader>ae", ":<C-u>'<,'>GpChatNew vsplit<CR>", opts("Visual Chat"))

      -- ##Step purpose: Normal-mode: open new chat with empty/fresh context
      -- FIX F2: Use vim.fn.delete() to wipe stale chats — avoids os.execute rm -rf
      vim.keymap.set("n", "<leader>ac", function()
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

      -- ##Step purpose: Visual-mode: rewrite the selected text via AI inline
      vim.keymap.set("v", "<leader>aw", ":<C-u>'<,'>GpRewrite<CR>", opts("Visual Rewrite"))

      -- ##Step purpose: Normal-mode: inline rewrite via InlineRewrite hook
      vim.keymap.set("n", "<leader>ai", "<cmd>GpInlineRewrite<CR>", opts("Inline Rewrite"))
    end,
  },
}
