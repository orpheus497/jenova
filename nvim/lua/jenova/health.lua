-- ##Script function and purpose: Jenova checkhealth module — registers a
-- :checkhealth jenova command that verifies all required components of the
-- Jenova Cognitive Architecture are present, reachable, and correctly configured.
-- PR #27: Covers backend ports, FreeBSD packages, model files, GPU, and formatters.

local M = {}

-- ---------------------------------------------------------------------------
-- Helper: TCP probe (native vim.uv, no external dependencies)
-- ---------------------------------------------------------------------------
--- Probe a host:port for reachability via TCP connect.
--- @return boolean|nil  true = reachable, false = unreachable, nil = probe skipped (vim.uv unavailable)
local function probe(host, port)
  local uv = vim.uv or vim.loop
  if not uv then return nil end
  local tcp = uv.new_tcp()
  if not tcp then return nil end
  local connected = false
  local done = false
  tcp:connect(host, tonumber(port), function(err)
    connected = (not err)
    done = true
    tcp:close()
  end)
  -- Synchronous wait with 2s timeout for checkhealth context
  local deadline = uv.now() + 2000
  while not done and uv.now() < deadline do
    uv.run("once")
  end
  if not done then
    pcall(function() tcp:close() end)
    return false
  end
  return connected
end

-- ---------------------------------------------------------------------------
-- Helper: Binary existence check
-- ---------------------------------------------------------------------------
local function has_bin(name)
  return vim.fn.executable(name) == 1
end

-- ---------------------------------------------------------------------------
-- checkhealth implementation
-- ---------------------------------------------------------------------------
function M.check()
  local h = vim.health

  -- -------------------------------------------------------------------------
  -- 1. Jenova CA Backend
  -- -------------------------------------------------------------------------
  h.start("Jenova CA Backend")

  local connect_host = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
  -- Normalize wildcard bind addresses to loopback for client connections
  if connect_host == "0.0.0.0" or connect_host == "::" or connect_host == "*" then
    connect_host = "127.0.0.1"
  end
  local proxy_port   = vim.env.JENOVA_PORT          or "8080"
  local llama_port   = vim.env.JENOVA_LLAMA_PORT    or "8081"
  -- Embed port is not exposed as env var by jvim yet; use fixed default
  local embed_port   = "8082"

  local proxy_url = string.format("http://%s:%s/health", connect_host, proxy_port)
  local proxy_status = probe(connect_host, proxy_port)
  if proxy_status == nil then
    h.info(string.format("Intelligence Proxy probe skipped (vim.uv unavailable) — %s", proxy_url))
  elseif proxy_status then
    h.ok(string.format("Intelligence Proxy reachable at %s", proxy_url))
  else
    h.error(
      string.format("Intelligence Proxy NOT reachable at %s", proxy_url),
      "Run: bin/jenova-ca --daemon   OR   jvim somefile.lua"
    )
  end

  local llama_url = string.format("http://%s:%s/health", connect_host, llama_port)
  local llama_status = probe(connect_host, llama_port)
  if llama_status == nil then
    h.info(string.format("llama-server probe skipped (vim.uv unavailable) — %s", llama_url))
  elseif llama_status then
    h.ok(string.format("llama-server (main inference) reachable at %s", llama_url))
  else
    h.warn(
      string.format("llama-server NOT reachable at %s", llama_url),
      "Backend may still be starting. Wait ~90s after jenova-ca --daemon."
    )
  end

  local embed_url = string.format("http://%s:%s/health", connect_host, embed_port)
  local embed_status = probe(connect_host, embed_port)
  if embed_status == nil then
    h.info(string.format("Embedding server probe skipped (vim.uv unavailable) — %s", embed_url))
  elseif embed_status then
    h.ok(string.format("Embedding server (nomic-embed) reachable at %s", embed_url))
  else
    h.warn(
      string.format("Embedding server NOT reachable at %s", embed_url),
      "RAG/semantic search unavailable. Check models/nomic-embed-text-v1.5.Q8_0.gguf exists."
    )
  end

  -- -------------------------------------------------------------------------
  -- 2. Neovim version
  -- -------------------------------------------------------------------------
  h.start("Neovim Version")
  local nv = vim.version()
  local nv_str = string.format("%d.%d.%d", nv.major, nv.minor, nv.patch)
  if nv.major > 0 or nv.minor >= 10 then
    h.ok(string.format("Neovim %s (>= 0.10 required)", nv_str))
  else
    h.error(
      string.format("Neovim %s — version 0.10+ required", nv_str),
      "pkg install neovim   (FreeBSD)"
    )
  end

  if vim.lsp.config then
    h.ok("Neovim 0.11+ native LSP config API available")
  else
    h.info("Neovim < 0.11 — using nvim-lspconfig fallback (functional but not latest API)")
  end

  -- -------------------------------------------------------------------------
  -- 3. Required system binaries
  -- -------------------------------------------------------------------------
  h.start("Required System Binaries")

  local required = {
    { "luajit",  "pkg install luajit-openresty" },
    { "git",     "pkg install git" },
    { "nvim",    "pkg install neovim" },
  }
  for _, r in ipairs(required) do
    if has_bin(r[1]) then
      h.ok(r[1])
    else
      h.error(r[1] .. " not found", r[2])
    end
  end

  local optional = {
    { "curl",               "pkg install curl (fallback health probe in jenova-ca)" },
    { "gmake",              "pkg install gmake (telescope-fzf-native build)" },
    { "flock",              "pkg install util-linux (daemon lock file)" },
  }
  for _, r in ipairs(optional) do
    if has_bin(r[1]) then
      h.ok(r[1] .. " (optional)")
    else
      h.warn(r[1] .. " not found", r[2])
    end
  end

  -- -------------------------------------------------------------------------
  -- 4. LSP servers
  -- -------------------------------------------------------------------------
  h.start("LSP Servers")

  local lsp_servers = {
    { bins = { "clangd19", "clangd18", "clangd17", "clangd15", "clangd" }, label = "clangd (C/C++)", pkg = "pkg install llvm" },
    { bins = { "rust-analyzer" }, label = "rust-analyzer (Rust)", pkg = "pkg install rust-analyzer  OR  rustup component add rust-analyzer" },
    { bins = { "lua-language-server" }, label = "lua-language-server (Lua)", pkg = "pkg install lua-language-server" },
    { bins = { "pyright" }, label = "pyright (Python)", pkg = "pkg install py311-pyright" },
    { bins = { "zls" }, label = "zls (Zig)", pkg = "pkg install zig" },
    { bins = { "bash-language-server" }, label = "bash-language-server (Shell)", pkg = "npm install -g bash-language-server" },
    { bins = { "gopls" }, label = "gopls (Go)", pkg = "go install golang.org/x/tools/gopls@latest" },
  }

  for _, s in ipairs(lsp_servers) do
    local found = false
    for _, b in ipairs(s.bins) do
      if has_bin(b) then
        h.ok(s.label .. "  (" .. b .. ")")
        found = true
        break
      end
    end
    if not found then
      h.warn(s.label .. " not found", s.pkg)
    end
  end

  -- -------------------------------------------------------------------------
  -- 5. Formatters (conform.nvim)
  -- -------------------------------------------------------------------------
  h.start("Code Formatters (conform.nvim)")

  local formatters = {
    { "stylua",       "cargo install stylua  OR  pkg install stylua" },
    { "isort",        "pip install isort" },
    { "black",        "pip install black" },
    { "rustfmt",      "rustup component add rustfmt" },
    { "gofmt",        "included with Go toolchain" },
    { "goimports",    "go install golang.org/x/tools/cmd/goimports@latest" },
    { "clang-format", "pkg install llvm (provides clang-format)" },
    { "shfmt",        "pkg install shfmt" },
  }

  for _, f in ipairs(formatters) do
    if has_bin(f[1]) then
      h.ok(f[1])
    else
      h.warn(f[1] .. " not found", f[2])
    end
  end

  -- -------------------------------------------------------------------------
  -- 6. GPU / Vulkan
  -- -------------------------------------------------------------------------
  h.start("GPU / Vulkan")

  if has_bin("vulkaninfo") then
    local vk_out = vim.fn.system("vulkaninfo --summary 2>/dev/null | head -20")
    if vim.v.shell_error == 0 then
      h.ok("vulkaninfo available — Vulkan driver present")
      -- Check for at least 2 devices for dual-GPU
      local dev_count = 0
      for _ in vk_out:gmatch("deviceName") do
        dev_count = dev_count + 1
      end
      if dev_count >= 2 then
        h.ok(string.format("Dual-GPU detected (%d Vulkan devices) — optimal configuration", dev_count))
      elseif dev_count == 1 then
        h.warn("Single Vulkan device detected — inference will use one GPU only")
      end
    else
      h.warn("vulkaninfo returned error — Vulkan may not be initialised")
    end
  else
    h.warn("vulkaninfo not found", "pkg install vulkan-tools (optional, for GPU diagnostics)")
  end

  -- Check JENOVA_ROOT for llama-server binary
  local jenova_root = vim.env.JENOVA_ROOT or vim.fn.expand("~/Projects/jenova")
  local llama_bin   = jenova_root .. "/llama.cpp/build/bin/llama-server"
  if vim.fn.filereadable(llama_bin) == 1 then
    h.ok("llama-server binary found at " .. llama_bin)
  else
    h.error(
      "llama-server not found at " .. llama_bin,
      "Build llama.cpp: cd " .. jenova_root .. "/llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build -j$(nproc)"
    )
  end

  -- -------------------------------------------------------------------------
  -- 7. Model files
  -- -------------------------------------------------------------------------
  h.start("Model Files")

  local models = {
    {
      path = vim.env.JENOVA_MODEL or (jenova_root .. "/models/jenova.gguf"),
      label = "Agent model (" .. vim.fn.fnamemodify(vim.env.JENOVA_MODEL or (jenova_root .. "/models/jenova.gguf"), ":t") .. ")",
      required = true,
    },
    {
      path = jenova_root .. "/models/nomic-embed-text-v1.5.Q8_0.gguf",
      label = "Embedding model (nomic-embed-text-v1.5)",
      required = true,
    },
    {
      path = jenova_root .. "/models/Qwen2.5-Coder-0.5B-Q8_0.gguf",
      label = "Draft model (Qwen2.5-Coder-0.5B) — speculative decoding",
      required = false,
    },
  }

  for _, m in ipairs(models) do
    if vim.fn.filereadable(m.path) == 1 then
      -- File size check: warn if <100MB (may be corrupted/placeholder)
      local size_bytes = vim.fn.getfsize(m.path)
      if size_bytes > 100 * 1024 * 1024 then
        h.ok(m.label)
      else
        h.warn(m.label .. " — file exists but is very small (" .. math.floor(size_bytes / 1024) .. " KB); may be corrupted")
      end
    elseif m.required then
      h.error(m.label .. " — NOT FOUND at " .. m.path, "Download the model GGUF and place it in " .. jenova_root .. "/models/")
    else
      h.warn(m.label .. " — not found (optional)", "Speculative decoding disabled. Run: tests/download-draft-model.sh")
    end
  end

  -- -------------------------------------------------------------------------
  -- 8. Memory
  -- -------------------------------------------------------------------------
  h.start("System Memory")

  local mem_total_mb = 0
  if vim.uv and vim.uv.get_total_memory then
    mem_total_mb = math.floor(vim.uv.get_total_memory() / 1024 / 1024)
  else
    -- Fallback for older Neovim versions
    local uname = (vim.uv or vim.loop).os_uname()
    local is_linux = uname.sysname == "Linux"
    local free_out = vim.fn.system("sysctl -n hw.physmem 2>/dev/null || grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}'")
    if vim.v.shell_error == 0 then
      local val = tonumber(free_out:match("%d+"))
      if val then
        if is_linux then
          mem_total_mb = math.floor(val / 1024)
        else
          mem_total_mb = math.floor(val / 1024 / 1024)
        end
      end
    end
  end

  if mem_total_mb >= 14000 then
    h.ok(string.format("System RAM: ~%d GiB — sufficient for 7B dual-GPU inference", math.floor(mem_total_mb / 1024)))
  elseif mem_total_mb >= 8000 then
    h.warn(string.format("System RAM: ~%d GiB — tight; consider reducing CTX_SIZE in jenova.conf", math.floor(mem_total_mb / 1024)))
  elseif mem_total_mb > 0 then
    h.error(string.format("System RAM: ~%d GiB — likely insufficient for 7B model", math.floor(mem_total_mb / 1024)))
  else
    h.info("Could not determine system RAM (sysctl/proc not available)")
  end

  h.info("Estimated resident usage when fully loaded: ~8.3 GiB (see JENOVA-NVIM-ROADMAP.md §9.3)")
  h.info("Optane NVMe swap handles cold tensor pages — check jenova-setup was run")
end

return M
