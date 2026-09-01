-- jvim.icons — first-party file/filetype icon table.
-- Replaces nvim-tree/nvim-web-devicons and mini.icons. Also installs an
-- in-memory shim for `require("nvim-web-devicons")` so any third-party
-- plugin that still expects that module keeps working.
--
-- Glyphs are Nerd Font v3 codepoints. Highlight groups are linked to
-- the standard JvimIcon* groups defined in runtime/colors/jvim.vim.

local M = {}

-- Short aliases used in the by_ft table below.
local C = {
  Red    = "JvimIconRed",
  Orange = "JvimIconOrange",
  Yellow = "JvimIconYellow",
  Green  = "JvimIconGreen",
  Cyan   = "JvimIconCyan",
  Blue   = "JvimIconBlue",
  Purple = "JvimIconPurple",
  Pink   = "JvimIconPink",
  Grey   = "JvimIconGrey",
  White  = "JvimIconWhite",
}

-- ##Subsection: filename-exact overrides (case-insensitive lookup key).
local by_name = {
  ["readme.md"]      = { "", C.Yellow },
  ["license"]        = { "", C.Yellow },
  ["license.txt"]    = { "", C.Yellow },
  ["makefile"]       = { "", C.Orange },
  ["bsdmakefile"]    = { "", C.Orange },
  ["cmakelists.txt"] = { "", C.Red    },
  ["dockerfile"]     = { "", C.Blue   },
  ["docker-compose.yml"] = { "", C.Blue },
  [".gitignore"]     = { "", C.Orange },
  [".gitattributes"] = { "", C.Orange },
  [".editorconfig"]  = { "", C.Grey   },
  ["package.json"]   = { "", C.Red    },
  ["package-lock.json"] = { "", C.Red },
  ["cargo.toml"]     = { "", C.Orange },
  ["cargo.lock"]     = { "", C.Orange },
  ["go.mod"]         = { "", C.Cyan   },
  ["go.sum"]         = { "", C.Cyan   },
  ["build.zig"]      = { "", C.Yellow },
  ["build.zig.zon"]  = { "", C.Yellow },
}

-- ##Subsection: extension lookup.
local by_ext = {
  -- Languages.
  lua    = { "", C.Blue   },
  py     = { "", C.Yellow },
  rs     = { "", C.Orange },
  go     = { "", C.Cyan   },
  c      = { "", C.Blue   },
  cc     = { "", C.Blue   },
  cpp    = { "", C.Blue   },
  cxx    = { "", C.Blue   },
  h      = { "", C.Purple },
  hpp    = { "", C.Purple },
  zig    = { "", C.Yellow },
  sh     = { "", C.Green  },
  bash   = { "", C.Green  },
  fish   = { "", C.Green  },
  zsh    = { "", C.Green  },
  ts     = { "", C.Blue   },
  tsx    = { "", C.Blue   },
  js     = { "", C.Yellow },
  jsx    = { "", C.Cyan   },
  vim    = { "", C.Green  },
  -- Data / config.
  json   = { "", C.Yellow },
  yaml   = { "", C.Red    },
  yml    = { "", C.Red    },
  toml   = { "", C.Orange },
  ini    = { "", C.Grey   },
  conf   = { "", C.Grey   },
  cfg    = { "", C.Grey   },
  -- Docs.
  md     = { "", C.Blue   },
  markdown = { "", C.Blue },
  txt    = { "", C.White  },
  rst    = { "", C.Blue   },
  ["org"]  = { "", C.Green  },
  -- Web.
  html   = { "", C.Orange },
  css    = { "", C.Blue   },
  scss   = { "", C.Pink   },
  -- Images / binary.
  png    = { "", C.Purple },
  jpg    = { "", C.Purple },
  jpeg   = { "", C.Purple },
  gif    = { "", C.Purple },
  svg    = { "", C.Yellow },
  pdf    = { "", C.Red    },
  ico    = { "", C.Cyan   },
  -- Archives.
  zip    = { "", C.Yellow },
  tar    = { "", C.Yellow },
  gz     = { "", C.Yellow },
  xz     = { "", C.Yellow },
  ["7z"]   = { "", C.Yellow },
  -- Misc.
  log    = { "", C.Grey   },
  lock   = { "", C.Grey   },
  patch  = { "", C.Pink   },
  diff   = { "", C.Pink   },
}

local DEFAULT_FILE   = { "", C.White }
local DEFAULT_FOLDER = { "", C.Yellow }
local OPEN_FOLDER    = { "", C.Yellow }

-- ##Function: M.get(name, opts?) → glyph, hl_group.
--   name : filename (basename ok) or full path
--   opts : { is_directory = bool, is_open = bool, default = bool }
function M.get(name, opts)
  opts = opts or {}
  if opts.is_directory then
    local entry = opts.is_open and OPEN_FOLDER or DEFAULT_FOLDER
    return entry[1], entry[2]
  end
  local base = name:match("([^/\\]+)$") or name
  local lower = base:lower()
  local entry = by_name[lower]
  if entry then return entry[1], entry[2] end
  local ext = lower:match("%.([^%.]+)$")
  if ext then
    entry = by_ext[ext]
    if entry then return entry[1], entry[2] end
    -- Sub-extensions like file.tar.gz fall through to gz handling above.
  end
  if opts.default == false then return nil, nil end
  return DEFAULT_FILE[1], DEFAULT_FILE[2]
end

-- ##Function: M.by_filetype(ft) → glyph, hl_group. Used by tabline / statusline.
local ft_to_ext = {
  python = "py", javascript = "js", typescript = "ts", rust = "rs",
  cpp = "cpp", c = "c", lua = "lua", go = "go", zig = "zig",
  sh = "sh", bash = "bash", markdown = "md", json = "json", yaml = "yaml",
  toml = "toml", html = "html", css = "css", vim = "vim",
}
function M.by_filetype(ft)
  local ext = ft_to_ext[ft]
  if not ext then return DEFAULT_FILE[1], DEFAULT_FILE[2] end
  local entry = by_ext[ext]
  if entry then return entry[1], entry[2] end
  return DEFAULT_FILE[1], DEFAULT_FILE[2]
end

-- ##Function: Install a vim.api compatible shim for nvim-web-devicons so any
-- still-third-party plugin that calls `require("nvim-web-devicons").get_icon(...)`
-- keeps working.
function M.install_devicons_shim()
  if package.loaded["nvim-web-devicons"] then return end
  local shim = {}
  function shim.setup() end
  function shim.has_loaded() return true end
  function shim.get_icon(name, ext, _opts)
    if ext and not name:find("%.") then
      local entry = by_ext[ext:lower()]
      if entry then return entry[1], entry[2] end
    end
    local g, h = M.get(name or "", {})
    return g, h
  end
  function shim.get_icon_color(name, ext, opts)
    local _, hl = shim.get_icon(name, ext, opts)
    return nil, hl
  end
  function shim.get_icon_by_filetype(ft)
    local g, h = M.by_filetype(ft)
    return g, h
  end
  function shim.get_default_icon()
    return { icon = DEFAULT_FILE[1], color = nil, name = "Default" }
  end
  function shim.set_icon() end
  function shim.set_default_icon() end
  function shim.refresh() end
  package.loaded["nvim-web-devicons"] = shim
end

return M
