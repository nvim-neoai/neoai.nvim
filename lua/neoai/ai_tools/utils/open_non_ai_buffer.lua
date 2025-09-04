local function open_non_ai_buffer(path)
  local abs_path = vim.fn.fnamemodify(path, ":p")
  local esc = vim.fn.fnameescape(abs_path)

  -- 1) If the file is already visible in any window, jump there.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.fn.fnamemodify(name, ":p") == abs_path then
        vim.api.nvim_set_current_win(win)
        return
      end
    end
  end

  -- Helper: determine whether a window is a normal editing window (not a file explorer or special)
  local function is_edit_win(win)
    if not vim.api.nvim_win_is_valid(win) then
      return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
    local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
    if bt ~= "" then
      return false
    end
    if ft == "NvimTree" or ft == "chadtree" or ft == "neo-tree" then
      return false
    end
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("^neoai://") then
      return false
    end
    return true
  end

  -- 2) Prefer an editing window that is unmodified
  local candidate_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_edit_win(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local modified = vim.api.nvim_get_option_value("modified", { buf = buf })
      if not modified then
        candidate_win = win
        break
      end
    end
  end

  -- 3) If none unmodified, pick any editing window (we'll split to avoid E37)
  if not candidate_win then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if is_edit_win(win) then
        candidate_win = win
        break
      end
    end
  end

  -- 4) Fallback to current window if nothing suitable found
  candidate_win = candidate_win or vim.api.nvim_get_current_win()

  -- Try to open safely in the chosen window
  local function try_edit_in_window(win)
    vim.api.nvim_set_current_win(win)
    local ok, err = pcall(vim.cmd, "edit " .. esc)
    if ok then
      return true
    end
    -- If we hit E37, create a split so the modified buffer stays visible, then try again
    if type(err) == "string" and err:match("E37") then
      vim.cmd("vsplit")
      local split_win = vim.api.nvim_get_current_win()
      local ok2, err2 = pcall(vim.cmd, "edit " .. esc)
      if ok2 then
        return true
      end
      -- Last resort: temporarily allow hiding modified buffers
      local old_hidden = vim.o.hidden
      vim.o.hidden = true
      ok2 = pcall(vim.cmd, "edit " .. esc)
      vim.o.hidden = old_hidden
      return ok2
    end
    -- Unknown failure: attempt hidden-toggle fallback once
    local old_hidden = vim.o.hidden
    vim.o.hidden = true
    local ok3 = pcall(vim.cmd, "edit " .. esc)
    vim.o.hidden = old_hidden
    return ok3
  end

  -- Attempt to edit in the chosen window
  if not try_edit_in_window(candidate_win) then
    -- Absolute fallback: open in current window (with split/hidden workarounds inside)
    try_edit_in_window(vim.api.nvim_get_current_win())
  end
end

return open_non_ai_buffer
