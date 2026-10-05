-- jenova/agent/learning_extractors.lua
-- Per-tool fact extractors. Given a tool call (name, args, result, ok)
-- each extractor synthesises zero or more memory facts that capture what
-- was learned: working build commands, file structure, LSP-clean states,
-- patterns that didn't work, etc.
--
-- These facts are written to jenova.agent.memory and surface back into the
-- system prompt under "Known about this project" — that is what enables
-- natural context compression: the agent doesn't need to re-Run or
-- re-Read what it has already verified.
--
-- Adding a new extractor is just `extractors[ToolName] = fn`.

local M = {}

-- A fact spec returned by an extractor:
--   { text, tags, confidence, source }
-- The extractor returns a list (table-of-tables) so a single tool call can
-- produce multiple facts.

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function rel(path)
  if not path or path == "" then return path end
  return vim.fn.fnamemodify(path, ":~:.")
end

local function lang_tag(path)
  if not path then return nil end
  local ext = vim.fn.fnamemodify(path, ":e")
  if ext and ext ~= "" then return "lang:" .. ext end
  return nil
end

local function file_tag(path)
  if not path or path == "" then return nil end
  return "file:" .. rel(path)
end

local function compact_text(s, n)
  if not s then return "" end
  s = tostring(s):gsub("%s+", " ")
  return #s <= n and s or s:sub(1, n) .. "…"
end

-- ── Extractors ───────────────────────────────────────────────────────────────

local extractors = {}

function extractors.Shell(args, result, ok)
  if not args or type(args.command) ~= "string" then return nil end
  local cmd = args.command
  if ok then
    local desc = type(args.description) == "string" and #args.description > 0
      and args.description or compact_text(cmd, 80)
    return {{
      text   = string.format("Shell command works: `%s` (%s)", compact_text(cmd, 100), desc),
      tags   = { "shell", "verified", "cmd:" .. (cmd:match("^%S+") or "?") },
      source = "Shell exit 0",
      confidence = 0.75,
    }}
  end
  -- Don't record raw command failures as facts — they tend to be transient
  -- (missing dep, typo) and the repetition guard already handles loops.
  -- Exception: explicit "command not found" — worth remembering.
  if result and result.text and result.text:match("not found") then
    return {{
      text   = string.format("Shell binary missing: `%s` returned 'not found'", compact_text(cmd, 80)),
      tags   = { "shell", "missing", "cmd:" .. (cmd:match("^%S+") or "?") },
      source = "Shell ENOENT",
      confidence = 0.85,
    }}
  end
end

function extractors.Read(args, result, ok)
  if not ok or not args or not args.file_path then return nil end
  if type(result) ~= "table" then return nil end
  local n = result.num_lines
  if not n or n == 0 then return nil end
  return {{
    text   = string.format("File `%s` is %d lines.", rel(args.file_path), n),
    tags   = { file_tag(args.file_path), lang_tag(args.file_path), "file-shape" },
    source = "Read",
    confidence = 0.8,
  }}
end

function extractors.Edit(args, _result, ok)
  if not ok or not args or not args.file_path then return nil end
  return {{
    text   = string.format("Edited `%s` lines %s-%s successfully.",
      rel(args.file_path),
      tostring(args.start_line or "?"),
      tostring(args.end_line or "?")),
    tags   = { file_tag(args.file_path), lang_tag(args.file_path), "edit-history" },
    source = "Edit",
    confidence = 0.6,   -- ephemeral — superseded by next edit
  }}
end

function extractors.Write(args, _result, ok)
  if not ok or not args or not args.file_path then return nil end
  return {{
    text   = string.format("Wrote `%s` (file is now editable from this session).",
      rel(args.file_path)),
    tags   = { file_tag(args.file_path), lang_tag(args.file_path), "write-history" },
    source = "Write",
    confidence = 0.7,
  }}
end

function extractors.LSP(args, result, ok)
  if not ok or not args then return nil end
  local action = args.action
  if action == "diagnostics" and type(result) == "table"
     and result.text == "No diagnostics." then
    local target = args.file_path or "(workspace)"
    return {{
      text   = string.format("`%s` is LSP-clean (no diagnostics).", rel(target)),
      tags   = { file_tag(args.file_path), lang_tag(args.file_path), "lsp", "clean" },
      source = "LSP diagnostics",
      confidence = 0.85,
    }}
  end
  if action == "symbols" and type(result) == "table" and result.text
     and result.num_lines and result.num_lines > 0 then
    return {{
      text   = string.format("`%s` exposes %d LSP symbol(s) at last query.",
        rel(args.file_path or "(workspace)"), result.num_lines),
      tags   = { file_tag(args.file_path), "lsp", "symbols" },
      source = "LSP symbols",
      confidence = 0.6,
    }}
  end
end

function extractors.Grep(args, result, ok)
  if not ok or not args then return nil end
  if type(result) ~= "table" or not result.text then return nil end
  if result.text == "No matches found." then
    return {{
      text   = string.format("Grep `%s` finds no matches in workspace.",
        compact_text(args.pattern or "?", 60)),
      tags   = { "grep", "absent" },
      source = "Grep empty",
      confidence = 0.5,
    }}
  end
end

function extractors.VimCmd(args, _result, ok)
  if not ok or not args then return nil end
  if args.action == "ex" and type(args.command) == "string" then
    return {{
      text   = string.format("Editor command `:%s` runs cleanly here.",
        compact_text(args.command, 80)),
      tags   = { "vim", "ex" },
      source = "VimCmd ex",
      confidence = 0.6,
    }}
  end
end

-- ── Public ───────────────────────────────────────────────────────────────────

function M.extract(name, args, result, ok)
  local fn = extractors[name]
  if not fn then return nil end
  local okx, facts = pcall(fn, args, result, ok)
  if not okx or type(facts) ~= "table" then return nil end
  return facts
end

-- Apply extracted facts to the memory store. Returns the count of facts
-- recorded (after dedup).
function M.apply(name, args, result, ok)
  local facts = M.extract(name, args, result, ok)
  if not facts or #facts == 0 then return 0 end
  local memory = require("jenova.agent.memory")
  local n = 0
  for _, fact in ipairs(facts) do
    if fact and type(fact.text) == "string" and #fact.text > 0 then
      local opts = {
        tags       = fact.tags,
        source     = fact.source,
        confidence = fact.confidence,
      }
      memory.record(fact.text, opts)
      n = n + 1
    end
  end
  return n
end

return M
