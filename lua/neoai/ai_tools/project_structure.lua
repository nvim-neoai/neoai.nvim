local M = {} -- Type: table

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "ProjectStructure",
  description = utils.read_description("project_structure"), -- Type: string

  parameters = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Relative path to inspect (default: current working directory).",
      },
      -- preferred_depth is the target display depth (default 3). If adaptive is true,
      -- this is used as a baseline and may be increased/decreased based on file count.
      preferred_depth = {
        type = "number",
        description = "Preferred display depth (default 3).",
      },

      adaptive = {
        type = "boolean",
        description = "Enable adaptive depth based on repository size (default true).",
      },
      small_file_threshold = {
        type = "number",
        description = "If total files <= threshold, expand fully (default 50).",
      },
      large_file_threshold = {
        type = "number",
        description = "If total files >= threshold, clamp depth (default 400).",
      },
    },
    required = {},
    additionalProperties = false,
  },
}
--- Runs the project structure listing (adaptive depth)
-- @param args table { path?: string, preferred_depth?: number, adaptive?: boolean, small_file_threshold?: number, large_file_threshold?: number }
-- @return string
M.run = function(args) -- Type: function
  args = type(args) == "table" and args or {}
  -- Normalise path: default to current directory when nil/empty/whitespace.
  local path = args.path
  if type(path) ~= "string" then
    path = "."
  else
    path = path:gsub("^%s*(.-)%s*$", "%1")
    if path == "" then
      path = "."
    end
  end
  -- Expand ~ and environment variables
  path = vim.fn.expand(path)

  -- Always list all files first (respecting .gitignore) so we can adapt depth based on repo size
  local cmd = { "rg", "--files", path }
  local result = vim.system(cmd, { cwd = vim.fn.getcwd(), text = true }):wait()

  if result.code > 1 then
    return "Error running `rg`: " .. (result.stderr or "Unknown error") -- Type: string
  end

  local files = vim.split(result.stdout or "", "\n", { trimempty = true }) -- Type: table

  if vim.tbl_isempty(files) then
    return "No files found in '" .. path .. "' (respecting .gitignore)."
  end

  -- Determine effective display depth
  local adaptive = args.adaptive
  if adaptive == nil then
    adaptive = true
  end
  local preferred_depth = args.preferred_depth or 3
  local small_thr = args.small_file_threshold or 50
  local large_thr = args.large_file_threshold or 400

  local effective_depth = preferred_depth
  local total_files = #files
  if adaptive then
    if total_files <= small_thr then
      -- Expand fully for small repos
      effective_depth = 1e9 -- effectively unlimited
    elseif total_files >= large_thr then
      -- Clamp for very large repos
      effective_depth = math.min(preferred_depth, 2)
    end
  end

  -- Build a directory tree from the file list
  local tree = {} -- Type: table
  for _, filepath in ipairs(files) do
    local parts = vim.split(filepath, "/", { plain = true }) -- Type: table
    local current_level = tree -- Type: table
    for i, part in ipairs(parts) do
      if i == #parts then
        current_level[part] = true -- file sentinel
      else
        if type(current_level[part]) ~= "table" then
          current_level[part] = {}
        end
        current_level = current_level[part]
      end
    end
  end

  local lines = { "🔍 Project structure for: " .. path } -- Type: table

  -- Helper to count descendants in a subtree
  local function count_descendants(node)
    local dirs, files_n = 0, 0
    for _, v in pairs(node) do
      if type(v) == "table" then
        dirs = dirs + 1
        local d2, f2 = count_descendants(v)
        dirs = dirs + d2
        files_n = files_n + f2
      else
        files_n = files_n + 1
      end
    end
    return dirs, files_n
  end

  local function format_tree(t, prefix, depth, depth_limit) -- Type: function
    local keys = {}
    for k in pairs(t) do
      table.insert(keys, k)
    end
    table.sort(keys)

    for i, k in ipairs(keys) do
      local v = t[k]
      local is_last = (i == #keys)
      local new_prefix = prefix .. (is_last and "    " or "│   ")
      local entry_prefix = prefix .. (is_last and "└── " or "├── ")

      if type(v) == "table" then
        if depth >= depth_limit then
          local dcnt, fcnt = count_descendants(v)
          table.insert(lines, entry_prefix .. "📁 " .. k .. " … (" .. dcnt .. " dirs, " .. fcnt .. " files)")
        else
          table.insert(lines, entry_prefix .. "📁 " .. k)
          format_tree(v, new_prefix, depth + 1, depth_limit)
        end
      else
        table.insert(lines, entry_prefix .. "📄 " .. k)
      end
    end
  end

  local function format_root(t, depth_limit) -- Type: function
    local keys = {}
    for k in pairs(t) do
      table.insert(keys, k)
    end
    table.sort(keys)

    for i, k in ipairs(keys) do
      local v = t[k]
      local is_last = (i == #keys)
      local prefix = is_last and "└── " or "├── "
      local next_prefix = is_last and "    " or "│   "

      if type(v) == "table" then
        if 1 > depth_limit then
          local dcnt, fcnt = count_descendants(v)
          table.insert(lines, prefix .. "📁 " .. k .. " … (" .. dcnt .. " dirs, " .. fcnt .. " files)")
        else
          table.insert(lines, prefix .. "📁 " .. k)
          format_tree(v, next_prefix, 2, depth_limit)
        end
      else
        table.insert(lines, prefix .. "📄 " .. k)
      end
    end
  end

  -- If rg returned a single path that is a file, show just that.
  if #files == 1 and vim.fn.filereadable(files[1]) == 1 and vim.fn.isdirectory(files[1]) == 0 then
    table.insert(lines, "📄 " .. files[1])
  else
    format_root(tree, effective_depth)
  end

  return utils.make_code_block(table.concat(lines, "\n"), "txt") -- Type: string
end

return M
