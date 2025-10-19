local M = {}

M.tools = {}
M.tool_schemas = {}

-- List of tool modules to load
local tool_names = {
  "project_structure",
  "read",
  "treesitter_query",
  "symbol_index",
  "edit",
  "grep",
  "lsp_diagnostic",
  "lsp_code_action",
}

-- Load tools dynamically
local get_tools = function()
  M.tools = {} -- Clear existing tools
  for _, name in ipairs(tool_names) do
    local ok, mod = pcall(require, "neoai.ai_tools." .. name)
    if ok and mod.meta and mod.run then
      table.insert(M.tools, {
        meta = mod.meta,
        run = mod.run,
      })
    else
      vim.notify("Failed to load tool: " .. name, vim.log.levels.WARN)
    end
  end
end

-- Return metadata for use with AI tools (e.g., OpenAI function calling)
local get_tool_schemas = function()
  M.tool_schemas = {} -- Clear old schemas
  for _, tool in ipairs(M.tools) do
    table.insert(M.tool_schemas, {
      type = "function",
      ["function"] = tool.meta,
    })
  end
end

M.setup = function()
  get_tools()
  get_tool_schemas()
end

return M
