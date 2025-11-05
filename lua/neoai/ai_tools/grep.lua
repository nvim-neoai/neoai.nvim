---@class GrepModule
---@field meta table
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
        description = "The search query for ripgrep.",
      },
      use_regex = {
        type = "boolean",
        description = "When true, treat query_string as a ripgrep regex. Default: false (literal search).",
      },
      file_type = {
        type = "string",
        description = "(Optional) Restrict search to files of this type (e.g., 'lua', 'ts'). Use 'all' to search all known file types. See `rg --type-list` for options.",
      },
      exclude_file_type = {
        type = "string",
        description = "(Optional) Exclude files of this type from the search (e.g., 'md', 'json').",
      },
    },
    required = { "query_string" },
    additionalProperties = false,
  },
}

--- Format a single-line summary of parameters used for the grep call.
--- @param query string
--- @param use_regex boolean
--- @param file_type string|nil
--- @param exclude_file_type string|nil
--- @return string
local function make_params_line(query, use_regex, file_type, exclude_file_type)
  local q = string.format("%q", query or "")
  local ft = file_type and string.format("%q", file_type) or "nil"
  local eft = exclude_file_type and string.format("%q", exclude_file_type) or "nil"
  return string.format(
    "Parameters used: query_string=%s; use_regex=%s; file_type=%s; exclude_file_type=%s",
    q,
    tostring(use_regex),
    ft,
    eft
  )
end

--- Executes the grep command with given arguments.
--- @param args table: Contains optional parameters 'query_string', 'use_regex', 'file_type', and 'exclude_file_type'.
--- @return table|string: A table with `content` and `params_line`, or an error message.
M.run = function(args)
  local query = args.query_string
  local use_regex = args.use_regex == true
  local file_type = (args.file_type and #args.file_type > 0) and args.file_type or nil
  local exclude_file_type = (args.exclude_file_type and #args.exclude_file_type > 0) and args.exclude_file_type or nil
  local params_line = make_params_line(query or "", use_regex, file_type, exclude_file_type)

  if not query or #query == 0 then
    return {
      content = "Error: 'query_string' is required.",
      params_line = params_line,
    }
  end

  -- Base ripgrep command with vimgrep-style output
  local cmd = { "rg", "--vimgrep", "--color", "never" }
  if not use_regex then
    table.insert(cmd, "--fixed-strings")
  end
  if file_type then
    table.insert(cmd, "-t")
    table.insert(cmd, file_type)
  end
  if exclude_file_type then
    table.insert(cmd, "-T")
    table.insert(cmd, exclude_file_type)
  end
  -- Use -e to ensure the pattern is treated as the pattern argument
  table.insert(cmd, "-e")
  table.insert(cmd, query)

  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return {
      content = "Error running rg: " .. tostring(result),
      params_line = params_line,
    }
  end

  local exit_code = vim.v.shell_error or 0

  -- If ripgrep returned an error and we were in regex mode, try a safe fallback to literal search
  if use_regex and (exit_code ~= 0 and exit_code ~= 1) then
    local retry_cmd = { "rg", "--vimgrep", "--color", "never", "--fixed-strings" }
    if file_type then
      table.insert(retry_cmd, "-t")
      table.insert(retry_cmd, file_type)
    end
    if exclude_file_type then
      table.insert(retry_cmd, "-T")
      table.insert(retry_cmd, exclude_file_type)
    end
    table.insert(retry_cmd, "-e")
    table.insert(retry_cmd, query)
    local ok2, retry_res = pcall(vim.fn.systemlist, retry_cmd)
    if ok2 and not vim.tbl_isempty(retry_res) then
      return {
        content = utils.make_code_block(table.concat(retry_res, "\n"), "txt"),
        params_line = make_params_line(query, false, file_type, exclude_file_type),
      }
    end
  end

  if vim.tbl_isempty(result) then
    -- 0 with empty output is unlikely; rg uses 1 for 'no matches'
    return {
      content = "No matches found for: " .. query,
      params_line = params_line,
    }
  end

  -- In some environments systemlist may capture stderr. If we detect a regex parse error
  -- in the output, retry with a literal search for resilience.
  local joined = table.concat(result, "\n")
  if use_regex and (joined:find("regex parse error", 1, true) or joined:find("unclosed group", 1, true)) then
    local retry_cmd = { "rg", "--vimgrep", "--color", "never", "--fixed-strings" }
    if file_type then
      table.insert(retry_cmd, "-t")
      table.insert(retry_cmd, file_type)
    end
    if exclude_file_type then
      table.insert(retry_cmd, "-T")
      table.insert(retry_cmd, exclude_file_type)
    end
    table.insert(retry_cmd, "-e")
    table.insert(retry_cmd, query)
    local ok2, retry_res = pcall(vim.fn.systemlist, retry_cmd)
    if ok2 and not vim.tbl_isempty(retry_res) then
      return {
        content = utils.make_code_block(table.concat(retry_res, "\n"), "txt"),
        params_line = make_params_line(query, false, file_type, exclude_file_type),
      }
    end
  end

  -- Wrap results in a code block for readability
  return {
    content = utils.make_code_block(joined, "txt"),
    params_line = params_line,
  }
end

return M
