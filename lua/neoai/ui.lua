---@type table<string, function>
local ui = {}
local chat_state = require("neoai.chat").chat_state

---@return integer|nil # Rightmost window ID or nil if no windows exist
local function get_rightmost_win()
  ---@type integer|nil
  local rightmost_win = nil
  ---@type integer
  local max_col = -1

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local pos = vim.api.nvim_win_get_position(win)
    local col = pos[2]
    if col > max_col then
      max_col = col
      rightmost_win = win
    end
  end

  return rightmost_win
end

--- Determine whether our UI state still points to valid buffers and windows
---@return boolean
local function ui_is_valid()
  local b = chat_state.buffers or {}
  local w = chat_state.windows or {}
  local b_chat_ok = (b.chat ~= nil) and vim.api.nvim_buf_is_valid(b.chat)
  local b_input_ok = (b.input ~= nil) and vim.api.nvim_buf_is_valid(b.input)
  local w_chat_ok = (w.chat ~= nil) and vim.api.nvim_win_is_valid(w.chat)
  local w_input_ok = (w.input ~= nil) and vim.api.nvim_win_is_valid(w.input)
  return b_chat_ok and b_input_ok and w_chat_ok and w_input_ok
end

--- Open NeoAI chat UI
--- Opens the NeoAI chat UI by creating necessary windows and buffers.
---@return nil
function ui.open()
  -- Recover from stale state where buffers/windows were manually closed
  if chat_state.is_open and not ui_is_valid() then
    -- Force a clean close so we can recreate everything
    pcall(function()
      ui.close()
    end)
  end
  if chat_state.is_open and ui_is_valid() then
    return
  end

  -- Create buffers
  chat_state.buffers.chat = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(chat_state.buffers.chat, "neoai://chat")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "filetype", "markdown")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "buftype", "nofile")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(chat_state.buffers.chat, "wrap", true)

  chat_state.buffers.input = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(chat_state.buffers.input, "neoai://input")
  vim.api.nvim_buf_set_option(chat_state.buffers.input, "filetype", "markdown")
  vim.api.nvim_buf_set_option(chat_state.buffers.input, "buftype", "nofile")
  vim.api.nvim_buf_set_option(chat_state.buffers.input, "bufhidden", "wipe")

  -- Ensure manual buffer wipes close the UI state cleanly
  local grp = vim.api.nvim_create_augroup("NeoAIUI", { clear = false })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = grp,
    buffer = chat_state.buffers.chat,
    callback = function()
      pcall(function()
        require("neoai.chat").close()
      end)
    end,
    desc = "Close NeoAI UI when chat buffer is wiped",
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = grp,
    buffer = chat_state.buffers.input,
    callback = function()
      pcall(function()
        require("neoai.chat").close()
      end)
    end,
    desc = "Close NeoAI UI when input buffer is wiped",
  })

  -- Open vertical split at far right
  local right_most_win = get_rightmost_win()
  vim.api.nvim_set_current_win(right_most_win)
  vim.cmd("rightbelow vsplit")
  local vsplit_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(vsplit_win, chat_state.config.window.width or 80)

  -- Use current win (vsplit)(bottom) for input
  local input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(vsplit_win, chat_state.buffers.input)
  vim.api.nvim_set_option_value("winbar", " Input (Enter to send) ", { win = input_win })
  chat_state.windows.input = input_win

  -- Use aboveleft split (top) for chat
  vim.cmd("aboveleft split")
  local chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(chat_win, chat_state.buffers.chat)
  vim.api.nvim_set_option_value("winbar", " Chat ", { win = chat_win })
  ---@type table
  local cfg = chat_state.config.window or {}
  ---@type number
  local ratio = cfg.height_ratio or 0.8
  if ratio < 0 then
    ratio = 0
  end
  if ratio > 1 then
    ratio = 1
  end
  ---@type integer
  local min_input = cfg.min_input_lines or 3
  if min_input < 1 then
    min_input = 1
  end
  ---@type integer
  local chat_h = vim.api.nvim_win_get_height(chat_win)
  ---@type integer
  local input_h = vim.api.nvim_win_get_height(input_win)
  ---@type integer
  local total_h = chat_h + input_h
  ---@type integer
  local target_chat_h = math.floor(total_h * ratio + 0.5)
  if total_h - target_chat_h < min_input then
    target_chat_h = math.max(1, total_h - min_input)
  end
  target_chat_h = math.max(1, math.min(target_chat_h, total_h - 1))
  vim.api.nvim_win_set_height(chat_win, target_chat_h)

  chat_state.windows.chat = chat_win

  -- Set focus to input
  vim.api.nvim_set_current_win(chat_state.windows.input)

  chat_state.is_open = true
end

--- Close NeoAI chat UI
--- Closes the NeoAI chat UI and cleans up the associated windows and buffers.
---@return nil
function ui.close()
  if not chat_state.is_open then
    -- Even if the flag says closed, ensure we drop any stale handles
    chat_state.windows = {}
    chat_state.buffers = {}
    chat_state.is_open = false
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
