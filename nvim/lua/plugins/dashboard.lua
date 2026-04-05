return {
  {
    "goolord/alpha-nvim",
    dependencies = { "nvim-web-devicons" },
    config = function()
      local alpha = require("alpha")
      local dashboard = require("alpha.themes.dashboard")

      local function detect_os()
        local sysname = vim.uv and vim.uv.os_uname().sysname or (vim.loop and vim.loop.os_uname().sysname) or "Unknown"
        local release = ""
        if sysname == "FreeBSD" then
          local r = vim.fn.system("uname -r")
          release = " " .. vim.fn.trim(r)
        elseif sysname == "Linux" then
          local ok, lines = pcall(vim.fn.readfile, "/etc/os-release")
          if ok then
            for _, line in ipairs(lines) do
              local name = line:match('^PRETTY_NAME="(.-)"')
              if name then release = " (" .. name .. ")" break end
            end
          end
        elseif sysname == "Darwin" then
          local r = vim.fn.system("sw_vers -productVersion")
          release = " " .. vim.fn.trim(r)
        end
        return sysname .. release
      end

      local function btn(sc, txt, lua_func_str)
        local b = dashboard.button(sc, txt, "<cmd>lua " .. lua_func_str .. "<CR>")
        return b
      end

      local os_info = detect_os()
      local v = vim.version()
      local nvim_version = string.format("NVIM %d.%d.%d", v.major, v.minor, v.patch)

      local header = {
        type = "text",
        val = {
          "",
          "",
          "",
          "       ██╗███████╗███╗   ██╗ ██████╗ ██╗   ██╗ █████╗        ",
          "       ██║██╔════╝████╗  ██║██╔═══██╗██║   ██║██╔══██╗       ",
          "       ██║█████╗  ██╔██╗ ██║██║   ██║██║   ██║███████║       ",
          "  ██   ██║██╔══╝  ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║      ",
          "  ╚█████╔╝███████╗██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║      ",
          "   ╚════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝      ",
          "",
          "            Cognitive Architecture — IDE",
          "",
          "     " .. os_info .. "  │  " .. nvim_version,
          "",
        },
        opts = { position = "center", hl = "AlphaHeader" },
      }

      local quick_actions = {
        type = "group",
        val = {
          { type = "text", val = "── Quick Actions ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
          { type = "padding", val = 1 },
          dashboard.button("e",   "  New File",             "<cmd>ene<CR>"),
          btn("f",                "  Find File",            "require('telescope.builtin').find_files()"),
          btn("r",                "  Recent Files",         "require('telescope.builtin').oldfiles()"),
          btn("g",                "  Live Grep",            "require('telescope.builtin').live_grep()"),
          btn("b",                "  Buffers",              "require('telescope.builtin').buffers()"),
          dashboard.button("i",   "  Open IDE Panels",     "<cmd>IDE<CR>"),
        },
        opts = { spacing = 0 },
      }

      local ai_section = {
        type = "group",
        val = {
          { type = "text", val = "── AI / Jenova ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
          { type = "padding", val = 1 },
          btn("c",   "  AI Chat (Buffer Context)",  "require('lazy').load({plugins={'gp.nvim'}}); vim.cmd('GpChatNew vsplit')"),
          btn("t",   "  Toggle AI Chat",            "require('lazy').load({plugins={'gp.nvim'}}); vim.cmd('GpChatToggle vsplit')"),
          btn("s",   "  Web Search",                "require('lazy').load({plugins={'gp.nvim'}}); vim.cmd('GpWebSearch')"),
          btn("j",   "  Jenova Agent Terminal",     "local r=vim.fn.expand('$JENOVA_ROOT'); if r=='' or r=='$JENOVA_ROOT' then r=vim.fn.expand('~/Projects/jenova') end; vim.cmd('term cd '..vim.fn.shellescape(r)..' && bin/jenova')"),
          btn("M",   "  Backend Monitor",           "require('jenova.monitor').open_monitor()"),
        },
        opts = { spacing = 0 },
      }

      local git_section = {
        type = "group",
        val = {
          { type = "text", val = "── Git ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
          { type = "padding", val = 1 },
          btn("G",   "  Neogit Status",       "require('lazy').load({plugins={'neogit'}}); vim.cmd('Neogit')"),
          btn("D",   "  Diff View",            "require('lazy').load({plugins={'diffview.nvim'}}); vim.cmd('DiffviewOpen')"),
          dashboard.button("F",   "  Fugitive",  "<cmd>Git<CR>"),
        },
        opts = { spacing = 0 },
      }

      local diagnostics_section = {
        type = "group",
        val = {
          { type = "text", val = "── Diagnostics & LSP ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
          { type = "padding", val = 1 },
          dashboard.button("x",   "  Workspace Diagnostics",  "<cmd>Trouble diagnostics toggle<CR>"),
          dashboard.button("S",   "  Symbols",                 "<cmd>Trouble symbols toggle focus=false<CR>"),
          dashboard.button("R",   "  LSP Defs / References",   "<cmd>Trouble lsp toggle focus=false win.position=right<CR>"),
        },
        opts = { spacing = 0 },
      }

      local config_section = {
        type = "group",
        val = {
          { type = "text", val = "── Config ──", opts = { position = "center", hl = "AlphaHeaderLabel" } },
          { type = "padding", val = 1 },
          dashboard.button("l",   "  Lazy (Plugin Manager)", "<cmd>Lazy<CR>"),
          dashboard.button("m",   "  Mason (LSP Installer)", "<cmd>Mason<CR>"),
          dashboard.button("h",   "  Checkhealth",           "<cmd>checkhealth<CR>"),
          dashboard.button("q",   "  Quit",                  "<cmd>qa<CR>"),
        },
        opts = { spacing = 0 },
      }

      -- ##Section purpose: Dynamic backend status section — polls services at startup
      local backend_status = {
        type = "text",
        val = (function()
          local host = vim.env.JENOVA_CONNECT_HOST or vim.env.JENOVA_HOST or "127.0.0.1"
          if host == "0.0.0.0" or host == "::" or host == "*" then host = "127.0.0.1" end
          local proxy_port = vim.env.JENOVA_PORT or "8080"
          local llama_port = vim.env.JENOVA_LLAMA_PORT or "8081"
          local embed_port = "8082"

          -- Detect hardware profile
          local jenova_root = vim.env.JENOVA_ROOT or ""
          local profile_name = "unknown"
          if jenova_root ~= "" and jenova_root ~= "$JENOVA_ROOT" then
            local detect = jenova_root .. "/hardware-profiles/detect-hardware.sh"
            if vim.fn.filereadable(detect) == 1 then
              local result = vim.fn.system(detect .. " 2>/dev/null")
              result = vim.fn.trim(result or "")
              if result ~= "" and vim.v.shell_error == 0 then
                profile_name = result
              end
            end
          end

          return {
            "",
            "── Backend Status ──",
            "",
            string.format("     Proxy:    :%s     Llama:  :%s     Embed:  :%s",
              proxy_port, llama_port, embed_port),
            string.format("     Host:     %s      Profile: %s", host, profile_name),
            "",
          }
        end)(),
        opts = { position = "center", hl = "AlphaHeaderLabel" },
      }

      local controls = {
        type = "text",
        val = {
          "",
          "┌─────────────── Navigation & Controls ───────────────┐",
          "│                                                      │",
          "│  SPC w       Save          SPC q       Quit          │",
          "│  SPC e       File Tree     SPC f f     Find File     │",
          "│  SPC f g     Live Grep     SPC f b     Buffers       │",
          "│  Shift-H/L   Prev/Next Buffer                        │",
          "│                                                      │",
          "│  Ctrl-h/j/k/l   Window Navigation                    │",
          "│  [ d  /  ] d    Prev / Next Diagnostic               │",
          "│  [ h  /  ] h    Prev / Next Git Hunk                 │",
          "│  g d            Go to Definition                      │",
          "│  K              Hover Documentation                   │",
          "│  SPC c a        Code Action     SPC r n   Rename      │",
          "│  SPC c d        Diagnostic Float                      │",
          "│                                                      │",
          "│  SPC a c   AI Chat     SPC a t   Toggle Chat          │",
          "│  SPC a r   Respond     SPC a d   Delete Chat          │",
          "│  SPC a w   Rewrite (v) SPC a s   Web Search           │",
          "│  SPC a m   Monitor     SPC a h   Checkhealth          │",
          "│                                                      │",
          "│  g c       Toggle Comment   s a / s d / s r  Surround │",
          "│  SPC b d   Delete Buffer    SPC c f   Format Buffer   │",
          "│                                                      │",
          "└──────────────────────────────────────────────────────┘",
        },
        opts = { position = "center", hl = "AlphaFooter" },
      }

      local footer_val = {
        type = "text",
        val = "",
        opts = { position = "center", hl = "AlphaFooter" },
      }

      alpha.setup({
        layout = {
          { type = "padding", val = 1 },
          header,
          { type = "padding", val = 1 },
          quick_actions,
          { type = "padding", val = 1 },
          ai_section,
          { type = "padding", val = 1 },
          git_section,
          { type = "padding", val = 1 },
          diagnostics_section,
          { type = "padding", val = 1 },
          config_section,
          { type = "padding", val = 1 },
          backend_status,
          { type = "padding", val = 1 },
          controls,
          { type = "padding", val = 1 },
          footer_val,
        },
        opts = { margin = 5 },
      })

      vim.api.nvim_create_autocmd("User", {
        pattern = "LazyVimStarted",
        once = true,
        callback = function()
          local stats = require("lazy").stats()
          footer_val.val = string.format(
            "  %d plugins loaded in %.0f ms",
            stats.count,
            stats.startuptime or 0
          )
          pcall(vim.cmd, "AlphaRedraw")
        end,
      })
    end,
  },
}
