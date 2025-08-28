local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "Read",
  description = utils.read_description("read"),
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format(
          "The path of the file to read (relative to the current working directory %s)",
          vim.fn.getcwd()
        ),
      },
      start_line = {
        type = "number",
        description = "Line number to start reading the content (default: 1)",
      },
      end_line = {
        type = "number",
        description = "Line number to stop reading the content (default: end of file)",
      },
    },
    required = {
      "file_path",
    },
    additionalProperties = false,
  },
}

M.run = function(args)
  local pwd = vim.fn.getcwd()
  local path = pwd .. "/" .. args.file_path
  local start_line = args.start_line or 1
  local end_line = args.end_line or math.huge

  local file = io.open(path, "r")
  if not file then
    return { content = "Cannot open file: " .. path, display = "Read: " .. args.file_path .. " (failed)" }
  end

  local lines = {}
  local current_line = 1
  for line in file:lines() do
    if current_line >= start_line and current_line <= end_line then
      local width = #tostring(end_line) -- max digits of the highest line number
      table.insert(lines, string.format("%" .. width .. "d|%s", current_line, line))
    end
    if current_line > end_line then
      break
    end
    current_line = current_line + 1
  end
  file:close()

  local function get_extension(filename)
    return filename:match("^.+%.([a-zA-Z0-9_]+)$") or ""
  end

  local ext = get_extension(path)
  local text = table.concat(lines, "\n")
  local result = utils.make_code_block(text, ext)

  -- Append LSP diagnostics
  local diag = require("neoai.ai_tools.lsp_diagnostic").run({ file_path = args.file_path })
  local content = result .. "\n" .. diag
  local display = string.format("Read: %s (%s:%s-%s)", args.file_path, ext ~= "" and ext or "txt", tostring(start_line), tostring(end_line == math.huge and "EOF" or end_line))
  return { content = content, display = display }
end

return M
