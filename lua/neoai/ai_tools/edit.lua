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

--- Converts a line range to a byte offset range within a string.
---@param content_lines table The original content as a table of lines.
---@param start_line integer The 1-based start line of the block.
---@param end_line integer The 1-based end line of the block.
---@return integer, integer The 1-based start and end byte offsets.
local function convert_lines_to_offsets(content_lines, start_line, end_line)
  local start_offset = 1
  for i = 1, start_line - 1 do
    start_offset = start_offset + #content_lines[i] + 1 -- +1 for the newline character
  end

  local end_offset = start_offset - 1 -- Start from the beginning of the start_line content
  for i = start_line, end_line do
    end_offset = end_offset + #content_lines[i] + 1 -- +1 for the newline character
  end

  -- For insertions (end_line < start_line), the end_offset should be one less than start_offset,
  -- indicating a zero-length replacement.
  if end_line < start_line then
    return start_offset, start_offset - 1
  end

  return start_offset, end_offset
end

--- Generates a detailed report for why a find operation failed.
---@param edit table The edit operation that failed.
---@param orig_lines table The original lines of the buffer.
---@param edit_index integer The index of the failing edit.
---@return string A formatted string for logging.
local function generate_failure_report(edit, orig_lines, edit_index)
  local report_parts = {
    string.format("--- FIND FAILURE REPORT (Edit #%d) ---", edit_index),
    "The 'old_string' provided by the AI could not be found.",
    "\n[SEARCH BLOCK PROVIDED BY AI]",
    "--------------------------------",
    edit.old_string,
    "--------------------------------",
  }

  if edit.start_line and edit.end_line then
    table.insert(
      report_parts,
      string.format("\nAI hinted to search between lines %d and %d.", edit.start_line, edit.end_line)
    )

    local actual_lines_at_hint = {}
    if edit.start_line > #orig_lines then
      table.insert(report_parts, "The hinted start line is beyond the end of the file.")
    else
      local start_l = math.max(1, edit.start_line)
      local end_l = math.min(#orig_lines, edit.end_line)
      for i = start_l, end_l do
        table.insert(actual_lines_at_hint, orig_lines[i])
      end

      table.insert(report_parts, "\n[ACTUAL CONTENT AT HINTED LOCATION]")
      table.insert(report_parts, "--------------------------------")
      table.insert(report_parts, table.concat(actual_lines_at_hint, "\n"))
      table.insert(report_parts, "--------------------------------")

      local old_lines_for_diff = split_lines(normalise_eol(edit.old_string))
      strip_cr(old_lines_for_diff)
      local diff_text = unified_diff(old_lines_for_diff, actual_lines_at_hint)

      table.insert(report_parts, "\n[DIFF (AI Search Block vs Actual Content)]")
      table.insert(report_parts, "--------------------------------")
      table.insert(report_parts, diff_text)
      table.insert(report_parts, "--------------------------------")
    end
  else
    table.insert(report_parts, "\nAI provided no line number hints for this edit.")
  end

  table.insert(report_parts, "--- END REPORT ---")
  return table.concat(report_parts, "\n")
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

  local original_content_str = normalise_eol(content)
  local orig_lines = split_lines(original_content_str)
  strip_cr(orig_lines) -- Strip CR just for finder, original_content_str keeps \n

  -- NEW: Order-invariant algorithm using byte offsets
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
      -- NEW: Generate and log a detailed failure report
      local report = generate_failure_report(edit, orig_lines, i)
      vim.notify(report, vim.log.levels.WARN, { title = "NeoAI Edit Failure" })

      return string.format(
        "Edit %d: Could not find a matching block for 'old_string'. See Neovim messages for a detailed failure report.",
        i
      )
    end

    -- Convert line range to byte offsets in the original content string
    local start_offset, end_offset = convert_lines_to_offsets(orig_lines, start_line, end_line)

    -- Normalise new_string and handle indentation
    local new_lines = split_lines(normalise_eol(edit.new_string))
    strip_cr(new_lines)

    local indent = ""
    if start_line > 0 and start_line <= #orig_lines then
      indent = orig_lines[start_line]:match("^%s*") or ""
    end

    local adjusted_new_lines = {}
    for _, line in ipairs(new_lines) do
      if line:match("%S") then
        table.insert(adjusted_new_lines, indent .. line)
      else
        table.insert(adjusted_new_lines, "")
      end
    end
    local final_new_string = table.concat(adjusted_new_lines, "\n")

    table.insert(planned_edits, {
      start_offset = start_offset,
      end_offset = end_offset,
      new_string = final_new_string,
    })
  end

  if #planned_edits == 0 then
    return string.format("No replacements made in %s.", rel_path)
  end

  -- Sort edits by start offset, making them order-invariant
  table.sort(planned_edits, function(a, b)
    return a.start_offset < b.start_offset
  end)

  -- Rebuild the file from scratch using the sorted, offset-based edits
  local result_parts = {}
  local last_pos = 1
  for _, planned_edit in ipairs(planned_edits) do
    -- Safety check for overlapping edits, which are ambiguous.
    if planned_edit.start_offset < last_pos then
      return string.format(
        "Edit application failed: An overlapping edit was detected. The AI tried to modify the same piece of code twice. Please review the request."
      )
    end

    -- Add the slice of original content before this edit
    table.insert(result_parts, original_content_str:sub(last_pos, planned_edit.start_offset - 1))
    -- Add the new content for this edit
    table.insert(result_parts, planned_edit.new_string)
    -- Move the cursor past the replaced section
    last_pos = planned_edit.end_offset + 1
  end
  -- Add any remaining content from the end of the original file
  table.insert(result_parts, original_content_str:sub(last_pos))

  local updated_content = table.concat(result_parts)
  local updated_lines = split_lines(updated_content)

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
      summary = string.format("Applied %d replacement(s) to %s (auto-approved, headless)", #planned_edits, rel_path)
    else
      summary = string.format("Created %s with %d replacement(s) (auto-approved, headless)", #planned_edits, rel_path)
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
