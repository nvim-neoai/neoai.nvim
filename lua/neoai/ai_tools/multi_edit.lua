local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "GitDiffEdit",
  description = [[
Git-diff style file editing tool that shows changes in a familiar diff format.
Provides context around changes and uses git-like syntax for modifications.

Edit types:
- add: Add new lines (shown as +line)
- remove: Remove existing lines (shown as -line)
- change: Replace existing content (shown as -old_line +new_line)

The tool shows context around changes similar to `git diff` output, making it easier
to understand what's being modified. Each edit specifies:
- The target line number in the original file
- The operation type (add/remove/change)
- The content being added or changed
- Context lines around the change for clarity

Line numbers refer to the original file state. All edits are applied atomically.
]],
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format("The path of the file to modify (relative to cwd %s)", vim.fn.getcwd()),
      },
      edits = {
        type = "array",
        description = "Array of git-diff style edits",
        items = {
          type = "object",
          properties = {
            type = {
              type = "string",
              enum = { "add", "remove", "change" },
              description = "Type of operation: 'add', 'remove', or 'change'",
            },
            line_number = {
              type = "number",
              description = "1-based line number in original file where change occurs",
            },
            content = {
              type = "string",
              description = "New content to add (for 'add' and 'change' operations)",
            },
            old_content = {
              type = "string",
              description = "Expected old content (for 'change' and 'remove' - used for verification)",
            },
          },
          required = { "type", "line_number" },
        },
      },
      show_diff = {
        type = "boolean",
        description = "Whether to show a git-diff style preview before applying changes",
        default = true,
      },
    },
    required = { "file_path", "edits" },
    additionalProperties = false,
  },
}

-- Generate git-diff style output
local function generate_diff_preview(original_lines, edits, file_path)
  local diff_lines = {
    string.format("diff --git a/%s b/%s", file_path, file_path),
    string.format("index 1234567..abcdefg 100644"),
    string.format("--- a/%s", file_path),
    string.format("+++ b/%s", file_path),
  }

  -- Sort edits by line number for proper diff generation
  local sorted_edits = {}
  for _, edit in ipairs(edits) do
    table.insert(sorted_edits, edit)
  end
  table.sort(sorted_edits, function(a, b)
    return a.line_number < b.line_number
  end)

  local context_lines = 3
  local processed_lines = {}

  for _, edit in ipairs(sorted_edits) do
    local line_num = edit.line_number
    local start_context = math.max(1, line_num - context_lines)
    local end_context = math.min(#original_lines, line_num + context_lines)

    -- Skip if we've already processed this area
    local already_processed = false
    for proc_start, proc_end in pairs(processed_lines) do
      if line_num >= proc_start and line_num <= proc_end then
        already_processed = true
        break
      end
    end

    if not already_processed then
      -- Add hunk header
      local hunk_size = end_context - start_context + 1
      if edit.type == "add" then
        hunk_size = hunk_size + 1
      end
      if edit.type == "remove" then
        hunk_size = hunk_size - 1
      end

      table.insert(
        diff_lines,
        string.format("@@ -%d,%d +%d,%d @@", start_context, end_context - start_context + 1, start_context, hunk_size)
      )

      -- Add context and changes
      for i = start_context, end_context do
        if i == line_num then
          if edit.type == "remove" then
            table.insert(diff_lines, "-" .. (original_lines[i] or ""))
          elseif edit.type == "add" then
            table.insert(diff_lines, " " .. (original_lines[i] or ""))
            table.insert(diff_lines, "+" .. edit.content)
          elseif edit.type == "change" then
            table.insert(diff_lines, "-" .. (original_lines[i] or ""))
            table.insert(diff_lines, "+" .. edit.content)
          end
        else
          table.insert(diff_lines, " " .. (original_lines[i] or ""))
        end
      end

      processed_lines[start_context] = end_context
    end
  end

  return table.concat(diff_lines, "\n")
end

-- Apply edits in git-diff style (bottom to top to avoid line number shifts)
local function apply_diff_edits(lines, edits)
  -- This ensures that line numbers remain valid as we process each edit
  local sorted_edits = {}
  for _, edit in ipairs(edits) do
    table.insert(sorted_edits, edit)
  end
  table.sort(sorted_edits, function(a, b)
    return a.line_number > b.line_number
  end)

  local changes_made = 0

  for _, edit in ipairs(sorted_edits) do
    local line_num = edit.line_number

    if edit.type == "remove" then
      -- Verify old content if provided
      if edit.old_content and lines[line_num] ~= edit.old_content then
        return nil,
          string.format(
            "Line %d content mismatch. Expected: '%s', Found: '%s'",
            line_num,
            edit.old_content,
            lines[line_num] or ""
          )
      end

      if line_num >= 1 and line_num <= #lines then
        table.remove(lines, line_num)
        changes_made = changes_made + 1
      else
        return nil, string.format("Invalid line number %d for remove (file has %d lines)", line_num, #lines)
      end
    elseif edit.type == "add" then
      if line_num >= 1 and line_num <= #lines + 1 then
        table.insert(lines, line_num, edit.content)
        changes_made = changes_made + 1
      else
        return nil, string.format("Invalid line number %d for add (file has %d lines)", line_num, #lines)
      end
    elseif edit.type == "change" then
      -- Verify old content if provided
      if edit.old_content and lines[line_num] ~= edit.old_content then
        return nil,
          string.format(
            "Line %d content mismatch. Expected: '%s', Found: '%s'",
            line_num,
            edit.old_content,
            lines[line_num] or ""
          )
      end

      if line_num >= 1 and line_num <= #lines then
        lines[line_num] = edit.content
        changes_made = changes_made + 1
      else
        return nil, string.format("Invalid line number %d for change (file has %d lines)", line_num, #lines)
      end
    end
  end

  return changes_made, nil
end

M.run = function(args)
  local rel_path = args.file_path
  local edits = args.edits
  local show_diff = args.show_diff ~= false -- default to true

  if type(rel_path) ~= "string" then
    return "file_path must be a string"
  end
  if type(edits) ~= "table" then
    return "edits must be an array of edit operations"
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. rel_path

  -- Read file into lines
  local file, err = io.open(abs_path, "r")
  if not file then
    return "Cannot open file: " .. abs_path .. ": " .. tostring(err)
  end
  local original_lines = {}
  for line in file:lines() do
    table.insert(original_lines, line)
  end
  file:close()

  -- Validate edits
  for i, edit in ipairs(edits) do
    if type(edit.type) ~= "string" or not (edit.type == "add" or edit.type == "remove" or edit.type == "change") then
      return string.format("Edit %d: type must be 'add', 'remove', or 'change'", i)
    end

    if type(edit.line_number) ~= "number" then
      return string.format("Edit %d: line_number must be a number", i)
    end

    if (edit.type == "add" or edit.type == "change") and type(edit.content) ~= "string" then
      return string.format("Edit %d: %s operation requires 'content' field", i, edit.type)
    end
  end

  -- Generate and show diff preview (sorted for display)
  local result_parts = {}

  if show_diff then
    local diff_preview = generate_diff_preview(original_lines, edits, rel_path)
    table.insert(result_parts, "📋 Diff Preview:")
    table.insert(result_parts, "```diff")
    table.insert(result_parts, diff_preview)
    table.insert(result_parts, "```")
    table.insert(result_parts, "")
  end

  -- Apply edits (processed bottom-to-top to preserve line numbers)
  local working_lines = {}
  for _, line in ipairs(original_lines) do
    table.insert(working_lines, line)
  end

  local changes_made, apply_err = apply_diff_edits(working_lines, edits)
  if apply_err then
    return apply_err
  end

  -- Write updated lines to temp file
  local tmp_path = abs_path .. ".tmp"
  local out, werr = io.open(tmp_path, "w")
  if not out then
    return "Cannot write to temp file: " .. werr
  end

  -- Handle empty file case
  if #working_lines > 0 then
    out:write(table.concat(working_lines, "\n"))
    out:write("\n")
  end
  out:close()

  -- Atomically replace original
  local ok, rename_err = os.rename(tmp_path, abs_path)
  if not ok then
    return "Failed to rename temp file: " .. tostring(rename_err)
  end

  utils.open_non_ai_buffer(abs_path)

  local success_msg = string.format("✅ Applied %d changes to %s", changes_made, rel_path)
  table.insert(result_parts, success_msg)

  local diag = require("neoai.ai_tools.lsp_diagnostic").run({ file_path = rel_path })
  table.insert(result_parts, diag)

  return table.concat(result_parts, "\n")
end

return M
