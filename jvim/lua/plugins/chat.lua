return {
  {
    "jenova.chat",
    event = "VeryLazy",
    config = function()
      require("jenova.agent").setup()
      require("jenova.chat").setup()
    end,
  },
}
