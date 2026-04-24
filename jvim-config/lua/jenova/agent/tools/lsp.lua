-- jenova/agent/tools/lsp.lua
-- jvim-native LSP tool — overrides cli-agent's grep/ctags fallback with live
-- vim.lsp and vim.diagnostic API calls. Runs inside the editor process so it
-- has direct access to every attached language server with no subprocess.

local M = {}

M.name = "LSP"
M.description = "ONLY tool for errors, linting, and definitions inside jvim. CRITICAL: You MUST provide 'file_path'. Actions: diagnostics, definition, references, hover, symbols, code_actions, rename_preview."

M.parameters = {
  type = "object",
  properties = {
    action = { enum = {"diagnostics", "definition", "references", "hover", "symbols", "code_actions", "rename_preview"} },
    file_path = { type = "string", description = "Target file (required)" },
    line = { type = "integer", description = "1-based line" },
    character = { type = "integer", description = "0-based col" },
    query = { type = "string", description = "Search query" },
    new_name = { type = "string", description = "New name" },
  },
  required = { "action" },
}

function M.is_enabled() return true end
function M.is_read_only() return true end
function M.user_facing_name(input) return "LSP:" .. (input and input.action or "?") end
function M.check_permissions() return { allowed = true } end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function resolve_buf(file_path)
  if not file_path then
    return vim.api.nvim_get_current_buf(), false
  end
  local abs = vim.fn.fnamemodify(file_path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname == abs or bname == file_path then
        return b, false
      end
    end
  end
  -- Buffer not open — open it silently so LSP can attach
  local ok, bn = pcall(vim.fn.bufadd, abs)
  if ok and bn > 0 then
    vim.fn.bufload(bn)
    -- Wait up to 1 second for LSP to attach
    vim.wait(1000, function()
      local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bn })
        or (vim.lsp.get_active_clients and vim.lsp.get_active_clients({ bufnr = bn })) or {}
      return #clients > 0
    end, 50)
    return bn, true
  end
  return nil, false
end

local function buf_has_lsp(buf)
  local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = buf })
    or (vim.lsp.get_active_clients and vim.lsp.get_active_clients({ bufnr = buf }))
    or {}
  return #clients > 0, clients
end

local function make_position(line, character)
  return { line = (line or 1) - 1, character = character or 0 }
end

local function loc_to_str(loc)
  local uri = loc.uri or loc.targetUri or ""
  local range = loc.range or loc.targetSelectionRange or loc.targetRange or {}
  local start = range.start or {}
  local path = vim.uri_to_fname(uri)
  path = vim.fn.fnamemodify(path, ":~:.")
  return string.format("%s:%d:%d", path, (start.line or 0) + 1, (start.character or 0))
end

-- Synchronous LSP request via vim.lsp.buf_request_sync
local function lsp_request_sync(buf, method, params, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local results, err = vim.lsp.buf_request_sync(buf, method, params, timeout_ms)
  if err or not results then return nil, err or "no response" end
  -- Collect all non-nil results from all clients
  local out = {}
  for _, res in pairs(results) do
    if res and res.result then
      if type(res.result) == "table" then
        if res.result[1] ~= nil then
          -- array result
          for _, item in ipairs(res.result) do
            table.insert(out, item)
          end
        else
          table.insert(out, res.result)
        end
      end
    end
  end
  return out, nil
end

-- ── Action: diagnostics ───────────────────────────────────────────────────────

local function action_diagnostics(args)
  local diags = {}
  local buf = nil
  
  if args.file_path and args.file_path ~= "" then
    buf = resolve_buf(args.file_path)
    if buf then
      diags = vim.diagnostic.get(buf)
    else
      return { type = "error", error = "Could not resolve buffer for " .. args.file_path }
    end
  else
    diags = vim.diagnostic.get()
  end

  -- Fallback: If no diagnostics found and it's a C file, try compiler-based linting
  if (#diags == 0) and args.file_path then
    local ext = args.file_path:match("%.([^.]+)$")
    if ext == "c" or ext == "h" then
      local abs = vim.fn.fnamemodify(args.file_path, ":p")
      local res = vim.system({ "cc", "-fsyntax-only", "-I.", "-Iinclude", abs }, { text = true }):wait()
      if res.code ~= 0 and res.stderr and res.stderr ~= "" then
        -- Convert compiler stderr to a simplified diagnostic string
        return { type = "text", text = "Compiler Diagnostics:\n" .. res.stderr }
      end
    end
  end

  if not diags or #diags == 0 then
    return { type = "text", text = "No diagnostics." }
  end

  local sev_name = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }
  local lines = {}
  -- Sort: errors first, then by line
  table.sort(diags, function(a, b)
    if a.severity ~= b.severity then return a.severity < b.severity end
    return a.lnum < b.lnum
  end)

  for _, d in ipairs(diags) do
    local path = vim.api.nvim_buf_get_name(d.bufnr or 0)
    path = vim.fn.fnamemodify(path, ":~:.")
    local sev = sev_name[d.severity] or "?"
    local src = d.source and ("[" .. d.source .. "] ") or ""
    local code = d.code and ("(" .. tostring(d.code) .. ") ") or ""
    table.insert(lines, string.format("%s:%d:%d  %s  %s%s%s",
      path, d.lnum + 1, d.col + 1, sev, src, code, d.message))
  end

  return { type = "text", text = table.concat(lines, "\n"), num_lines = #lines }
end

-- ── Action: definition ────────────────────────────────────────────────────────

local function action_definition(args)
  local buf = resolve_buf(args.file_path)
  if not buf then return { type = "error", error = "file not found: " .. (args.file_path or "?") } end

  local has, _ = buf_has_lsp(buf)
  if not has then
    return { type = "error", error = "no LSP client attached to " .. (args.file_path or "current buffer") }
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = make_position(args.line, args.character),
  }

  local results, err = lsp_request_sync(buf, "textDocument/definition", params)
  if err then return { type = "error", error = "LSP definition failed: " .. err } end
  if not results or #results == 0 then
    return { type = "text", text = "No definition found." }
  end

  local lines = {}
  for _, loc in ipairs(results) do
    table.insert(lines, loc_to_str(loc))
  end
  return { type = "text", text = table.concat(lines, "\n") }
end

-- ── Action: references ────────────────────────────────────────────────────────

local function action_references(args)
  local buf = resolve_buf(args.file_path)
  if not buf then return { type = "error", error = "file not found: " .. (args.file_path or "?") } end

  local has, _ = buf_has_lsp(buf)
  if not has then
    return { type = "error", error = "no LSP client attached to " .. (args.file_path or "current buffer") }
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = make_position(args.line, args.character),
    context = { includeDeclaration = true },
  }

  local results, err = lsp_request_sync(buf, "textDocument/references", params)
  if err then return { type = "error", error = "LSP references failed: " .. err } end
  if not results or #results == 0 then
    return { type = "text", text = "No references found." }
  end

  local lines = {}
  for _, loc in ipairs(results) do
    table.insert(lines, loc_to_str(loc))
  end
  return { type = "text", text = string.format("%d reference(s):\n%s", #lines, table.concat(lines, "\n")),
    num_lines = #lines }
end

-- ── Action: hover ─────────────────────────────────────────────────────────────

local function action_hover(args)
  local buf = resolve_buf(args.file_path)
  if not buf then return { type = "error", error = "file not found: " .. (args.file_path or "?") } end

  local has, _ = buf_has_lsp(buf)
  if not has then
    return { type = "error", error = "no LSP client attached" }
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = make_position(args.line, args.character),
  }

  local results, err = lsp_request_sync(buf, "textDocument/hover", params)
  if err then return { type = "error", error = "LSP hover failed: " .. err } end
  if not results or #results == 0 then
    return { type = "text", text = "No hover information available." }
  end

  local parts = {}
  for _, res in ipairs(results) do
    local contents = res.contents
    if type(contents) == "string" then
      table.insert(parts, contents)
    elseif type(contents) == "table" then
      if contents.value then
        table.insert(parts, contents.value)
      elseif contents[1] then
        for _, c in ipairs(contents) do
          if type(c) == "string" then table.insert(parts, c)
          elseif type(c) == "table" and c.value then table.insert(parts, c.value) end
        end
      end
    end
  end

  if #parts == 0 then return { type = "text", text = "No hover information." } end
  return { type = "text", text = table.concat(parts, "\n---\n") }
end

-- ── Action: symbols ───────────────────────────────────────────────────────────

local function action_symbols(args)
  local buf = resolve_buf(args.file_path)

  -- Workspace symbol search if query provided
  if args.query and #args.query > 0 then
    local any_buf = buf or 0
    local _, clients = buf_has_lsp(any_buf)
    if #clients == 0 then
      return { type = "error", error = "no LSP client available for workspace symbols" }
    end

    local params = { query = args.query }
    local results, err = lsp_request_sync(any_buf, "workspace/symbol", params, 8000)
    if err then return { type = "error", error = "workspace/symbol failed: " .. err } end
    if not results or #results == 0 then
      return { type = "text", text = "No workspace symbols found for: " .. args.query }
    end

    local SymbolKind = {
      [1]="File",[2]="Module",[3]="Namespace",[4]="Package",[5]="Class",
      [6]="Method",[7]="Property",[8]="Field",[9]="Constructor",[10]="Enum",
      [11]="Interface",[12]="Function",[13]="Variable",[14]="Constant",
      [15]="String",[16]="Number",[17]="Boolean",[18]="Array",[19]="Object",
      [20]="Key",[21]="Null",[22]="EnumMember",[23]="Struct",[24]="Event",
      [25]="Operator",[26]="TypeParameter",
    }

    local lines = {}
    for _, sym in ipairs(results) do
      local loc = sym.location or {}
      local uri = loc.uri or ""
      local range = loc.range or {}
      local start = range.start or {}
      local path = uri ~= "" and vim.fn.fnamemodify(vim.uri_to_fname(uri), ":~:.") or "?"
      local kind = SymbolKind[sym.kind] or "?"
      table.insert(lines, string.format("%s  [%s]  %s:%d",
        sym.name, kind, path, (start.line or 0) + 1))
    end
    return { type = "text", text = table.concat(lines, "\n"), num_lines = #lines }
  end

  -- Document symbols
  if not buf then return { type = "error", error = "file_path required for document symbols" } end
  local has, _ = buf_has_lsp(buf)
  if not has then
    return { type = "error", error = "no LSP client attached to " .. (args.file_path or "current buffer") }
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
  local results, err = lsp_request_sync(buf, "textDocument/documentSymbol", params)
  if err then return { type = "error", error = "document symbols failed: " .. err } end
  if not results or #results == 0 then
    return { type = "text", text = "No symbols found." }
  end

  local lines = {}
  local function walk(syms, indent)
    indent = indent or ""
    for _, sym in ipairs(syms) do
      local range = (sym.range or sym.selectionRange or {}).start or {}
      table.insert(lines, string.format("%s%s  [%s]  line %d",
        indent, sym.name, sym.kind, (range.line or 0) + 1))
      if sym.children then walk(sym.children, indent .. "  ") end
    end
  end
  walk(results)
  return { type = "text", text = table.concat(lines, "\n"), num_lines = #lines }
end

-- ── Action: code_actions ──────────────────────────────────────────────────────

local function action_code_actions(args)
  local buf = resolve_buf(args.file_path)
  if not buf then return { type = "error", error = "file not found: " .. (args.file_path or "?") } end

  local has, _ = buf_has_lsp(buf)
  if not has then return { type = "error", error = "no LSP client attached" } end

  local line0 = (args.line or 1) - 1
  local col0  = args.character or 0
  local diags_at = vim.tbl_filter(function(d)
    return d.lnum == line0
  end, vim.diagnostic.get(buf))

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    range = {
      start = { line = line0, character = col0 },
      ["end"] = { line = line0, character = col0 },
    },
    context = {
      diagnostics = vim.tbl_map(function(d)
        return vim.diagnostic.toqflist({ d })[1] or {}
      end, diags_at),
    },
  }

  local results, err = lsp_request_sync(buf, "textDocument/codeAction", params)
  if err then return { type = "error", error = "codeAction failed: " .. err } end
  if not results or #results == 0 then
    return { type = "text", text = "No code actions available at this position." }
  end

  local lines = {}
  for i, action in ipairs(results) do
    local title = type(action) == "table" and (action.title or action.command or "?") or tostring(action)
    table.insert(lines, string.format("%d. %s", i, title))
  end
  return { type = "text", text = table.concat(lines, "\n"), num_lines = #lines }
end

-- ── Action: rename_preview ────────────────────────────────────────────────────

local function action_rename_preview(args)
  local buf = resolve_buf(args.file_path)
  if not buf then return { type = "error", error = "file not found: " .. (args.file_path or "?") } end

  local has, _ = buf_has_lsp(buf)
  if not has then return { type = "error", error = "no LSP client attached" } end

  if not args.new_name or #args.new_name == 0 then
    return { type = "error", error = "new_name is required for rename_preview" }
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = make_position(args.line, args.character),
    newName = args.new_name,
  }

  -- prepareRename first to confirm the symbol is renameable
  local prep, _ = lsp_request_sync(buf, "textDocument/prepareRename", params)
  if not prep or #prep == 0 then
    return { type = "text", text = "Symbol is not renameable at this position." }
  end

  -- Now do the actual rename to see what would change (without applying)
  local results, err = lsp_request_sync(buf, "textDocument/rename", params)
  if err then return { type = "error", error = "rename failed: " .. err } end
  if not results or #results == 0 then
    return { type = "text", text = "No changes from rename." }
  end

  local lines = {}
  for _, edit in ipairs(results) do
    local changes = edit.changes or (edit.documentChanges and
      vim.tbl_map(function(dc) return { [dc.textDocument.uri] = dc.edits } end, edit.documentChanges)[1]) or {}
    for uri, edits in pairs(changes) do
      local path = vim.fn.fnamemodify(vim.uri_to_fname(uri), ":~:.")
      table.insert(lines, string.format("%s: %d change(s)", path, #edits))
    end
    if edit.documentChanges then
      for _, dc in ipairs(edit.documentChanges) do
        local path = vim.fn.fnamemodify(vim.uri_to_fname(dc.textDocument.uri), ":~:.")
        table.insert(lines, string.format("%s: %d change(s)", path, #(dc.edits or {})))
      end
    end
  end

  if #lines == 0 then return { type = "text", text = "Rename would make no changes." } end
  return {
    type = "text",
    text = string.format("Rename to '%s' would affect:\n%s", args.new_name, table.concat(lines, "\n")),
  }
end

-- ── Dispatch ──────────────────────────────────────────────────────────────────

function M.call(args, _ctx)
  local action = args and args.action or "diagnostics"

  if action == "diagnostics"    then return action_diagnostics(args) end
  if action == "definition"     then return action_definition(args) end
  if action == "references"     then return action_references(args) end
  if action == "hover"          then return action_hover(args) end
  if action == "symbols"        then return action_symbols(args) end
  if action == "code_actions"   then return action_code_actions(args) end
  if action == "rename_preview" then return action_rename_preview(args) end

  return { type = "error", error = "Unknown LSP action: " .. tostring(action) }
end

return M
