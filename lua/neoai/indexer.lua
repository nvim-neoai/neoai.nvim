local M = {}

local uv = vim.loop
local json_encode = vim.fn.json_encode
local json_decode = vim.fn.json_decode
local config = require("neoai.config")

-- Open JSON store
local function open_store(path)
  local store = { chunks = {} }
  local f = io.open(path, "r")
  if f then
    local ok, dec = pcall(json_decode, f:read("*a"))
    if ok and dec and dec.chunks then
      store = dec
    end
    f:close()
  end
  return { path = path, data = store }
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
    local req = uv.fs_scandir(dir)
    if not req then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(req)
      if not name then
        break
      end
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
  if not f then
    return {}
  end
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
local function embed(text)
  local api_conf = config.get().api
  local url = api_conf.embedding_url
  local model = api_conf.embedding_model
  local header_field = api_conf.embedding_api_key_header
  local api_key = api_conf.embedding_api_key
  local key_header = string.format("%s: %s", header_field, string.format(api_conf.embedding_api_key_format, api_key))
  local payload = { model = model, input = text }
  local body = json_encode(payload)
  local cmd = string.format(
    "curl -s %s " .. "-H 'Content-Type: application/json' " .. "-H '%s' " .. "-d '%s'",
    url,
    key_header,
    body
  )
  local res = vim.fn.system(cmd)
  local ok, dec = pcall(json_decode, res)
  return ok and dec and dec.data and dec.data[1] and dec.data[1].embedding or nil
end

-- Build index: JSON only
function M.build_index(opts)
  opts = vim.tbl_deep_extend("force", {
    root = uv.cwd(),
    exts = { "lua", "js", "ts", "py", "go", "java" },
    db_path = uv.cwd() .. "/.neoai_index.db",
    chunk_size = 2000,
  }, opts or {})

  local api_conf = config.get().api
  local api_key = api_conf.embedding_api_key
  if not api_key or api_key == "" or api_key == "<your api key>" then
    error("Embedding API key not set")
  end

  local store_path = opts.db_path:gsub("%.db$", ".json")
  local store = open_store(store_path)

  local files = collect_files(opts.root, opts.exts)
  for _, file in ipairs(files) do
    local chunks = read_chunks(file, opts.chunk_size)
    for idx, chunk in ipairs(chunks) do
      local vec = embed(chunk)
      if vec then
        table.insert(store.data.chunks, { file = file, idx = idx, content = chunk, vector = vec })
      end
    end
  end

  save_json(store)
  print("✅ Indexed " .. #files .. " files into JSON store")
end

-- Query index
function M.query_index(query, opts)
  opts = vim.tbl_deep_extend("force", {
    db_path = uv.cwd() .. "/.neoai_index.db",
  }, opts or {})

  local api_conf = config.get().api
  local api_key = api_conf.embedding_api_key
  if not api_key or api_key == "" or api_key == "<your api key>" then
    error("Embedding API key not set")
  end

  local qvec = embed(query)
  if not qvec then
    return {}
  end

  local store_path = opts.db_path:gsub("%.db$", ".json")
  local f = io.open(store_path, "r")
  if not f then
    return {}
  end
  local store = json_decode(f:read("*a")) or {}
  f:close()
  local chunks = store.chunks or {}

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
    results[#results + 1] = { score = score, file = item.file, idx = item.idx, content = item.content }
  end
  table.sort(results, function(a, b)
    return a.score > b.score
  end)

  return vim.list_slice(results, 1, 5)
end

return M
