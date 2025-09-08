local M = {}
local utils = require("neoai.ai_tools.utils")

-- This tool lets the model run Tree-sitter queries against a buffer or file.
-- It aims to reduce reliance on grep/LSP for structural extraction tasks.
M.meta = {
  name = "TreeSitterQuery",
  description = utils.read_description("treesitter_query"),
  parameters = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "Tree-sitter s-expression query. Supports standard @capture labels.",
      },
      file_path = {
        type = "string",
        description = string.format(
          "(Optional) Path to the file to inspect (relative to cwd %s). If omitted, uses current buffer.",
          vim.fn.getcwd()
        ),
      },
      language = {
        type = "string",
        description = "(Optional) Force language name (e.g., 'lua', 'python'). If omitted, detected from buffer.",
      },
      include_text = {
        type = "boolean",
        description = "(Optional) Include matched node text in results. Default: true.",
      },
      include_ranges = {
        type = "boolean",
        description = "(Optional) Include start/end ranges (1-based line:col). Default: true.",
      },
      captures = {
        type = "array",
        items = { type = "string" },
        description = "(Optional) Only include these @capture names (e.g., ['@func', 'name']).",
      },
      first_only = {
        type = "boolean",
        description = "(Optional) Return only the first match for brevity.",
      },
      max_results = {
        type = "integer",
        description = "(Optional) Maximum number of matches to return (safeguard).",
      },
    },
    required = { "query" },
    additionalProperties = false,
  },
}

local function get_bufnr_for_path(file_path)
  if file_path and #file_path > 0 then
    local bufnr = vim.fn.bufnr(file_path, true)
    vim.fn.bufload(bufnr)
    return bufnr
  else
    return vim.api.nvim_get_current_buf()
  end
end

local function detect_lang(bufnr)
  -- Prefer explicit ft, then treesitter language mapping
  local ft = vim.bo[bufnr].filetype
  if ft and ft ~= "" then
    return ft
  end
  -- Fallback: try via nvim-treesitter language detection helpers if available
  local ok_ns, parsers = pcall(require, "nvim-treesitter.parsers")
  if ok_ns then
    local lang = parsers.get_buf_lang(bufnr)
    if lang and lang ~= "" then
      return lang
    end
  end
  return nil
end

local function get_parser(bufnr, lang)
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return nil, "Tree-sitter not available (require 'vim.treesitter' failed)"
  end

  -- Prefer nvim-treesitter's get_parser when installed to leverage its mapping
  local ok_np, ts_parsers = pcall(require, "nvim-treesitter.parsers")
  if ok_np and ts_parsers then
    local resolved = lang or ts_parsers.get_buf_lang(bufnr)
    if not resolved or resolved == "" then
      return nil, "Unable to determine language for buffer"
    end
    local ok_get, parser = pcall(ts.get_parser, bufnr, resolved)
    if ok_get and parser then
      return parser, nil
    else
      return nil, "Failed to get parser for language '" .. tostring(resolved) .. "'"
    end
  end

  -- Fallback to core treesitter
  if not lang then
    return nil, "Language not specified and nvim-treesitter not installed"
  end
  local ok_get, parser = pcall(ts.get_parser, bufnr, lang)
  if ok_get and parser then
    return parser, nil
  else
    return nil, "Failed to get parser for language '" .. tostring(lang) .. "'"
  end
end

local function make_range(node)
  if not node or type(node.range) ~= "function" then
    return nil, "Invalid node object provided."
  end

  local sr, sc, er, ec = node:range() -- 0-based
  return {
    start_line = sr + 1,
    start_col = sc + 1,
    end_line = er + 1,
    end_col = ec + 1,
  }
end

local function node_text(node, bufnr)
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return nil
  end
  local ok2, text = pcall(ts.get_node_text, node, bufnr)
  if ok2 then
    return text
  end
  -- Fallback: manual extraction via buffer lines
  local sr, sc, er, ec = node:range()
  local lines = vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {})
  return table.concat(lines, "\n")
end

local function parse_query_for_lang(lang, query)
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return nil, "Tree-sitter not available (require 'vim.treesitter' failed)"
  end
  if ts.query and ts.query.parse then
    local okp, q = pcall(ts.query.parse, lang, query)
    if okp then
      return q
    end
    return nil, q
  elseif ts.parse_query then
    local okp, q = pcall(ts.parse_query, lang, query)
    if okp then
      return q
    end
    return nil, q
  end
  return nil, "No query.parse or parse_query available in vim.treesitter"
end

M.run = function(args)
  args = args or {}
  local query = args.query
  if not query or #query == 0 then
    return "Error: 'query' is required."
  end

  local bufnr = get_bufnr_for_path(args.file_path)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return "Failed to load buffer for: " .. tostring(args.file_path)
  end

  local lang = args.language or detect_lang(bufnr)
  local parser, perr = get_parser(bufnr, lang)
  if not parser then
    return perr or ("Failed to get parser for buffer (lang=" .. tostring(lang) .. ")")
  end

  local tsq, qerr = parse_query_for_lang(lang or detect_lang(bufnr) or "", query)
  if not tsq then
    return "Query parse error: " .. tostring(qerr)
  end

  -- Defaults
  local include_text = args.include_text ~= false -- default true
  local include_ranges = args.include_ranges ~= false -- default true
  local first_only = args.first_only == true
  local max_results = args.max_results or 500

  -- Optional filter set for capture names
  local capture_filter
  if type(args.captures) == "table" and #args.captures > 0 then
    capture_filter = {}
    for _, c in ipairs(args.captures) do
      -- Allow '@name' or 'name'
      local key = tostring(c)
      if key:sub(1, 1) == "@" then
        key = key:sub(2)
      end
      capture_filter[key] = true
    end
  end

  -- Ensure we have an up-to-date syntax tree
  local tree = parser:parse()[1]
  local root = tree:root()

  local results = {}
  local count = 0

  for _, match, metadata in tsq:iter_matches(root, bufnr, 0, -1) do
    -- match is a table: index -> node, with capture names from the query
    for id, node in pairs(match) do
      local capname = tsq.captures[id]
      -- Filter by capture names if provided
      if not capture_filter or capture_filter[capname] then
        count = count + 1
        if count > max_results then
          break
        end
        local item = {
          capture = "@" .. capname,
        }
        if include_ranges then
          item.range = make_range(node)
        end
        if include_text then
          item.text = node_text(node, bufnr)
        end
        -- Attach any metadata fields for this capture, if present
        if metadata and metadata[id] then
          item.metadata = metadata[id]
        end
        table.insert(results, item)
        if first_only then
          break
        end
      end
    end
    if first_only or count > max_results then
      break
    end
  end

  if #results == 0 then
    return utils.make_code_block("No matches for query", "txt")
  end

  -- Format results in a deterministic, readable manner
  local lines = {}
  for i, r in ipairs(results) do
    local parts = { string.format("%d. %s", i, r.capture) }
    if r.range then
      table.insert(
        parts,
        string.format(" [%d:%d - %d:%d]", r.range.start_line, r.range.start_col, r.range.end_line, r.range.end_col)
      )
    end
    if r.text then
      -- Trim long texts for readability
      local t = r.text
      if #t > 400 then
        t = t:sub(1, 400) .. " …"
      end
      -- Replace newlines to keep each result on one or a few lines
      t = t:gsub("\n", "\\n")
      table.insert(parts, " => " .. t)
    end
    lines[#lines + 1] = table.concat(parts)
  end

  return utils.make_code_block(table.concat(lines, "\n"), "txt")
end

return M
