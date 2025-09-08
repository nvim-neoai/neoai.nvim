-- lua/neoai/ai_tools/edit/find.lua

local M = {}

--[[
  UTILITY FUNCTIONS
--]]

--- Normalises a block of code for fuzzy matching.
--- Removes comments and collapses whitespace.
---@param lines table A table of strings representing the code block.
---@return string The normalised code string.
local function normalise_code_block(lines)
  if not lines or #lines == 0 then
    return ""
  end

  local content = table.concat(lines, "\n")
  -- Remove block comments (non-greedy)
  content = content:gsub("/%*.-%*/", ""):gsub("<!--.- -->", ""):gsub("%-%-%[%[.-%]%]", "")
  -- Remove single-line comments
  content = content:gsub("//[^\n]*", ""):gsub("#[^\n]*", ""):gsub("%-%-[^\n]*", "")
  -- Normalise whitespace (newlines, tabs, multiple spaces) to a single space
  content = content:gsub("%s+", " ")
  -- Trim leading/trailing whitespace
  return content:gsub("^%s+", ""):gsub("%s+$", "")
end

--[[
  TREE-SITTER BASED SEARCH (STAGE 2)
--]]

local ts_utils = vim.treesitter
local parsers = require("nvim-treesitter.parsers")

--- Check if a Tree-sitter node is significant for comparison.
--- We ignore comments, punctuation, and other "noise".
---@param node userdata The Tree-sitter node.
---@return boolean
local function is_significant_node(node)
  if not node then
    return false
  end
  -- Anonymous nodes are typically syntax sugar like '(', ')', ',', ';'.
  if node:is_named() then
    local node_type = node:type()
    -- Explicitly ignore comments, as some parsers treat them as named.
    return not (string.find(node_type, "comment") or string.find(node_type, "doc"))
  end
  return false
end

--- Get a list of significant child nodes from a given node.
---@param node userdata The parent Tree-sitter node.
---@return table A list of significant child nodes.
local function get_significant_children(node)
  local children = {}
  for child in node:iter_children() do
    if is_significant_node(child) then
      table.insert(children, child)
    end
  end
  return children
end

--- Recursively compare two Tree-sitter nodes for structural equivalence.
---@param node_a userdata The first node.
---@param node_b userdata The second node.
---@param buffer_lines table The lines of the buffer for text extraction.
---@return boolean True if nodes are structurally equivalent.
local function compare_nodes(node_a, node_b, buffer_lines)
  if node_a:type() ~= node_b:type() then
    return false
  end

  local children_a = get_significant_children(node_a)
  local children_b = get_significant_children(node_b)

  if #children_a ~= #children_b then
    return false
  end

  -- If it's a leaf node (no significant children), compare its text content.
  if #children_a == 0 then
    local text_a = ts_utils.get_node_text(node_a, 0) -- Text from node_a's source
    local text_b = ts_utils.get_node_text(node_b, buffer_lines) -- Text from buffer
    return text_a == text_b
  end

  -- If it has children, recurse.
  for i = 1, #children_a do
    if not compare_nodes(children_a[i], children_b[i], buffer_lines) then
      return false
    end
  end

  return true
end

--- Attempt to find a block using Tree-sitter structural matching.
---@param buffer_lines table The lines of the entire buffer.
---@param block_lines_to_find table The lines of the block to find.
---@param start_hint integer|nil The line to start searching from (1-based).
---@param end_hint integer|nil The line to end searching at (1-based).
---@return integer|nil, integer|nil The start and end line numbers of the match, or nil.
local function find_ts_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  local bufnr = vim.api.nvim_get_current_buf()
  local lang = parsers.get_parser_configs()[vim.bo[bufnr].filetype]
  if not lang then
    return nil, nil -- No parser configured for this filetype
  end

  -- Ensure parser is installed and available
  local ok, parser = pcall(ts_utils.get_parser, bufnr)
  if not ok or not parser then
    return nil, nil
  end

  -- Parse the block to find. We create a temporary, detached tree.
  local block_parser = ts_utils.get_parser(0, lang.name)
  local block_tree = block_parser:parse_string(table.concat(block_lines_to_find, "\n"))
  local block_root = block_tree:root()
  if not block_root then
    return nil, nil
  end

  -- The target AST must have a single significant node at its root after parsing.
  -- Otherwise, it's likely a collection of unrelated statements, which is hard to match.
  local block_significant_children = get_significant_children(block_root)
  if #block_significant_children ~= 1 then
    return nil, nil
  end
  local target_node = block_significant_children[1]

  -- Parse the entire buffer
  local buffer_tree = parser:parse()[1]
  if not buffer_tree then
    return nil, nil
  end
  local buffer_root = buffer_tree:root()

  local query_str = string.format("([(%s)] @match)", target_node:type())
  local ok_query, query = pcall(ts_utils.query.parse, lang.name, query_str)
  if not ok_query then
    return nil, nil
  end

  local search_start_row = (start_hint or 1) - 1
  local search_end_row = (end_hint or #buffer_lines) - 1

  for _, node, _ in query:iter_captures(buffer_root, 0, search_start_row, search_end_row + 1) do
    if compare_nodes(target_node, node, buffer_lines) then
      local r1, _, r2, _ = node:range()
      return r1 + 1, r2 + 1 -- Convert 0-based to 1-based
    end
  end

  return nil, nil
end

--[[
  NORMALISED TEXT SEARCH (STAGE 3)
--]]

--- Attempt to find a block using normalised text matching.
---@param buffer_lines table The lines of the entire buffer.
---@param block_lines_to_find table The lines of the block to find.
---@param start_hint integer|nil The line to start searching from (1-based).
---@param end_hint integer|nil The line to end searching at (1-based).
---@return integer|nil, integer|nil The start and end line numbers of the match, or nil.
local function find_normalised_text_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  local normalised_target = normalise_code_block(block_lines_to_find)
  if normalised_target == "" then
    return nil, nil -- Cannot match an empty or comment-only block
  end

  local start_search = start_hint or 1
  local end_search = end_hint or #buffer_lines

  local line_count_tolerance = 5
  local min_scan_lines = math.max(1, #block_lines_to_find - line_count_tolerance)
  local max_scan_lines = #block_lines_to_find + line_count_tolerance

  for i = start_search, end_search do
    for L = min_scan_lines, max_scan_lines do
      if i + L - 1 > #buffer_lines then
        break
      end

      local window_lines = {}
      for k = i, i + L - 1 do
        table.insert(window_lines, buffer_lines[k])
      end

      local normalised_window = normalise_code_block(window_lines)

      if normalised_window == normalised_target then
        return i, i + L - 1
      end
    end
  end
  return nil, nil
end

--[[
  MAIN FUNCTION
--]]

--- Finds the location of a code block using a robust, multi-stage approach.
---@param buffer_lines table The lines of the entire buffer.
---@param block_lines_to_find table The lines of the block to find.
---@param start_hint integer|nil The line to start searching from (1-based).
---@param end_hint integer|nil The line to end searching at (1-based).
---@return integer|nil, integer|nil The start and end line numbers of the match, or nil.
function M.find_block_location(buffer_lines, block_lines_to_find, start_hint, end_hint)
  if #block_lines_to_find == 0 then
    return nil, nil
  end

  -- Stage 1: Exact match. Fast and reliable if the AI is accurate.
  do
    local start_search = start_hint or 1
    local end_search = end_hint or #buffer_lines
    end_search = math.min(end_search, #buffer_lines - #block_lines_to_find + 1)

    for i = start_search, end_search do
      local match = true
      for j = 1, #block_lines_to_find do
        if buffer_lines[i + j - 1] ~= block_lines_to_find[j] then
          match = false
          break
        end
      end
      if match then
        vim.notify("[AI] Found block via exact match.", vim.log.levels.DEBUG, { title = "NeoAI" })
        return i, i + #block_lines_to_find - 1
      end
    end
  end

  -- Stage 2: Tree-sitter structural match. Resilient to formatting and comment changes.
  do
    local ok, start_line, end_line = pcall(find_ts_match, buffer_lines, block_lines_to_find, start_hint, end_hint)
    if ok and start_line then
      vim.notify("[AI] Found block via Tree-sitter structural match.", vim.log.levels.INFO, { title = "NeoAI" })
      return start_line, end_line
    end
  end

  -- Stage 3: Normalised text match. A robust fallback.
  do
    local start_line, end_line = find_normalised_text_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
    if start_line then
      vim.notify("[AI] Found block via normalised text match.", vim.log.levels.WARN, { title = "NeoAI" })
      return start_line, end_line
    end
  end

  -- If we are here, all attempts failed.
  return nil, nil
end

return M
