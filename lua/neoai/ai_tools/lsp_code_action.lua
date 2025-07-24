local M = {}
local utils = require("neoai.ai_tools.utils")
local kwargs = {}

M.meta = {
  name = "LspCodeAction",
  description = [[
    Retrieves available LSP code actions for a given file (or current buffer if none provided) and formats them.
    Sends a "textDocument/codeAction" request at the current cursor position.
  ]],
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format(
          "(Optional) The path of the file to check (relative to cwd %s). If omitted, uses current buffer.",
          vim.fn.getcwd()
        ),
      },
    },
    additionalProperties = false,
  },
}

M.run = function(args)
  -- Determine buffer number
  local bufnr
  if args and args.file_path and #args.file_path > 0 then
    bufnr = vim.fn.bufnr(args.file_path, true)
    vim.fn.bufload(bufnr)
  else
    bufnr = vim.api.nvim_get_current_buf()
    args = args or {}
    args.file_path = vim.api.nvim_buf_get_name(bufnr)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return "Failed to load buffer for: " .. tostring(args.file_path)
  end

  -- Prepare parameters for codeAction request
  local params = vim.lsp.util.make_range_params()
  params.context = { diagnostics = vim.diagnostic.get(bufnr) }

  -- Perform synchronous request for code actions
  local results = vim.lsp.buf_request_sync(bufnr, 'textDocument/codeAction', params, 1000) or {}
  local titles = {}
  for _, res in pairs(results) do
    for _, action in ipairs(res) do
      table.insert(titles, action.title)
    end
  end

  -- If no actions available
  if vim.tbl_isempty(titles) then
    return utils.make_code_block(
      "✅ No code actions available for: " .. (args.file_path or bufnr),
      "txt"
    )
  end

  -- Format list of action titles
  local lines = {}
  for i, title in ipairs(titles) do
    table.insert(lines, string.format("%d. %s", i, title))
  end

  return utils.make_code_block(table.concat(lines, "\n"), "txt")
end

return M
