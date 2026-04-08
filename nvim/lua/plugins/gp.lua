return {
  {
    dir = vim.fn.stdpath("config") .. "/lua/jenova",
    name = "jenova-chat",
    event = "VeryLazy",
    config = function()
      require("jenova.chat").setup()
    end,
  },
}
