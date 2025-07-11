local M = {}

--- Setup user commands for NeoAI chat
---@param chat table NeoAI chat module with methods like open, toggle, clear_history, save_history, load_history
function M.setup(chat)
  vim.api.nvim_create_user_command("NeoAIChat", function()
    chat.open()
  end, { desc = "Open NeoAI Chat" })

  vim.api.nvim_create_user_command("NeoAIChatToggle", function()
    chat.toggle()
  end, { desc = "Toggle NeoAI Chat" })

  vim.api.nvim_create_user_command("NeoAIChatClear", function()
    chat.clear_history()
  end, { desc = "Clear NeoAI Chat History" })

  vim.api.nvim_create_user_command("NeoAIChatSave", function()
    chat.save_history()
  end, { desc = "Save NeoAI Chat History" })

  vim.api.nvim_create_user_command("NeoAIChatLoad", function()
    chat.load_history()
  end, { desc = "Load NeoAI Chat History" })
end

return M
