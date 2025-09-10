-- lua/neoai/ai_tools/utils/find.lua

local M = {}

-- ... (All utility functions like trim, normalise_code_block are here) ...
-- ... (All find_* functions like find_line_trimmed_match, find_shrinking_window_match are here) ...
-- The full code for these helpers is in the previous response, so they are omitted here for brevity.

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

  -- If we are here, all attempts failed.
  return nil, nil
end

-- The individual find_* functions (find_line_trimmed_match, etc.) would be here.
-- They are identical to the previous version.

return M
