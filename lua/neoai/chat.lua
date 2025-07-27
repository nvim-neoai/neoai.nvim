local chat = {}
local ai_tools = require("neoai.ai_tools")
local prompt = require("neoai.prompt")
local storage = require("neoai.storage")

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

  chat.chat_state = {
    config = require("neoai.config").values.chat,
    windows = {},
    buffers = {},
    current_session = nil,
    sessions = {},
    is_open = false,
    streaming_active = false,
  }

  -- Initialize storage backend (SQLite or JSON)
  local success = storage.init(chat.chat_state.config)
  assert(success, "NeoAI: Failed to initialize storage")

  -- Load or create session
  chat.chat_state.current_session = storage.get_active_session()
  if not chat.chat_state.current_session then
    chat.new_session()
  end

  -- Load sessions for UI
  chat.chat_state.sessions = storage.get_all_sessions()
end

-- Scroll helper
local function scroll_to_bottom(bufnr)
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
  local sess = chat.chat_state.current_session
  assert(sess, "NeoAI: Failed to initialize session")
  local messages = storage.get_session_messages(sess.id)

  table.insert(lines, " **NeoAI Chat** ")
  table.insert(lines, " *Session: " .. (sess.title or "Untitled") .. "* ")
  table.insert(lines, " *ID: " .. sess.id .. " | Messages: " .. #messages .. "* ")
  table.insert(lines, " *Created: " .. sess.created_at .. "* ")
  if #chat.chat_state.sessions > 1 then
    table.insert(lines, " *Total Sessions: " .. #chat.chat_state.sessions .. " | Use :NeoAISessionList or `<leader>as` to switch* ")
  end
  table.insert(lines, "")

  for _, message in ipairs(messages) do
    local prefix = ""
    local ts = message.metadata and message.metadata.timestamp or message.created_at or "Unknown"
    if message.type == MESSAGE_TYPES.USER then
      prefix = "**User:** *" .. ts .. "*"
    elseif message.type == MESSAGE_TYPES.ASSISTANT then
      prefix = "**Assistant:** *" .. ts .. "*"
      if message.metadata and message.metadata.response_time then
        prefix = prefix:gsub("%*$", " (" .. message.metadata.response_time .. "s)*")
      end
    elseif message.type == MESSAGE_TYPES.TOOL then
      prefix = "**Tool Response:** *" .. ts .. "*"
    elseif message.type == MESSAGE_TYPES.SYSTEM then
      prefix = "**System:** *" .. ts .. "*"
    elseif message.type == MESSAGE_TYPES.ERROR then
      prefix = "**Error:** *" .. ts .. "*"
    end

    table.insert(lines, "---")
    table.insert(lines, prefix)
    table.insert(lines, "")
    for _, line in ipairs(vim.split(message.content, "\n")) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, lines)
  if chat.chat_state.config.auto_scroll then
    scroll_to_bottom(chat.chat_state.buffers.chat)
  end
end

-- Add message
function chat.add_message(type, content, metadata, tool_call_id, tool_calls)
  metadata = metadata or {}
  metadata.timestamp = metadata.timestamp or os.date("%Y-%m-%d %H:%M:%S")

  local msg_id = storage.add_message(
    chat.chat_state.current_session.id,
    type,
    content,
    metadata,
    tool_call_id,
    tool_calls
  )
  if not msg_id then
    vim.notify("Failed to save message to storage", vim.log.levels.ERROR)
  end

  if chat.chat_state.is_open then
    update_chat_display()
  end
end

-- New session
function chat.new_session(title)
  title = title or ("Session " .. os.date("%Y-%m-%d %H:%M:%S"))
  local session_id = storage.create_session(title, {})
  assert(session_id, "NeoAI: Failed to create new session")

  chat.chat_state.current_session = storage.get_active_session()
  chat.chat_state.sessions = storage.get_all_sessions()

  chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", { session_id = session_id })
  vim.notify("Created new session: " .. title, vim.log.levels.INFO)
end

-- Open/close/toggle
function chat.open()
  local ui = require("neoai.ui")
  local keymaps = require("neoai.keymaps")
  ui.open()
  keymaps.buffer_setup()
  chat.chat_state.is_open = true
  update_chat_display()
end

function chat.close()
  require("neoai.ui").close()
  chat.chat_state.is_open = false
end

function chat.toggle()
  if chat.chat_state.is_open then
    chat.close()
  else
    chat.open()
  end
end

-- Send message
function chat.send_message()
  if chat.chat_state.streaming_active then
    vim.notify("Please wait for the current response to complete", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.input, 0, -1, false)
  local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
  if message == "" then return end

  chat.add_message(MESSAGE_TYPES.USER, message)
  vim.api.nvim_buf_set_lines(chat.chat_state.buffers.input, 0, -1, false, { "" })
  chat.send_to_ai()
end

-- Send to AI
function chat.send_to_ai()
  local data = { tools = chat.format_tools() }
  local system_prompt = prompt.get_system_prompt(data)
  local messages = {
    { role = "system", content = system_prompt }
  }

  local session_msgs = storage.get_session_messages(chat.chat_state.current_session.id, 100)
  local recent = {}
  for i = #session_msgs, 1, -1 do
    local msg = session_msgs[i]
    if msg.type == MESSAGE_TYPES.USER or msg.type == MESSAGE_TYPES.ASSISTANT or msg.type == MESSAGE_TYPES.TOOL then
      table.insert(recent, 1, msg)
      if #recent >= 100 then break end
    end
  end

  for _, msg in ipairs(recent) do
    table.insert(messages, {
      role = msg.type,
      content = msg.content,
      tool_calls = msg.tool_calls,
      tool_call_id = msg.tool_call_id
    })
  end

  if chat.chat_state.is_open then
    local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.chat, 0, -1, false)
    table.insert(lines, "---")
    table.insert(lines, "**Assistant:** *" .. os.date("%Y-%m-%d %H:%M:%S") .. "*")
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, lines)
    if chat.chat_state.config.auto_scroll then
      scroll_to_bottom(chat.chat_state.buffers.chat)
    end
  end

  chat.stream_ai_response(messages)
end

-- Tool call handling
function chat.get_tool_calls(tool_schemas)
  if #tool_schemas == 0 then
    vim.notify("No valid tool calls found", vim.log.levels.WARN)
    chat.chat_state.streaming_active = false
    return
  end

  chat.add_message(MESSAGE_TYPES.ASSISTANT, "**Tool call**", {}, nil, tool_schemas)
  local completed = 0
  for _, schema in ipairs(tool_schemas) do
    if schema.type == "function" and schema["function"] and schema["function"].name then
      local fn = schema["function"]
      local ok, args = pcall(vim.fn.json_decode, fn.arguments or "")
      if not ok then args = {} end

      local tool_found = false
      for _, tool in ipairs(ai_tools.tools) do
        if tool.meta.name == fn.name then
          tool_found = true
          local resp_ok, resp = pcall(tool.run, args)
          if not resp_ok then
            resp = "Error executing tool " .. fn.name .. ": " .. tostring(resp)
            vim.notify(resp, vim.log.levels.ERROR)
          end
          chat.add_message(MESSAGE_TYPES.TOOL, resp or "No response", {}, schema.id)
          break
        end
      end
      if not tool_found then
        local err = "Tool not found: " .. fn.name
        vim.notify(err, vim.log.levels.ERROR)
        chat.add_message(MESSAGE_TYPES.TOOL, err, {}, schema.id)
      end
      completed = completed + 1
    end
  end

  if completed > 0 then
    vim.defer_fn(function()
      chat.send_to_ai()
    end, 100)
  else
    chat.chat_state.streaming_active = false
  end
end

-- Format tools
function chat.format_tools()
  local names = {}
  for _, tool in ipairs(ai_tools.tool_schemas) do
    if tool.type == "function" and tool["function"] and tool["function"].name then
      table.insert(names, tool["function"].name)
    end
  end
  return table.concat(names, ", ")
end

-- Stream AI response
function chat.stream_ai_response(messages)
  local api = require("neoai.api")
  chat.chat_state.streaming_active = true
  local reason, content = "", ""
  local calls = {}
  local start_time = os.time()
  local last_activity = os.time()
  local timeout_timer = vim.loop.new_timer()
  timeout_timer:start(1000, 1000, vim.schedule_wrap(function()
    if os.time() - last_activity > 60 then
      timeout_timer:stop()
      timeout_timer:close()
      chat.chat_state.streaming_active = false
      chat.add_message(MESSAGE_TYPES.ERROR, "Stream timeout", { timeout = true })
      update_chat_display()
    end
  end))

  api.stream(messages,
    function(chunk)
      last_activity = os.time()
      if chunk.type == "content" and chunk.data ~= "" then
        content = content .. chunk.data
        chat.update_streaming_message(content)
      elseif chunk.type == "reasoning" and chunk.data ~= "" then
        reason = reason .. chunk.data
      elseif chunk.type == "tool_calls" and type(chunk.data) == "table" then
        for _, tc in ipairs(chunk.data) do
          if tc.index then
            table.insert(calls, {
              index = tc.index,
              id = tc.id,
              type = tc.type or "function",
              ["function"] = {
                name = tc["function"] and tc["function"].name or "",
                arguments = tc["function"] and tc["function"].arguments or "",
              }
            })
          end
        end
      end
    end,
    function()
      timeout_timer:stop()
      timeout_timer:close()
      local msg = ""
      if reason ~= "" then msg = "<think>\n" .. reason .. "</think>\n\n" end
      if content ~= "" then msg = msg .. content end
      if msg ~= "" then
        chat.add_message(MESSAGE_TYPES.ASSISTANT, msg, { response_time = os.time() - start_time })
      end
      update_chat_display()
      if #calls > 0 then
        chat.get_tool_calls(calls)
      else
        chat.chat_state.streaming_active = false
      end
    end,
    function(exit_code)
      timeout_timer:stop()
      timeout_timer:close()
      chat.chat_state.streaming_active = false
      chat.add_message(MESSAGE_TYPES.ERROR, "AI error: " .. tostring(exit_code), {})
      update_chat_display()
    end
  )
end

-- Update streaming display
function chat.update_streaming_message(content)
  if not chat.chat_state.is_open then return end
  local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.chat, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("^%*%*Assistant:%*%*") then
      local new_lines = {}
      for j = 1, i - 1 do table.insert(new_lines, lines[j]) end
      table.insert(new_lines, "**Assistant:** *" .. os.date("%Y-%m-%d %H:%M:%S") .. "*")
      table.insert(new_lines, "")
      for _, ln in ipairs(vim.split(content, "\n")) do
        table.insert(new_lines, "  " .. ln)
      end
      table.insert(new_lines, "")
      vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, new_lines)
      if chat.chat_state.config.auto_scroll then scroll_to_bottom(chat.chat_state.buffers.chat) end
      break
    end
  end
end

-- Session info and management
function chat.get_session_info()
  local msgs = storage.get_session_messages(chat.chat_state.current_session.id)
  return {
    id = chat.chat_state.current_session.id,
    title = chat.chat_state.current_session.title,
    created_at = chat.chat_state.current_session.created_at,
    message_count = #msgs,
  }
end

function chat.switch_session(session_id)
  local success = storage.switch_session(session_id)
  if success then
    chat.chat_state.current_session = storage.get_active_session()
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then update_chat_display() end
  end
  return success
end

function chat.get_all_sessions()
  return storage.get_all_sessions()
end

function chat.delete_session(session_id)
  local sessions = storage.get_all_sessions()
  if #sessions <= 1 then
    vim.notify("Cannot delete the only session", vim.log.levels.WARN)
    return false
  end
  local is_current = chat.chat_state.current_session.id == session_id
  local success = storage.delete_session(session_id)
  if success then
    if is_current then
      local rem = storage.get_all_sessions()
      if #rem > 0 then chat.switch_session(rem[1].id) else chat.new_session() end
    end
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then update_chat_display() end
  end
  return success
end

function chat.rename_session(new_title)
  local success = storage.update_session_title(chat.chat_state.current_session.id, new_title)
  if success then
    chat.chat_state.current_session.title = new_title
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then update_chat_display() end
    vim.notify("Session renamed to: " .. new_title, vim.log.levels.INFO)
  end
  return success
end

function chat.clear_session()
  local success = storage.clear_session_messages(chat.chat_state.current_session.id)
  if success then
    chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", {})
    if chat.chat_state.is_open then update_chat_display() end
  end
  return success
end

function chat.get_stats()
  return storage.get_stats()
end

function chat.lookup_messages(term)
  if term == "" then vim.notify("Provide a search term", vim.log.levels.WARN) return end
  local results = {}
  for _, m in ipairs(storage.get_session_messages(chat.chat_state.current_session.id)) do
    if m.content:find(term, 1, true) then table.insert(results, m) end
  end
  vim.cmd("botright new")
  vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile, vim.bo.filetype =
    "nofile", "wipe", false, "markdown"
  local lines = { "# Lookup messages containing '" .. term .. "'", "" }
  if #results == 0 then
    table.insert(lines, "No messages found.")
  else
    for _, m in ipairs(results) do
      local ts = m.metadata and m.metadata.timestamp or m.created_at or "Unknown"
      table.insert(lines, "- **" .. m.type .. "** at *" .. ts .. "*")
      table.insert(lines, "```")
      table.insert(lines, m.content)
      table.insert(lines, "```")
      table.insert(lines, "")
    end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modifiable = false
end

-- Export
chat.MESSAGE_TYPES = MESSAGE_TYPES
return chat
