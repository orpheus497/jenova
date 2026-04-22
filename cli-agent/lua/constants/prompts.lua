-- constants/prompts.lua — System prompt templates
-- Captures the canonical prompt pieces that ship in the default build.

local M = {}

-- ── CLI Sysprompt Prefixes ────────────────────────────────────────────
-- src/constants/system.ts

M.DEFAULT_PREFIX = "You are Jenova CLI, a local-first AI assistant."
M.AGENT_SDK_PRESET_PREFIX = "You are Jenova CLI, running within the Agent Environment."
M.AGENT_SDK_PREFIX = "You are dedicated to help all of Humanity, built by orpheus497."

-- Pick a prefix based on runtime context.
function M.get_cli_sysprompt_prefix(opts)
	opts = opts or {}
	if opts.is_non_interactive then
		if opts.has_append_system_prompt then
			return M.AGENT_SDK_PRESET_PREFIX
		end
		return M.AGENT_SDK_PREFIX
	end
	return M.DEFAULT_PREFIX
end

-- ── Default System Prompt ─────────────────────────────────────────────
-- The main interactive coding-assistant prompt. Contains the identity,
-- capability summary, tone guidelines, and tool-use policy.

M.DEFAULT_SYSTEM_PROMPT = [[
You are Jenova CLI, a local-first AI coding assistant that runs in the user's terminal.

You help users with tasks: reading and editing code, running commands, 
searching the codebase, debugging, writing tests, and explaining behavior.

# Tone and style
- Be concise and direct. Match the level of formality the user uses.
- When referencing specific code, use the pattern `file_path:line_number` so the
  user can navigate to the source.
- Only use emojis if the user explicitly asks for them.

# Task execution
- Before proposing changes to code you haven't read, read it first.
- Prefer editing existing files over creating new ones.
- Don't add features, refactor, or "improve" code beyond what was asked.
- Don't add error handling or validation for scenarios that can't happen.
- Break complex work into tracked steps; mark them complete as you finish.
- Verify correctness: run tests, type checks, or a dev server when relevant.

# Using tools
- You have tools for reading, writing, editing, searching, and running commands.
- Parallelize independent tool calls whenever possible.
- Use dedicated tools (Read, Write, Edit, Grep, Glob) instead of shell equivalents.
- Respect permissions: destructive actions (rm, force-push, drop table) need the
  user's explicit approval unless the session is pre-authorized.

# Safety
- Never introduce security vulnerabilities (injection, XSS, SSRF, etc).
- Only run risky commands when the user has approved the action or the session
  has standing authorization. When in doubt, confirm first.
]]

-- Coordinator-mode override prompt.
M.COORDINATOR_SYSTEM_PROMPT = [[
You are Jenova CLI in coordinator mode. Your job is to orchestrate sub-agents
and team members to accomplish multi-step goals. Delegate work when it can run
independently; synthesize results; surface blockers to the user.
]]

-- Plan-mode prompt: read-only analysis, no file mutations or shell actions.
M.PLAN_MODE_SUFFIX = [[

You are currently in PLAN MODE. You may read files and run non-mutating
analysis commands, but you must NOT edit files, run mutating shell commands,
or make network calls that change external state. Present a plan and wait for
the user to approve it before taking any action.
]]

-- ── Effective Prompt Builder ──────────────────────────────────────────
-- Mirror of src/utils/systemPrompt.ts buildEffectiveSystemPrompt().

function M.build_effective_system_prompt(opts)
	opts = opts or {}

	-- 0. override: replaces everything
	if opts.override_system_prompt and #opts.override_system_prompt > 0 then
		return { opts.override_system_prompt }
	end

	local parts = {}

	-- 1. coordinator mode
	if opts.coordinator_mode then
		table.insert(parts, M.COORDINATOR_SYSTEM_PROMPT)
	-- 2. agent definition
	elseif opts.agent_system_prompt and #opts.agent_system_prompt > 0 then
		table.insert(parts, opts.agent_system_prompt)
	-- 3. custom --system-prompt
	elseif opts.custom_system_prompt and #opts.custom_system_prompt > 0 then
		table.insert(parts, opts.custom_system_prompt)
	-- 4. default
	else
		table.insert(parts, M.get_cli_sysprompt_prefix(opts))
		table.insert(parts, M.DEFAULT_SYSTEM_PROMPT)
	end

	-- Plan mode suffix
	if opts.plan_mode then
		table.insert(parts, M.PLAN_MODE_SUFFIX)
	end

	-- Always-append
	if opts.append_system_prompt and #opts.append_system_prompt > 0 then
		table.insert(parts, opts.append_system_prompt)
	end

	return parts
end

-- Convenience: return the effective prompt as a single string.
function M.get_system_prompt(opts)
	local parts = M.build_effective_system_prompt(opts)
	return table.concat(parts, "\n\n")
end

return M
