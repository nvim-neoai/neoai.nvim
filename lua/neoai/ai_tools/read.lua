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
        description = "line number to start reading the content",
      },
      end_line = {
        type = "number",
        description = "line number to stop reading the content",
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
  local file = io.open(path, "r")
  if not file then
    return nil, "Cannot open file: " .. path
  end
  local content = file:read("*a")
  file:close()
  return "File content: " .. content
end

return M
