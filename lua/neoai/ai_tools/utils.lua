local M = {}

-- Opens or reloads the file in a window outside the AI chat UI
function M.open_non_ai_buffer(path)
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

-- Escapes a Lua pattern so it can be used as a literal in gsub
function M.escape_pattern(s)
  return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Wraps text in a markdown code block with optional language identifier
function M.make_code_block(text, lang)
  lang = lang or "txt"
  return string.format("```%s\n%s\n```", lang, text)
end

return M
