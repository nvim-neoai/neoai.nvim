local M = {}

-- JSON file-based storage backend for NeoAI chat sessions and messages

local json_path = nil
local data = {
  sessions = {},
  messages = {},
  last_session_id = 0,
  last_message_id = 0,
}

local function save()
  local ok, err = pcall(function()
    assert(json_path, "NeoAI: JSON file not found")
    local f = io.open(json_path, "w")
    assert(f, "Cannot open " .. json_path .. " for writing")
    f:write(vim.fn.json_encode(data))
    f:close()
  end)
  if not ok then
    vim.notify("NeoAI: Failed to save JSON storage: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function load()
  assert(json_path, "NeoAI: JSON file not found")
  local f = io.open(json_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.fn.json_decode, content)
    if ok and decoded then
      data = decoded
      data.sessions = data.sessions or {}
      data.messages = data.messages or {}
      data.last_session_id = data.last_session_id or 0
      data.last_message_id = data.last_message_id or 0
    end
  end
end

function M.init(config)
  json_path = config.database_path or (vim.fn.stdpath("data") .. "/neoai.json")
  load()
  vim.notify("NeoAI: Using JSON file for storage at " .. json_path, vim.log.levels.WARN)
  return true
end

function M.create_session(title, metadata)
  title = title or ("Session " .. os.date("%Y-%m-%d %H:%M:%S"))
  metadata = metadata or {}
  for _, s in ipairs(data.sessions) do
    s.is_active = false
  end
  data.last_session_id = (data.last_session_id or 0) + 1
  local session = {
    id = data.last_session_id,
    title = title,
    created_at = os.date("%Y-%m-%d %H:%M:%S"),
    updated_at = os.date("%Y-%m-%d %H:%M:%S"),
    is_active = true,
    metadata = metadata,
  }
  table.insert(data.sessions, session)
  save()
  return session.id
end

function M.get_active_session()
  for _, s in ipairs(data.sessions) do
    if s.is_active then
      return vim.deepcopy(s)
    end
  end
  return nil
end

function M.switch_session(session_id)
  local found = false
  for _, s in ipairs(data.sessions) do
    if s.id == session_id then
      s.is_active = true
      s.updated_at = os.date("%Y-%m-%d %H:%M:%S")
      found = true
    else
      s.is_active = false
    end
  end
  save()
  if found then
    vim.notify("Switched to session " .. session_id, vim.log.levels.INFO)
    return true
  else
    vim.notify("Failed to switch session", vim.log.levels.ERROR)
    return false
  end
end

function M.get_all_sessions(limit)
  limit = limit or 50
  local sessions = {}
  for i, s in ipairs(data.sessions) do
    if i > limit then
      break
    end
    table.insert(sessions, vim.deepcopy(s))
  end
  return sessions
end

function M.delete_session(session_id)
  local idx = nil
  for i, s in ipairs(data.sessions) do
    if s.id == session_id then
      idx = i
      break
    end
  end
  if idx then
    table.remove(data.sessions, idx)
    -- Remove all messages for this session
    local new_messages = {}
    for _, m in ipairs(data.messages) do
      if m.session_id ~= session_id then
        table.insert(new_messages, m)
      end
    end
    data.messages = new_messages
    save()
    vim.notify("Deleted session " .. session_id, vim.log.levels.INFO)
    return true
  else
    vim.notify("Failed to delete session", vim.log.levels.ERROR)
    return false
  end
end

function M.update_session_title(session_id, new_title)
  for _, s in ipairs(data.sessions) do
    if s.id == session_id then
      s.title = new_title
      s.updated_at = os.date("%Y-%m-%d %H:%M:%S")
      save()
      return true
    end
  end
  return false
end

function M.add_message(session_id, type, content, metadata, tool_call_id, tool_calls)
  metadata = metadata or {}
  metadata.timestamp = metadata.timestamp or os.date("%Y-%m-%d %H:%M:%S")
  data.last_message_id = (data.last_message_id or 0) + 1
  local message = {
    id = data.last_message_id,
    session_id = session_id,
    type = type,
    content = content,
    metadata = metadata,
    tool_call_id = tool_call_id,
    tool_calls = tool_calls,
    created_at = os.date("%Y-%m-%d %H:%M:%S"),
  }
  table.insert(data.messages, message)
  -- Update session updated_at
  for _, s in ipairs(data.sessions) do
    if s.id == session_id then
      s.updated_at = os.date("%Y-%m-%d %H:%M:%S")
      break
    end
  end
  save()
  return message.id
end

function M.get_session_messages(session_id, limit)
  limit = limit or 1000
  local messages = {}
  for _, m in ipairs(data.messages) do
    if m.session_id == session_id then
      table.insert(messages, vim.deepcopy(m))
      if #messages >= limit then
        break
      end
    end
  end
  return messages
end

function M.clear_session_messages(session_id)
  local new_messages = {}
  for _, m in ipairs(data.messages) do
    if m.session_id ~= session_id then
      table.insert(new_messages, m)
    end
  end
  data.messages = new_messages
  save()
  vim.notify("Cleared messages from session", vim.log.levels.INFO)
  return true
end

function M.get_stats()
  local active_sessions = 0
  for _, s in ipairs(data.sessions) do
    if s.is_active then
      active_sessions = active_sessions + 1
    end
  end
  return {
    sessions = #data.sessions,
    messages = #data.messages,
    active_sessions = active_sessions,
    database_path = json_path,
    storage_type = "json",
  }
end

function M.close()
  save()
end

return M
