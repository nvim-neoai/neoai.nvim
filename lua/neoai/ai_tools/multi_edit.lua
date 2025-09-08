local M = {}

local utils = require("neoai.ai_tools.utils")

-- State to hold original content of the buffer being edited.
local active_edit_state = {}

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
  name = "MultiEdit",
  description = utils.read_description("multi_edit"),
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

local function split_lines(str)
  return vim.split(str, "\n", { plain = true })
end

-- Normalise Windows line endings in-place (strip trailing \r)
local function strip_cr(lines)
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("\r$", "")
  end
end

-- Normalise Windows line endings in a single string
local function normalise_eol(s)
  return (s or ""):gsub("\r\n", "\n"):gsub("\r", "")
end

-- Create a unified diff text using Neovim's builtin diff
local function unified_diff(old_lines, new_lines)
  local old_str = table.concat(old_lines or {}, "\n")
  local new_str = table.concat(new_lines or {}, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local diff = vim.diff(old_str, new_str, { result_type = "unified", algorithm = "histogram" })
  return diff or "(no changes)"
end

-- Finds the location of a block of search_lines within buffer_lines.
-- @param buffer_lines table: The lines of the entire file.
-- @param search_lines table: The lines of the block to search for.
-- @param start_hint integer|nil: The suggested start line for the search.
-- @param end_hint integer|nil: The suggested end line for the search.
-- @return integer|nil, integer|nil: The start and end lines of the match, or nil, nil.
local function find_block_location(buffer_lines, search_lines, start_hint, end_hint)
  if #search_lines == 0 then
    return nil, nil
  end

  local function find_match(lines_to_search, start_idx, end_idx)
    for i = start_idx, end_idx - #search_lines + 1 do
      local is_match = true
      for j = 1, #search_lines do
        -- Use a whitespace-insensitive comparison for robustness
        if lines_to_search[i + j - 1]:match("^%s*(.-)%s*$") ~= search_lines[j]:match("^%s*(.-)%s*$") then
          is_match = false
          break
        end
      end
      if is_match then
        return i, i + #search_lines - 1
      end
    end
    return nil, nil
  end

  -- 1. Try searching within the hinted range first.
  if start_hint then
    local s, e = find_match(buffer_lines, start_hint, end_hint or #buffer_lines)
    if s then
      return s, e
    end
  end

  -- 2. If that fails or no hint was given, search the entire file.
  local s, e = find_match(buffer_lines, 1, #buffer_lines)
  if s then
    return s, e
  end

  -- 3. If all else fails, return nil.
  return nil, nil
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
  local working_content = table.concat(orig_lines, "\n")

  local total_replacements = 0

  -- Plan the edits:
  local planned_edits = {}
  for i, edit in ipairs(edits) do
    local old_lines = split_lines(normalise_eol(edit.old_string))
    strip_cr(old_lines)

    local start_line, end_line = find_block_location(orig_lines, old_lines, edit.start_line, edit.end_line)

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

  -- Apply edits in reverse order:
  table.sort(planned_edits, function(a, b)
    return a.start_line > b.start_line
  end)

  local working_lines = vim.deepcopy(orig_lines)
  local total_replacements = 0

  for _, planned_edit in ipairs(planned_edits) do
    -- Replace the lines for the matched block
    table.remove(working_lines, planned_edit.start_line, planned_edit.end_line - planned_edit.start_line + 1)
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
