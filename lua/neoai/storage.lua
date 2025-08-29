local storage = nil
local backend = nil

local function try_json()
  local ok, json = pcall(require, "neoai.storage_json")
  if ok then
    backend = "json"
    return json
  end
  error("NeoAI: No valid storage backend found (json)")
end

local function get_extension(path)
  return path:match("^.+%.([a-zA-Z0-9_]+)$") or ""
end

local M = {}

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

function M.create_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.create_session(...)
end

function M.get_active_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_active_session(...)
end

function M.switch_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.switch_session(...)
end

function M.get_all_sessions(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_all_sessions(...)
end

function M.delete_session(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.delete_session(...)
end

function M.update_session_title(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.update_session_title(...)
end

function M.add_message(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.add_message(...)
end

function M.get_session_messages(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_session_messages(...)
end

function M.clear_session_messages(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.clear_session_messages(...)
end

function M.get_stats(...)
  assert(storage, "NeoAI: No valid storage backend found")
  return storage.get_stats(...)
end

function M.close(...)
  if storage and storage.close then
    return storage.close(...)
  end
end

function M.get_backend()
  return backend
end

return M
