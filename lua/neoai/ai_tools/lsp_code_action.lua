local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "LspCodeAction",
  description = [[
    Retrieves available LSP code actions for a given file (or current buffer if none provided).
    If 'action_index' is provided, executes the selected code action.
  ]],
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format(
          "(Optional) Path to the file to inspect (relative to cwd %s). If omitted, uses current buffer.",
          vim.fn.getcwd()
        ),
      },
      action_index = {
        type = "integer",
        description = "The index of the code action to apply. If omitted, the tool will list available actions.",
      },
    },
    additionalProperties = false,
  },
}

M.run = function(args)
  args = args or {}
  -- Determine buffer number
  local bufnr
  if args.file_path and #args.file_path > 0 then
    bufnr = vim.fn.bufnr(args.file_path, true)
    vim.fn.bufload(bufnr)
  else
    bufnr = vim.api.nvim_get_current_buf()
    args.file_path = vim.api.nvim_buf_get_name(bufnr)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return "Failed to load buffer: " .. tostring(args.file_path)
  end

  -- Prepare parameters for codeAction request
  local params = vim.lsp.util.make_range_params()
  params.context = { diagnostics = vim.diagnostic.get(bufnr) }

  -- Perform synchronous request for code actions
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/codeAction", params, 1000) or {}
  local actions = {}
  for _, res in pairs(results) do
    for _, action in ipairs(res) do
      table.insert(actions, action)
    end
  end

  -- If no actions available
  if #actions == 0 then
    return utils.make_code_block("✅ No code actions available for: " .. (args.file_path or bufnr), "txt")
  end

  -- If action_index provided, execute that action
  if args.action_index then
    local idx = args.action_index
    if type(idx) ~= "number" or idx < 1 or idx > #actions then
      return "Invalid action_index: " .. tostring(idx)
    end
    local action = actions[idx]
    -- Apply workspace edit if present
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit)
    end
    -- Execute command if present
    if action.command then
      vim.lsp.buf.execute_command(action.command)
    end
    return "Applied code action: " .. action.title
  end

  -- Otherwise, list available actions
  local titles = {}
  for i, action in ipairs(actions) do
    table.insert(titles, string.format("%d. %s", i, action.title))
  end

  return utils.make_code_block(table.concat(titles, "\n"), "txt")
end

return M
