local M = {}

-- Track the session picker window and buffer
local session_picker_win = nil

-- Session picker using Telescope for better UX
local function session_picker()
  local chat = require("neoai.chat")
  local keymap_conf = require("neoai.config").values.keymaps
  local sessions = chat.get_all_sessions()

  if #sessions == 0 then
    vim.notify("No sessions available", vim.log.levels.WARN)
    return
  end

  local has_telescope, _ = pcall(require, "telescope")
  if has_telescope and keymap_conf.session_picker == "telescope" then
    M.telescope_session_picker(sessions)
  else
    M.simple_session_picker(sessions)
  end
end

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

          map({ "i", "n" }, "<C-r>", function()
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

          map({ "i", "n" }, "<C-n>", function()
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

local close_window = function()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, false)
    if win == session_picker_win then
      session_picker_win = nil
    end
  end
end

function M.simple_session_picker(sessions)
  local chat = require("neoai.chat")

  -- Close previous picker if it's still open
  if session_picker_win and vim.api.nvim_win_is_valid(session_picker_win) then
    vim.api.nvim_win_close(session_picker_win, true)
  end

  -- Create new session picker window
  vim.cmd("botright new")
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()

  session_picker_win = winid

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"

  local lines = { "# NeoAI Sessions", "", "Press <Enter> to switch, 'd' to delete, 'r' to rename", "" }

  local session_lines = {}
  for i, session in ipairs(sessions) do
    local prefix = session.is_active and "[ACTIVE] " or ""
    local line = string.format("%d. %s%s (ID: %d)", i, prefix, session.title, session.id)
    table.insert(lines, line)
    table.insert(lines, string.format("   Created: %s | Updated: %s", session.created_at, session.updated_at))
    table.insert(lines, "")

    session_lines[#lines - 2] = session
  end

  table.insert(lines, "")
  table.insert(lines, "**Keymaps:**")
  table.insert(lines, "- <Enter> - Switch to session")
  table.insert(lines, "- d - Delete session")
  table.insert(lines, "- r - Rename session")
  table.insert(lines, "- n - New session")
  table.insert(lines, "- q/<Esc>/<leader>as - Close")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local function get_session_at_cursor()
    local line_num = vim.api.nvim_win_get_cursor(0)[1]
    return session_lines[line_num]
  end

  vim.keymap.set("n", "<CR>", function()
    local session = get_session_at_cursor()
    if session and not session.is_active then
      close_window()
      chat.switch_session(session.id)
      if chat.chat_state.is_open then
        chat.close()
        chat.open()
      end
    elseif session then
      vim.notify("Session is already active", vim.log.levels.INFO)
    end
  end, { buffer = bufnr, desc = "Switch to session" })

  vim.keymap.set("n", "d", function()
    local session = get_session_at_cursor()
    if session then
      vim.ui.input({ prompt = "Delete session '" .. session.title .. "'? (y/N): " }, function(input)
        if input and input:lower() == "y" then
          chat.delete_session(session.id)
          close_window()
          vim.defer_fn(session_picker, 100)
        end
      end)
    end
  end, { buffer = bufnr, desc = "Delete session" })

  vim.keymap.set("n", "r", function()
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
          close_window()
          vim.defer_fn(session_picker, 100)
        end
      end)
    end
  end, { buffer = bufnr, desc = "Rename session" })

  vim.keymap.set("n", "n", function()
    vim.ui.input({ prompt = "New session title: " }, function(input)
      if input and input ~= "" then
        chat.new_session(input)
        close_window()
        if chat.chat_state.is_open then
          chat.close()
          chat.open()
        end
      end
    end)
  end, { buffer = bufnr, desc = "New session" })

  -- Multiple keys to close the window
  for _, key in ipairs({ "q", "<Esc>", "<leader>as" }) do
    vim.keymap.set("n", key, close_window, { buffer = bufnr, desc = "Close session picker window" })
  end
end

-- Entry point
function M.pick_session()
  session_picker()
end

return M
