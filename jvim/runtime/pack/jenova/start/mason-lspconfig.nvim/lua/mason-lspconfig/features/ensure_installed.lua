local notify = require "mason-lspconfig.notify"
local registry = require "mason-registry"
local settings = require "mason-lspconfig.settings"

---@param lspconfig_server_name string
local function resolve_package(lspconfig_server_name)
    local Optional = require "mason-core.optional"
    local server_mapping = require("mason-lspconfig.mappings").get_mason_map()

    return Optional.of_nilable(server_mapping.lspconfig_to_package[lspconfig_server_name]):map(function(package_name)
        local ok, pkg = pcall(registry.get_package, package_name)
        if ok then
            return pkg
        end
    end)
end

return function()
    for _, server_identifier in ipairs(settings.current.ensure_installed) do
        local Package = require "mason-core.package"

        local server_name, version = Package.Parse(server_identifier)
        resolve_package(server_name)
            :if_present(
                ---@param pkg Package
                function(pkg)
                    if not pkg:is_installed() and not pkg:is_installing() then
                        require("mason-lspconfig.install").install(pkg, version)
                    end
                end
            )
            :if_not_present(function()
                notify(
                    ("[mason-lspconfig.nvim] Server %q is not a valid entry in ensure_installed. Make sure to only provide lspconfig server names."):format(
                        server_name
                    ),
                    vim.log.levels.WARN
                )
            end)
    end
end
