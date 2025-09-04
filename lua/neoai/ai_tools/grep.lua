local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "Grep",
  description = utils.read_description("grep"),
  parameters = {
    type = "object",
    properties = {
      query_string = {
        type = "string",
        description = "The search query for ripgrep",
      },
      use_regex = {
        type = "boolean",
        description = "When true, treat query_string as a ripgrep regex. Default: false (literal search).",
      },
      glob = {
        type = "string",
        description = "(Optional) Include only files that match this glob (e.g., '*.lua', '**/*.ts').",
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

  local use_regex = args.use_regex == true

  -- Base ripgrep command with vimgrep-style output
  local cmd = { "rg", "--vimgrep", "--color", "never" }
  if not use_regex then
    table.insert(cmd, "--fixed-strings")
  end
  if args.glob and #args.glob > 0 then
    table.insert(cmd, "-g")
    table.insert(cmd, args.glob)
  end
  -- Use -e to ensure the pattern is treated as the pattern argument
  table.insert(cmd, "-e")
  table.insert(cmd, query)

  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return "Error running rg: " .. tostring(result)
  end

  local exit_code = vim.v.shell_error or 0

  -- If ripgrep returned an error and we were in regex mode, try a safe fallback to literal search
  if use_regex and (exit_code ~= 0 and exit_code ~= 1) then
    local retry_cmd = { "rg", "--vimgrep", "--color", "never", "--fixed-strings" }
    if args.glob and #args.glob > 0 then
      table.insert(retry_cmd, "-g")
      table.insert(retry_cmd, args.glob)
    end
    table.insert(retry_cmd, "-e")
    table.insert(retry_cmd, query)
    local ok2, retry_res = pcall(vim.fn.systemlist, retry_cmd)
    if ok2 and not vim.tbl_isempty(retry_res) then
      return utils.make_code_block(table.concat(retry_res, "\n"), "txt")
    end
  end

  if vim.tbl_isempty(result) then
    -- 0 with empty output is unlikely; rg uses 1 for 'no matches'
    return "No matches found for: " .. query
  end

  -- In some environments systemlist may capture stderr. If we detect a regex parse error
  -- in the output, retry with a literal search for resilience.
  local joined = table.concat(result, "\n")
  if use_regex and (joined:find("regex parse error", 1, true) or joined:find("unclosed group", 1, true)) then
    local retry_cmd = { "rg", "--vimgrep", "--color", "never", "--fixed-strings" }
    if args.glob and #args.glob > 0 then
      table.insert(retry_cmd, "-g")
      table.insert(retry_cmd, args.glob)
    end
    table.insert(retry_cmd, "-e")
    table.insert(retry_cmd, query)
    local ok2, retry_res = pcall(vim.fn.systemlist, retry_cmd)
    if ok2 and not vim.tbl_isempty(retry_res) then
      return utils.make_code_block(table.concat(retry_res, "\n"), "txt")
    end
  end

  -- Wrap results in a code block for readability
  return utils.make_code_block(joined, "txt")
end

return M
