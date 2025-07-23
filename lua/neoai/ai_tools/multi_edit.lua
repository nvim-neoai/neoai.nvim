local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "MultiEdit",
  description = "Makes multiple changes to a single file in one operation. Use this tool to edit files by providing the exact text to replace and the new text. Supports limiting replacements per edit.",
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format("The path of the file to modify (relative to cwd %s)", vim.fn.getcwd()),
      },
      max_replacements = {
        type = "number",
        description = "Maximum replacements per edit (default 0 = unlimited)",
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

M.run = function(args)
  local rel_path = args.file_path
  local max_replacements = args.max_replacements or 0
  local edits = args.edits

  if type(rel_path) ~= "string" then
    return "file_path must be a string"
  end
  if type(edits) ~= "table" then
    return "edits must be an array of {old_string, new_string}"
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. rel_path

  local file, err = io.open(abs_path, "r")
  if not file then
    return "Cannot open file: " .. abs_path .. ": " .. tostring(err)
  end
  local content = file:read("*a")
  file:close()

  for _, edit in ipairs(edits) do
    local old = edit.old_string
    local new = edit.new_string
    if type(old) ~= "string" or type(new) ~= "string" then
      return "Each edit must have old_string and new_string as strings"
    end
    local pattern = utils.escape_pattern(old)
    if max_replacements > 0 then
      content = content:gsub(pattern, new, max_replacements)
    else
      content = content:gsub(pattern, new)
    end
  end

  -- Atomic write via temp file
  local tmp_path = abs_path .. ".tmp"
  local out, werr = io.open(tmp_path, "w")
  if not out then
    return "Cannot write to temp file: " .. werr
  end
  out:write(content)
  out:close()

  local ok, rename_err = os.rename(tmp_path, abs_path)
  if not ok then
    return "Failed to rename temp file: " .. tostring(rename_err)
  end

  utils.open_non_ai_buffer(abs_path)
  -- After multi-edit, retrieve and append LSP diagnostics
  local success_msg = string.format("✅ Applied %d edits to %s", #edits, rel_path)
  local diag = require("neoai.ai_tools.lsp_diagnostic").run({ file_path = rel_path })
  return success_msg .. "\n" .. diag
end

return M
