local utils = require("neoai.ai_tools.utils")
-- The finder module now handles all search logic.
local finder = require("neoai.ai_tools.utils.find")

local M = {}

-- State to hold original content of the buffer being edited.
local active_edit_state = {}

-- Accumulator for deferred, end-of-loop reviews. Keyed by absolute path.
-- Each entry: { baseline = {lines...}, latest = {lines...} }
local deferred_reviews = {}

--[[
  UTILITY FUNCTIONS (with improved indentation handling)
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

-- Compute the leading whitespace string for a given line.
local function leading_ws(s)
  return (s or ""):match("^%s*") or ""
end

-- Compute minimal indent length (in characters) among non-empty lines.
local function min_indent_len(lines)
  local min_len
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local len = #leading_ws(l)
      if not min_len or len < min_len then
        min_len = len
      end
    end
  end
  return min_len or 0
end

-- Find the line index (1-based) within a range that has the minimal indent.
local function range_min_indent_line(lines, s, e)
  local min_len, min_idx
  for i = s, math.max(s, e) do
    local l = lines[i]
    if l and l:match("%S") then
      local len = #leading_ws(l)
      if not min_len or len < min_len then
        min_len = len
        min_idx = i
      end
    end
  end
  return min_len or 0, min_idx
end

-- Remove up to `n` leading whitespace characters (spaces or tabs) from a line.
local function remove_leading_ws_chars(line, n)
  if n <= 0 then
    return line
  end
  local i, removed = 1, 0
  while removed < n and i <= #line do
    local ch = line:sub(i, i)
    if ch == " " or ch == "\t" then
      i = i + 1
      removed = removed + 1
    else
      break
    end
  end
  return line:sub(i)
end

-- Dedent lines by their minimal common indentation while preserving relative indentation.
local function dedent(lines)
  local n = min_indent_len(lines)
  if n <= 0 then
    return vim.deepcopy(lines)
  end
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("%S") then
      out[i] = remove_leading_ws_chars(l, n)
    else
      out[i] = ""
    end
  end
  return out
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
      interactive_review = {
        type = "boolean",
        description = "When false, never open the inline diff UI (even if a UI is present). Apply changes headlessly and return the diff and diagnostics markers. Useful for iterative edit+diagnostic loops to defer user review until the end.",
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
  local force_headless = (args and args.interactive_review == false) or false

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

    -- Determine the base indent from the smallest-indented non-empty line in the matched range.
    local base_indent = ""
    if start_line and end_line and start_line >= 1 and end_line >= start_line then
      local _, idx = range_min_indent_line(working_lines, start_line, end_line)
      if idx and working_lines[idx] then
        base_indent = leading_ws(working_lines[idx])
      else
        base_indent = leading_ws(working_lines[start_line] or "")
      end
    else
      base_indent = leading_ws(working_lines[start_line] or "")
    end

    -- Dedent the incoming new_lines by their minimal common indentation,
    -- then re-indent them with the base indent derived from the context.
    local adjusted_new_lines = {}
    local dedented = dedent(new_lines)
    for k, line in ipairs(dedented) do
      if line:match("%S") then
        adjusted_new_lines[k] = base_indent .. line
      else
        adjusted_new_lines[k] = ""
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

  -- Update the deferred review accumulator for this file (baseline preserved from first edit)
  do
    local entry = deferred_reviews[abs_path]
    if entry == nil then
      deferred_reviews[abs_path] = { baseline = vim.deepcopy(orig_lines), latest = vim.deepcopy(updated_lines) }
    else
      entry.latest = vim.deepcopy(updated_lines)
      deferred_reviews[abs_path] = entry
    end
  end

  -- Decide whether to show the interactive inline diff or apply headlessly.
  local uis = vim.api.nvim_list_uis()
  if force_headless or not uis or #uis == 0 then
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
    local lsp_diag = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = lsp_diag.run({ file_path = abs_path, include_code_actions = false })

    -- Compute a simple hash of the unified diff for orchestration
    local function simple_hash(s)
      s = s or ""
      local h1, h2 = 0, 0
      for i = 1, #s do
        local b = string.byte(s, i)
        h1 = (h1 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
      end
      return string.format("%08x%08x_%d", h1, h2, #s)
    end
    local diff_hash = simple_hash(diff_text)

    -- In headless, wait for diagnostics to publish and then get the count
    local diag_count = 0
    pcall(lsp_diag.await_count, { file_path = abs_path, timeout_ms = 1500 })
    local b = vim.fn.bufnr(abs_path, true)
    if b > 0 then
      pcall(vim.fn.bufload, b)
      diag_count = #vim.diagnostic.get(b)
    end

    local parts = {
      summary,
      "Applied diff:",
      utils.make_code_block(diff_text, "diff"),
      diagnostics,
      string.format("NeoAI-Diff-Hash: %s", diff_hash),
      string.format("NeoAI-Diagnostics-Count: %d", diag_count),
    }
    return table.concat(parts, "\n\n")
  end

  local ok, msg = utils.inline_diff.apply(abs_path, orig_lines, updated_lines)
  if ok then
    active_edit_state = {
      bufnr = bufnr_from_list or vim.fn.bufadd(abs_path),
      original_lines = orig_lines,
    }

    -- Run diagnostics immediately and include a unified diff so the AI can self-correct before user review.
    local diff_text = unified_diff(orig_lines, updated_lines)
    local lsp_diag = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = lsp_diag.run({ file_path = abs_path, include_code_actions = false })

    -- Compute diagnostics count on the target buffer (reflecting patched content)
    local diag_count = 0
    local target_buf = active_edit_state.bufnr
    if target_buf then
      pcall(lsp_diag.await_count, { bufnr = target_buf, timeout_ms = 1500 })
      if vim.api.nvim_buf_is_loaded(target_buf) then
        diag_count = #vim.diagnostic.get(target_buf)
      end
    end

    -- Provide machine-readable markers for the orchestrator
    local function simple_hash(s)
      s = s or ""
      local h1, h2 = 0, 0
      for i = 1, #s do
        local b = string.byte(s, i)
        h1 = (h1 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
      end
      return string.format("%08x%08x_%d", h1, h2, #s)
    end
    local diff_hash = simple_hash(diff_text)

    local parts = {
      msg,
      "Applied diff:",
      utils.make_code_block(diff_text, "diff"),
      diagnostics,
      string.format("NeoAI-Diff-Hash: %s", diff_hash),
      string.format("NeoAI-Diagnostics-Count: %d", diag_count),
    }
    -- Do not autosave here; wait for the user to review and write or cancel in the inline diff UI.
    return table.concat(parts, "\n\n")
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
--- Open an accumulated, deferred inline diff review for the given file.
--- Shows a single review comparing the original baseline (before the first edit in the loop)
--- to the latest content after the AI's iterations.
---@param file_path string: Relative or absolute path to the file
---@return boolean, string
function M.open_deferred_review(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return false, "Invalid file path"
  end
  local abs_path = file_path
  if not abs_path:match("^/") and not abs_path:match("^%a:[/\\]") then
    abs_path = vim.fn.getcwd() .. "/" .. file_path
  end
  local entry = deferred_reviews[abs_path]
  if not entry or not entry.baseline or not entry.latest then
    return false, "No pending deferred review for this file"
  end

  -- If there are no differences, do not open the UI.
  local function lines_equal(a, b)
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if a[i] ~= b[i] then
        return false
      end
    end
    return true
  end
  if lines_equal(entry.baseline, entry.latest) then
    deferred_reviews[abs_path] = nil
    return false, "No changes to review"
  end

  local ok, msg = utils.inline_diff.apply(abs_path, entry.baseline, entry.latest)
  if ok then
    -- Prepare discard support: allow reverting to baseline if requested
    active_edit_state = {
      bufnr = vim.fn.bufadd(abs_path),
      original_lines = entry.baseline,
    }
    -- Clear the accumulator now that the review is open
    deferred_reviews[abs_path] = nil
  end
  return ok, msg
end

--- Clear any stored deferred review for a file (if present).
---@param file_path string
function M.clear_deferred_review(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return
  end
  local abs_path = file_path
  if not abs_path:match("^/") and not abs_path:match("^%a:[/\\]") then
    abs_path = vim.fn.getcwd() .. "/" .. file_path
  end
  deferred_reviews[abs_path] = nil
end

return M
