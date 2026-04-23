-- ##Script function and purpose: Registers the Jenova checkhealth module so that
-- :checkhealth jenova is available from within Neovim. The actual implementation
-- lives in lua/jenova/health.lua (not lua/jvim_plugins/) so lazy.nvim does not scan it
-- as a plugin spec.
--
-- Usage inside Neovim:   :checkhealth jenova
-- This verifies: backend ports, Neovim version, LSP servers, formatters,
-- Vulkan/GPU setup, model files, and system memory.

-- ##Step purpose: This file returns an empty plugin spec table. lazy.nvim scans
-- lua/jvim_plugins/*.lua expecting plugin specs. The actual health module is at
-- lua/jenova/health.lua which Neovim finds automatically for :checkhealth jenova.
return {}
