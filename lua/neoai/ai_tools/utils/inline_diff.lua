local M = {}

local open_non_ai_buffer = require("neoai.ai_tools.utils.open_non_ai_buffer")

local PRIORITY = (vim.hl or vim.highlight).priorities and (vim.hl or vim.highlight).priorities.user or 200
local NAMESPACE = vim.api.nvim_create_namespace("neoai-inline-diff")
local HINT_NAMESPACE = vim.api.nvim_create_namespace("neoai-inline-diff-hint")

-- Default keymaps (buffer-local)
local DEFAULT_KEYS = {
  ours = "co",     -- keep current (revert hunk)
  theirs = "ct",   -- accept suggestion (keep new)
  prev = "[d",     -- previous hunk
  next = "]d",     -- next hunk
  cancel = "q",    -- cancel review and restore original file content
}

-- Highlight groups (created if missing)
local function ensure_highlights()
  local function set(name, opts)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
  -- Incoming/new lines background
  set("NeoAIIncoming", { link = "DiffAdd", default = true })
  -- Deleted/old lines shown as virtual lines
  set("NeoAIDeleted", { link = "DiffDelete", default = true })
  -- Inline hint text
  set("NeoAIInlineHint", { link = "Comment", default = true })
end

local function slice(tbl, s, e)
  local res = {}
  if s == nil or e == nil then return res end
  for i = s, e do
    res[#res + 1] = tbl[i]
  end
  return res
end

local function lines_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- Compute diff hunks using vim.diff; returns a list of hunks { a_s, a_c, b_s, b_c }
local function compute_patch(old_lines, new_lines)
  local old_str = table.concat(old_lines, "\n")
  local new_str = table.concat(new_lines, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local patch = vim.diff(old_str, new_str, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  }) or {}

  if #patch == 0 and not lines_equal(old_lines, new_lines) then
    patch = { { 1, #old_lines, 1, #new_lines } }
  end

  return patch
end

-- Build diff blocks on top of patch
local function build_diff_blocks(old_lines, new_lines, patch)
  local blocks = {}
  for _, h in ipairs(patch) do
    local a_s, a_c, b_s, b_c = h[1], h[2], h[3], h[4]
    local block = {
      old_lines = a_c > 0 and slice(old_lines, a_s, a_s + a_c - 1) or {},
      new_lines = b_c > 0 and slice(new_lines, b_s, b_s + b_c - 1) or {},
      -- Coordinates in NEW buffer
      new_start_line = math.max(1, b_s),
      new_end_line = math.max(0, b_s + math.max(b_c, 1) - 1),
    }
    table.insert(blocks, block)
  end

  table.sort(blocks, function(a, b) return a.new_start_line < b.new_start_line end)

  return blocks
end

local function show_hint(bufnr, lnum, keys)
  vim.api.nvim_buf_clear_namespace(bufnr, HINT_NAMESPACE, 0, -1)
  local hint = string.format("[<%s>: ours, <%s>: theirs, <%s>: prev, <%s>: next, <%s>: cancel]", keys.ours, keys.theirs,
    keys.prev, keys.next, keys.cancel)
  return vim.api.nvim_buf_set_extmark(bufnr, HINT_NAMESPACE, math.max(0, lnum - 1), -1, {
    hl_group = "NeoAIInlineHint",
    virt_text = { { hint, "NeoAIInlineHint" } },
    virt_text_pos = "right_align",
    priority = PRIORITY,
  })
end

local function highlight_blocks(bufnr, blocks)
  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  local max_col = vim.o.columns
  for _, b in ipairs(blocks) do
    local start_line = math.max(1, b.new_start_line)
    local end_line = math.max(start_line - 1, b.new_end_line)

    -- Highlight incoming (new) lines
    if #b.new_lines > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, start_line - 1, 0, {
        hl_group = "NeoAIIncoming",
        hl_eol = true,
        hl_mode = "combine",
        end_row = end_line,
      })
    end

    -- Show deleted (old) lines as virt_lines just above the block's end
    if #b.old_lines > 0 then
      local virt_lines = {}
      for _, l in ipairs(b.old_lines) do
        local padded = l .. string.rep(" ", math.max(0, max_col - #l))
        table.insert(virt_lines, { { padded, "NeoAIDeleted" } })
      end
      vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, math.max(0, end_line - 1), 0, {
        virt_lines = virt_lines,
        hl_mode = "combine",
        hl_eol = true,
      })
    end
  end
end

local function recalc_positions_after(blocks, removed_idx, distance)
  for i = removed_idx + 1, #blocks do
    blocks[i].new_start_line = blocks[i].new_start_line + distance
    blocks[i].new_end_line = blocks[i].new_end_line + distance
  end
end

local function find_block_at_cursor(blocks, cursor_line)
  for idx, b in ipairs(blocks) do
    if cursor_line >= b.new_start_line and cursor_line <= b.new_end_line then
      return b, idx
    end
    -- Handle deletion-only hunks (no new lines): consider cursor at insertion point
    if #b.new_lines == 0 and cursor_line == b.new_start_line then
      return b, idx
    end
  end
  return nil, nil
end

local function prev_block(blocks, cursor_line)
  local best, best_dist
  for _, b in ipairs(blocks) do
    if b.new_start_line <= cursor_line then
      local d = cursor_line - b.new_start_line
      if not best_dist or d < best_dist then
        best = b
        best_dist = d
      end
    end
  end
  return best or blocks[#blocks]
end

local function next_block(blocks, cursor_line)
  local best, best_dist
  for _, b in ipairs(blocks) do
    if b.new_start_line >= cursor_line then
      local d = b.new_start_line - cursor_line
      if not best_dist or d < best_dist then
        best = b
        best_dist = d
      end
    end
  end
  return best or blocks[1]
end

local function buf_set_lines_safe(bufnr, start_idx1, end_idx1, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local max_line = vim.api.nvim_buf_line_count(bufnr)
  local s = math.min(math.max(0, start_idx1), max_line)
  local e = math.min(math.max(0, end_idx1), max_line)
  vim.api.nvim_buf_set_lines(bufnr, s, e, false, lines)
end

-- Apply inline diff preview and interactivity. Returns true, message on success; false, error on failure.
function M.apply(abs_path, old_lines, new_lines, opts)
  ensure_highlights()

  opts = opts or {}
  local keys = vim.tbl_deep_extend("force", DEFAULT_KEYS, opts.keys or {})

  -- Nothing to do
  if lines_equal(old_lines, new_lines) then
    return false, "No changes detected"
  end

  -- Compute patch and blocks
  local patch = compute_patch(old_lines, new_lines)
  local blocks = build_diff_blocks(old_lines, new_lines, patch)
  if #blocks == 0 then
    return false, "No hunks to review"
  end

  -- Open target in a non-AI buffer and replace content with NEW lines (preview 'theirs')
  open_non_ai_buffer(abs_path)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].modifiable = true

  -- Cache original for cancellation
  local original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Replace with new file content
  buf_set_lines_safe(bufnr, 0, -1, new_lines)

  -- Highlight diff blocks
  highlight_blocks(bufnr, blocks)

  -- Autocmds and state
  local augroup = vim.api.nvim_create_augroup("neoai_inline_diff_" .. bufnr, { clear = true })
  local function cleanup()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, HINT_NAMESPACE, 0, -1)
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    -- Remove keymaps
    pcall(vim.keymap.del, { "n", "v" }, keys.ours, { buffer = bufnr })
    pcall(vim.keymap.del, { "n", "v" }, keys.theirs, { buffer = bufnr })
    pcall(vim.keymap.del, { "n", "v" }, keys.prev, { buffer = bufnr })
    pcall(vim.keymap.del, { "n", "v" }, keys.next, { buffer = bufnr })
    pcall(vim.keymap.del, { "n", "v" }, keys.cancel, { buffer = bufnr })
  end

  -- Cursor hint
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufWinEnter", "BufEnter" }, {
    buffer = bufnr,
    group = augroup,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local b = next_block(blocks, cursor[1])
      if b then
        show_hint(bufnr, b.new_start_line, keys)
      end
    end,
  })

  -- BufWritePost: after successful write, just cleanup
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    group = augroup,
    callback = function()
      if #blocks == 0 then
        cleanup()
        vim.schedule(function()
          vim.notify("NeoAI: changes written to disk", vim.log.levels.INFO)
        end)
      else
        -- Even if unresolved blocks remain, the user chose to save previewed content
        cleanup()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload", "BufHidden" }, {
    buffer = bufnr,
    group = augroup,
    callback = cleanup,
  })

  -- Keymaps
  local function goto_block(b)
    if not b then return end
    local line = math.max(1, b.new_start_line)
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd("normal! zz")
  end

  local function remove_block(idx, keep_new)
    local b = blocks[idx]
    if not b then return end
    -- Adjust following blocks positions
    local distance = 0
    if keep_new then
      -- keep new => buffer already contains new; positions stay unless old/new len diff matters on later blocks
      distance = 0
    else
      -- revert to old => we replace current new lines with old lines, potentially shifting later blocks
      distance = #b.old_lines - #b.new_lines
    end
    table.remove(blocks, idx)
    if distance ~= 0 then
      recalc_positions_after(blocks, idx - 1, distance)
    end
  end

  local function accept_theirs()
    local cur = vim.api.nvim_win_get_cursor(0)
    local b, idx = find_block_at_cursor(blocks, cur[1])
    if not b then return end
    -- Keep new lines, just clear extmarks for this block
    highlight_blocks(bufnr, {})
    remove_block(idx, true)
    highlight_blocks(bufnr, blocks)
    goto_block(next_block(blocks, cur[1]))
  end

  local function keep_ours()
    local cur = vim.api.nvim_win_get_cursor(0)
    local b, idx = find_block_at_cursor(blocks, cur[1])
    if not b then return end
    -- Replace this region with old lines
    local start0 = math.max(0, b.new_start_line - 1)
    local end0 = math.max(start0, b.new_end_line)
    buf_set_lines_safe(bufnr, start0, end0, b.old_lines)
    highlight_blocks(bufnr, {})
    remove_block(idx, false)
    highlight_blocks(bufnr, blocks)
    goto_block(next_block(blocks, cur[1]))
  end

  local function goto_prev()
    local cur = vim.api.nvim_win_get_cursor(0)
    goto_block(prev_block(blocks, cur[1]))
  end

  local function goto_next()
    local cur = vim.api.nvim_win_get_cursor(0)
    goto_block(next_block(blocks, cur[1]))
  end

  local function cancel_review()
    -- Restore original content and cleanup
    buf_set_lines_safe(bufnr, 0, -1, original_lines)
    cleanup()
    vim.schedule(function()
      vim.notify("NeoAI: inline diff cancelled; original content restored", vim.log.levels.WARN)
    end)
  end

  local mapopts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set({ "n", "v" }, keys.theirs, accept_theirs, mapopts)
  vim.keymap.set({ "n", "v" }, keys.ours, keep_ours, mapopts)
  vim.keymap.set({ "n", "v" }, keys.next, goto_next, mapopts)
  vim.keymap.set({ "n", "v" }, keys.prev, goto_prev, mapopts)
  vim.keymap.set({ "n", "v" }, keys.cancel, cancel_review, mapopts)

  -- Focus first block
  if blocks[1] then
    goto_block(blocks[1])
  end

  local msg = string.format(
    "🔍 Inline diff preview opened for %d change(s). Use <%s> ours, <%s> theirs, <%s>/<%s> navigate, <%s> cancel, :w to save.",
    #blocks, keys.ours, keys.theirs, keys.prev, keys.next, keys.cancel)

  return true, msg
end

return M
