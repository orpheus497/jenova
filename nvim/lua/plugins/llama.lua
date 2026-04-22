-- ##Script function and purpose: llama.vim FIM (fill-in-the-middle) inline
-- completions, pointing at the Jenova llama-server infill port and the
-- intelligence proxy for instruction completions. Ports come from
-- jenova.endpoints (driven by JENOVA_PORT / JENOVA_LLAMA_PORT).

local ep = require("jenova.endpoints")

if not vim.env.JENOVA_CONNECT_HOST and not ep.has_jvim_env() and not ep.is_lan_mode() then
  vim.notify(
    "Jenova environment not detected.\n" ..
    "Launch via 'jvim' or set JENOVA_CONNECT_HOST for LAN mode.",
    vim.log.levels.WARN,
    { title = "Jenova" }
  )
end

vim.g.llama_config = {
  endpoint_fim    = ep.fim_url(),
  endpoint_inst   = ep.proxy_url(),
  show_info       = 2,
  auto_fim        = true,
  n_prefix        = 128,
  n_suffix        = 64,
  n_predict       = 64,
  t_max_prompt_ms  = 500,
  t_max_predict_ms = 1000,
}
