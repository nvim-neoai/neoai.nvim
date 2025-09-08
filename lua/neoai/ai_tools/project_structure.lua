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
        description = "Relative path to inspect (default: current working directory).",
      },
      max_depth = {
        type = "number",
        description = "Maximum recursion depth for listing files.",
      },
    },
    required = {},
    additionalProperties = false,
  },
}

M.run = function(args)
  local path = args.path or "."
  local max_depth = args.max_depth

  -- Build the ripgrep command
  local cmd = { "rg", "--files" }

  if max_depth then
    table.insert(cmd, "--max-depth")
    table.insert(cmd, tostring(max_depth))
  end

  -- Add the path argument to scope the search
  table.insert(cmd, path)

  -- Execute the command using vim.system for better control and output handling
  local result = vim
    .system(cmd, {
      cwd = vim.fn.getcwd(),
      text = true, -- Get stdout as a string
    })
    :wait()

  -- rg exits 2 on error, 1 for no matches (which is not an error for us)
  if result.code > 1 then
    return "Error running `rg`: " .. (result.stderr or "Unknown error")
  end

  local files = vim.split(result.stdout, "\n", { trimempty = true })

  if vim.tbl_isempty(files) then
    return "No files found in '" .. path .. "' (respecting .gitignore)."
  end

  -- Build a nested table representing the directory structure
  local tree = {}
  for _, filepath in ipairs(files) do
    local parts = vim.split(filepath, "/")
    local current_level = tree

    for i, part in ipairs(parts) do
      if i == #parts then
        -- It's a file
        current_level[part] = true -- Use `true` as a sentinel for files
      else
        -- It's a directory
        if type(current_level[part]) ~= "table" then
          current_level[part] = {}
        end
        current_level = current_level[part]
      end
    end
  end

  -- Recursively format the tree into the final output string
  local lines = { "🔍 Project structure for: " .. path }
  local function format_tree(t, prefix)
    -- Sort keys for consistent, alphabetical output
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
        table.insert(lines, entry_prefix .. "📁 " .. k)
        format_tree(v, new_prefix)
      else
        table.insert(lines, entry_prefix .. "📄 " .. k)
      end
    end
  end

  -- A slightly different initial call to format_tree for a cleaner root
  local function format_root(t)
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
        table.insert(lines, prefix .. "📁 " .. k)
        format_tree(v, next_prefix)
      else
        table.insert(lines, prefix .. "📄 " .. k)
      end
    end
  end

  -- If the initial path was a directory, build a tree.
  -- If it was just one file, the output from rg will be that one file.
  if #files == 1 and vim.fn.filereadable(files[1]) == 1 and vim.fn.isdirectory(files[1]) == 0 then
    table.insert(lines, "📄 " .. files[1])
  else
    -- Use a slightly nicer tree-drawing format
    format_root(tree)
  end

  return utils.make_code_block(table.concat(lines, "\n"), "txt")
end

return M
