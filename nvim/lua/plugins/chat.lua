-- ##Script function and purpose: Initialise the in-tree jenova.chat module on
-- startup so that the AI chat UI commands and keymaps are immediately
-- available. The module itself lives at lua/jenova/chat.lua.
require("jenova.chat").setup()
