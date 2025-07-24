local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "Grep",
  description = "Live grep using ripgrep (rg). Detect keyword from user message and grep it.",
  parameters = {
    type = "object",
    properties = {
      query_string = {
        type = "string",
        description = "The search query for ripgrep",
      },
    },
    required = { "query_string" },
    additionalProperties = false,
  },
}

M.run = function(args)
  local query = args.query_string
  if not query or #query == 0 then
    return "Error: 'query_string' is required."
  end

  -- Construct the ripgrep command with vimgrep output
  local cmd = { "rg", "--vimgrep", query }
  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return "Error running rg: " .. tostring(result)
  end

  if vim.tbl_isempty(result) then
    return "No matches found for: " .. query
  end

  -- Wrap results in a code block for readability
  return utils.make_code_block(table.concat(result, "\n"), "txt")
end

return M
