return {
  {
    dir = vim.env.VIMRUNTIME .. "/lua/jenova",
    name = "jenova-chat",
    event = "VeryLazy",
    config = function()
      require("jenova.chat").setup()
    end,
  },
}
