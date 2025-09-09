local M = {}
local chat = require("neoai.chat")

--- Setup user commands for NeoAI chat
--- @return nil
function M.setup()
  vim.api.nvim_create_user_command("NeoAIChat", function()
    chat.open()
  end, { desc = "Open NeoAI Chat" })

  vim.api.nvim_create_user_command("NeoAIChatToggle", function()
    chat.toggle()
  end, { desc = "Toggle NeoAI Chat" })

  vim.api.nvim_create_user_command("NeoAIChatClear", function()
    chat.clear_session()
  end, { desc = "Clear current NeoAI Chat session" })

  vim.api.nvim_create_user_command(
    "NeoAINewSession", --- @param opts table Optional arguments including `args`
    function(opts)
      local title = opts.args ~= "" and opts.args or nil
      chat.new_session(title)
      if chat.chat_state.is_open then
        chat.close()
        chat.open()
      end
    end,
    { desc = "Create new NeoAI Chat session", nargs = "?" }
  )

  vim.api.nvim_create_user_command("NeoAISessionList", function()
    require("neoai.session_picker").pick_session()
  end, { desc = "Interactive session picker for NeoAI Chat" })

  vim.api.nvim_create_user_command("NeoAISwitchSession", function(opts)
    if opts.args == "" then
      vim.notify("Please provide a session ID", vim.log.levels.ERROR)
      return
    end

    local session_id = tonumber(opts.args)
    if not session_id then
      vim.notify("Invalid session ID", vim.log.levels.ERROR)
      return
    end

    local success = chat.switch_session(session_id)
    if success and chat.chat_state.is_open then
      -- Refresh the chat display
      chat.close()
      chat.open()
    end
  end, { desc = "Switch to a specific NeoAI Chat session", nargs = 1 })

  vim.api.nvim_create_user_command("NeoAIDeleteSession", function(opts)
    if opts.args == "" then
      vim.notify("Please provide a session ID", vim.log.levels.ERROR)
      return
    end

    local session_id = tonumber(opts.args)
    if not session_id then
      vim.notify("Invalid session ID", vim.log.levels.ERROR)
      return
    end

    -- Confirm deletion
    vim.ui.input({ prompt = "Delete session " .. session_id .. "? (y/N): " }, function(input)
      if input and input:lower() == "y" then
        local success = chat.delete_session(session_id)
        if success and chat.chat_state.is_open then
          -- Refresh the chat display
          chat.close()
          chat.open()
        end
      end
    end)
  end, { desc = "Delete a NeoAI Chat session", nargs = 1 })

  vim.api.nvim_create_user_command("NeoAIRenameSession", function(opts)
    if opts.args == "" then
      vim.notify("Please provide a new session title", vim.log.levels.ERROR)
      return
    end

    local success = chat.rename_session(opts.args)
    if success and chat.chat_state.is_open then
      -- Refresh the chat display
      chat.close()
      chat.open()
    end
  end, { desc = "Rename current NeoAI Chat session", nargs = 1 })

  vim.api.nvim_create_user_command("NeoAIStats", function()
    local stats = chat.get_stats()

    vim.cmd("botright new")
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.bo.swapfile = false
    vim.bo.filetype = "markdown"

    local lines = {
      "# NeoAI Statistics",
      "",
      "**Storage Type:** " .. (stats.storage_type or "unknown"),
      "**Database Path:** " .. (stats.database_path or "N/A"),
      "",
      "**Sessions:** " .. (stats.sessions or 0),
      "**Messages:** " .. (stats.messages or 0),
      "**Active Sessions:** " .. (stats.active_sessions or 0),
      "",
      "**Current Session:**",
    }

    local session_info = chat.get_session_info()
    if session_info then
      table.insert(lines, "- **Title:** " .. (session_info.title or "Untitled"))
      table.insert(lines, "- **ID:** " .. session_info.id)
      table.insert(lines, "- **Created:** " .. session_info.created_at)
      table.insert(lines, "- **Messages:** " .. session_info.message_count)
    else
      table.insert(lines, "No active session")
    end

    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.modifiable = false
  end, { desc = "Show NeoAI statistics" })

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
