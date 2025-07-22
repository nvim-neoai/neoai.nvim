local M = {}
local utils = require("neoai.ai_tools.utils")

local description = string.format(
  [[
  Request to write content to a file at the specified path. If the file exists, it will be overwritten with the provided content. If the file doesn't exist, it will be created. This tool will automatically create any directories needed to write the file.

  Usage:
  - The file_path parameter must be an relative path to the current working directory: %s
  - This tool will overwrite the existing file if there is one at the provided path.
  - If this is an existing file, you MUST use the Read tool first to read the file's contents.
    - ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
    - NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
  ]],
  vim.fn.getcwd()
)

M.meta = {
  name = "Write",
  description = description,
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format(
          "The path of the file to write to (relative to the current working directory %s)",
          vim.fn.getcwd()
        ),
      },
      content = {
        type = "string",
        description = "The content to write to the file. ALWAYS provide the COMPLETE intended content of the file, without any truncation or omissions. You MUST include ALL parts of the file, even if they haven't been modified.",
      },
    },
    required = { "file_path", "content" },
    additionalProperties = false,
  },
}

M.run = function(args)
  local file_path = args.file_path
  local content = args.content

  if type(file_path) ~= "string" or type(content) ~= "string" then
    return "file_path and content are required"
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. file_path

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(abs_path, ":h")
  vim.fn.mkdir(dir, "p")

  -- Explicit I/O error handling
  local f, ferr = io.open(abs_path, "w")
  if not f then
    return string.format("Failed to open file %s for writing: %s", abs_path, ferr)
  end
  f:write(content)
  f:close()

  utils.open_non_ai_buffer(abs_path)

  -- After writing, retrieve and append LSP diagnostics
  local success_msg = string.format("✅ Successfully wrote and opened: %s", file_path)
  local diag = require("neoai.ai_tools.lsp_diagnostic").run({ file_path = file_path })
  return success_msg .. "\n" .. diag
end

return M
