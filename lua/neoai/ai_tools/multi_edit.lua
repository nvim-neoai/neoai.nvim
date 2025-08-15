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

  local lines = split_lines(content)
  local total_replacements = 0

  for _, edit in ipairs(edits) do
    local old_pat = utils.escape_pattern(edit.old_string)
    local count = 0
    local start_line = edit.start_line or 1
    local end_line = edit.end_line or #lines
    start_line = math.max(1, start_line)
    end_line = math.min(#lines, end_line)

    -- Replace within specified line range
    for idx = start_line, end_line do
      local new_line, c = lines[idx]:gsub(old_pat, edit.new_string)
      if c > 0 then
        lines[idx] = new_line
        count = count + c
      end
    end

    if count == 0 then
      -- No replacements in range: fallback to first occurrence in entire file
      for idx, line in ipairs(lines) do
        if line:find(edit.old_string, 1, true) then
          lines[idx] = line:gsub(old_pat, edit.new_string, 1)
          count = 1
          break
        end
      end
    end

    if count == 0 then
      return string.format("⚠️ No match for '%s'. Fallback to Write tool.", edit.old_string)
    end

    total_replacements = total_replacements + count
  end

  if total_replacements == 0 then
    return string.format("⚠️ No replacements made in %s. Fallback to Write tool.", rel_path)
  end

  -- Write updated content to temp file
  local updated = table.concat(lines, "\n")
  local tmp_path = abs_path .. ".tmp"
  local out, werr = io.open(tmp_path, "w")
  if not out then
    return "Cannot write to temp file: " .. tostring(werr)
  end
  out:write(updated)
  out:close()

  -- Rename temp file over original
  local ok, rename_err = os.rename(tmp_path, abs_path)
  if not ok then
    return "Failed to rename temp file: " .. tostring(rename_err)
  end

  -- Open updated file outside AI UI
  utils.open_non_ai_buffer(abs_path)

  -- Summary of replacements
  local summary = string.format("✅ Applied %d replacements to %s", total_replacements, rel_path)
  -- Retrieve diagnostics for the updated file
  local diag_tool = require("neoai.ai_tools.lsp_diagnostic")
  local diagnostics = diag_tool.run({ file_path = rel_path, include_code_actions = false })

  return summary .. "\n\n" .. diagnostics
end

return M
