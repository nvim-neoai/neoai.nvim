local chat = {}

local ai_tools = require("neoai.ai_tools")
local prompt = require("neoai.prompt")

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
    streaming_active = false, -- Track streaming state
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

  -- Don't allow sending new messages while streaming
  if chat.chat_state.streaming_active then
    vim.notify("Please wait for the current response to complete", vim.log.levels.WARN)
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
  local data = {}
  data["tools"] = chat.format_tools()

  local messages = {}

  -- Add system prompt
  local system_prompt = prompt.get_system_prompt(data)
  table.insert(messages, {
    role = "system",
    content = system_prompt,
  })

  -- Add conversation history (last 100 messages to avoid context limit)
  local recent_messages = {}
  local count = 0
  for i = #chat.chat_state.current_session.messages, 1, -1 do
    local msg = chat.chat_state.current_session.messages[i]
    if msg.type == MESSAGE_TYPES.USER or msg.type == MESSAGE_TYPES.ASSISTANT or msg.type == MESSAGE_TYPES.TOOL then
      table.insert(recent_messages, 1, msg)
      count = count + 1
      if count >= 100 then
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

-- Handle tool calls with proper error handling and timeout
chat.get_tool_calls = function(tool_schemas)
  -- Validate tool_schemas
  if not tool_schemas or type(tool_schemas) ~= "table" or #tool_schemas == 0 then
    vim.notify("Invalid or empty tool calls received", vim.log.levels.WARN)
    chat.chat_state.streaming_active = false
    return
  end

  -- Add tool call message
  chat.add_message(MESSAGE_TYPES.ASSISTANT, "**Tool call**", {}, nil, tool_schemas)

  local tools = ai_tools.tools
  local tool_responses_completed = 0
  local total_tools = 0

  -- Count valid tool calls
  for _, tool_schema in ipairs(tool_schemas) do
    if tool_schema.type == "function" and tool_schema["function"] and tool_schema["function"].name then
      total_tools = total_tools + 1
    end
  end

  if total_tools == 0 then
    vim.notify("No valid tool calls found", vim.log.levels.WARN)
    chat.chat_state.streaming_active = false
    return
  end

  -- Execute tool calls
  for _, tool_schema in ipairs(tool_schemas) do
    if tool_schema.type == "function" and tool_schema["function"] then
      local fn = tool_schema["function"]
      if fn.name then
        local tool_found = false

        for _, tool in ipairs(tools) do
          if tool.meta.name == fn.name then
            tool_found = true

            -- Parse arguments with error handling
            local ok, args = pcall(function()
              if fn.arguments and fn.arguments ~= "" then
                return vim.fn.json_decode(fn.arguments)
              else
                return {}
              end
            end)

            if not ok then
              vim.notify(
                "Failed to parse tool arguments for " .. fn.name .. ": " .. tostring(args),
                vim.log.levels.ERROR
              )
              args = {}
            end

            -- Execute tool with error handling
            local tool_ok, tool_response = pcall(function()
              return tool.run(args)
            end)

            if not tool_ok then
              tool_response = "Error executing tool " .. fn.name .. ": " .. tostring(tool_response)
              vim.notify(tool_response, vim.log.levels.ERROR)
            end

            -- Add tool response
            chat.add_message(MESSAGE_TYPES.TOOL, tool_response or "No response", {}, tool_schema.id)
            tool_responses_completed = tool_responses_completed + 1
            break
          end
        end

        if not tool_found then
          local error_msg = "Tool not found: " .. fn.name
          vim.notify(error_msg, vim.log.levels.ERROR)
          chat.add_message(MESSAGE_TYPES.TOOL, error_msg, {}, tool_schema.id)
          tool_responses_completed = tool_responses_completed + 1
        end
      else
        vim.notify("Tool call missing function name", vim.log.levels.ERROR)
        tool_responses_completed = tool_responses_completed + 1
      end
    else
      vim.notify("Invalid tool call format", vim.log.levels.ERROR)
      tool_responses_completed = tool_responses_completed + 1
    end
  end

  -- Continue conversation after all tools are executed
  if tool_responses_completed == total_tools then
    -- Small delay to ensure UI updates are complete
    vim.defer_fn(function()
      chat.send_to_ai()
    end, 100)
  else
    vim.notify("Not all tool calls completed successfully", vim.log.levels.WARN)
    chat.chat_state.streaming_active = false
  end
end

-- Format tools into a comma-separated string of tool names
chat.format_tools = function()
  local names = {}
  for _, tool in ipairs(ai_tools.tool_schemas) do
    if tool.type == "function" and tool["function"] then
      local fn = tool["function"]
      if fn.name then
        table.insert(names, fn.name)
      end
    end
  end
  return table.concat(names, ", ")
end

-- Stream AI response with improved error handling
function chat.stream_ai_response(messages)
  local api = require("neoai.api")

  -- Set streaming state
  chat.chat_state.streaming_active = true

  local reason_response = ""
  local content_response = ""
  local tool_calls_response = {}
  local response_start_time = os.time()
  local stream_timeout = 60
  local last_activity = os.time()

  -- Timeout checker
  local timeout_timer = vim.loop.new_timer()
  timeout_timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if os.time() - last_activity > stream_timeout then
        timeout_timer:stop()
        timeout_timer:close()
        chat.chat_state.streaming_active = false
        chat.add_message(
          MESSAGE_TYPES.ERROR,
          "Stream timeout - no response received for " .. stream_timeout .. " seconds",
          {
            timeout = true,
          }
        )
        update_chat_display()
      end
    end)
  )

  api.stream(
    messages,
    -- Single chunk callback
    function(chunk)
      last_activity = os.time()

      if chunk.type == "content" then
        if chunk.data and chunk.data ~= "" then
          content_response = content_response .. chunk.data
          chat.update_streaming_message(content_response)
        end
      elseif chunk.type == "reasoning" then
        if chunk.data and chunk.data ~= "" then
          reason_response = reason_response .. chunk.data
        end
      elseif chunk.type == "tool_calls" then
        if chunk.data and type(chunk.data) == "table" then
          for _, tool_call in ipairs(chunk.data) do
            if tool_call and tool_call.index then
              local found = false
              for _, existing_call in ipairs(tool_calls_response) do
                if existing_call.index == tool_call.index then
                  -- Merge tool call arguments
                  if tool_call["function"] and tool_call["function"].arguments then
                    existing_call["function"] = existing_call["function"] or {}
                    existing_call["function"].arguments = (existing_call["function"].arguments or "")
                        .. tool_call["function"].arguments
                  end
                  found = true
                  break
                end
              end
              -- If not already tracked, add the new tool_call
              if not found then
                -- Ensure we have a complete tool call structure
                local complete_tool_call = {
                  index = tool_call.index,
                  id = tool_call.id,
                  type = tool_call.type or "function",
                  ["function"] = {
                    name = tool_call["function"] and tool_call["function"].name or "",
                    arguments = tool_call["function"] and tool_call["function"].arguments or "",
                  },
                }
                table.insert(tool_calls_response, complete_tool_call)
              end
            end
          end
        end
      end
    end,
    -- Single completion callback
    function()
      -- Stop timeout timer
      if timeout_timer then
        timeout_timer:stop()
        timeout_timer:close()
      end

      local _message = ""

      if reason_response and reason_response ~= "" then
        _message = "<think>\n" .. reason_response .. "</think>\n\n"
      end
      if content_response and content_response ~= "" then
        _message = _message .. content_response
      end

      -- Always add the assistant message if we have any content
      -- This handles cases where AI streams both content AND tool calls
      if _message ~= "" then
        chat.add_message(MESSAGE_TYPES.ASSISTANT, _message, {
          response_time = os.time() - response_start_time,
        })
      end

      -- Update display before potentially calling tools
      update_chat_display()

      -- Handle tool calls if present
      if tool_calls_response and #tool_calls_response > 0 then
        -- Process tool calls (this will continue the conversation)
        chat.get_tool_calls(tool_calls_response)
      else
        -- No tool calls, streaming is complete
        chat.chat_state.streaming_active = false
      end
    end,
    -- Error callback
    function(exit_code)
      -- Stop timeout timer
      if timeout_timer then
        timeout_timer:stop()
        timeout_timer:close()
      end

      chat.chat_state.streaming_active = false
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
      table.insert(new_lines, "")
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
