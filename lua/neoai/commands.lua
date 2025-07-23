local M = {}
local chat = require("neoai.chat")

--- Setup user commands for NeoAI chat
function M.setup()
  vim.api.nvim_create_user_command("NeoAIChat", function()
    chat.open()
  end, { desc = "Open NeoAI Chat" })

  vim.api.nvim_create_user_command("NeoAIChatToggle", function()
    chat.toggle()
  end, { desc = "Toggle NeoAI Chat" })

  vim.api.nvim_create_user_command("NeoAIChatClear", function()
    chat.new_session()
  end, { desc = "Clear NeoAI Chat History" })

  vim.api.nvim_create_user_command("NeoAIChatSave", function()
    chat.save_history()
  end, { desc = "Save NeoAI Chat History" })

  -- Check errors: read file and LSP diagnostics
  vim.api.nvim_create_user_command("NeoAICheckError", function(opts)
    local file = opts.args ~= "" and opts.args or vim.api.nvim_buf_get_name(0)
    if file == "" then
      print("No file specified or active buffer.")
      return
    end
    local read_tool = require("neoai.ai_tools.read").run({ file_path = file })
    local diag_tool = require("neoai.ai_tools.lsp_diagnostic").run({ file_path = file })
    -- Display results in a new scratch buffer
    vim.cmd("botright new")
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.bo.swapfile = false
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(read_tool, "\n"))
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "", "Diagnostics:" })
    vim.api.nvim_buf_set_lines(0, -1, -1, false, vim.split(diag_tool, "\n"))
  end, { desc = "Read file and check LSP diagnostics", nargs = "?", complete = "file" })
end

return M
