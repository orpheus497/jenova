-- ##Script function and purpose: Third-party UI plugin specs that have been
-- replaced by jvim's first-party native modules. This file is intentionally
-- empty: every UI plugin we previously loaded (kanagawa, lualine, which-key,
-- indent-blankline, nvim-notify, noice, edgy) is now provided by
-- runtime/lua/jvim/*.lua and wired in runtime/plugin/jvim_ui.lua.
--
-- The shape (`return {}`) is preserved so the jvim configuration scanner
-- import path continues to resolve.

return {}
