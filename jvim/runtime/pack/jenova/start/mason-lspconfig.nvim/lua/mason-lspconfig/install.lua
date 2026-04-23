local mappings = require "mason-lspconfig.mappings"
local notify = require "mason-lspconfig.notify"

local M = {}

---@param pkg Package
---@param version string?
---@return InstallHandle
function M.install(pkg, version)
    local lspconfig_name = mappings.get_mason_map().package_to_lspconfig[pkg.name]
    notify(("[mason-lspconfig.nvim] installing %s"):format(lspconfig_name))
    return pkg:install(
        { version = version },
        vim.schedule_wrap(function(success, err)
            if success then
                notify(("[mason-lspconfig.nvim] %s was successfully installed"):format(lspconfig_name))
            else
                notify(
                    ("[mason-lspconfig.nvim] failed to install %s. Installation logs are available in :Mason and :MasonLog"):format(
                        lspconfig_name
                    ),
                    vim.log.levels.ERROR
                )
            end
        end)
    )
end

return M
