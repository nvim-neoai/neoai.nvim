local function open_non_ai_buffer(path)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if not name:match("^neoai://") then
      vim.api.nvim_set_current_win(win)
      vim.cmd("edit " .. path)
      return
    end
  end
  -- Fallback: open in current window
  vim.cmd("edit " .. path)
end

return open_non_ai_buffer
