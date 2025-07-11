local chat = {}

-- Chat state
local chat_state = {
  config = {},
  windows = {},
  buffers = {},
  history = {},
  thinking_history = {},
  current_session = nil,
  is_open = false,
}

-- Message types
local MESSAGE_TYPES = {
  USER = "user",
  ASSISTANT = "assistant",
  SYSTEM = "system",
  THINKING = "thinking",
  ERROR = "error",
}

-- Setup function
function chat.setup()
  chat_state.config = require("neoai.config").values.chat

  -- Load history on startup
  if chat_state.config.save_history then
    chat.load_history()
  end

  -- Only create new session if none loaded from history
  if not chat_state.current_session then
    chat.new_session()
  end
end

-- Create new chat session
function chat.new_session()
  chat_state.current_session = {
    id = os.time(),
    messages = {},
    thinking = {},
    created_at = os.date("%Y-%m-%d %H:%M:%S"),
  }

  -- Add system message
  chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", {
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    session_id = chat_state.current_session.id,
  })
end

-- Add message to current session
function chat.add_message(type, content, metadata)
  if not chat_state.current_session then
    chat.new_session()
  end

  local message = {
    type = type,
    content = content,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    metadata = metadata or {},
  }

  table.insert(chat_state.current_session.messages, message)

  -- Update UI if open
  if chat_state.is_open then
    chat.update_chat_display()
  end

  -- Auto-save if enabled
  if chat_state.config.save_history then
    chat.save_history()
  end
end

-- Add thinking step
function chat.add_thinking(content, step)
  if not chat_state.current_session then
    chat.new_session()
  end

  local thinking = {
    content = content,
    step = step or 1,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
  }

  table.insert(chat_state.current_session.thinking, thinking)

  -- Update UI if open and thinking is enabled
  if chat_state.is_open and chat_state.config.show_thinking then
    chat.update_thinking_display()
  end
end

-- Open chat window
function chat.open()
  local ui = require("neoai.ui")
  local keymaps = require("neoai.keymaps")

  ui.open(chat_state)
  keymaps.setup(chat_state, MESSAGE_TYPES)

  chat.update_chat_display()
  if chat_state.config.show_thinking then
    chat.update_thinking_display()
  end
end

-- Close chat window
function chat.close()
  local ui = require("neoai.ui")
  ui.close(chat_state)
end

-- Toggle chat window
function chat.toggle()
  if chat_state.is_open then
    chat.close()
  else
    chat.open()
  end
end

-- Send message
function chat.send_message()
  if not chat_state.is_open then
    return
  end

  -- Get input
  local lines = vim.api.nvim_buf_get_lines(chat_state.buffers.input, 0, -1, false)
  local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")

  if message == "" then
    return
  end

  -- Add user message
  chat.add_message(MESSAGE_TYPES.USER, message)

  -- Clear input
  vim.api.nvim_buf_set_lines(chat_state.buffers.input, 0, -1, false, { "" })

  -- Send to AI
  chat.send_to_ai(message)
end

-- Send message to AI
function chat.send_to_ai(message)
  -- Build message history for API
  local messages = {}

  -- Add system prompt
  local system_prompt = chat.get_system_prompt("system_prompt.md")
  table.insert(messages, {
    role = "system",
    content = system_prompt,
  })

  -- Add conversation history (last 10 messages to avoid context limit)
  local recent_messages = {}
  local count = 0
  for i = #chat_state.current_session.messages, 1, -1 do
    local msg = chat_state.current_session.messages[i]
    if msg.type == MESSAGE_TYPES.USER or msg.type == MESSAGE_TYPES.ASSISTANT then
      table.insert(recent_messages, 1, msg)
      count = count + 1
      if count >= 10 then
        break
      end
    end
  end

  -- Convert to API format
  for _, msg in ipairs(recent_messages) do
    table.insert(messages, {
      role = msg.type,
      content = msg.content,
    })
  end

  -- Add thinking step
  chat.add_thinking("Processing user message: " .. message, 1)
  chat.add_thinking("Preparing API request with " .. #messages .. " messages", 2)

  -- Insert placeholder for streaming response (fix for first message not streaming)
  if chat_state.is_open then
    local lines = vim.api.nvim_buf_get_lines(chat_state.buffers.chat, 0, -1, false)
    table.insert(lines, "Assistant: " .. os.date("%H:%M:%S"))
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(chat_state.buffers.chat, 0, -1, false, lines)
    if chat_state.config.auto_scroll then
      chat.scroll_to_bottom(chat_state.buffers.chat)
    end
  end

  -- Call API with streaming
  chat.stream_ai_response(messages)
end

-- Stream AI response
function chat.stream_ai_response(messages)
  local api = require("neoai.api")

  local response_content = ""
  local response_start_time = os.time()

  chat.add_thinking("Starting streaming response from AI", 3)

  api.stream(messages, function(content)
    response_content = response_content .. content
    chat.update_streaming_message(response_content)
    if #content > 10 then
      chat.add_thinking("Received chunk: " .. content:sub(1, 50) .. "...", 4)
    end
  end, function()
    chat.add_message(MESSAGE_TYPES.ASSISTANT, response_content, {
      response_time = os.time() - response_start_time,
    })
    chat.add_thinking("Response completed successfully", 5)
    chat.update_chat_display()
    if chat_state.config.show_thinking then
      chat.update_thinking_display()
    end
  end, function(exit_code)
    chat.add_message(MESSAGE_TYPES.ERROR, "Failed to get response from AI", {
      exit_code = exit_code,
    })
    chat.add_thinking("Response failed with exit code: " .. exit_code, 5)
    chat.update_chat_display()
    if chat_state.config.show_thinking then
      chat.update_thinking_display()
    end
  end)
end

-- Update streaming message display
function chat.update_streaming_message(content)
  if not chat_state.is_open then
    return
  end

  -- Get current display lines
  local lines = vim.api.nvim_buf_get_lines(chat_state.buffers.chat, 0, -1, false)

  -- Find the last "Assistant:" line and update it
  for i = #lines, 1, -1 do
    if lines[i]:match("^Assistant:") then
      -- Replace lines from this point
      local new_lines = {}
      for j = 1, i - 1 do
        table.insert(new_lines, lines[j])
      end

      -- Add streaming response
      table.insert(new_lines, "Assistant: " .. os.date("%H:%M:%S"))
      local content_lines = vim.split(content, "\n")
      for _, line in ipairs(content_lines) do
        table.insert(new_lines, "  " .. line)
      end
      table.insert(new_lines, "")

      -- Update buffer
      vim.api.nvim_buf_set_lines(chat_state.buffers.chat, 0, -1, false, new_lines)

      -- Auto-scroll if enabled
      if chat_state.config.auto_scroll then
        chat.scroll_to_bottom(chat_state.buffers.chat)
      end

      break
    end
  end
end

-- Update chat display
function chat.update_chat_display()
  if not chat_state.is_open or not chat_state.current_session then
    return
  end

  local lines = {}

  -- Add session header
  table.insert(lines, "=== NeoAI Chat Session ===")
  table.insert(lines, "Session ID: " .. chat_state.current_session.id)
  table.insert(lines, "Created: " .. chat_state.current_session.created_at)
  table.insert(lines, "Messages: " .. #chat_state.current_session.messages)
  table.insert(lines, "")

  -- Add messages
  for _, message in ipairs(chat_state.current_session.messages) do
    local prefix = ""
    if message.type == MESSAGE_TYPES.USER then
      prefix = "User: " .. message.timestamp
    elseif message.type == MESSAGE_TYPES.ASSISTANT then
      prefix = "Assistant: " .. message.timestamp
      if message.metadata.response_time then
        prefix = prefix .. " (" .. message.metadata.response_time .. "s)"
      end
    elseif message.type == MESSAGE_TYPES.SYSTEM then
      prefix = "System: " .. message.timestamp
    elseif message.type == MESSAGE_TYPES.ERROR then
      prefix = "Error: " .. message.timestamp
    end

    table.insert(lines, prefix)

    -- Add message content
    local content_lines = vim.split(message.content, "\n")
    for _, line in ipairs(content_lines) do
      table.insert(lines, "  " .. line)
    end
    table.insert(lines, "")
  end

  -- Update buffer
  vim.api.nvim_buf_set_lines(chat_state.buffers.chat, 0, -1, false, lines)

  -- Auto-scroll if enabled
  if chat_state.config.auto_scroll then
    chat.scroll_to_bottom(chat_state.buffers.chat)
  end
end

-- Update thinking display
function chat.update_thinking_display()
  if not chat_state.is_open or not chat_state.config.show_thinking or not chat_state.current_session then
    return
  end

  local lines = {}

  -- Add thinking header
  table.insert(lines, "=== AI Thinking Process ===")
  table.insert(lines, "")

  -- Add thinking steps (last 10)
  local thinking_steps = chat_state.current_session.thinking
  local start_idx = math.max(1, #thinking_steps - 9)

  for i = start_idx, #thinking_steps do
    local step = thinking_steps[i]
    table.insert(lines, "Step " .. step.step .. " [" .. step.timestamp .. "]:")

    -- ✅ SAFELY add multiline content
    local content_lines = vim.split(step.content, "\n", { plain = true })
    for _, line in ipairs(content_lines) do
      table.insert(lines, "  " .. line)
    end

    table.insert(lines, "")
  end

  -- Update buffer
  vim.api.nvim_buf_set_lines(chat_state.buffers.thinking, 0, -1, false, lines)

  -- Auto-scroll if enabled
  if chat_state.config.auto_scroll then
    chat.scroll_to_bottom(chat_state.buffers.thinking)
  end
end

-- Scroll to bottom of buffer
function chat.scroll_to_bottom(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, win in pairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_win_set_cursor(win, { line_count, 0 })
      break
    end
  end
end

local function get_plugin_dir()
  local info = debug.getinfo(1, "S")
  return info.source:sub(2):match("(.*/)")
end

-- Get system prompt
---@param path string
function chat.get_system_prompt(path)
  path = get_plugin_dir() .. path
  local file, err = io.open(path, "r")
  if not file then
    print("Failed to open file:", err)
    return nil
  end
  local prompt = file:read("*a")
  file:close()
  return prompt
end

-- Clear chat history
function chat.clear_history()
  if chat_state.current_session then
    chat_state.current_session.messages = {}
    chat_state.current_session.thinking = {}
  end

  -- Update display
  if chat_state.is_open then
    chat.update_chat_display()
    if chat_state.config.show_thinking then
      chat.update_thinking_display()
    end
  end

  vim.notify("Chat history cleared")

  -- Save cleared history immediately if enabled
  if chat_state.config.save_history then
    chat.save_history()
  end
end

-- Save history to file
function chat.save_history()
  if not chat_state.config.save_history then
    return
  end

  local history_data = {
    sessions = { chat_state.current_session },
    saved_at = os.date("%Y-%m-%d %H:%M:%S"),
    version = "1.0",
  }

  local file = io.open(chat_state.config.history_file, "w")
  if file then
    file:write(vim.fn.json_encode(history_data))
    file:close()
    vim.notify("Chat history saved to " .. chat_state.config.history_file)
  else
    vim.notify("Failed to save chat history", vim.log.levels.ERROR)
  end
end

-- Load history from file
function chat.load_history()
  if not chat_state.config.save_history then
    return
  end

  local file = io.open(chat_state.config.history_file, "r")
  if file then
    local content = file:read("*a")
    file:close()

    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and data and data.sessions and #data.sessions > 0 then
      chat_state.current_session = data.sessions[1] -- Load most recent session
      vim.notify("Chat history loaded from " .. chat_state.config.history_file)
    end
  end
end

-- Get current session info
function chat.get_session_info()
  if not chat_state.current_session then
    return nil
  end

  return {
    id = chat_state.current_session.id,
    created_at = chat_state.current_session.created_at,
    message_count = #chat_state.current_session.messages,
    thinking_count = #chat_state.current_session.thinking,
  }
end

-- Export functions
chat.MESSAGE_TYPES = MESSAGE_TYPES

return chat
