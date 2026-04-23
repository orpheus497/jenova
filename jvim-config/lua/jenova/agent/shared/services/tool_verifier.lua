-- services/tool_verifier.lua — Backend tool-result verification and retry policy
--
-- Purpose: after every tool call the query engine asks the verifier what to do.
-- The verifier inspects the (tool_name, input, result, attempt) tuple and returns
-- one of three verdicts:
--
--   "accept"    — result is good, continue the loop normally
--   "retry"     — result is bad but recoverable; inject a corrective hint
--   "fail"      — result is bad and NOT recoverable; surface the error to the model
--
-- This is the single place where "should we try again differently?" is decided,
-- keeping query_engine.lua clean of per-tool heuristics.

local M = {}

-- Maximum automatic retries per (tool, file) pair before giving up.
local MAX_RETRIES = {
    Edit      = 2,
    MultiEdit = 2,
    Write     = 1,
    Shell     = 1,
    Read      = 1,
    Glob      = 1,
    Grep      = 1,
}

-- Errors that are permanent and should never trigger a retry.
local PERMANENT_ERRORS = {
    "Permission denied",
    "Access denied",
    "cannot edit restricted path",
    "old_string and new_string are identical",
    "old_string is empty",
    "old_string matches multiple locations",
    "edits array is empty",
}

-- Errors that specifically indicate the model needs to re-read the file before
-- retrying an edit, rather than just retrying the same call.
local READ_BEFORE_RETRY_ERRORS = {
    "old_string not found",
    "Read the file",
    "copy the exact text",
    "not found in",
}

-- ── Helpers ────────────────────────────────────────────────────────────────

local function is_error_result(result)
    if type(result) == "table" then
        return result.type == "error" or (result.error ~= nil)
    end
    return false
end

local function error_text(result, raw_err)
    if raw_err then return tostring(raw_err) end
    if type(result) == "table" then
        return result.error or result.text or tostring(result)
    end
    return tostring(result or "")
end

local function matches_any(text, patterns)
    for _, pat in ipairs(patterns) do
        if text:find(pat, 1, true) then return true end
    end
    return false
end

-- ── Per-session attempt counters ───────────────────────────────────────────
-- Key: tool_name .. "|" .. (file_path or command[:40])
local attempt_counters = {}

local function attempt_key(tool_name, input)
    local detail = ""
    if type(input) == "table" then
        detail = input.file_path or input.command or input.path or input.pattern or input.query or ""
        detail = tostring(detail):sub(1, 60)
    end
    return tool_name .. "|" .. detail
end

local function increment_attempt(key)
    attempt_counters[key] = (attempt_counters[key] or 0) + 1
    return attempt_counters[key]
end

local function get_attempt(key)
    return attempt_counters[key] or 0
end

function M.reset()
    attempt_counters = {}
end

function M.get_attempt_count(tool_name, input)
    return get_attempt(attempt_key(tool_name, input))
end

-- ── Main verdict function ──────────────────────────────────────────────────
--
-- Returns: verdict ("accept"|"retry"|"fail"), hint_message (string|nil)
--
-- hint_message is injected into the conversation as a [System: ...] message
-- before the next model turn so the model gets actionable guidance.

function M.verify(tool_name, input, result, raw_err)
    local is_err = raw_err ~= nil or is_error_result(result)

    -- No error — always accept.
    if not is_err then
        -- Reset attempt counter on success so future calls to the same tool start fresh.
        local key = attempt_key(tool_name, input)
        attempt_counters[key] = 0
        return "accept", nil
    end

    local err_msg = error_text(result, raw_err)
    local key = attempt_key(tool_name, input)
    local attempt = increment_attempt(key)
    local max_retries = MAX_RETRIES[tool_name] or 1

    -- Permanent errors: never retry regardless of attempt count.
    if matches_any(err_msg, PERMANENT_ERRORS) then
        return "fail", string.format(
            "[System: %s('%s') failed with a permanent error — do NOT retry with the same arguments: %s]",
            tool_name,
            type(input) == "table" and (input.file_path or input.command or "") or "",
            err_msg)
    end

    -- Exceeded retry budget.
    if attempt > max_retries then
        return "fail", string.format(
            "[System: %s has failed %d time(s) — retry limit reached. Accept the failure, " ..
            "report what you tried and what went wrong, then ask the user how to proceed. Error: %s]",
            tool_name, attempt, err_msg)
    end

    -- Edit/MultiEdit failures where the old_string wasn't found — the model MUST
    -- re-read the file before attempting again. Inject a hard nudge.
    if (tool_name == "Edit" or tool_name == "MultiEdit") and
       matches_any(err_msg, READ_BEFORE_RETRY_ERRORS) then
        local fp = type(input) == "table" and (input.file_path or "") or ""
        return "retry", string.format(
            "[System: %s on '%s' failed because old_string was not found (attempt %d/%d). " ..
            "You MUST call Read('%s') NOW and copy the exact text character-for-character. " ..
            "Do NOT guess or reconstruct old_string. Do NOT call Edit again until you have called Read.]",
            tool_name, fp, attempt, max_retries, fp)
    end

    -- Shell failures (non-zero exit code or explicit error).
    if tool_name == "Shell" then
        local exit = type(result) == "table" and result.exit_code or nil
        if exit and exit ~= 0 then
            if attempt <= max_retries then
                return "retry", string.format(
                    "[System: Shell command failed with exit code %d (attempt %d/%d). " ..
                    "Read the error output above carefully, then either fix the command or " ..
                    "fix the underlying issue before retrying. Do NOT run the same command unchanged.]",
                    exit, attempt, max_retries)
            end
        end
    end

    -- Write failures.
    if tool_name == "Write" then
        local fp = type(input) == "table" and (input.file_path or "") or ""
        return "retry", string.format(
            "[System: Write to '%s' failed (attempt %d/%d): %s — " ..
            "verify the path is correct and try again with Write.]",
            fp, attempt, max_retries, err_msg)
    end

    -- Generic recoverable error.
    return "retry", string.format(
        "[System: %s failed (attempt %d/%d): %s — try a different approach.]",
        tool_name, attempt, max_retries, err_msg:sub(1, 120))
end

-- ── Result summariser ─────────────────────────────────────────────────────
-- Produces a short human-readable summary of a tool result for UI display.

function M.summarise(tool_name, result, raw_err)
    if raw_err then return "error: " .. tostring(raw_err):sub(1, 80) end
    if type(result) ~= "table" then return tostring(result):sub(1, 80) end
    if result.type == "error" then return "error: " .. (result.error or "?"):sub(1, 80) end
    if result.num_lines then return tostring(result.num_lines) .. " lines" end
    if result.num_files then return tostring(result.num_files) .. " files" end
    if result.exit_code and result.exit_code ~= 0 then return "exit " .. result.exit_code end
    if result.text then return result.text:sub(1, 60):gsub("\n", " ") end
    return "ok"
end

return M
