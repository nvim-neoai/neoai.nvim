local M = {}

M.meta = {
  name = "WebFetch",
  description = [[
- Fetches content from a specified URL and processes into markdown
- Takes a URL as input
- Fetches the URL content, converts HTML to markdown
- Use this tool when you need to retrieve and analyze web content

Usage notes:
  - IMPORTANT: If an MCP-provided web fetch tool is available, prefer using that tool instead of this one, as it may have fewer restrictions.
  - The URL must be a fully-formed valid URL
  - HTTP URLs will be automatically upgraded to HTTPS
  - This tool is read-only and does not modify any files
]],
  parameters = {
    type = "object",
    properties = {
      url = {
        type = "string",
        format = "url",
        description = "The URL to fetch content from",
      },
    },
    required = { "url" },
    additionalProperties = false,
  },
}

M.run = function(args)
  local utils = require("neoai.ai_tools.utils")

  local url = args.url
  if not url then
    return "Error: URL is required."
  end

  -- Upgrade http to https
  url = url:gsub("^http://", "https://")

  -- Use curl to fetch content
  local curl_cmd = { "curl", "-sL", url }
  local ok, html = pcall(vim.fn.system, curl_cmd)
  if not ok then
    return "Error fetching URL: " .. tostring(html)
  end

  -- Try to convert HTML to Markdown using pandoc if available
  local tmp_html = "/tmp/webfetch_input.html"
  local tmp_md = "/tmp/webfetch_output.md"
  local file = io.open(tmp_html, "w")
  if not file then
    return "Error: failed to write temporary HTML file."
  end
  file:write(html)
  file:close()

  local pandoc_cmd = { "pandoc", "-f", "html", "-t", "markdown", tmp_html, "-o", tmp_md }
  local convert_ok = os.execute(table.concat(pandoc_cmd, " "))

  if convert_ok == 0 then
    local out = io.open(tmp_md, "r")
    local markdown = out and out:read("*a") or nil
    if out then
      out:close()
    end
    if markdown then
      return utils.make_code_block(markdown, "markdown")
    else
      return "Error reading converted markdown."
    end
  else
    return utils.make_code_block(html, "html") .. "\n\n(Note: pandoc not available, returning raw HTML.)"
  end
end

return M
