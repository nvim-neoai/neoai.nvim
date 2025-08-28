local M = {}
local keymaps = require("neoai.config").values.keymaps

--- Setup key mappings
function M.setup()
  -- Normal mappings
  vim.keymap.set("n", keymaps.normal.open, ":NeoAIChat<CR>", { desc = "Open NeoAI Chat" })
  vim.keymap.set("n", keymaps.normal.toggle, ":NeoAIChatToggle<CR>", { desc = "Toggle NeoAI Chat" })
  vim.keymap.set("n", keymaps.normal.clear_history, function()
    require("neoai.chat").open_and_clear()
  end, { desc = "Clear NeoAI Chat" })

  -- Session management mappings
  vim.keymap.set("n", "<leader>as", ":NeoAISessionList<CR>", { desc = "List NeoAI Sessions" })
  vim.keymap.set("n", "<leader>an", ":NeoAINewSession<CR>", { desc = "New NeoAI Session" })
  vim.keymap.set("n", "<leader>aS", ":NeoAIStats<CR>", { desc = "NeoAI Statistics" })
end

--- Setup buffer-local key mappings when chat is open
function M.buffer_setup()
  local chat_state = require("neoai.chat").chat_state

  -- Insert file with @@ trigger in insert mode
  vim.keymap.set("i", "@@", function()
    require("neoai.file_picker").select_file()
  end, { noremap = true, silent = true, buffer = chat_state.buffers.input })

  -- Input buffer mappings
  vim.keymap.set("n", keymaps.input.send_message, function()
    require("neoai.chat").send_message()
  end, { noremap = true, silent = true, buffer = chat_state.buffers.input })

  -- Ctrl-C: close
  vim.keymap.set("n", keymaps.input.close, function()
    require("neoai.chat").close()
  end, { noremap = true, silent = true, buffer = chat_state.buffers.input })

  -- Insert mode Ctrl-C in input buffer
  vim.keymap.set("i", keymaps.chat.close[1], function()
    require("neoai.chat").close()
  end, { noremap = true, silent = true, buffer = chat_state.buffers.input })

  -- Chat buffer mappings
  -- Ctrl-C: cancel if streaming, else close chat
  vim.keymap.set("n", keymaps.chat.close[1], function()
    require("neoai.chat").cancel_or_close()
  end, { noremap = true, silent = true, buffer = chat_state.buffers.chat })

  -- 'q' remains a hard close
  vim.keymap.set("n", keymaps.chat.close[2], function()
    require("neoai.chat").close()
  end, { noremap = true, silent = true, buffer = chat_state.buffers.chat })
end

return M
