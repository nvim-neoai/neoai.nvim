local utils = require("neoai.ai_tools.utils")
-- The finder module now handles all search logic.
local finder = require("neoai.ai_tools.utils.find")

local M = {}

-- State to hold original content of the buffer being edited.
local active_edit_state = {}

--[[
  UTILITY FUNCTIONS (unchanged)
--]]
local function split_lines(str)
  return vim.split(str, "\n", { plain = true })
end

local function normalise_eol(s)
  return (s or ""):gsub("\r\n", "\n"):gsub("\r", "")
end

local function strip_cr(lines)
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("\r$", "")
  end
end

local function unified_diff(old_lines, new_lines)
  local old_str = table.concat(old_lines or {}, "\n")
  local new_str = table.concat(new_lines or {}, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local diff = vim.diff(old_str, new_str, { result_type = "unified", algorithm = "histogram" })
  return diff or "(no changes)"
end

-- This function is called from chat.lua to close an open diffview window.
function M.discard_all_diffs()
  -- ... (function is unchanged)
  local ok, diff_utils = pcall(require, "neoai.ai_tools.utils")
  if ok and diff_utils and diff_utils.inline_diff and diff_utils.inline_diff.close then
    diff_utils.inline_diff.close()
  end
  local bufnr = active_edit_state.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, active_edit_state.original_lines)
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
  end
  active_edit_state = {}
  return "All pending edits discarded and buffer reverted."
end

-- NEW: Simplified schema. No more line numbers from the AI.
M.meta = {
  name = "Edit",
  description = utils.read_description("edit")
    .. " The 'edits' should be provided in the order they appear in the file.",
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
        description = "Array of edit operations, each containing old_string and new_string. MUST be in file order.",
        items = {
          type = "object",
          properties = {
            old_string = {
              type = "string",
              description = "Exact text to replace (empty string means insert at beginning of file)",
            },
            new_string = { type = "string", description = "The replacement text" },
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

  local orig_lines = split_lines(normalise_eol(content))
  strip_cr(orig_lines)

  -- NEW: Stateful, sequential application logic
  local working_lines = vim.deepcopy(orig_lines)
  local search_start_line = 1 -- Our "bookmark" for where to start the next search
  local total_replacements = 0

  for i, edit in ipairs(edits) do
    local old_lines = split_lines(normalise_eol(edit.old_string))
    strip_cr(old_lines)

    local start_line, end_line
    if #old_lines == 0 then
      start_line, end_line = 1, 0
    else
      -- Use the bookmark to hint the finder where to start looking
      start_line, end_line = finder.find_block_location(working_lines, old_lines, search_start_line, nil)
    end

    if not start_line then
      -- Since we now assume in-order edits, a failure to find is a critical error.
      return string.format(
        "Edit %d: Could not find a matching block for 'old_string' starting from line %d. The AI may have provided edits out of order or the code has changed.",
        i,
        search_start_line
      )
    end

    -- Apply the edit to the working copy of the lines
    local new_lines = split_lines(normalise_eol(edit.new_string))
    strip_cr(new_lines)

    local indent = ""
    if start_line > 0 and start_line <= #working_lines then
      indent = working_lines[start_line]:match("^%s*") or ""
    end

    local adjusted_new_lines = {}
    for _, line in ipairs(new_lines) do
      if line:match("%S") then
        table.insert(adjusted_new_lines, indent .. line)
      else
        table.insert(adjusted_new_lines, "")
      end
    end

    -- Perform the replacement on the working_lines table
    local num_to_remove = end_line - start_line + 1
    if num_to_remove < 0 then
      num_to_remove = 0
    end

    for _ = 1, num_to_remove do
      table.remove(working_lines, start_line)
    end

    for j, line in ipairs(adjusted_new_lines) do
      table.insert(working_lines, start_line - 1 + j, line)
    end

    total_replacements = total_replacements + 1

    -- CRITICAL: Update the bookmark for the next search.
    -- It's the line where the edit started plus the number of lines we added.
    search_start_line = start_line + #adjusted_new_lines
  end

  if total_replacements == 0 then
    return string.format("No replacements made in %s.", rel_path)
  end

  local updated_lines = working_lines

  -- The rest of the file (UI, writing to disk) is unchanged...
  local uis = vim.api.nvim_list_uis()
  if not uis or #uis == 0 then
    -- ... headless logic
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
    -- Do not autosave here; wait for the user to review and write or cancel in the inline diff UI.
    return msg
  else
    -- ... fallback write logic
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
