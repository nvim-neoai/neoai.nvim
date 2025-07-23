local M = {}

M.meta = {
  name = "VectorSearch",
  description = [[
Perform a semantic vector search over indexed files and return the most relevant chunks.
This tool **must be called first** before using any other tools when the user asks a general, broad, or code-related question.
Use this tool to retrieve relevant context before proceeding with further analysis or code generation.
]],
  parameters = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "The search query to vectorize and use for semantic search.",
      },
      k = {
        type = "number",
        description = "The number of top results to return.",
      },
    },
    required = { "query" },
    additionalProperties = false,
  },
}

M.run = function(args)
  local indexer = require("neoai.indexer")
  local utils = require("neoai.ai_tools.utils")
  -- Query the index
  local results = indexer.query_index(args.query)
  -- Limit results if k provided
  if args.k and type(args.k) == "number" and args.k > 0 then
    results = vim.list_slice(results, 1, args.k)
  end

  if not results or #results == 0 then
    return "No results found for query: " .. args.query
  end

  local out = {}
  for i, res in ipairs(results) do
    -- determine file extension for code block language
    local lang = res.file:match("^.+%.([a-zA-Z0-9_]+)$") or ""
    local header = string.format("%d. File: %s (chunk %d) [score: %.4f]", i, res.file, res.idx, res.score)
    local block = utils.make_code_block(res.content, lang)
    table.insert(out, header .. "\n" .. block)
  end
  -- Concatenate outputs separated by blank lines
  return table.concat(out, "\n\n")
end

return M
