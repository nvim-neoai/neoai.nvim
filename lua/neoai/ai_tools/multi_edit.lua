local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "MultiEdit",
  description = utils.read_description("multi_edit"),
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format("The path of the file to modify (relative to cwd %s)", vim.fn.getcwd()),
      },
      edits = {
        type = "array",
        description = "Array of edit operations, each containing old_string, new_string, and optional line range",
        items = {
          type = "object",
          properties = {
            old_string = { type = "string", description = "Exact text to replace" },
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

-- Shallow copy of an array-like table (lines)
local function copy_lines(t)
  local c = {}
  for i = 1, #t do
    c[i] = t[i]
  end
  return c
end

-- Safely gsub on a single line and expand to multiple lines if replacement contains newlines.
-- Returns: replacements_made, lines_inserted
local function gsub_expand_line(lines, idx, old_pat, replacement_text, limit)
  local repl_fn = function()
    return replacement_text
  end
  local new_line, c
  if limit ~= nil then
    new_line, c = lines[idx]:gsub(old_pat, repl_fn, limit)
  else
    new_line, c = lines[idx]:gsub(old_pat, repl_fn)
  end
  if c > 0 then
    if new_line:find("\n", 1, true) then
      local parts = split_lines(new_line)
      lines[idx] = parts[1]
      -- Insert the remaining parts as new lines after idx
      for p = 2, #parts do
        table.insert(lines, idx + p - 1, parts[p])
      end
      return c, (#parts - 1)
    else
      lines[idx] = new_line
      return c, 0
    end
  end
  return 0, 0
end

-- Create a unified diff text using Neovim's builtin diff
local function unified_diff(old_lines, new_lines)
  local old_str = table.concat(old_lines or {}, "\n")
  local new_str = table.concat(new_lines or {}, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local diff = vim.diff(old_str, new_str, { result_type = "unified", algorithm = "histogram" })
  return diff or "(no changes)"
end

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
  local file, err = io.open(abs_path, "r")
  if not file then
    return "Cannot open file: " .. tostring(err)
  end
  local content = file:read("*a")
  file:close()

  local orig_lines = split_lines(content)
  local lines = copy_lines(orig_lines)
  local total_replacements = 0

  for _, edit in ipairs(edits) do
    local old_pat = utils.escape_pattern(edit.old_string)
    local count = 0
    local start_line = edit.start_line or 1
    local end_line = edit.end_line or #lines
    start_line = math.max(1, start_line)
    end_line = math.min(#lines, end_line)

    -- Replace within specified line range
    local idx = start_line
    while idx <= end_line do
      local c, inserted = gsub_expand_line(lines, idx, old_pat, edit.new_string)
      if c > 0 then
        count = count + c
        -- Keep scanning only the original region, but account for inserted lines
        end_line = end_line + inserted
        -- Skip over the newly inserted lines so we don't process replacement text
        idx = idx + 1 + inserted
      else
        idx = idx + 1
      end
    end

    if count == 0 then
      -- No replacements in range: fallback to first occurrence in entire file
      for i2, line in ipairs(lines) do
        if line:find(edit.old_string, 1, true) then
          local c2, _ = gsub_expand_line(lines, i2, old_pat, edit.new_string, 1)
          count = c2
          break
        end
      end
    end

    if count == 0 then
      return string.format("No match for '%s'. Consider using the Write tool.", edit.old_string)
    end

    total_replacements = total_replacements + count
  end

  if total_replacements == 0 then
    return string.format("No replacements made in %s. Consider using the Write tool.", rel_path)
  end

  -- Compose updated content in memory
  local updated_lines = lines

  -- If headless (no UI), auto-apply and return summary + diff + diagnostics.
  local uis = vim.api.nvim_list_uis()
  if not uis or #uis == 0 then
    local f, ferr = io.open(abs_path, "w")
    if not f then
      return "Failed to open file for writing: " .. tostring(ferr)
    end
    f:write(table.concat(updated_lines, "\n"))
    f:close()

    local summary =
      string.format("Applied %d replacement(s) to %s (auto-approved, headless)", total_replacements, rel_path)
    local diff_text = unified_diff(orig_lines, updated_lines)
    local diag_tool = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = diag_tool.run({ file_path = rel_path, include_code_actions = false })
    local parts = { summary, "Applied diff:", utils.make_code_block(diff_text, "diff"), diagnostics }
    return table.concat(parts, "\n\n")
  end

  -- UI mode: open an interactive inline diff with accept/reject controls
  local ok, msg = utils.inline_diff.apply(abs_path, orig_lines, updated_lines)
  if ok then
    return msg
  else
    return msg or "Failed to open inline diff"
  end
end

return M
