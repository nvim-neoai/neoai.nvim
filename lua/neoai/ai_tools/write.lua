local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "Write",
  description = utils.read_description("write"),
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

local function split_lines(str)
  return vim.split(str or "", "\n", { plain = true })
end

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

  -- Read existing content if any
  local existing = nil
  do
    local f = io.open(abs_path, "r")
    if f then
      existing = f:read("*a")
      f:close()
    end
  end

  local new_lines = split_lines(content)
  local old_lines = split_lines(existing or "")

  -- UI available? If file exists and differs, open inline diff suggestion instead of writing immediately
  local uis = vim.api.nvim_list_uis()
  if existing ~= nil and existing ~= table.concat(new_lines, "\n") and uis and #uis > 0 then
    local ok, msg = utils.inline_diff.apply(abs_path, old_lines, new_lines)
    if ok then
      return msg
    else
      -- Fall back to direct write on failure to show diff
      vim.notify("NeoAI: inline diff failed, writing file directly (" .. (msg or "unknown error") .. ")", vim.log.levels.WARN)
    end
  end

  -- Write content directly
  local f, ferr = io.open(abs_path, "w")
  if not f then
    return string.format("Failed to open file %s for writing: %s", abs_path, ferr)
  end
  f:write(content)
  f:close()

  utils.open_non_ai_buffer(abs_path)

  -- Diagnostics
  local success_msg
  if existing == nil then
    success_msg = string.format("Created and opened: %s", file_path)
  elseif existing == content then
    success_msg = string.format("No changes for %s; opened existing file", file_path)
  else
    success_msg = string.format("Wrote and opened: %s", file_path)
  end
  local diag = require("neoai.ai_tools.lsp_diagnostic").run({ file_path = file_path })
  return success_msg .. "\n" .. diag
end

return M
