local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "LspDiagnostic",
  description = utils.read_description("lsp_diagnostic"),

  parameters = {
    type = "object",
    properties = {
      include_code_actions = {
        type = "boolean",
        description = "(Optional) When true, also retrieve available code actions for the file.",
      },
      file_path = {
        type = "string",
        description = string.format(
          "(Optional) Path to the file to inspect (relative to cwd %s). If omitted, uses current buffer.",
          vim.fn.getcwd()
        ),
      },
    },
    additionalProperties = false,
  },
}

local severity_map = {
  [vim.diagnostic.severity.ERROR] = "Error",
  [vim.diagnostic.severity.WARN] = "Warn",
  [vim.diagnostic.severity.INFO] = "Info",
  [vim.diagnostic.severity.HINT] = "Hint",
}

M.run = function(args)
  args = args or {}
  -- Determine buffer number
  local bufnr
  if type(args.file_path) == "string" and #args.file_path > 0 then
    -- Load or get existing buffer
    bufnr = vim.fn.bufnr(args.file_path, true)
    vim.fn.bufload(bufnr)
  else
    bufnr = vim.api.nvim_get_current_buf()
    args.file_path = vim.api.nvim_buf_get_name(bufnr)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return "Failed to load buffer for: " .. tostring(args.file_path)
  end

  -- Get all diagnostics for this buffer
  local diags = vim.diagnostic.get(bufnr)
  if vim.tbl_isempty(diags) then
    return "✅ No diagnostics for: " .. (args.file_path or bufnr)
  end

  -- Format each diagnostic
  local lines = {}
  for _, d in ipairs(diags) do
    local line = d.lnum + 1
    local col = d.col + 1
    local sev = severity_map[d.severity] or tostring(d.severity)
    local src = d.source or ""
    table.insert(
      lines,
      string.format(
        "%s:%d:%d [%s] %s%s",
        args.file_path or "<buffer>",
        line,
        col,
        sev,
        d.message:gsub("\n", " "),
        (src ~= "" and string.format(" (%s)", src) or "")
      )
    )
  end

  local text = table.concat(lines, "\n")
  -- Base diagnostics output
  local result = utils.make_code_block(text, "txt")
  -- Append code actions if requested
  if args.include_code_actions then
    local code_action_tool = require("neoai.ai_tools.lsp_code_action")
    local ca = code_action_tool.run({ file_path = args.file_path })
    result = result .. "\n\n" .. ca
  end
  return result
end

return M
