local M = {}

local uv = vim.loop
local json_encode = vim.fn.json_encode

local json_decode = vim.fn.json_decode
local config = require("neoai.config")

-- Try to load lua sqlite3 module
local has_sqlite, sqlite3 = pcall(require, "sqlite3")

-- Open a SQLite DB or fallback to JSON file store
local function open_store(path)
  if has_sqlite then
    local db = sqlite3.open(path)
    db:exec([[
      CREATE TABLE IF NOT EXISTS code_chunks (
        id INTEGER PRIMARY KEY,
        file TEXT,
        chunk_idx INTEGER,
        content TEXT,
        vector_json TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_file ON code_chunks(file);
    ]])
    return { kind = "sqlite", db = db }
  else
    -- JSON fallback: path should end with .json
    local store = { chunks = {} }
    -- load existing
    local f = io.open(path, "r")
    if f then
      local ok, dec = pcall(json_decode, f:read("*a"))
      if ok and dec and dec.chunks then store = dec end
      f:close()
    end
    return { kind = "json", path = path, data = store }
  end
end

-- Save JSON store to disk
local function save_json(store)
  local f = io.open(store.path, "w")
  if f then
    f:write(json_encode(store.data))
    f:close()
  end
end

-- Collect files by extension
local function collect_files(root, exts)
  local result = {}
  local function walk(dir)
        local req, err = uv.fs_scandir(dir)
    if not req then return end
    while true do
      local name, typ = uv.fs_scandir_next(req)
      if not name then break end
      local full = dir .. "/" .. name
      if typ == "file" then
        for _, ext in ipairs(exts) do
          if name:match("%..*" .. ext .. "$") then
            table.insert(result, full)
            break
          end
        end
      elseif typ == "directory" then
        walk(full)
      end
    end
  end
  walk(root)
  return result
end

-- Read and split file into chunks
local function read_chunks(filepath, max_chars)
  max_chars = max_chars or 2000
  local f = io.open(filepath, "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()

  local chunks = {}
  local start = 1
  while start <= #text do
    local chunk = text:sub(start, start + max_chars - 1)
    table.insert(chunks, chunk)
    start = start + max_chars
  end
  return chunks
end

-- Call OpenAI Embeddings API
local function embed(text, api_key)
  local payload = { model = "text-embedding-ada-002", input = text }
  local body = json_encode(payload)
  local cmd = string.format(
    "curl -s https://api.openai.com/v1/embeddings " ..
    "-H 'Content-Type: application/json' " ..
    "-H 'Authorization: Bearer %s' " ..
    "-d '%s'", api_key, body
  )
  local res = vim.fn.system(cmd)
  local ok, dec = pcall(json_decode, res)
  return ok and dec and dec.data and dec.data[1] and dec.data[1].embedding or nil
end

-- Build index: either SQLite or JSON
function M.build_index(opts)
  opts = vim.tbl_deep_extend("force", {
    root = uv.cwd(),
    exts = { "lua", "js", "ts", "py", "go", "java" },
    db_path = uv.cwd() .. "/.neoai_index.db",
    api_key = config.get().api.api_key,
    chunk_size = 2000,
  }, opts or {})

  if not opts.api_key or opts.api_key == "" then
    error("API key not set")
  end

  -- Determine storage mode
  local store_path = opts.db_path
  if not has_sqlite then
    store_path = store_path:gsub("%.db$", ".json")
    vim.notify("[neoai] sqlite3 module not found, using JSON store at " .. store_path, vim.log.levels.WARN)
  end
  local store = open_store(store_path)

  local files = collect_files(opts.root, opts.exts)
  for _, file in ipairs(files) do
    local chunks = read_chunks(file, opts.chunk_size)
    for idx, chunk in ipairs(chunks) do
      local vec = embed(chunk, opts.api_key)
      if vec then
        if store.kind == "sqlite" then
          local stmt = store.db:prepare([[
            INSERT INTO code_chunks (file, chunk_idx, content, vector_json)
            VALUES (?, ?, ?, ?);
          ]])
          stmt:bind_values(file, idx, chunk, json_encode(vec))
          stmt:step()
          stmt:finalize()
        else
          table.insert(store.data.chunks, { file = file, idx = idx, content = chunk, vector = vec })
        end
      end
    end
  end

  if store.kind == "sqlite" then
    store.db:close()
    print("✅ Indexed " .. #files .. " files into SQLite DB")
  else
    save_json(store)
    print("✅ Indexed " .. #files .. " files into JSON store")
  end
end

-- Query index
function M.query_index(query, opts)
  opts = vim.tbl_deep_extend("force", {
    db_path = uv.cwd() .. "/.neoai_index.db",
    api_key = config.get().api.api_key,
  }, opts or {})

  if not opts.api_key or opts.api_key == "" then
    error("API key not set")
  end

  local qvec = embed(query, opts.api_key)
  if not qvec then return {} end

  -- Load store
  local store_path = opts.db_path
  if not has_sqlite then store_path = store_path:gsub("%.db$", ".json") end

  local chunks = {}
  if has_sqlite then
    local db = sqlite3.open(store_path)
    for row in db:nrows("SELECT file, chunk_idx AS idx, content, vector_json FROM code_chunks") do
      chunks[#chunks+1] = { file = row.file, idx = row.idx, content = row.content, vector = json_decode(row.vector_json) }
    end
    db:close()
  else
    -- JSON load
    local f = io.open(store_path, "r")
    if not f then return {} end
    local store = json_decode(f:read("*a"))
    f:close()
    chunks = store.chunks or {}
  end

  -- Compute similarities
  local results = {}
  for _, item in ipairs(chunks) do
    local vec = item.vector
    local dot, mq, mc = 0, 0, 0
    for i = 1, #qvec do
      dot = dot + qvec[i] * vec[i]
      mq = mq + qvec[i] * qvec[i]
      mc = mc + vec[i] * vec[i]
    end
    local score = dot / (math.sqrt(mq) * math.sqrt(mc) + 1e-12)
    results[#results+1] = { score = score, file = item.file, idx = item.idx, content = item.content }
  end
  table.sort(results, function(a, b) return a.score > b.score end)

  return vim.list_slice(results, 1, 5)
end

return M