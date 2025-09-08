local M = {}

local utils = require("neoai.ai_tools.utils")

-- State to hold original content of the buffer being edited.
local active_edit_state = {}

--[[
  UTILITY FUNCTIONS
  Moved to the top of the file to be available for all subsequent functions.
--]]

local function split_lines(str)
  -- Use vim.split for consistency with Neovim's line handling.
  return vim.split(str, "\n", { plain = true })
end

local function normalise_eol(s)
  -- Ensure all line endings are just '\n' for consistent processing.
  return (s or ""):gsub("\r\n", "\n"):gsub("\r", "")
end

-- Normalise Windows line endings in-place (strip trailing \r)
local function strip_cr(lines)
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("\r$", "")
  end
end

-- Create a unified diff text using Neovim's builtin diff
local function unified_diff(old_lines, new_lines)
  local old_str = table.concat(old_lines or {}, "\n")
  local new_str = table.concat(new_lines or {}, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local diff = vim.diff(old_str, new_str, { result_type = "unified", algorithm = "histogram" })
  return diff or "(no changes)"
end

-- This function is called from chat.lua to close an open diffview window.
-- CORRECTED: Now fully reverts buffer content to its original state.
function M.discard_all_diffs()
  -- 1. Attempt to close the diff UI.
  local ok, diff_utils = pcall(require, "neoai.ai_tools.utils")
  if ok and diff_utils and diff_utils.inline_diff and diff_utils.inline_diff.close then
    diff_utils.inline_diff.close()
  end

  -- 2. Restore the buffer content from our saved state.
  local bufnr = active_edit_state.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    -- Overwrite the entire buffer with the original lines.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, active_edit_state.original_lines)
    -- After reverting, tell Neovim the buffer is no longer "modified".
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

-- Enhanced function to find the location of a block in buffer_lines with fuzzy matching
local function find_fuzzy_block_location(buffer_lines, block, start_hint, end_hint)
  local old_lines = block.old_lines

  -- Helper function to calculate a simple similarity score between two strings
  local function similarity_score(str1, str2)
    str1, str2 = str1:gsub("%s+", ""), str2:gsub("%s+", "") -- Ignore spaces for similarity
    if #str1 < #str2 then
      str1, str2 = str2, str1
    end -- Ensure str1 is longer

    -- Calculate Levenshtein distance
    local costs = {}
    for i = 0, #str1 do
      costs[i] = i
    end
    for j = 0, #str2 do
      local last_value = j
      for i = 0, #str1 do
        if i == 0 then
          costs[i] = j
        else
          local new_value = costs[i - 1]
          if str1:sub(i, i) ~= str2:sub(j, j) then
            new_value = math.min(math.min(new_value, last_value), costs[i]) + 1
          end
          costs[i - 1] = last_value
          last_value = new_value
        end
      end
      if j > 0 then
        costs[#str1] = last_value
      end
    end
    return costs[#str1]
  end

  local function find_fuzzy_match(search_lines, starting_idx, ending_idx)
    for idx = starting_idx, (ending_idx - #search_lines + 1) do
      local total_difference = 0
      local match_threshold = 2 -- Allow up to a small number of differences per line

      for j = 1, #search_lines do
        local diff =
          similarity_score(buffer_lines[idx + j - 1]:match("^%s*(.-)%s*$"), search_lines[j]:match("^%s*(.-)%s*$"))
        if diff > match_threshold then
          total_difference = total_difference + 1
          if total_difference > match_threshold then
            break
          end
        end
      end

      if total_difference <= match_threshold then
        return idx, idx + #search_lines - 1
      end
    end

    return nil, nil
  end

  if start_hint ~= nil then
    local start_idx, end_idx = find_fuzzy_match(old_lines, start_hint, end_hint or #buffer_lines)
    if start_idx then
      return start_idx, end_idx
    end
  end

  return find_fuzzy_match(old_lines, 1, #buffer_lines)
end

-- CORRECTED: Now saves the original buffer state before applying the diff.
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

  -- Prefer current buffer content if the file is loaded (avoids mismatch with unsaved changes)
  local content
  local file_exists = false
  local bufnr_from_list -- We'll capture the buffer number here if found
  do
    local target = vim.fn.fnamemodify(abs_path, ":p")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if vim.fn.fnamemodify(name, ":p") == target then
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          content = table.concat(lines, "\n")
          file_exists = true
          bufnr_from_list = b -- Capture it
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

  -- Normalise for consistent matching across platforms
  content = normalise_eol(content)

  -- Prepare original and working lines (strip CR to avoid Windows EOL mismatch)
  local orig_lines = split_lines(content)
  strip_cr(orig_lines)

  --[[
    REMOVED: This entire block was buggy and redundant.
    1. It unsafely modified the `planned_edits` table while iterating over it.
    2. It was immediately discarded by `local planned_edits = {}` on the next line.
    The correct logic is handled by the loop that follows.
  --]]

  local planned_edits = {}
  for i, edit in ipairs(edits) do
    local old_lines = split_lines(normalise_eol(edit.old_string))
    strip_cr(old_lines)

    local start_line, end_line = find_fuzzy_block_location(orig_lines, {
      old_lines = old_lines,
      new_lines = {}, -- Placeholder for new lines
    }, edit.start_line, edit.end_line)

    if not start_line then
      return string.format(
        "Edit %d: Could not find a matching block for 'old_string'. The code may have changed or the string is inaccurate.",
        i
      )
    end

    local new_lines = split_lines(normalise_eol(edit.new_string))
    strip_cr(new_lines)

    table.insert(planned_edits, {
      start_line = start_line,
      end_line = end_line,
      new_lines = new_lines,
    })
  end

  -- Apply edits in reverse order to avoid line number shifts
  table.sort(planned_edits, function(a, b)
    return a.start_line > b.start_line
  end)

  local working_lines = vim.deepcopy(orig_lines)
  local total_replacements = 0

  for _, planned_edit in ipairs(planned_edits) do
    -- CORRECTED: Replace the lines for the matched block.
    -- The standard `table.remove` only accepts a single position, so we must
    -- loop to remove a range of lines.
    local num_to_remove = planned_edit.end_line - planned_edit.start_line + 1
    for _ = 1, num_to_remove do
      table.remove(working_lines, planned_edit.start_line)
    end

    -- Insert the new lines at the now-empty position.
    for i, line in ipairs(planned_edit.new_lines) do
      table.insert(working_lines, planned_edit.start_line - 1 + i, line)
    end
    total_replacements = total_replacements + 1
  end

  if total_replacements == 0 then
    return string.format("No replacements made in %s.", rel_path)
  end

  -- The 'working_lines' table now holds the fully modified content.
  local updated_lines = working_lines

  -- If headless (no UI), auto-apply and return summary + diff + diagnostics.
  local uis = vim.api.nvim_list_uis()
  if not uis or #uis == 0 then
    -- Ensure parent directory if requested
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

  -- UI mode: open an interactive inline diff with accept/reject controls
  local ok, msg = utils.inline_diff.apply(abs_path, orig_lines, updated_lines)
  if ok then
    -- SUCCESS: The diff is open. Now we save the state needed to revert.
    active_edit_state = {
      -- Find the buffer for the file path, creating it if it doesn't exist.
      bufnr = bufnr_from_list or vim.fn.bufadd(abs_path),
      original_lines = orig_lines,
    }
    return msg
  else
    -- If diff cannot open (e.g. new file), ensure dirs and write directly as a fallback
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
