local M = {}

M.meta = {
  name = "ReadFile",
  description = "Reads the content of a file from the filesystem.",
  parameters = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "The absolute path to the file to read",
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
      "path",
    },
    additionalProperties = false,
  },
}

M.run = function(args)
  local path = args.path
  local start_line = args.start_line or 1
  local end_line = args.end_line or math.huge

  local file = io.open(path, "r")
  if not file then
    return nil, "Cannot open file: " .. path
  end

  local lines = {}
  local current_line = 1
  for line in file:lines() do
    if current_line >= start_line and current_line <= end_line then
      table.insert(lines, line)
    end
    if current_line > end_line then
      break
    end
    current_line = current_line + 1
  end

  file:close()
  return table.concat(lines, "\n")
end

return M
