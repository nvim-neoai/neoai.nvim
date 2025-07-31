local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "ProjectStructure",
  description = utils.read_description("project_structure"),
  parameters = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Relative path to inspect (default: current working directory)",
      },
      max_depth = {
        type = "number",
        description = "Maximum recursion depth (default: unlimited)",
      },
    },
    required = {},
    additionalProperties = false,
  },
}

M.run = function(args)
  local uv = vim.loop
  local cwd = vim.fn.getcwd()
  local base = args.path and (cwd .. "/" .. args.path) or cwd
  local max_depth = args.max_depth or math.huge

  -- Build ignore set: default directories and entries from .gitignore
  local ignore = {
    [".git"] = true,
    ["node_modules"] = true,
    [".venv"] = true,
    ["venv"] = true,
    ["myenv"] = true,
    ["pyenv"] = true,
  }
  local gitignore_file = cwd .. "/.gitignore"
  if uv.fs_stat(gitignore_file) then
    for _, line in ipairs(vim.fn.readfile(gitignore_file)) do
      -- trim whitespace
      line = line:match("^%s*(.-)%s*$")
      -- skip comments and empty lines
      if line ~= "" and not line:match("^#") then
        -- strip trailing slash for directories
        if line:sub(-1) == "/" then
          line = line:sub(1, -2)
        end
        ignore[line] = true
      end
    end
  end

  local lines = {}
  -- Recursive scanner
  local function scan(dir, prefix, depth)
    if depth > max_depth then
      return
    end
    local handle = uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, t = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if not ignore[name] then
        local full = dir .. "/" .. name
        local symbol = (t == "directory") and "📁 " or "📄 "
        table.insert(lines, prefix .. symbol .. name)
        if t == "directory" then
          scan(full, prefix .. "    ", depth + 1)
        end
      end
    end
  end

  -- Start scanning
  table.insert(lines, "🔍 Project structure for: " .. (args.path or "."))
  scan(base, "", 1)

  return "```txt\n" .. table.concat(lines, "\n") .. "\n```"
end

return M
