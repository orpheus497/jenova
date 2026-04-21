-- vim/keybindings.lua — Vim mode keybindings
-- Equivalent to src/vim/

local VimMode = {}

VimMode.MODES = {
    NORMAL = "normal",
    INSERT = "insert",
    VISUAL = "visual",
    COMMAND = "command",
}

-- Current mode
local current_mode = VimMode.MODES.NORMAL

-- ── Mode Management ───────────────────────────────────────────────────

function VimMode.get_mode()
    return current_mode
end

function VimMode.set_mode(mode)
    current_mode = mode
end

function VimMode.is_enabled()
    local config = require("config.loader")
    return config.get("vim_mode") or false
end

-- ── Keybinding Handlers ───────────────────────────────────────────────

function VimMode.handle_key(key, input_buffer, cursor_pos)
    if not VimMode.is_enabled() then
        return nil
    end

    if current_mode == VimMode.MODES.NORMAL then
        return VimMode.handle_normal_mode(key, input_buffer, cursor_pos)
    elseif current_mode == VimMode.MODES.INSERT then
        return VimMode.handle_insert_mode(key, input_buffer, cursor_pos)
    elseif current_mode == VimMode.MODES.VISUAL then
        return VimMode.handle_visual_mode(key, input_buffer, cursor_pos)
    elseif current_mode == VimMode.MODES.COMMAND then
        return VimMode.handle_command_mode(key, input_buffer, cursor_pos)
    end

    return nil
end

-- ── Normal Mode ───────────────────────────────────────────────────────

function VimMode.handle_normal_mode(key, input_buffer, cursor_pos)
    local actions = {
        -- Movement
        h = function() return {action = "cursor_left"} end,
        l = function() return {action = "cursor_right"} end,
        ["0"] = function() return {action = "cursor_home"} end,
        ["$"] = function() return {action = "cursor_end"} end,
        w = function() return {action = "word_forward"} end,
        b = function() return {action = "word_backward"} end,

        -- Editing
        i = function() current_mode = VimMode.MODES.INSERT; return {action = "enter_insert"} end,
        a = function() current_mode = VimMode.MODES.INSERT; return {action = "append"} end,
        A = function() current_mode = VimMode.MODES.INSERT; return {action = "append_end"} end,
        I = function() current_mode = VimMode.MODES.INSERT; return {action = "insert_home"} end,
        o = function() current_mode = VimMode.MODES.INSERT; return {action = "open_below"} end,
        O = function() current_mode = VimMode.MODES.INSERT; return {action = "open_above"} end,

        -- Deletion
        x = function() return {action = "delete_char"} end,
        dd = function() return {action = "delete_line"} end,
        D = function() return {action = "delete_to_end"} end,

        -- Undo/Redo
        u = function() return {action = "undo"} end,
        ["\x12"] = function() return {action = "redo"} end, -- Ctrl+R

        -- Visual mode
        v = function() current_mode = VimMode.MODES.VISUAL; return {action = "enter_visual"} end,

        -- Command mode
        [":"] = function() current_mode = VimMode.MODES.COMMAND; return {action = "enter_command"} end,
    }

    local handler = actions[key]
    if handler then
        return handler()
    end

    return nil
end

-- ── Insert Mode ───────────────────────────────────────────────────────

function VimMode.handle_insert_mode(key, input_buffer, cursor_pos)
    -- ESC to return to normal mode
    if key == "\x1b" then
        current_mode = VimMode.MODES.NORMAL
        return {action = "exit_insert"}
    end

    -- All other keys are passed through
    return {action = "insert_char", char = key}
end

-- ── Visual Mode ───────────────────────────────────────────────────────

function VimMode.handle_visual_mode(key, input_buffer, cursor_pos)
    -- ESC to return to normal mode
    if key == "\x1b" then
        current_mode = VimMode.MODES.NORMAL
        return {action = "exit_visual"}
    end

    -- Movement keys
    local movement = {
        h = "cursor_left",
        l = "cursor_right",
        ["0"] = "cursor_home",
        ["$"] = "cursor_end",
        w = "word_forward",
        b = "word_backward",
    }

    if movement[key] then
        return {action = movement[key], extend_selection = true}
    end

    -- Operations on selection
    if key == "d" then
        current_mode = VimMode.MODES.NORMAL
        return {action = "delete_selection"}
    elseif key == "y" then
        current_mode = VimMode.MODES.NORMAL
        return {action = "yank_selection"}
    end

    return nil
end

-- ── Command Mode ──────────────────────────────────────────────────────

function VimMode.handle_command_mode(key, input_buffer, cursor_pos)
    -- ESC to return to normal mode
    if key == "\x1b" then
        current_mode = VimMode.MODES.NORMAL
        return {action = "exit_command"}
    end

    -- Enter to execute command
    if key == "\r" or key == "\n" then
        current_mode = VimMode.MODES.NORMAL
        return {action = "execute_command", command = input_buffer}
    end

    -- All other keys are input to command buffer
    return {action = "command_input", char = key}
end

-- ── Status Line ───────────────────────────────────────────────────────

function VimMode.get_status_line()
    if not VimMode.is_enabled() then
        return ""
    end

    local mode_display = {
        [VimMode.MODES.NORMAL] = "NORMAL",
        [VimMode.MODES.INSERT] = "INSERT",
        [VimMode.MODES.VISUAL] = "VISUAL",
        [VimMode.MODES.COMMAND] = "COMMAND",
    }

    local mode_color = {
        [VimMode.MODES.NORMAL] = "\x1b[44m", -- Blue background
        [VimMode.MODES.INSERT] = "\x1b[42m", -- Green background
        [VimMode.MODES.VISUAL] = "\x1b[45m", -- Magenta background
        [VimMode.MODES.COMMAND] = "\x1b[43m", -- Yellow background
    }

    local color = mode_color[current_mode] or "\x1b[47m"
    local display = mode_display[current_mode] or "UNKNOWN"

    return string.format("%s\x1b[30m -- %s -- \x1b[0m", color, display)
end

return VimMode
