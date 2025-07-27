local M = {}

-- Session picker using Telescope for better UX
local function session_picker()
  local chat = require("neoai.chat")
  local sessions = chat.get_all_sessions()

  if #sessions == 0 then
    vim.notify("No sessions available", vim.log.levels.WARN)
    return
  end

  -- Check if Telescope is available
  local has_telescope, _ = pcall(require, "telescope")
  if has_telescope then
    M.telescope_session_picker(sessions)
  else
    M.simple_session_picker(sessions)
  end
end

-- Telescope-based session picker
function M.telescope_session_picker(sessions)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local chat = require("neoai.chat")

  -- Prepare session entries for Telescope
  local session_entries = {}
  for _, session in ipairs(sessions) do
    local status = session.is_active and "[ACTIVE] " or ""
    local entry = {
      value = session,
      display = string.format("%s%s (ID: %d) - %s", status, session.title, session.id, session.updated_at),
      ordinal = session.title .. " " .. session.id,
    }
    table.insert(session_entries, entry)
  end

  pickers
    .new({}, {
      prompt_title = "NeoAI Sessions",
      finder = finders.new_table({
        results = session_entries,
        entry_maker = function(entry)
          return {
            value = entry.value,
            display = entry.display,
            ordinal = entry.ordinal,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            local session = selection.value
            if not session.is_active then
              chat.switch_session(session.id)
              if chat.chat_state.is_open then
                chat.close()
                chat.open()
              end
            else
              vim.notify("Session is already active", vim.log.levels.INFO)
            end
          end
        end)

        -- Add custom mappings
        map({ "i", "n" }, "<C-d>", function()
          local selection = action_state.get_selected_entry()
          if selection then
            local session = selection.value
            actions.close(prompt_bufnr)

            vim.ui.input({ prompt = "Delete session '" .. session.title .. "'? (y/N): " }, function(input)
              if input and input:lower() == "y" then
                chat.delete_session(session.id)
                -- Reopen picker
                vim.defer_fn(session_picker, 100)
              end
            end)
          end
        end)

        map("i", "<C-r>", function()
          local selection = action_state.get_selected_entry()
          if selection then
            local session = selection.value
            actions.close(prompt_bufnr)

            vim.ui.input({
              prompt = "New title for '" .. session.title .. "': ",
              default = session.title,
            }, function(input)
              if input and input ~= "" then
                if session.is_active then
                  chat.rename_session(input)
                else
                  require("neoai.storage").update_session_title(session.id, input)
                end
                -- Reopen picker
                vim.defer_fn(session_picker, 100)
              end
            end)
          end
        end)

        map("i", "<C-n>", function()
          actions.close(prompt_bufnr)
          vim.ui.input({ prompt = "New session title: " }, function(input)
            if input and input ~= "" then
              chat.new_session(input)
              if chat.chat_state.is_open then
                chat.close()
                chat.open()
              end
            end
          end)
        end)

        return true
      end,
    })
    :find()
end

-- Simple session picker fallback (without Telescope)
function M.simple_session_picker(sessions)
  local chat = require("neoai.chat")

  -- Create a buffer to display sessions
  vim.cmd("botright new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "neoai-sessions"

  local lines = { "# NeoAI Sessions", "", "Press <Enter> to switch, 'd' to delete, 'r' to rename", "" }

  local session_lines = {}
  for i, session in ipairs(sessions) do
    local prefix = session.is_active and "[ACTIVE] " or ""
    local line = string.format("%d. %s%s (ID: %d)", i, prefix, session.title, session.id)
    table.insert(lines, line)
    table.insert(lines, string.format("   Created: %s | Updated: %s", session.created_at, session.updated_at))
    table.insert(lines, "")

    -- Store session info for line mapping
    session_lines[#lines - 2] = session
  end

  table.insert(lines, "")
  table.insert(lines, "**Keymaps:**")
  table.insert(lines, "- <Enter> - Switch to session")
  table.insert(lines, "- d - Delete session")
  table.insert(lines, "- r - Rename session")
  table.insert(lines, "- n - New session")
  table.insert(lines, "- q - Close")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Set up keymaps for the session picker
  local function get_session_at_cursor()
    local line_num = vim.api.nvim_win_get_cursor(0)[1]
    return session_lines[line_num]
  end

  vim.keymap.set("n", "<CR>", function()
    local session = get_session_at_cursor()
    if session and not session.is_active then
      vim.cmd("close")
      chat.switch_session(session.id)
      if chat.chat_state.is_open then
        chat.close()
        chat.open()
      end
    elseif session then
      vim.notify("Session is already active", vim.log.levels.INFO)
    end
  end, { buffer = bufnr, desc = "Switch to session" })

  vim.keymap.set("n", "<C-d>", function()
    local session = get_session_at_cursor()
    if session then
      vim.ui.input({ prompt = "Delete session '" .. session.title .. "'? (y/N): " }, function(input)
        if input and input:lower() == "y" then
          chat.delete_session(session.id)
          vim.cmd("close")
          -- Reopen picker
          vim.defer_fn(session_picker, 100)
        end
      end)
    end
  end, { buffer = bufnr, desc = "Delete session" })

  vim.keymap.set("n", "<C-r>", function()
    local session = get_session_at_cursor()
    if session then
      vim.ui.input({
        prompt = "New title for '" .. session.title .. "': ",
        default = session.title,
      }, function(input)
        if input and input ~= "" then
          if session.is_active then
            chat.rename_session(input)
          else
            require("neoai.storage").update_session_title(session.id, input)
          end
          vim.cmd("close")
          -- Reopen picker
          vim.defer_fn(session_picker, 100)
        end
      end)
    end
  end, { buffer = bufnr, desc = "Rename session" })

  vim.keymap.set("n", "<C-n>", function()
    vim.ui.input({ prompt = "New session title: " }, function(input)
      if input and input ~= "" then
        chat.new_session(input)
        vim.cmd("close")
        if chat.chat_state.is_open then
          chat.close()
          chat.open()
        end
      end
    end)
  end, { buffer = bufnr, desc = "New session" })
end

-- Main entry point
function M.pick_session()
  session_picker()
end

return M
