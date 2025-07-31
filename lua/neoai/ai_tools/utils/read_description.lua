local function read_description(tool_name)
  local info = debug.getinfo(1, "S").source:sub(2)
  local base = info:match("(.*/)" ) or "./"
  local path = base .. "descriptions/" .. tool_name .. ".md"
  local file = io.open(path, "r")
  if not file then return "" end
  local content = file:read("*a")
  file:close()
  return content
end

return read_description
