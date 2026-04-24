-- tools/notebook_edit.lua — NotebookEditTool: Edit Jupyter notebook cells
-- Parses .ipynb JSON format and modifies cells in place.

local json = require("utils.json_fallback")

local M = {}
M.name = "NotebookEdit"
M.description = "Edit a Jupyter notebook cell. Modifies the source of a specific cell by index."

M.parameters = {
    type = "object",
    properties = {
        notebook_path = { type = "string", description = "Path to the .ipynb notebook file" },
        cell_number = { type = "integer", description = "Cell index (0-based)" },
        new_source = { type = "string", description = "New source content for the cell" },
        cell_type = { type = "string", description = "Cell type: 'code' or 'markdown' (optional, keeps existing)" },
    },
    required = { "notebook_path", "cell_number", "new_source" }
}

function M.is_enabled() return true end
function M.is_read_only() return false end
function M.user_facing_name(input) return "NotebookEdit" end
function M.check_permissions() return { allowed = true } end

function M.call(args, ctx)
    local path = args.notebook_path
    if not path then return { type = "error", error = "No notebook path provided" } end

    -- Read notebook
    local f = io.open(path, "r")
    if not f then return { type = "error", error = "Cannot open: " .. path } end
    local content = f:read("*a")
    f:close()

    local ok, notebook = pcall(json.parse, content)
    if not ok or not notebook then
        return { type = "error", error = "Failed to parse notebook JSON" }
    end

    -- Get cells array
    local cells = notebook.cells
    if not cells then
        return { type = "error", error = "No cells found in notebook" }
    end

    -- Find the cell (0-based index)
    local idx = args.cell_number + 1 -- Convert to 1-based
    if idx < 1 or idx > #cells then
        return { type = "error", error = string.format("Cell index %d out of range (0-%d)", args.cell_number, #cells - 1) }
    end

    -- Update cell source
    -- Notebook source is an array of lines
    local lines = {}
    for line in (args.new_source .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line .. "\n")
    end
    -- Remove trailing newline from last line
    if #lines > 0 then
        lines[#lines] = lines[#lines]:gsub("\n$", "")
    end

    cells[idx].source = lines

    -- Update cell type if specified
    if args.cell_type then
        cells[idx].cell_type = args.cell_type
    end

    -- Clear outputs for code cells
    if cells[idx].cell_type == "code" then
        cells[idx].outputs = {}
        cells[idx].execution_count = nil
    end

    -- Write back
    local json_str = json.stringify_pretty(notebook)
    f = io.open(path, "w")
    if not f then return { type = "error", error = "Cannot write: " .. path } end
    f:write(json_str)
    f:close()

    return {
        type = "text",
        text = string.format("Updated cell %d in %s", args.cell_number, path),
    }
end

return M
