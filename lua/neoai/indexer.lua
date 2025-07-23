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

-- Collect files by extension, honoring .gitignore and default ignores
local function collect_files(root, exts)
  local result = {}

  -- 1) Build ignore set (defaults)
  local ignore = {
    [".git"] = true,
    ["node_modules"] = true,
    [".venv"] = true,
    ["venv"] = true,
    ["myenv"] = true,
    ["pyenv"] = true,
  }

  -- 2) Merge in .gitignore from <root>/.gitignore
  local gitignore_file = root .. "/.gitignore"
  if uv.fs_stat(gitignore_file) then
    for _, line in ipairs(vim.fn.readfile(gitignore_file)) do
      line = line:match("^s*(.-)s*$")
      if line ~= "" and not line:match("^#") then
        if line:sub(-1) == "/" then
          line = line:sub(1, -2)
        end
        ignore[line] = true
      end
    end
  end

  -- 3) Recurse, skipping ignores
  local function walk(dir)
    local req = uv.fs_scandir(dir)
    if not req then return end
    while true do
      local name, typ = uv.fs_scandir_next(req)
      if not name then break end

      if not ignore[name] then
        local full = dir .. "/" .. name
        if typ == "file" then
          for _, ext in ipairs(exts) do
            if name:lower():match("%." .. ext:lower() .. "$") then
              table.insert(result, full)
              break
            end
          end
        elseif typ == "directory" then
          walk(full)
        end
      end
    end
  end

  walk(root)
  return result
end

-- Split text into chunks preserving sentence and paragraph boundaries
local function split_text(text, max_chars)
  max_chars = max_chars or 2000
  local paragraphs = vim.split(text, "\n\n")
  local segments = {}

  -- Helper: split a paragraph into segments
  local function split_para(para)
    if #para <= max_chars then
      table.insert(segments, para)
    else
      -- Split into sentences
      for sentence in para:gmatch("([^%.%!%?]+[%.%!%?])") do
        if #sentence <= max_chars then
          table.insert(segments, sentence)
        else
          -- Fallback: hard split
          local start = 1
          while start <= #sentence do
            table.insert(segments, sentence:sub(start, start + max_chars - 1))
            start = start + max_chars
          end
        end
      end
    end
  end

  for _, para in ipairs(paragraphs) do
    split_para(para)
  end

  -- Merge segments into chunks up to max_chars
  local chunks = {}
  local current = ""
  for _, seg in ipairs(segments) do
    if current == "" then
      current = seg
    elseif #current + #seg + 1 <= max_chars then
      current = current .. "\n" .. seg
    else
      table.insert(chunks, current)
      current = seg
    end
  end
  if #current > 0 then
    table.insert(chunks, current)
  end

  return chunks
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
  return split_text(text, max_chars)
end

-- Escape shell argument safely
local function escape_shell_arg(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
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
    "curl -s %s -H 'Content-Type: application/json' -H '%s' -d %s",
    url,
    key_header,
    escape_shell_arg(body)
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
        table.insert(store.data.chunks, {
          file = file,
          idx = idx,
          content = chunk,
          vector = vec,
        })
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
    table.insert(results, {
      score = score,
      file = item.file,
      idx = item.idx,
      content = item.content,
    })
  end

  table.sort(results, function(a, b)
    return a.score > b.score
  end)

  return vim.list_slice(results, 1, 5)
end

return M
