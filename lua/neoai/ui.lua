local ui = {}

--- Open NeoAI chat UI
---@param chat_state table Chat state containing buffers, windows, and configuration
function ui.open(chat_state)
  if chat_state.is_open then
    return
  end

  -- Create buffers
  chat_state.buffers.chat = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(chat_state.buffers.chat, "neoai://chat")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "filetype", "neoai-chat")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "buftype", "nofile")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "wrap", true)

  chat_state.buffers.input = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(chat_state.buffers.input, "neoai://input")
  vim.api.nvim_buf_set_option(chat_state.buffers.input, "filetype", "neoai-input")
  vim.api.nvim_buf_set_option(chat_state.buffers.input, "buftype", "nofile")
  vim.api.nvim_buf_set_option(chat_state.buffers.input, "bufhidden", "wipe")

  if chat_state.config.show_thinking then
    chat_state.buffers.thinking = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(chat_state.buffers.thinking, "neoai://thinking")
    vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "filetype", "neoai-thinking")
    vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "buftype", "nofile")
    vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "wrap", true)
  end

  -- Open vertical split at far right
  vim.cmd("vsplit")
  local vsplit_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(vsplit_win, chat_state.config.window.width or 80)

  -- Use current win (vsplit)(bottom) for input
  local input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(vsplit_win, chat_state.buffers.input)
  vim.api.nvim_set_option_value("winbar", " Input (Enter to send) ", { win = input_win })
  chat_state.windows.input = input_win

  -- Split for thinking box (middle)
  if chat_state.config.show_thinking then
    vim.cmd("aboveleft split")
    local thinking_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(thinking_win, chat_state.buffers.thinking)
    vim.api.nvim_win_set_height(thinking_win, 3)
    vim.api.nvim_set_option_value("winbar", " Thinking ", { win = thinking_win })
    chat_state.windows.thinking = thinking_win
  end

  -- Use aboveleft split (top) for chat
  vim.cmd("aboveleft split")
  local chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(chat_win, chat_state.buffers.chat)
  vim.api.nvim_set_option_value("winbar", " Chat ", { win = chat_win })
  vim.api.nvim_win_set_height(chat_win, 25)
  chat_state.windows.chat = chat_win

  -- Set focus to input
  vim.api.nvim_set_current_win(chat_state.windows.input)

  chat_state.is_open = true
end

--- Close NeoAI chat UI
---@param chat_state table Chat state containing buffers and windows
function ui.close(chat_state)
  if not chat_state.is_open then
    return
  end

  -- Close windows
  for _, win in pairs(chat_state.windows) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Clear state
  chat_state.windows = {}
  chat_state.buffers = {}
  chat_state.is_open = false
end

return ui
