-- jenova/agent/compactor.lua
-- Deterministic context compactor for the engine's message history.
--
-- The agent's `messages` array grows linearly: every tool call adds an
-- assistant message (with the JSON tool-call block) and a user message
-- (with the tool result). After a few dozen turns the context becomes
-- the bottleneck. This compactor folds the OLDER portion of history into
-- a single compact session digest while preserving the tail verbatim, so
-- the model still has full fidelity for the recent reasoning chain.
--
-- The compactor is rule-based: no extra LLM call. It pattern-matches on
-- the structured shape of the conversation (assistant emits ```json``` tool
-- calls; tool results are user messages prefixed with "[Tool Result: …]")
-- and rewrites each older turn as a one-line bullet:
--
--   • User asks → kept verbatim (capped)
--   • Assistant tool calls → "✓/✗ Tool args"
--   • Assistant prose       → first sentence (capped)
--
-- Crucially, anything dropped here ALSO survives in jenova.agent.memory
-- via the learning extractors, so the model can still recall facts about
-- earlier turns even though the raw transcript is gone.

local M = {}

local DEFAULT_MAX_MESSAGES = 24
local DEFAULT_KEEP_RECENT  = 8
local DEFAULT_MAX_CHARS    = 60000  -- ≈ 15-20k tokens depending on tokenizer
local DIGEST_TAG           = "[SESSION DIGEST]"

-- ── Decision ─────────────────────────────────────────────────────────────────

function M.should_compact(messages, opts)
  if not messages or #messages == 0 then return false end
  opts = opts or {}
  local max_msgs  = opts.max_messages or DEFAULT_MAX_MESSAGES
  local max_chars = opts.max_chars    or DEFAULT_MAX_CHARS

  if #messages > max_msgs then return true end

  local total = 0
  for _, m in ipairs(messages) do
    total = total + #(m.content or "")
    if total > max_chars then return true end
  end
  return false
end

-- ── Per-message rewriting ────────────────────────────────────────────────────

local function clip(s, n)
  s = tostring(s or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #s <= n then return s end
  return s:sub(1, n) .. "…"
end

-- Detect a ```json {"name":..,"arguments":..} ``` block inside an assistant
-- message and return the parsed list of tool calls + the surrounding prose.
local function parse_assistant(content)
  local out_calls = {}
  local prose_parts = {}

  local pos = 1
  while pos <= #content do
    local s = content:find("```json", pos, true)
    if not s then
      table.insert(prose_parts, content:sub(pos))
      break
    end
    if s > pos then table.insert(prose_parts, content:sub(pos, s - 1)) end
    local body_start = s + 7
    if content:sub(body_start, body_start) == "\n" then body_start = body_start + 1 end
    local e = content:find("```", body_start, true)
    if not e then break end
    local body = content:sub(body_start, e - 1):gsub("%s+$", "")
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and type(decoded) == "table" then
      table.insert(out_calls, {
        name = decoded.name or decoded.tool or "?",
        args = decoded.arguments or decoded.parameters or decoded.input or {},
      })
    end
    pos = e + 3
  end

  return out_calls, table.concat(prose_parts, " ")
end

-- Detect "[Tool Result: NAME]" prefix in a user message and pull the result.
local function parse_tool_result(content)
  local name, body = content:match("^%[Tool Result:%s*([^%]]+)%]%s*\n(.*)$")
  if not name then
    name = content:match("^%[Tool Result:%s*([^%]]+)%]")
    body = ""
  end
  return name, body or ""
end

-- One-line summary of a tool call's args (the operand the user cares about).
local function args_one_liner(args)
  if type(args) ~= "table" then return "" end
  local key = args.command or args.file_path or args.path or args.pattern
           or args.query or args.url
  if type(key) == "string" and #key > 0 then return clip(key, 80) end
  return ""
end

-- Was a [Tool Result: X] body an error? Heuristic: starts with "Error:"
-- (engine prefix) or contains an "error" key in the JSON-encoded payload.
local function tool_result_failed(body)
  if not body or body == "" then return false end
  if body:sub(1, 6) == "Error:" then return true end
  if body:find('"error"', 1, true) and body:find('"type":"error"', 1, true) then
    return true
  end
  return false
end

-- ── Digest builder ───────────────────────────────────────────────────────────

local function build_digest(old_messages)
  local lines = { DIGEST_TAG }
  local pending_calls = nil   -- carry tool calls from assistant → next user

  for _, m in ipairs(old_messages) do
    if m.role == "user" then
      local tname, tbody = parse_tool_result(m.content or "")
      if tname then
        -- Tool result: pair with the most recent tool call from the
        -- preceding assistant turn so we can render ✓/✗ name args.
        if pending_calls and #pending_calls > 0 then
          local call = table.remove(pending_calls, 1)
          local glyph = tool_result_failed(tbody) and "✗" or "✓"
          table.insert(lines, string.format("  %s %s %s",
            glyph, call.name, args_one_liner(call.args)))
        else
          local glyph = tool_result_failed(tbody) and "✗" or "✓"
          table.insert(lines, string.format("  %s %s", glyph, tname))
        end
      else
        -- Plain user message — keep its first line, capped.
        local first_line = (m.content or ""):match("^[^\n]*") or ""
        table.insert(lines, "User: " .. clip(first_line, 200))
        pending_calls = nil
      end
    elseif m.role == "assistant" then
      local calls, prose = parse_assistant(m.content or "")
      if prose and #vim.trim(prose) > 0 then
        local first = vim.trim(prose):match("^[^\n]*") or ""
        if #first > 0 then
          table.insert(lines, "Assistant: " .. clip(first, 200))
        end
      end
      pending_calls = calls
    end
  end

  -- Any leftover tool calls without a matching result.
  if pending_calls then
    for _, call in ipairs(pending_calls) do
      table.insert(lines, string.format("  · pending %s %s",
        call.name, args_one_liner(call.args)))
    end
  end

  return table.concat(lines, "\n")
end

-- ── Public: compact ──────────────────────────────────────────────────────────

-- Returns a new messages array with old turns folded into a single digest.
-- Never modifies the input. The digest goes in as a system-style user
-- message ("[SESSION DIGEST] …") so the model treats it as authoritative
-- background context rather than a real user turn.
function M.compact(messages, opts)
  if not messages or #messages == 0 then return messages, 0 end
  opts = opts or {}
  local keep_recent = opts.keep_recent or DEFAULT_KEEP_RECENT
  if #messages <= keep_recent then return messages, 0 end

  local cutoff = #messages - keep_recent
  local old, kept = {}, {}
  for i, m in ipairs(messages) do
    if i <= cutoff then table.insert(old, m) else table.insert(kept, m) end
  end

  -- If the first kept message is a tool-result orphan (no preceding
  -- assistant tool-call in the kept window), absorb it into the digest so
  -- the kept tail stays coherent.
  while #kept > 0 do
    local first = kept[1]
    if first.role == "user" and parse_tool_result(first.content or "") then
      table.insert(old, first)
      table.remove(kept, 1)
    else
      break
    end
  end

  local digest_text = build_digest(old)
  local digest_msg  = { role = "user", content = digest_text }

  local out = { digest_msg }
  for _, m in ipairs(kept) do table.insert(out, m) end
  return out, #old
end

-- Convenience: detect-and-compact in one call. Returns (new_messages,
-- compacted_count) so the engine can log when a compaction fired.
function M.maybe_compact(messages, opts)
  if not M.should_compact(messages, opts) then return messages, 0 end
  return M.compact(messages, opts)
end

return M
