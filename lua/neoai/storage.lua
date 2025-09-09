local storage = nil --[[@type table?]]
local backend = nil --[[@type string?]]

---Attempts to require a JSON storage backend.
---@return table
local function try_json()
  local ok, json = pcall(require, "neoai.storage_json")
  if ok then
    backend = "json"
    return json
  end
  error("NeoAI: No valid storage backend found (json)")
end

---Extracts the file extension from a path.
---@param path string: The filepath to extract the extension from.
---@return string
local function get_extension(path)
  return path:match("^.+%.([a-zA-Z0-9_]+)$") or ""
end

local M = {}

---Initialise the storage module with a given configuration.
---@param config table: The configuration table.
---@return any
function M.init(config)
  -- Always use the JSON backend. If a .db path is provided, map it to a .json path with the same base name.
  local db_path = config.database_path or (vim.fn.stdpath("data") .. "/neoai.json")
  local ext = get_extension(db_path)
  local json_config = config

  if ext == "db" then
    local json_path = db_path:gsub("%.db$", ".json")
    json_config = vim.tbl_extend("force", config, { database_path = json_path })
  elseif ext ~= "json" then
    -- Use the provided path as JSON. Ensure a sensible default when not provided.
    if not config.database_path then
      json_config = vim.tbl_extend("force", config, { database_path = db_path })
    end
  end

  storage = try_json()
  return storage.init(json_config)
end

---Creates a new storage session.
---@param ... any
---@return any
function M.create_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.create_session(...)
end

---Retrieves the active storage session.
---@param ... any
---@return any
function M.get_active_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_active_session(...)
end

---Switches to a specified session.
---@param ... any
---@return any
function M.switch_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.switch_session(...)
end

---Retrieves all storage sessions.
---@param ... any
---@return any
function M.get_all_sessions(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_all_sessions(...)
end

---Deletes a specified session.
---@param ... any
---@return any
function M.delete_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.delete_session(...)
end

---Updates the title of a session.
---@param ... any
---@return any
function M.update_session_title(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.update_session_title(...)
end

---Adds a message to a session.
---@param ... any
---@return any
function M.add_message(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.add_message(...)
end

---Retrieves messages from a session.
---@param ... any
---@return any
function M.get_session_messages(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_session_messages(...)
end

---Clears messages from a session.
---@param ... any
---@return any
function M.clear_session_messages(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.clear_session_messages(...)
end

---Retrieves statistics from the storage.
---@param ... any
---@return any
function M.get_stats(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_stats(...)
end

---Closes the storage backend.
---@param ... any
---@return any|nil
function M.close(...)
  if storage and storage.close then
    return storage.close(...)
  end
end

---Returns the current storage backend.
---@return string?
function M.get_backend()
  return backend
end

return M
