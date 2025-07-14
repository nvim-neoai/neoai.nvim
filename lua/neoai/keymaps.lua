local M = {}
local keymaps = require("neoai.config").values.keymaps

--- Setup key mappings
function M.setup()
  -- Normal mappings
  vim.keymap.set("n", keymaps.normal.open, ":NeoAIChat<CR>", { desc = "Open NeoAI Chat" })
  vim.keymap.set("n", keymaps.normal.toggle, ":NeoAIChatToggle<CR>", { desc = "Toggle NeoAI Chat" })
  vim.keymap.set("n", keymaps.normal.clear_history, ":NeoAIChatClear<CR>", { desc = "Clear NeoAI Chat" })
end

function M.buffer_setup()
  local chat_state = require("neoai.chat").chat_state

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
