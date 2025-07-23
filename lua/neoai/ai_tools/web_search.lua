local M = {}

M.meta = {
  name = "WebSearch",
  description = "Fetch web page content by URL or perform a Google search and return the HTML result.",
  parameters = {
    type = "object",
    properties = {
      url = {
        type = "string",
        description = "The URL of the web page to fetch.",
      },
      query = {
        type = "string",
        description = "A search query to perform on Google. When provided, ignores 'url'.",
      },
    },
    anyOf = {
      { required = { "url" } },
      { required = { "query" } },
    },
    additionalProperties = false,
  },
}

M.run = function(args)
  local utils = require("neoai.ai_tools.utils")

  -- URL encode function
  local function urlencode(str)
    if not str then
      return ""
    end
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w%-_.~])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    return str
  end

  local target = ""
  if args.query then
    local encoded = urlencode(args.query)
    target = "https://www.google.com/search?q=" .. encoded
  elseif args.url then
    target = args.url
  else
    return "Error: neither 'url' nor 'query' provided."
  end

  -- Use curl to fetch content
  local cmd = { "curl", "-sL", target }
  local ok, result = pcall(vim.fn.system, cmd)
  if not ok then
    return "Error fetching URL: " .. tostring(result)
  end

  -- Wrap HTML result in markdown code block
  return utils.make_code_block(result, "html")
end

return M
