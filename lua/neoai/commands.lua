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

  -- Index codebase and search commands
  vim.api.nvim_create_user_command("NeoAIIndex", function()
    require("neoai.indexer").build_index()
  end, { desc = "Build vector index of the codebase" })

  vim.api.nvim_create_user_command("NeoAISearch", function(opts)
    local q = opts.args
    local hits = require("neoai.indexer").query_index(q)
    -- Display search results in a new scratch buffer
    vim.cmd("botright new")
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.bo.swapfile = false
    local lines = {}
    for _, h in ipairs(hits) do
      table.insert(lines, string.format("[%s:%d] (%.3f) %s", h.file, h.idx, h.score, h.content:sub(1, 60):gsub("\n", " ")))
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end, { desc = "Search indexed code", nargs = "*" })
end

return M
