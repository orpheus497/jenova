return {
  {
    dir = vim.fn.stdpath("config"),
    name = "jenova-chat",
    event = "VeryLazy",
    config = function()
      require("jenova.chat").setup()
    end,
  },
}
