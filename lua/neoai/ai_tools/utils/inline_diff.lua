local M = {}

-- ---
-- Helper Functions
-- ---

local PRIORITY = (vim.hl or vim.highlight).priorities and (vim.hl or vim.highlight).priorities.user or 200
local NAMESPACE = vim.api.nvim_create_namespace("neoai-inline-diff")
local HINT_NAMESPACE = vim.api.nvim_create_namespace("neoai-inline-diff-hint")

local DEFAULT_KEYS = {
  ours = "co", -- keep current (revert hunk)
  theirs = "ct", -- accept suggestion (keep new)
  all = "ca", -- accept all remaining hunks
  prev = "[d", -- previous hunk
  next = "]d", -- next hunk
  cancel = "q", -- cancel review and restore original file content
}

-- These will only be used if the theme doesn't define the linked groups.
local function ensure_highlights()
  local function set(name, opts)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
  set("NeoAIIncoming", { link = "DiffAdd", bg = "#1A3E2A", default = true })
  set("NeoAIDeleted", { link = "DiffDelete", bg = "#4D2424", default = true })
  set("NeoAIInlineHint", { link = "Comment", default = true })
end

-- This avoids opening it in file explorers or other non-editing windows.
local function find_last_active_editing_window()
  -- nvim_list_wins() is the API equivalent and has been around much longer.
  for _, win_handle in ipairs(vim.api.nvim_list_wins()) do
    -- Check if the window is valid and currently shown
    if vim.api.nvim_win_is_valid(win_handle) then
      local bufnr = vim.api.nvim_win_get_buf(win_handle)
      local buf_type = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
      local file_type = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

      -- We are looking for a normal buffer that is not a file explorer
      if buf_type == "" and file_type ~= "chadtree" and file_type ~= "NvimTree" then
        return win_handle -- Return the window handle
      end
    end
  end
  return 0 -- Fallback to current window
end

local function slice(tbl, s, e)
  local res = {}
  if s == nil or e == nil then
    return res
  end
  for i = s, e do
    res[#res + 1] = tbl[i]
  end
  return res
end

local function lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

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

-- Additional helpers for final outcome reporting
local function unified_diff(old_lines, new_lines)
  local old_str = table.concat(old_lines or {}, "\n")
  local new_str = table.concat(new_lines or {}, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local diff = vim.diff(old_str, new_str, { result_type = "unified", algorithm = "histogram" })
  return diff or "(no changes)"
end

local function simple_hash(s)
  s = s or ""
  local h1, h2 = 0, 0
  for i = 1, #s do
    local b = string.byte(s, i)
    h1 = (h1 + b) % 4294967296
    h2 = (h2 * 31 + b) % 4294967296
  end
  return string.format("%08x%08x_%d", h1, h2, #s)
end

-- ---
-- Main Apply Function
-- ---

function M.apply(abs_path, old_lines, new_lines, opts)
  ensure_highlights()

  if lines_equal(old_lines, new_lines) then
    return false, "No changes detected"
  end

  -- This makes the code much cleaner and easier to reason about than closures.
  local State = {
    bufnr = -1,
    augroup = -1,
    original_lines = {},
    blocks = {},
    keys = vim.tbl_deep_extend("force", DEFAULT_KEYS, (opts or {}).keys or {}),
    event_fired = false,
  }

  -- ---
  -- State and UI Management Functions (now methods of State)
  -- ---

  function State:build_blocks()
    local patch = compute_patch(old_lines, new_lines)
    local blocks = {}
    for _, h in ipairs(patch) do
      local a_s, a_c, b_s, b_c = h[1], h[2], h[3], h[4]
      table.insert(blocks, {
        old_lines = a_c > 0 and slice(old_lines, a_s, a_s + a_c - 1) or {},
        new_lines = b_c > 0 and slice(new_lines, b_s, b_s + b_c - 1) or {},
        new_start_line = math.max(1, b_s),
        new_end_line = math.max(0, b_s + math.max(b_c, 1) - 1),
      })
    end
    table.sort(blocks, function(a, b)
      return a.new_start_line < b.new_start_line
    end)
    self.blocks = blocks
  end

  function State:highlight_blocks()
    vim.api.nvim_buf_clear_namespace(self.bufnr, NAMESPACE, 0, -1)
    local max_col = vim.o.columns
    for _, b in ipairs(self.blocks) do
      local start_line = math.max(1, b.new_start_line)
      local end_line = math.max(start_line - 1, b.new_end_line)

      if #b.new_lines > 0 then
        vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, start_line - 1, 0, {
          hl_group = "NeoAIIncoming",
          hl_eol = true,
          hl_mode = "combine",
          end_row = end_line,
        })
      end
      if #b.old_lines > 0 then
        local virt_lines = vim
          .iter(b.old_lines)
          :map(function(l)
            local padded = l .. string.rep(" ", math.max(0, max_col - #l))
            return { { padded, "NeoAIDeleted" } }
          end)
          :totable()
        vim.api.nvim_buf_set_extmark(self.bufnr, NAMESPACE, math.max(0, end_line - 1), 0, {
          virt_lines = virt_lines,
          hl_mode = "combine",
          hl_eol = true,
        })
      end
    end
  end

  function State:show_hint(lnum)
    vim.api.nvim_buf_clear_namespace(self.bufnr, HINT_NAMESPACE, 0, -1)
    if not lnum then
      return
    end
    local hint_text = "[<%s>:ours <%s>:theirs <%s>:all | <%s>:prev <%s>:next | <%s>:cancel]"
    local hint = string.format(
      hint_text,
      self.keys.ours,
      self.keys.theirs,
      self.keys.all,
      self.keys.prev,
      self.keys.next,
      self.keys.cancel
    )

    -- Place the hint one line above the first line of the current diff hunk.
    -- If the hunk starts at the top of the file, try to place it on the line below.
    local row
    if lnum > 1 then
      -- 0-based row index for the line above the hunk start
      row = lnum - 2
    else
      -- Hunk starts on the first line; prefer showing the hint on the second line if it exists
      local line_count = vim.api.nvim_buf_line_count(self.bufnr)
      row = (line_count >= 2) and 1 or 0
    end

    vim.api.nvim_buf_set_extmark(self.bufnr, HINT_NAMESPACE, row, -1, {
      hl_group = "NeoAIInlineHint",
      virt_text = { { hint, "NeoAIInlineHint" } },
      virt_text_pos = "right_align",
      priority = PRIORITY,
    })
  end

  function State:find_block_at_cursor(cursor_line)
    for idx, b in ipairs(self.blocks) do
      if cursor_line >= b.new_start_line and cursor_line <= b.new_end_line then
        return b, idx
      end
      if #b.new_lines == 0 and cursor_line == b.new_start_line then
        return b, idx
      end
    end
    return nil, nil
  end

  function State:cleanup()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(self.bufnr, NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.bufnr, HINT_NAMESPACE, 0, -1)
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    for _, key in pairs(self.keys) do
      pcall(vim.keymap.del, { "n", "v" }, key, { buffer = self.bufnr })
    end
  end

  -- ---
  -- Keymap Actions
  -- ---

  function State:resolve_block(idx, keep_new_lines)
    local block = self.blocks[idx]
    if not block then
      return
    end

    local distance = 0
    if not keep_new_lines then
      -- Reverting to 'ours'. Replace new lines with old lines in the buffer.
      local start0 = math.max(0, block.new_start_line - 1)
      local end0 = math.max(start0, block.new_end_line)
      vim.api.nvim_buf_set_lines(self.bufnr, start0, end0, false, block.old_lines)
      distance = #block.old_lines - #block.new_lines
    end

    -- Remove the resolved block from our list.
    table.remove(self.blocks, idx)

    -- After a change, we must update the coordinates of all subsequent blocks.
    if distance ~= 0 then
      for i = idx, #self.blocks do
        self.blocks[i].new_start_line = self.blocks[i].new_start_line + distance
        self.blocks[i].new_end_line = self.blocks[i].new_end_line + distance
      end
    end

    -- Redraw all highlights based on the new state.
    self:highlight_blocks()
  end

  function State:accept_theirs()
    local cur = vim.api.nvim_win_get_cursor(0)
    local _, idx = self:find_block_at_cursor(cur[1])
    if not idx then
      return
    end
    self:resolve_block(idx, true) -- true = keep new lines
    self:goto_next()
  end

  function State:keep_ours()
    local cur = vim.api.nvim_win_get_cursor(0)
    local _, idx = self:find_block_at_cursor(cur[1])
    if not idx then
      return
    end
    self:resolve_block(idx, false) -- false = revert to old lines
    self:goto_next()
  end

  function State:accept_all()
    -- Mark all hunks as resolved and fire the close event (reuses goto_block finalisation)
    self.blocks = {}
    -- Delegate to goto_block(nil) to cleanup, clear the active flag, and emit NeoAIInlineDiffClosed
    self:goto_block(nil)
  end

  function State:goto_block(block)
    if not block then
      -- If no blocks left, save, cleanup and notify.
      if #self.blocks == 0 then
        -- Clean up UI state first to avoid double events from BufWritePost
        self:cleanup()

        -- Attempt to save the buffer so changes are persisted before resuming the AI
        local will_write, wrote_ok = false, false
        if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
          local bt = vim.api.nvim_get_option_value("buftype", { buf = self.bufnr })
          local ro = vim.api.nvim_get_option_value("readonly", { buf = self.bufnr })
          local mod = vim.api.nvim_get_option_value("modified", { buf = self.bufnr })
          will_write = (bt == "" and not ro and mod)
          if will_write then
            wrote_ok = pcall(function()
              vim.api.nvim_buf_call(self.bufnr, function()
                vim.cmd("silent write")
              end)
            end)
          end
        end

        if not self.event_fired then
          self.event_fired = true
          -- Prepare final outcome data for the AI/orchestrator
          local final_lines = {}
          if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
            final_lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
          else
            final_lines = vim.deepcopy(self.original_lines)
          end
          local diff_text = unified_diff(self.original_lines or {}, final_lines or {})
          -- Await diagnostics publish for accuracy
          local diag_count = 0
          if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
            pcall(function()
              require("neoai.ai_tools.lsp_diagnostic").await_count({ bufnr = self.bufnr, timeout_ms = 1500 })
            end)
            diag_count = #vim.diagnostic.get(self.bufnr)
          end
          local payload = {
            action = ((will_write and wrote_ok) and "written" or "resolved"),
            path = abs_path,
            bufnr = self.bufnr,
            diff = diff_text,
            diff_hash = simple_hash(diff_text),
            diagnostics_count = diag_count,
          }
          -- Mark review as inactive now that it is closed
          vim.g.neoai_inline_diff_active = false
          vim.schedule(function()
            pcall(vim.api.nvim_exec_autocmds, "User", {
              pattern = "NeoAIInlineDiffClosed",
              modeline = false,
              data = payload,
            })
            if will_write and wrote_ok then
              vim.notify("NeoAI: All hunks resolved. Changes written to disk.", vim.log.levels.INFO)
            else
              vim.notify("NeoAI: All hunks resolved. Press :w to save.", vim.log.levels.INFO)
            end
          end)
        end
      end
      return
    end
    local line = math.max(1, block.new_start_line)
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd("normal! zz")
  end

  function State:goto_prev()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local target
    for i = #self.blocks, 1, -1 do
      if self.blocks[i].new_start_line < cursor_line then
        target = self.blocks[i]
        break
      end
    end
    self:goto_block(target or self.blocks[#self.blocks])
  end

  function State:goto_next()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local target
    for i = 1, #self.blocks do
      if self.blocks[i].new_start_line > cursor_line then
        target = self.blocks[i]
        break
      end
    end
    self:goto_block(target or self.blocks[1])
  end

  function State:cancel_review()
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, self.original_lines)
    self:cleanup()
    if not self.event_fired then
      self.event_fired = true
      -- Prepare final outcome data (cancelled -> restored to original)
      local final_lines = vim.deepcopy(self.original_lines)
      local diff_text = unified_diff(self.original_lines or {}, final_lines or {})
      -- Await diagnostics publish (reverted content)
      local diag_count = 0
      if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        pcall(function()
          require("neoai.ai_tools.lsp_diagnostic").await_count({ bufnr = self.bufnr, timeout_ms = 1500 })
        end)
        diag_count = #vim.diagnostic.get(self.bufnr)
      end
      local payload = {
        action = "cancelled",
        path = abs_path,
        bufnr = self.bufnr,
        diff = diff_text,
        diff_hash = simple_hash(diff_text),
        diagnostics_count = diag_count,
      }
      -- Mark review as inactive
      vim.g.neoai_inline_diff_active = false
      vim.schedule(function()
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = "NeoAIInlineDiffClosed",
          modeline = false,
          data = payload,
        })
        vim.notify("NeoAI: Inline diff cancelled; original content restored.", vim.log.levels.WARN)
      end)
    end
  end

  -- ---
  -- Initialisation
  -- ---

  State:build_blocks()
  if #State.blocks == 0 then
    return false, "No hunks to review"
  end

  local target_winnr = find_last_active_editing_window()
  vim.api.nvim_set_current_win(target_winnr)
  -- Open the target file in this window without prompting to save the current buffer.
  -- Using 'hide' avoids confirm prompts when the current buffer has unsaved changes.
  pcall(vim.cmd, "silent keepalt keepjumps hide edit " .. vim.fn.fnameescape(abs_path))
  State.bufnr = vim.api.nvim_get_current_buf()
  vim.bo[State.bufnr].modifiable = true

  State.original_lines = old_lines -- Use original lines passed in for perfect restoration
  vim.api.nvim_buf_set_lines(State.bufnr, 0, -1, false, new_lines)
  State:highlight_blocks()

  State.augroup = vim.api.nvim_create_augroup("neoai_inline_diff_" .. State.bufnr, { clear = true })
  local autocmd_opts = { buffer = State.bufnr, group = State.augroup }

  vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI" },
    vim.tbl_extend("force", autocmd_opts, {
      callback = function()
        local block, _ = State:find_block_at_cursor(vim.api.nvim_win_get_cursor(0)[1])
        State:show_hint(block and block.new_start_line or nil)
      end,
    })
  )

  vim.api.nvim_create_autocmd(
    "BufWritePost",
    vim.tbl_extend("force", autocmd_opts, {
      callback = function()
        State:cleanup()
        if not State.event_fired then
          State.event_fired = true
          -- Prepare final outcome data on write
          local final_lines = {}
          if State.bufnr and vim.api.nvim_buf_is_valid(State.bufnr) then
            final_lines = vim.api.nvim_buf_get_lines(State.bufnr, 0, -1, false)
          else
            final_lines = vim.deepcopy(State.original_lines)
          end
          local diff_text = unified_diff(State.original_lines or {}, final_lines or {})
          -- Await diagnostics publish
          local diag_count = 0
          if State.bufnr and vim.api.nvim_buf_is_valid(State.bufnr) then
            pcall(function()
              require("neoai.ai_tools.lsp_diagnostic").await_count({ bufnr = State.bufnr, timeout_ms = 1500 })
            end)
            diag_count = #vim.diagnostic.get(State.bufnr)
          end
          local payload = {
            action = "written",
            path = abs_path,
            bufnr = State.bufnr,
            diff = diff_text,
            diff_hash = simple_hash(diff_text),
            diagnostics_count = diag_count,
          }
          -- Mark review as inactive
          vim.g.neoai_inline_diff_active = false
          vim.schedule(function()
            pcall(vim.api.nvim_exec_autocmds, "User", {
              pattern = "NeoAIInlineDiffClosed",
              modeline = false,
              data = payload,
            })
            vim.notify("NeoAI: Changes written to disk.", vim.log.levels.INFO)
          end)
        end
      end,
    })
  )

  vim.api.nvim_create_autocmd(
    { "BufWipeout", "BufUnload" },
    vim.tbl_extend("force", autocmd_opts, {
      callback = function()
        State:cleanup()
        if not State.event_fired then
          State.event_fired = true
          -- Prepare final outcome data on close
          local final_lines = {}
          if State.bufnr and vim.api.nvim_buf_is_valid(State.bufnr) then
            final_lines = vim.api.nvim_buf_get_lines(State.bufnr, 0, -1, false)
          else
            final_lines = vim.deepcopy(State.original_lines)
          end
          local diff_text = unified_diff(State.original_lines or {}, final_lines or {})
          -- Await diagnostics publish
          local diag_count = 0
          if State.bufnr and vim.api.nvim_buf_is_valid(State.bufnr) then
            pcall(function()
              require("neoai.ai_tools.lsp_diagnostic").await_count({ bufnr = State.bufnr, timeout_ms = 1500 })
            end)
            diag_count = #vim.diagnostic.get(State.bufnr)
          end
          local payload = {
            action = "closed",
            path = abs_path,
            bufnr = State.bufnr,
            diff = diff_text,
            diff_hash = simple_hash(diff_text),
            diagnostics_count = diag_count,
          }
          -- Mark review as inactive
          vim.g.neoai_inline_diff_active = false
          vim.schedule(function()
            pcall(vim.api.nvim_exec_autocmds, "User", {
              pattern = "NeoAIInlineDiffClosed",
              modeline = false,
              data = payload,
            })
          end)
        end
      end,
    })
  )

  local mapopts = { buffer = State.bufnr, nowait = true, silent = true }
  vim.keymap.set({ "n", "v" }, State.keys.theirs, function()
    State:accept_theirs()
  end, mapopts)
  vim.keymap.set({ "n", "v" }, State.keys.ours, function()
    State:keep_ours()
  end, mapopts)
  vim.keymap.set({ "n", "v" }, State.keys.all, function()
    State:accept_all()
  end, mapopts)
  vim.keymap.set({ "n", "v" }, State.keys.next, function()
    State:goto_next()
  end, mapopts)
  vim.keymap.set({ "n", "v" }, State.keys.prev, function()
    State:goto_prev()
  end, mapopts)
  vim.keymap.set({ "n", "v" }, State.keys.cancel, function()
    State:cancel_review()
  end, mapopts)

  State:goto_block(State.blocks[1])

  -- Mark interactive review active
  vim.g.neoai_inline_diff_active = true

  local msg = string.format("🔍 Inline diff for %d change(s). Use keys to review.", #State.blocks)
  return true, msg
end

-- Provide a best-effort close helper so callers can revert UI state when needed.
-- This cleans up highlights, keymaps, and autocommands for the buffer and
-- marks the review as inactive. It does not attempt to restore content.
function M.close(bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  if b and vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_clear_namespace, b, NAMESPACE, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, b, HINT_NAMESPACE, 0, -1)
    -- Remove buffer-local keymaps set by apply()
    local mapopts = { buffer = b }
    pcall(vim.keymap.del, { "n", "v" }, DEFAULT_KEYS.theirs, mapopts)
    pcall(vim.keymap.del, { "n", "v" }, DEFAULT_KEYS.ours, mapopts)
    pcall(vim.keymap.del, { "n", "v" }, DEFAULT_KEYS.all, mapopts)
    pcall(vim.keymap.del, { "n", "v" }, DEFAULT_KEYS.next, mapopts)
    pcall(vim.keymap.del, { "n", "v" }, DEFAULT_KEYS.prev, mapopts)
    pcall(vim.keymap.del, { "n", "v" }, DEFAULT_KEYS.cancel, mapopts)
  end
  -- Remove the augroup created by apply() if present
  local group_name = "neoai_inline_diff_" .. tostring(b)
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
  vim.g.neoai_inline_diff_active = false
end

return M
