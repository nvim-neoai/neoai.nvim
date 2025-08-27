local M = {}

-- SQLite database module for NeoAI chat sessions and messages
-- This module provides persistent storage for multi-session chat history

local sqlite = nil
local db = nil
local db_path = nil

local function load_sqlite()
  local ok, lib = pcall(require, "lsqlite3")
  if ok then
    return lib, "lsqlite3"
  end
  return nil, nil
end

function M.init(config)
  db_path = config.database_path or (vim.fn.stdpath("data") .. "/neoai.db")
  local lib, lib_name = load_sqlite()
  if not lib then
    error("NeoAI: SQLite not available. Please install `lsqlite3`.")
  end
  sqlite = lib
  vim.notify("NeoAI: Using " .. lib_name .. " for database", vim.log.levels.INFO)
  return M.init_sqlite()
end

function M.init_sqlite()
  assert(sqlite, "NeoAI: SQLite not loaded")
  db = sqlite.open(db_path)
  if not db then
    vim.notify("Failed to open database at " .. db_path, vim.log.levels.ERROR)
    return false
  end

  db:exec("PRAGMA foreign_keys = ON;")

  local create_sessions = [[
    CREATE TABLE IF NOT EXISTS sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      is_active BOOLEAN DEFAULT 0,
      metadata TEXT
    )
  ]]

  local create_messages = [[
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      type TEXT NOT NULL,
      content TEXT NOT NULL,
      metadata TEXT,
      tool_call_id TEXT,
      tool_calls TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    )
  ]]

  if db:exec(create_sessions) ~= sqlite.OK or db:exec(create_messages) ~= sqlite.OK then
    vim.notify("Failed to create database tables", vim.log.levels.ERROR)
    return false
  end

  vim.notify("NeoAI: SQLite database initialised at " .. db_path, vim.log.levels.INFO)
  return true
end

function M.create_session(title, metadata)
  title = title or ("Session " .. os.date("%Y-%m-%d %H:%M:%S"))
  metadata = metadata or {}
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  db:exec("UPDATE sessions SET is_active = 0, updated_at = datetime('now')")
  local stmt = db:prepare("INSERT INTO sessions (title, is_active, metadata) VALUES (?, 1, ?)")
  if stmt then
    stmt:bind_values(title, vim.fn.json_encode(metadata))
    local result = stmt:step()
    stmt:finalise()
    if result == sqlite.DONE then
      return db:last_insert_rowid()
    end
  end
  vim.notify("Failed to create session", vim.log.levels.ERROR)
  return nil
end

function M.get_active_session()
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local stmt = db:prepare("SELECT * FROM sessions WHERE is_active = 1 LIMIT 1")
  if stmt then
    if stmt:step() == sqlite.ROW then
      local session = {
        id = stmt:get_value(0),
        title = stmt:get_value(1),
        created_at = stmt:get_value(2),
        updated_at = stmt:get_value(3),
        is_active = stmt:get_value(4) == 1,
        metadata = stmt:get_value(5),
      }
      if session.metadata then
        local ok, decoded = pcall(vim.fn.json_decode, session.metadata)
        session.metadata = ok and decoded or {}
      else
        session.metadata = {}
      end
      stmt:finalise()
      return session
    end
    stmt:finalise()
  end
  return nil
end

function M.switch_session(session_id)
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  db:exec("UPDATE sessions SET is_active = 0, updated_at = datetime('now')")
  local stmt = db:prepare("UPDATE sessions SET is_active = 1, updated_at = datetime('now') WHERE id = ?")
  if stmt then
    stmt:bind_values(session_id)
    local result = stmt:step()
    stmt:finalise()
    if result == sqlite.DONE then
      vim.notify("Switched to session " .. session_id, vim.log.levels.INFO)
      return true
    end
  end
  vim.notify("Failed to switch session", vim.log.levels.ERROR)
  return false
end

function M.get_all_sessions(limit)
  limit = limit or 50
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local sessions = {}
  local stmt = db:prepare("SELECT * FROM sessions ORDER BY updated_at DESC LIMIT ?")
  if stmt then
    stmt:bind_values(limit)
    while stmt:step() == sqlite.ROW do
      local session = {
        id = stmt:get_value(0),
        title = stmt:get_value(1),
        created_at = stmt:get_value(2),
        updated_at = stmt:get_value(3),
        is_active = stmt:get_value(4) == 1,
        metadata = stmt:get_value(5),
      }
      if session.metadata then
        local ok, decoded = pcall(vim.fn.json_decode, session.metadata)
        session.metadata = ok and decoded or {}
      else
        session.metadata = {}
      end
      table.insert(sessions, session)
    end
    stmt:finalise()
  end
  return sessions
end

function M.delete_session(session_id)
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local stmt = db:prepare("DELETE FROM sessions WHERE id = ?")
  if stmt then
    stmt:bind_values(session_id)
    local result = stmt:step()
    stmt:finalise()
    if result == sqlite.DONE then
      vim.notify("Deleted session " .. session_id, vim.log.levels.INFO)
      return true
    end
  end
  vim.notify("Failed to delete session", vim.log.levels.ERROR)
  return false
end

function M.update_session_title(session_id, new_title)
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local stmt = db:prepare("UPDATE sessions SET title = ?, updated_at = datetime('now') WHERE id = ?")
  if stmt then
    stmt:bind_values(new_title, session_id)
    local result = stmt:step()
    stmt:finalise()
    return result == sqlite.DONE
  end
  return false
end

function M.add_message(session_id, type, content, metadata, tool_call_id, tool_calls)
  metadata = metadata or {}
  metadata.timestamp = metadata.timestamp or os.date("%Y-%m-%d %H:%M:%S")
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local stmt = db:prepare([[
    INSERT INTO messages (session_id, type, content, metadata, tool_call_id, tool_calls)
    VALUES (?, ?, ?, ?, ?, ?)
  ]])
  if stmt then
    stmt:bind_values(
      session_id,
      type,
      content,
      vim.fn.json_encode(metadata),
      tool_call_id,
      tool_calls and vim.fn.json_encode(tool_calls) or nil
    )
    local result = stmt:step()
    stmt:finalise()
    if result == sqlite.DONE then
      local update_stmt = db:prepare("UPDATE sessions SET updated_at = datetime('now') WHERE id = ?")
      if update_stmt then
        update_stmt:bind_values(session_id)
        update_stmt:step()
        update_stmt:finalise()
      end
      return db:last_insert_rowid()
    end
  end
  return nil
end

function M.get_session_messages(session_id, limit)
  limit = limit or 1000
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local messages = {}
  local stmt = db:prepare("SELECT * FROM messages WHERE session_id = ? ORDER BY created_at ASC LIMIT ?")
  if stmt then
    stmt:bind_values(session_id, limit)
    while stmt:step() == sqlite.ROW do
      local message = {
        id = stmt:get_value(0),
        session_id = stmt:get_value(1),
        type = stmt:get_value(2),
        content = stmt:get_value(3),
        metadata = stmt:get_value(4),
        tool_call_id = stmt:get_value(5),
        tool_calls = stmt:get_value(6),
        created_at = stmt:get_value(7),
      }
      if message.metadata then
        local ok, decoded = pcall(vim.fn.json_decode, message.metadata)
        message.metadata = ok and decoded or {}
      else
        message.metadata = {}
      end
      if message.tool_calls then
        local ok, decoded = pcall(vim.fn.json_decode, message.tool_calls)
        message.tool_calls = ok and decoded or nil
      end
      table.insert(messages, message)
    end
    stmt:finalise()
  end
  return messages
end

function M.clear_session_messages(session_id)
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local stmt = db:prepare("DELETE FROM messages WHERE session_id = ?")
  if stmt then
    stmt:bind_values(session_id)
    local result = stmt:step()
    stmt:finalise()
    if result == sqlite.DONE then
      vim.notify("Cleared messages from session", vim.log.levels.INFO)
      return true
    end
  end
  vim.notify("Failed to clear session messages", vim.log.levels.ERROR)
  return false
end

function M.get_stats()
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  local session_count, message_count, active_sessions = 0, 0, 0
  local stmt = db:prepare("SELECT COUNT(*) FROM sessions")
  if stmt and stmt:step() == sqlite.ROW then
    session_count = stmt:get_value(0)
    stmt:finalise()
  end
  stmt = db:prepare("SELECT COUNT(*) FROM messages")
  if stmt and stmt:step() == sqlite.ROW then
    message_count = stmt:get_value(0)
    stmt:finalise()
  end
  stmt = db:prepare("SELECT COUNT(*) FROM sessions WHERE is_active = 1")
  if stmt and stmt:step() == sqlite.ROW then
    active_sessions = stmt:get_value(0)
    stmt:finalise()
  end
  return {
    sessions = session_count,
    messages = message_count,
    active_sessions = active_sessions,
    database_path = db_path,
    storage_type = "sqlite",
  }
end

function M.close()
  assert(sqlite and db, "NeoAI: SQLite not initialised")
  db:close()
  db = nil
end

return M
