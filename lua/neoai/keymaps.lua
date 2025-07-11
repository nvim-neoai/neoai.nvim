local M = {}

--- Setup key mappings
---@param chat_state table Chat state containing buffers and windows
---@param MESSAGE_TYPES table Message types used in chat
function M.setup(chat_state, MESSAGE_TYPES)
local keymaps = require("neoai.config").values.keymaps
  -- Input buffer mappings
  vim.api.nvim_buf_set_keymap(
    chat_state.buffers.input,
    "n",
    keymaps.input.send_message,
    ":lua require('neoai.chat').send_message()<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    chat_state.buffers.input,
    "n",
    keymaps.input.close,
    ":lua require('neoai.chat').close()<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    chat_state.buffers.input,
    "i",
    keymaps.chat.close[1],
    "<Esc>:lua require('neoai.chat').close()<CR>",
    { noremap = true, silent = true }
  )

  -- Chat buffer mappings
  vim.api.nvim_buf_set_keymap(
    chat_state.buffers.chat,
    "n",
    keymaps.chat.close[1],
    ":lua require('neoai.chat').close()<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    chat_state.buffers.chat,
    "n",
    keymaps.chat.close[2],
    ":lua require('neoai.chat').close()<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    chat_state.buffers.chat,
    "n",
    keymaps.chat.new_session,
    ":lua require('neoai.chat').new_session()<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_buf_set_keymap(
    chat_state.buffers.chat,
    "n",
    keymaps.chat.save_history,
    ":lua require('neoai.chat').save_history()<CR>",
    { noremap = true, silent = true }
  )

  -- Thinking buffer mappings (if enabled)
  if chat_state.config.show_thinking and chat_state.buffers.thinking then
    vim.api.nvim_buf_set_keymap(
      chat_state.buffers.thinking,
      "n",
      keymaps.thinking.close[1],
      ":lua require('neoai.chat').close()<CR>",
      { noremap = true, silent = true }
    )
    vim.api.nvim_buf_set_keymap(
      chat_state.buffers.thinking,
      "n",
      keymaps.thinking.close[2],
      ":lua require('neoai.chat').close()<CR>",
      { noremap = true, silent = true }
    )
  end
end

return M
