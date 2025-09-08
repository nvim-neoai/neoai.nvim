local utils = require("neoai.ai_tools.utils")
-- The finder module now handles all search logic.
local finder = require("neoai.ai_tools.utils.find")

local M = {}

-- State to hold original content of the buffer being edited.
local active_edit_state = {}

--[[
  UTILITY FUNCTIONS
--]]

--- Split a string into lines.
---@param str string: The input string.
---@return table: A table containing the split lines.
local function split_lines(str)
  -- Use vim.split for consistency with Neovim's line handling.
  return vim.split(str, "\n", { plain = true })
end

---@param s string: The input string.
---@return string: The string with normalised line endings.
local function normalise_eol(s)
  -- Ensure all line endings are just '\n' for consistent processing.
  return (s or ""):gsub("\r\n", "\n"):gsub("\r", "")
end

-- Normalise Windows line endings in-place (strip trailing \r)
--- Strip carriage return characters from each line.
---@param lines table: A table of strings.
local function strip_cr(lines)
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("\r$", "")
  end
end

-- Create a unified diff text using Neovim's builtin diff
--- Create a unified diff between two sets of lines.
---@param old_lines table: The original lines.
---@param new_lines table: The modified lines.
---@return string: A string representing the unified diff.
local function unified_diff(old_lines, new_lines)
  local old_str = table.concat(old_lines or {}, "\n")
  local new_str = table.concat(new_lines or {}, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local diff = vim.diff(old_str, new_str, { result_type = "unified", algorithm = "histogram" })
  return diff or "(no changes)"
end

-- This function is called from chat.lua to close an open diffview window.
--- Discard all diffs and revert buffer changes.
---@return string: A status message.
function M.discard_all_diffs()
  -- 1. Attempt to close the diff UI.
  local ok, diff_utils = pcall(require, "neoai.ai_tools.utils")
  if ok and diff_utils and diff_utils.inline_diff and diff_utils.inline_diff.close then
    diff_utils.inline_diff.close()
  end

  -- 2. Restore the buffer content from our saved state.
  local bufnr = active_edit_state.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, active_edit_state.original_lines)
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
  end

  -- 3. Clear the state to prevent accidental reuse.
  active_edit_state = {}

  return "All pending edits discarded and buffer reverted."
end

M.meta = {
  name = "Edit",
  description = utils.read_description("edit"),
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format("The path of the file to modify or create (relative to cwd %s)", vim.fn.getcwd()),
      },
      ensure_dir = {
        type = "boolean",
        description = "Create parent directories if they do not exist (default: true)",
      },
      edits = {
        type = "array",
        description = "Array of edit operations, each containing old_string, new_string, and optional line range",
        items = {
          type = "object",
          properties = {
            old_string = {
              type = "string",
              description = "Exact text to replace (empty string means insert at beginning of file)",
            },
            new_string = { type = "string", description = "The replacement text" },
            start_line = { type = "integer", description = "(Optional) Start line number for this edit (1-based)" },
            end_line = { type = "integer", description = "(Optional) End line number for this edit (1-based)" },
          },
          required = { "old_string", "new_string" },
        },
      },
    },
    required = { "file_path", "edits" },
    additionalProperties = false,
  },
}

--- Validate an edit operation.
---@param edit table: The edit operation.
---@param index integer: The index of the edit operation.
---@return string|nil: An error message if validation fails, otherwise nil.
local function validate_edit(edit, index)
  if type(edit.old_string) ~= "string" then
    return string.format("Edit %d: 'old_string' must be a string", index)
  end
  if type(edit.new_string) ~= "string" then
    return string.format("Edit %d: 'new_string' must be a string", index)
  end
  if edit.start_line ~= nil and type(edit.start_line) ~= "number" then
    return string.format("Edit %d: 'start_line' must be a number", index)
  end
  if edit.end_line ~= nil and type(edit.end_line) ~= "number" then
    return string.format("Edit %d: 'end_line' must be a number", index)
  end
  if edit.start_line and edit.end_line and edit.start_line > edit.end_line then
    return string.format("Edit %d: 'start_line' must be <= 'end_line'", index)
  end
  return nil
end

--- Execute the edit operations on a file.
---@param args table: A table containing the file path and edits.
---@return string: A status message.
M.run = function(args)
  local rel_path = args.file_path
  local edits = args.edits

  if type(rel_path) ~= "string" then
    return "file_path must be a string"
  end
  if type(edits) ~= "table" then
    return "edits must be an array"
  end

  for i, edit in ipairs(edits) do
    local err = validate_edit(edit, i)
    if err then
      return err
    end
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. rel_path

  local content
  local file_exists = false
  local bufnr_from_list
  do
    local target = vim.fn.fnamemodify(abs_path, ":p")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if vim.fn.fnamemodify(name, ":p") == target then
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          content = table.concat(lines, "\n")
          file_exists = true
          bufnr_from_list = b
          break
        end
      end
    end
    if content == nil then
      local file = io.open(abs_path, "r")
      if file then
        file_exists = true
        content = file:read("*a") or ""
        file:close()
      else
        content = ""
      end
    end
  end

  content = normalise_eol(content)
  local orig_lines = split_lines(content)
  strip_cr(orig_lines)

  local planned_edits = {}
  for i, edit in ipairs(edits) do
    local old_lines = split_lines(normalise_eol(edit.old_string))
    strip_cr(old_lines)

    local start_line, end_line
    if #old_lines == 0 then
      -- Per description: "empty string means insert at beginning of file"
      start_line = 1
      end_line = 0 -- This means we replace 0 lines before line 1.
    else
      start_line, end_line = finder.find_block_location(orig_lines, old_lines, edit.start_line, edit.end_line)
    end

    if not start_line then
      return string.format(
        "Edit %d: Could not find a matching block for 'old_string'. The code may have changed or the string is inaccurate. All matching strategies (Exact, Tree-sitter, Normalised Text) failed.",
        i
      )
    end

    local new_lines = split_lines(normalise_eol(edit.new_string))
    strip_cr(new_lines)

    local adjusted_new_lines = {}
    local indent = ""
    -- Check if the found block exists in the buffer to get its indentation.
    if start_line > 0 and start_line <= #orig_lines then
      indent = orig_lines[start_line]:match("^%s*") or ""
    end

    for _, line in ipairs(new_lines) do
      -- Only add indentation if the line is not empty.
      if line:match("%S") then
        table.insert(adjusted_new_lines, indent .. line)
      else
        table.insert(adjusted_new_lines, "")
      end
    end

    table.insert(planned_edits, {
      start_line = start_line,
      end_line = end_line,
      new_lines = adjusted_new_lines, -- Use the indentation-adjusted lines
    })
  end

  table.sort(planned_edits, function(a, b)
    return a.start_line > b.start_line
  end)

  local working_lines = vim.deepcopy(orig_lines)
  local total_replacements = 0

  for _, planned_edit in ipairs(planned_edits) do
    local num_to_remove = planned_edit.end_line - planned_edit.start_line + 1
    -- Handle insertion case where end_line < start_line
    if num_to_remove < 0 then
      num_to_remove = 0
    end

    for _ = 1, num_to_remove do
      table.remove(working_lines, planned_edit.start_line)
    end

    for i, line in ipairs(planned_edit.new_lines) do
      table.insert(working_lines, planned_edit.start_line - 1 + i, line)
    end
    total_replacements = total_replacements + 1
  end

  if total_replacements == 0 then
    return string.format("No replacements made in %s.", rel_path)
  end

  local updated_lines = working_lines

  local uis = vim.api.nvim_list_uis()
  if not uis or #uis == 0 then
    local ensure_dir = args.ensure_dir
    if ensure_dir == nil then
      ensure_dir = true
    end
    if ensure_dir then
      local dir = vim.fn.fnamemodify(abs_path, ":h")
      vim.fn.mkdir(dir, "p")
    end

    local f, ferr = io.open(abs_path, "w")
    if not f then
      return "Failed to open file for writing: " .. tostring(ferr)
    end
    f:write(table.concat(updated_lines, "\n"))
    f:close()

    local summary
    if file_exists then
      summary = string.format("Applied %d replacement(s) to %s (auto-approved, headless)", total_replacements, rel_path)
    else
      summary =
        string.format("Created %s with %d replacement(s) (auto-approved, headless)", rel_path, total_replacements)
    end
    local diff_text = unified_diff(orig_lines, updated_lines)
    local diag_tool = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = diag_tool.run({ file_path = rel_path, include_code_actions = false })
    local parts = { summary, "Applied diff:", utils.make_code_block(diff_text, "diff"), diagnostics }
    return table.concat(parts, "\n\n")
  end

  local ok, msg = utils.inline_diff.apply(abs_path, orig_lines, updated_lines)
  if ok then
    active_edit_state = {
      bufnr = bufnr_from_list or vim.fn.bufadd(abs_path),
      original_lines = orig_lines,
    }
    vim.api.nvim_command("write") -- Autosave after resolving diffs
    return msg
  else
    local ensure_dir = args.ensure_dir
    if ensure_dir == nil then
      ensure_dir = true
    end
    if ensure_dir then
      local dir = vim.fn.fnamemodify(abs_path, ":h")
      vim.fn.mkdir(dir, "p")
    end
    local f, ferr = io.open(abs_path, "w")
    if f then
      f:write(table.concat(updated_lines, "\n"))
      f:close()
      return string.format("Wrote %s (inline diff failed: %s)", rel_path, msg or "unknown error")
    end
    return msg or ("Failed to open inline diff and could not write file: " .. tostring(ferr))
  end
end

return M
