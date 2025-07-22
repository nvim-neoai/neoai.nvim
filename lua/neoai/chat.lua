local chat = {}

local ai_tools = require("neoai.ai_tools")

-- Message types
local MESSAGE_TYPES = {
  USER = "user",
  ASSISTANT = "assistant",
  TOOL = "tool",
  SYSTEM = "system",
  THINKING = "thinking",
  ERROR = "error",
}

-- Setup function
function chat.setup()
  ai_tools.setup()

  -- Chat state
  chat.chat_state = {
    config = {},
    windows = {},
    buffers = {},
    current_session = nil,
    is_open = false,
  }
  chat.chat_state.config = require("neoai.config").values.chat

  -- Load history on startup
  if chat.chat_state.config.save_history then
    chat.load_history()
  end

  -- Only create new session if none loaded from history
  if not chat.chat_state.current_session then
    chat.new_session()
  end
end

-- Scroll to bottom of buffer
local scroll_to_bottom = function(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, win in pairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_win_set_cursor(win, { line_count, 0 })
      break
    end
  end
end
-- Update chat display
local function update_chat_display()
  if not chat.chat_state.is_open or not chat.chat_state.current_session then
    return
  end

  local lines = {}

  -- Add session header
  table.insert(lines, " **NeoAI Chat Session** ")
  table.insert(lines, " *Session ID: " .. chat.chat_state.current_session.id .. "* ")
  table.insert(lines, " *Created: " .. chat.chat_state.current_session.created_at .. "* ")
  table.insert(lines, " *Messages: " .. #chat.chat_state.current_session.messages .. "* ")
  table.insert(lines, "")

  -- Add messages
  for _, message in ipairs(chat.chat_state.current_session.messages) do
    local prefix = ""
    if message.type == MESSAGE_TYPES.USER then
      prefix = "**User:** " .. "*" .. message.metadata.timestamp .. "*"
    elseif message.type == MESSAGE_TYPES.ASSISTANT then
      prefix = "**Assistant:** " .. "*" .. message.metadata.timestamp
      if message.metadata.response_time then
        prefix = prefix .. " (" .. message.metadata.response_time .. "s)"
      end
      prefix = prefix .. "*"
    elseif message.type == MESSAGE_TYPES.TOOL then
      prefix = "**Tool Response:** " .. "*" .. message.metadata.timestamp .. "*"
    elseif message.type == MESSAGE_TYPES.SYSTEM then
      prefix = "**System:** " .. "*" .. message.metadata.timestamp .. "*"
    elseif message.type == MESSAGE_TYPES.ERROR then
      prefix = "**Error:** " .. "*" .. message.metadata.timestamp .. "*"
    end

    table.insert(lines, "---")
    table.insert(lines, prefix)
    table.insert(lines, "")

    -- Add message content
    local content_lines = vim.split(message.content, "\n")
    for _, line in ipairs(content_lines) do
      table.insert(lines, "" .. line)
    end
    table.insert(lines, "")
  end

  -- Update buffer
  vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, lines)

  -- Auto-scroll if enabled
  if chat.chat_state.config.auto_scroll then
    scroll_to_bottom(chat.chat_state.buffers.chat)
  end
end

-- Add message to current session
---@param type string
---@param content string
---@param metadata? table
---@param tool_call_id? string
---@param tool_calls? table
function chat.add_message(type, content, metadata, tool_call_id, tool_calls)
  if not chat.chat_state.current_session then
    chat.new_session()
  end
  metadata = metadata or {}
  metadata["timestamp"] = os.date("%Y-%m-%d %H:%M:%S")

  local message = {
    type = type,
    content = content,
    metadata = metadata or {},
  }
  if tool_call_id then
    message["tool_call_id"] = tool_call_id
  end
  if tool_calls then
    message["tool_calls"] = tool_calls
  end

  table.insert(chat.chat_state.current_session.messages, message)

  -- Update UI if open
  if chat.chat_state.is_open then
    update_chat_display()
  end

  -- Auto-save if enabled
  if chat.chat_state.config.save_history then
    chat.save_history()
  end
end

-- Create new chat session
function chat.new_session()
  chat.chat_state.current_session = {
    id = os.time(),
    messages = {},
    created_at = os.date("%Y-%m-%d %H:%M:%S"),
  }

  -- Add system message
  chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", {
    session_id = chat.chat_state.current_session.id,
  })
end

-- Open chat window
function chat.open()
  local ui = require("neoai.ui")
  local keymaps = require("neoai.keymaps")

  ui.open()
  keymaps.buffer_setup()

  update_chat_display()
end

-- Close chat window
function chat.close()
  local ui = require("neoai.ui")
  ui.close()
end

-- Toggle chat window
function chat.toggle()
  if chat.chat_state.is_open then
    chat.close()
  else
    chat.open()
  end
end

-- Send message
function chat.send_message()
  if not chat.chat_state.is_open then
    return
  end

  -- Get input
  local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.input, 0, -1, false)
  local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")

  if message == "" then
    return
  end

  -- Add user message
  chat.add_message(MESSAGE_TYPES.USER, message)

  -- Clear input
  vim.api.nvim_buf_set_lines(chat.chat_state.buffers.input, 0, -1, false, { "" })

  -- Send to AI
  chat.send_to_ai()
end

-- Send message to AI
function chat.send_to_ai()
  -- Build message history for API
  local messages = {}

  -- Add system prompt
  local system_prompt = chat.get_system_prompt()
  table.insert(messages, {
    role = "system",
    content = system_prompt,
  })

  -- Add conversation history (last 20 messages to avoid context limit)
  local recent_messages = {}
  local count = 0
  for i = #chat.chat_state.current_session.messages, 1, -1 do
    local msg = chat.chat_state.current_session.messages[i]
    if msg.type == MESSAGE_TYPES.USER or msg.type == MESSAGE_TYPES.ASSISTANT or msg.type == MESSAGE_TYPES.TOOL then
      table.insert(recent_messages, 1, msg)
      count = count + 1
      if count >= 20 then
        break
      end
    end
  end

  -- Convert to API format
  for _, msg in ipairs(recent_messages) do
    table.insert(messages, {
      role = msg.type,
      content = msg.content,
      tool_calls = msg.tool_calls or nil,
      tool_call_id = msg.tool_call_id or nil,
    })
  end

  -- Insert placeholder for streaming response (fix for first message not streaming)
  if chat.chat_state.is_open then
    local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.chat, 0, -1, false)
    table.insert(lines, "---")
    table.insert(lines, "**Assistant:** " .. "*" .. os.date("%Y-%m-%d %H:%M:%S") .. "*")
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, lines)
    if chat.chat_state.config.auto_scroll then
      scroll_to_bottom(chat.chat_state.buffers.chat)
    end
  end

  -- Call API with streaming
  chat.stream_ai_response(messages)
end

chat.get_tool_calls = function(tool_schemas)
  chat.add_message(MESSAGE_TYPES.ASSISTANT, "**Tool call**", {}, nil, tool_schemas)
  local tools = ai_tools.tools
  for _, tool_schema in ipairs(tool_schemas) do
    if tool_schema.type == "function" and tool_schema["function"] then
      local fn = tool_schema["function"]
      for _, tool in ipairs(tools) do
        if tool.meta.name == fn.name then
          local args = vim.fn.json_decode(fn.arguments)
          local tool_response = tool.run(args)
          chat.add_message(MESSAGE_TYPES.TOOL, tool_response, {}, tool_schema.id)
        end
      end
    end
  end
  chat.send_to_ai()
end

-- Format tools into a string for %tools substitution
chat.format_tools = function()
  local entries = {}

  for _, tool in ipairs(ai_tools.tool_schemas) do
    if tool.type == "function" and tool["function"] then
      local fn = tool["function"]
      local args = {}

      local properties = fn.parameters and fn.parameters.properties or {}
      local required = fn.parameters and fn.parameters.required or {}

      local function is_required(arg)
        for _, r in ipairs(required) do
          if r == arg then
            return true
          end
        end
        return false
      end

      for arg, def in pairs(properties) do
        table.insert(
          args,
          string.format(
            "  - %s: %s - %s%s",
            arg,
            def.type or "any",
            def.description or "No description",
            is_required(arg) and " (required)" or ""
          )
        )
      end

      local entry = string.format(
        [[
Tool Name: %s
Tool Description: %s
Tool Arguments:
%s
]],
        fn.name or "Unnamed Tool",
        fn.description or "No description",
        next(args) and table.concat(args, "\n") or "  (no arguments)"
      )

      table.insert(entries, entry)
    end
  end

  return table.concat(entries, "\n")
end

-- Stream AI response
function chat.stream_ai_response(messages)
  local api = require("neoai.api")

  local reason_response = ""
  local content_response = ""
  local tool_calls_response = {}
  local response_start_time = os.time()

  api.stream(
    messages,
    -- streaming callback
    function(content_chunk)
      content_response = content_response .. content_chunk
      chat.update_streaming_message(content_response)
    end,
    function(reason_chunk)
      reason_response = reason_response .. reason_chunk
    end,
    -- tool call callback
    function(tool_calls_chunk)
      for _, tool_call in ipairs(tool_calls_chunk) do
        local found = false
        for _, existing_call in ipairs(tool_calls_response) do
          if existing_call.index == tool_call.index then
            existing_call["function"].arguments = (existing_call["function"].arguments or "")
              .. (tool_call["function"].arguments or "")
            found = true
            break
          end
        end
        -- If not already tracked, add the new tool_call
        if not found then
          table.insert(tool_calls_response, tool_call)
        end
      end
    end,
    -- streaming complete callback
    function()
      local _message = ""

      if reason_response and reason_response ~= "" then
        _message = "<think>\n" .. reason_response .. "</think>\n\n"
      end
      if content_response and content_response ~= "" then
        _message = _message .. content_response
      end

      if not messages then
        return
      end

      chat.add_message(MESSAGE_TYPES.ASSISTANT, _message, {
        response_time = os.time() - response_start_time,
      })

      update_chat_display()
    end,
    -- tool call complete callback
    function()
      chat.get_tool_calls(tool_calls_response)
    end,
    -- error callback
    function(exit_code)
      chat.add_message(MESSAGE_TYPES.ERROR, "Failed to get response from AI", {
        exit_code = exit_code,
      })
      update_chat_display()
    end
  )
end

-- Update streaming message display
function chat.update_streaming_message(content)
  if not chat.chat_state.is_open then
    return
  end

  -- Get current display lines
  local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.chat, 0, -1, false)

  -- Find the last "**Assistant:**" line and update it
  for i = #lines, 1, -1 do
    if lines[i]:match("^%*%*Assistant:%*%*") then
      -- Replace lines from this point
      local new_lines = {}
      for j = 1, i - 1 do
        table.insert(new_lines, lines[j])
      end

      -- Add streaming response
      table.insert(new_lines, "**Assistant:** " .. "*" .. os.date("%Y-%m-%d %H:%M:%S") .. "*")
      local content_lines = vim.split(content, "\n")
      for _, line in ipairs(content_lines) do
        table.insert(new_lines, "  " .. line)
      end
      table.insert(new_lines, "")

      -- Update buffer
      vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, new_lines)

      -- Auto-scroll if enabled
      if chat.chat_state.config.auto_scroll then
        scroll_to_bottom(chat.chat_state.buffers.chat)
      end

      break
    end
  end
end

local function get_plugin_dir()
  local info = debug.getinfo(1, "S")
  return info.source:sub(2):match("(.*/)")
end

-- Get prompt template
function chat.get_prompt_template()
  local template_path = get_plugin_dir() .. "system_prompt.md"
  local file, err = io.open(template_path, "r")
  if not file then
    print("Failed to open file:", err)
    return nil
  end
  local prompt_template = file:read("*a")
  file:close()
  return prompt_template
end

-- Get system prompt
function chat.get_system_prompt()
  local prompt_template = chat.get_prompt_template()

  local data = {}
  data["tools"] = chat.format_tools()

  local message = ""

  if prompt_template then
    message = prompt_template:gsub("%%(%w+)", function(key)
      return data[key] or ""
    end)
  end

  return message
end

-- Save history to file
function chat.save_history()
  if not chat.chat_state.config.save_history then
    return
  end

  local history_data = {
    sessions = { chat.chat_state.current_session },
    saved_at = os.date("%Y-%m-%d %H:%M:%S"),
    version = "1.0",
  }

  local file = io.open(chat.chat_state.config.history_file, "w")
  if file then
    file:write(vim.fn.json_encode(history_data))
    file:close()
    vim.notify("Chat history saved to " .. chat.chat_state.config.history_file)
  else
    vim.notify("Failed to save chat history", vim.log.levels.ERROR)
  end
end

-- Load history from file
function chat.load_history()
  if not chat.chat_state.config.save_history then
    return
  end

  local file = io.open(chat.chat_state.config.history_file, "r")
  if file then
    local content = file:read("*a")
    file:close()

    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and data and data.sessions and #data.sessions > 0 then
      chat.chat_state.current_session = data.sessions[1] -- Load most recent session
      vim.notify("Chat history loaded from " .. chat.chat_state.config.history_file)
    end
  end
end

-- Get current session info
function chat.get_session_info()
  if not chat.chat_state.current_session then
    return nil
  end

  return {
    id = chat.chat_state.current_session.id,
    created_at = chat.chat_state.current_session.created_at,
    message_count = #chat.chat_state.current_session.messages,
  }
end

-- Export functions
chat.MESSAGE_TYPES = MESSAGE_TYPES

return chat
