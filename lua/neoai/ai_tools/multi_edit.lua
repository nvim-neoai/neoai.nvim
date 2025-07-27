local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "MultiEdit",
  description = [[
Makes multiple changes to a single file in one operation.
Use this tool to edit files by providing the exact text to replace and the new text.
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
        description = "Array of edit operations, each containing old_string and new_string",
        items = {
          type = "object",
          properties = {
            old_string = { type = "string", description = "Exact text to replace" },
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

local function validate_edit(edit, index)
  if type(edit.old_string) ~= "string" then
    return string.format("Edit %d: 'old_string' must be a string", index)
  end
  if type(edit.new_string) ~= "string" then
    return string.format("Edit %d: 'new_string' must be a string", index)
  end
  return nil
end

local function split_lines(str)
  -- Split string into lines preserving empty lines
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

  local total_replacements = 0
  for _, edit in ipairs(edits) do
    -- Try exact global replacement
    local count = 0
    content, count = content:gsub(edit.old_string, edit.new_string)

    if count == 0 then
      -- Fallback: scan lines and replace first occurrence
      local lines = split_lines(content)
      for idx, line in ipairs(lines) do
        if line:find(edit.old_string, 1, true) then
          lines[idx] = line:gsub(edit.old_string, edit.new_string)
          count = 1
          break
        end
      end
      if count > 0 then
        content = table.concat(lines, "\n")
      else
        -- Both exact and scan fallback failed: switch to Write tool
        return string.format("⚠️ Exact match for '%s' failed. Fallback to Write tool.", edit.old_string)
      end
    end
    total_replacements = total_replacements + count
  end

  if total_replacements == 0 then
    -- No replacements done: fallback to Write tool
    return string.format("⚠️ No replacements made in %s. Fallback to Write tool.", rel_path)
  end

  -- Write updated content to temp file
  local tmp_path = abs_path .. ".tmp"
  local out, werr = io.open(tmp_path, "w")
  if not out then
    return "Cannot write to temp file: " .. tostring(werr)
  end
  out:write(content)
  out:close()

  -- Rename temp file over original
  local ok, rename_err = os.rename(tmp_path, abs_path)
  if not ok then
    return "Failed to rename temp file: " .. tostring(rename_err)
  end

  -- Open updated file outside AI UI
  utils.open_non_ai_buffer(abs_path)

  return string.format("✅ Applied %d replacements to %s", total_replacements, rel_path)
end

return M
