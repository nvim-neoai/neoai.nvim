local storage = nil
local backend = nil

local function try_sqlite()
  local ok, db = pcall(require, "neoai.database")
  if ok then
    backend = "sqlite"
    return db
  end
  return nil
end

local function try_json()
  local ok, json = pcall(require, "neoai.storage_json")
  if ok then
    backend = "json"
    return json
  end
  error("NeoAI: No valid storage backend found (sqlite or json)")
end

local function get_extension(path)
  return path:match("^.+%.([a-zA-Z0-9_]+)$") or ""
end

local M = {}

function M.init(config)
  local db_path = config.database_path or (vim.fn.stdpath("data") .. "/neoai.db")
  local ext = get_extension(db_path)
  local ok, backend_mod, init_ok
  if ext == "db" then
    ok, backend_mod = pcall(require, "neoai.database")
    if ok then
      local success = pcall(backend_mod.init, config)
      if success then
        backend = "sqlite"
        storage = backend_mod
        return true
      end
    end
    -- fallback to json with same base name
    local json_path = db_path:gsub("%.db$", ".json")
    local json_config = vim.tbl_extend("force", config, { database_path = json_path })
    storage = try_json()
    return storage.init(json_config)
  elseif ext == "json" then
    storage = try_json()
    return storage.init(config)
  else
    ok, backend_mod = pcall(require, "neoai.database")
    if ok then
      local success = pcall(backend_mod.init, config)
      if success then
        backend = "sqlite"
        storage = backend_mod
        return true
      end
    end
    storage = try_json()
    return storage.init(config)
  end
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
