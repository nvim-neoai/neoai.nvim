local M = {}

--[[
  UTILITY FUNCTIONS
--]]

--- Utility to trim whitespace from a string.
---@param s string
---@return string
local function trim(s)
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end

--- Normalises a block of code for fuzzy matching.
--- Removes comments and collapses whitespace.
---@param lines table A table of strings representing the code block.
---@return string The normalised code string.
local function normalise_code_block(lines)
  if not lines or #lines == 0 then
    return ""
  end

  local content = table.concat(lines, "\n")
  -- Remove multi-line comments first (JS/TS, HTML, Lua long comments)
  content = content:gsub("/%*.-%*/", ""):gsub("<!--.- -->", ""):gsub("%-%-%[%[.-%]%]", "")
  -- Remove JSX curly-wrapped block comments like `{/* ... */}` (with optional surrounding whitespace)
  -- This prevents leaving stray `{}` behind which would otherwise break normalised comparisons.
  content = content:gsub("{%s*/%*.-%*/%s*}", "")
  -- Lowercase after comment stripping to make matching case-insensitive
  content = content:lower()
  -- Remove single-line comments
  content = content:gsub("//[^\n]*", ""):gsub("#[^\n]*", ""):gsub("%-%-[^\n]*", "")
  -- Normalise all whitespace (newlines, tabs, multiple spaces) to a single space
  content = content:gsub("%s+", " ")
  -- Trim leading/trailing whitespace
  return content:gsub("^%s+", ""):gsub("%s+$", "")
end

--[[
  SEARCH STRATEGY IMPLEMENTATIONS
  All helper functions are defined here as locals before they are used.
--]]

--- Stage 2: Attempt to find a block by matching lines with whitespace trimmed.
local function find_line_trimmed_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  if #block_lines_to_find == 0 then
    return nil, nil
  end
  local start_search = start_hint or 1
  local end_search = (end_hint or #buffer_lines) - #block_lines_to_find + 1
  for i = start_search, end_search do
    local match = true
    for j = 1, #block_lines_to_find do
      if trim(buffer_lines[i + j - 1]) ~= trim(block_lines_to_find[j]) then
        match = false
        break
      end
    end
    if match then
      return i, i + #block_lines_to_find - 1
    end
  end
  return nil, nil
end

--- Stage 3: For single-line searches, check if the search string is a substring of a buffer line.
local function find_fuzzy_substring_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  if #block_lines_to_find ~= 1 then
    return nil, nil
  end
  local start_search = start_hint or 1
  local end_search = end_hint or #buffer_lines
  local trimmed_search_line = trim(block_lines_to_find[1])
  if trimmed_search_line == "" then
    return nil, nil
  end
  for i = start_search, end_search do
    local trimmed_buffer_line = trim(buffer_lines[i])
    if string.find(trimmed_buffer_line, trimmed_search_line, 1, true) then
      vim.notify("[AI] Found block via fuzzy substring match.", vim.log.levels.DEBUG, { title = "NeoAI" })
      return i, i
    end
  end
  return nil, nil
end

--- Stage 4: Attempt to find a block using its first and last lines as anchors.
local function find_block_anchor_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  if #block_lines_to_find < 3 then
    return nil, nil
  end
  local first_line_search = trim(block_lines_to_find[1])
  local last_line_search = trim(block_lines_to_find[#block_lines_to_find])
  local block_size = #block_lines_to_find
  local start_search = start_hint or 1
  local end_search = (end_hint or #buffer_lines) - block_size + 1
  for i = start_search, end_search do
    if trim(buffer_lines[i]) == first_line_search then
      if trim(buffer_lines[i + block_size - 1]) == last_line_search then
        vim.notify("[AI] Found block via block-anchor match.", vim.log.levels.DEBUG, { title = "NeoAI" })
        return i, i + block_size - 1
      end
    end
  end
  return nil, nil
end

--- Stage 5: Shrinking Window Sub-Block Match.
local function find_shrinking_window_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  local original_size = #block_lines_to_find
  if original_size < 3 then
    return nil, nil
  end
  local min_block_size = math.max(2, math.floor(original_size * 0.5))
  for top_trim = 0, original_size - min_block_size do
    for bottom_trim = 0, original_size - top_trim - min_block_size do
      local sub_block_start = 1 + top_trim
      local sub_block_end = original_size - bottom_trim
      local sub_block = {}
      for i = sub_block_start, sub_block_end do
        table.insert(sub_block, block_lines_to_find[i])
      end
      local start_line, end_line = find_line_trimmed_match(buffer_lines, sub_block, start_hint, end_hint)
      if start_line then
        vim.notify(
          "[AI] Found block via shrinking window match. Original size: "
            .. original_size
            .. ", Found size: "
            .. #sub_block,
          vim.log.levels.DEBUG,
          { title = "NeoAI" }
        )
        return start_line, end_line
      end
    end
  end
  return nil, nil
end

--- Stage 6: Tree-sitter structural match.
local ts_utils = vim.treesitter
local parsers = require("nvim-treesitter.parsers")

local function is_significant_node(node)
  if not node then
    return false
  end
  if node:is_named() then
    local node_type = node:type()
    return not (string.find(node_type, "comment") or string.find(node_type, "doc"))
  end
  return false
end

local function get_significant_children(node)
  local children = {}
  for child in node:iter_children() do
    if is_significant_node(child) then
      table.insert(children, child)
    end
  end
  return children
end

local function compare_nodes(node_a, node_b, buffer_lines)
  if node_a:type() ~= node_b:type() then
    return false
  end
  local children_a = get_significant_children(node_a)
  local children_b = get_significant_children(node_b)
  if #children_a ~= #children_b then
    return false
  end
  if #children_a == 0 then
    local text_a = ts_utils.get_node_text(node_a, 0)
    local text_b = ts_utils.get_node_text(node_b, buffer_lines)
    return text_a == text_b
  end
  for i = 1, #children_a do
    if not compare_nodes(children_a[i], children_b[i], buffer_lines) then
      return false
    end
  end
  return true
end

local function find_ts_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  local bufnr = vim.api.nvim_get_current_buf()
  local lang = parsers.get_parser_configs()[vim.bo[bufnr].filetype]
  if not lang then
    return nil, nil
  end
  local ok, parser = pcall(ts_utils.get_parser, bufnr)
  if not ok or not parser then
    return nil, nil
  end
  local block_parser = ts_utils.get_parser(0, lang.name)
  local block_tree = block_parser:parse_string(table.concat(block_lines_to_find, "\n"))
  local block_root = block_tree:root()
  if not block_root then
    return nil, nil
  end
  local block_significant_children = get_significant_children(block_root)
  if #block_significant_children ~= 1 then
    return nil, nil
  end
  local target_node = block_significant_children[1]
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
      return r1 + 1, r2 + 1
    end
  end
  return nil, nil
end

--- Stage 7: Normalised text match.
local function find_normalised_text_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
  local fuzziness_allowed = math.floor(#block_lines_to_find * 0.1)
  local normalised_target = normalise_code_block(block_lines_to_find)
  if normalised_target == "" then
    return nil, nil
  end
  local start_search = start_hint or 1
  local end_search = end_hint or #buffer_lines
  local line_count_tolerance = 5
  local min_scan_lines = math.max(1, #block_lines_to_find - line_count_tolerance)
  local max_scan_lines = #block_lines_to_find + line_count_tolerance
  for i = start_search, end_search do
    for L = min_scan_lines - fuzziness_allowed, max_scan_lines + fuzziness_allowed do
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

  -- Stage 1: Exact match (case-insensitive).
  do
    local start_search = start_hint or 1
    local end_search = (end_hint or #buffer_lines) - #block_lines_to_find + 1
    for i = start_search, end_search do
      local match = true
      for j = 1, #block_lines_to_find do
        if buffer_lines[i + j - 1]:lower() ~= block_lines_to_find[j]:lower() then
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

  -- Stage 2: Line-trimmed match.
  do
    local start_line, end_line = find_line_trimmed_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
    if start_line then
      return start_line, end_line
    end
  end

  -- Stage 3: Fuzzy substring match (for single lines).
  do
    local start_line, end_line = find_fuzzy_substring_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
    if start_line then
      return start_line, end_line
    end
  end

  -- Stage 4: Block anchor match.
  do
    local start_line, end_line = find_block_anchor_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
    if start_line then
      return start_line, end_line
    end
  end

  -- Stage 5: Shrinking window sub-block match.
  do
    local start_line, end_line = find_shrinking_window_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
    if start_line then
      return start_line, end_line
    end
  end

  -- Stage 6: Tree-sitter structural match.
  do
    local ok, start_line, end_line = pcall(find_ts_match, buffer_lines, block_lines_to_find, start_hint, end_hint)
    if ok and start_line then
      vim.notify("[AI] Found block via Tree-sitter structural match.", vim.log.levels.INFO, { title = "NeoAI" })
      return start_line, end_line
    end
  end

  -- Stage 7: Normalised text match.
  do
    local start_line, end_line = find_normalised_text_match(buffer_lines, block_lines_to_find, start_hint, end_hint)
    if start_line then
      vim.notify("[AI] Found block via normalised text match.", vim.log.levels.WARN, { title = "NeoAI" })
      return start_line, end_line
    end
  end

  -- If we are here, all attempts failed in the forward scan.
  -- Wrap-around fallback: search from the beginning up to (start_hint - 1)
  if start_hint and start_hint > 1 then
    local wrap_end = math.min(#buffer_lines, start_hint - 1)
    if wrap_end >= 1 then
      local s, e = M.find_block_location(buffer_lines, block_lines_to_find, 1, wrap_end)
      if s then
        vim.notify("[AI] Found block via wrap-around search.", vim.log.levels.DEBUG, { title = "NeoAI" })
        return s, e
      end
    end
  end

  -- Still not found.
  return nil, nil
end

return M
