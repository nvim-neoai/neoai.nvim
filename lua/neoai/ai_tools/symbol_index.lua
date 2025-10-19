local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "SymbolIndex",
  description = utils.read_description("symbol_index"),
  parameters = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Root path to scan. Defaults to current working directory.",
      },
      files = {
        type = "array",
        items = { type = "string" },
        description = "Optional explicit list of files to scan (relative to cwd). Overrides path/globs when present.",
      },
      globs = {
        type = "array",
        items = { type = "string" },
        description = "Ripgrep -g patterns to include (e.g. ['**/*.lua','**/*.py']).",
      },
      languages = {
        type = "array",
        items = { type = "string" },
        description = "Only index these languages (e.g. ['lua','python']).",
      },
      include_docstrings = {
        type = "boolean",
        description = "Include docstrings/comments when available (default true).",
      },
      include_ranges = {
        type = "boolean",
        description = "Include 1-based line/col ranges (default true).",
      },
      include_signatures = {
        type = "boolean",
        description = "Include basic signatures when available (default true).",
      },
      max_files = {
        type = "number",
        description = "Maximum files to process (default 50).",
      },
      max_symbols_per_file = {
        type = "number",
        description = "Maximum symbols to collect per file (default 200).",
      },
      fallback_to_text = {
        type = "boolean",
        description = "Fallback to textual heuristics if Tree-sitter fails (default true).",
      },
    },
    required = {},
    additionalProperties = false,
  },
}

-- Helpers (duplicated in a small form from treesitter_query for encapsulation)
local function get_bufnr_for_path(file_path)
  if file_path and #file_path > 0 then
    local bufnr = vim.fn.bufnr(file_path, true)
    vim.fn.bufload(bufnr)
    return bufnr
  else
    return vim.api.nvim_get_current_buf()
  end
end

local function detect_lang(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft and ft ~= "" then
    return ft
  end
  local ok_ns, parsers = pcall(require, "nvim-treesitter.parsers")
  if ok_ns then
    local lang = parsers.get_buf_lang(bufnr)
    if lang and lang ~= "" then
      return lang
    end
  end
  return nil
end

local function get_parser(bufnr, lang)
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return nil, "Tree-sitter not available (require 'vim.treesitter' failed)"
  end
  local ok_np, ts_parsers = pcall(require, "nvim-treesitter.parsers")
  if ok_np and ts_parsers then
    local resolved = lang or ts_parsers.get_buf_lang(bufnr)
    if not resolved or resolved == "" then
      return nil, "Unable to determine language for buffer"
    end
    local ok_get, parser = pcall(ts.get_parser, bufnr, resolved)
    if ok_get and parser then
      return parser, nil
    else
      return nil, "Failed to get parser for language '" .. tostring(resolved) .. "'"
    end
  end
  if not lang then
    return nil, "Language not specified and nvim-treesitter not installed"
  end
  local ok_get, parser = pcall(ts.get_parser, bufnr, lang)
  if ok_get and parser then
    return parser, nil
  else
    return nil, "Failed to get parser for language '" .. tostring(lang) .. "'"
  end
end

local function node_text(node, bufnr)
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return nil
  end
  if node == nil or not node.range then
    return nil
  end
  local ok2, text = pcall(ts.get_node_text, node, bufnr)
  if ok2 then
    return text
  end
  local sr, sc, er, ec = node:range()
  local lines = vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {})
  return table.concat(lines, "\n")
end

local function make_range(node)
  if not node or not node.range then
    return nil
  end
  local sr, sc, er, ec = node:range()
  return { start_line = sr + 1, start_col = sc + 1, end_line = er + 1, end_col = ec + 1 }
end

local function parse_query_for_lang(lang, query)
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return nil, "Tree-sitter not available"
  end
  if ts.query and ts.query.parse then
    local okp, q = pcall(ts.query.parse, lang, query)
    if okp then
      return q
    end
    return nil, q
  elseif ts.parse_query then
    local okp, q = pcall(ts.parse_query, lang, query)
    if okp then
      return q
    end
    return nil, q
  end
  return nil, "No query.parse or parse_query available"
end

-- Try to load a runtime query from queries/<lang>/symbol_index.scm
local function get_runtime_query(lang)
  local ok, ts = pcall(require, "vim.treesitter")
  if not ok then
    return nil
  end
  -- Neovim 0.10+
  if ts.query and ts.query.get then
    local okq, q = pcall(ts.query.get, lang, "symbol_index")
    if okq then
      return q
    end
  end
  -- Older API
  local okrq, ts_query = pcall(require, "vim.treesitter.query")
  if okrq and ts_query and ts_query.get_query then
    local okq, q = pcall(ts_query.get_query, lang, "symbol_index")
    if okq then
      return q
    end
  end
  return nil
end

-- Language mappings and queries
local ext2lang = {
  lua = "lua",
  py = "python",
  js = "javascript",
  jsx = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  ts = "typescript",
  tsx = "tsx",
  go = "go",
  rs = "rust",
  java = "java",
}

local builtin_queries = {
  python = [[
    (function_definition
      name: (identifier) @name
      parameters: (parameters) @params
    ) @func

    (class_definition
      name: (identifier) @name
    ) @class
  ]],
  javascript = [[
    (function_declaration
      name: (identifier) @name
      parameters: (formal_parameters) @params
    ) @func

    (method_definition
      name: (property_identifier) @name
      parameters: (formal_parameters) @params
    ) @method

    (class_declaration
      name: (identifier) @name
    ) @class
  ]],
  java = [[
    (class_declaration
      name: (identifier) @name
    ) @class

    (interface_declaration
      name: (identifier) @name
    ) @class

    (method_declaration
      name: (identifier) @name
      parameters: (formal_parameters) @params
    ) @method
  ]],
  typescript = [[
    (function_declaration
      name: (identifier) @name
      parameters: (formal_parameters) @params
    ) @func

    (method_definition
      name: (property_identifier) @name
      parameters: (formal_parameters) @params
    ) @method

    (class_declaration
      name: (identifier) @name
    ) @class
  ]],
  tsx = [[
    (function_declaration
      name: (identifier) @name
      parameters: (formal_parameters) @params
    ) @func

    (method_definition
      name: (property_identifier) @name
      parameters: (formal_parameters) @params
    ) @method

    (class_declaration
      name: (identifier) @name
    ) @class
  ]],
  lua = [[
    (function_declaration
      name: (function_name) @name
      parameters: (parameters) @params
    ) @func

    (local_function
      name: (identifier) @name
      parameters: (parameters) @params
    ) @func
  ]],
  go = [[
    (function_declaration
      name: (identifier) @name
      parameters: (parameter_list) @params
    ) @func

    (method_declaration
      name: (field_identifier) @name
      parameters: (parameter_list) @params
    ) @method
  ]],
  rust = [[
    (function_item
      name: (identifier) @name
      parameters: (parameters) @params
    ) @func
  ]],
}

local function file_extension(path)
  return path:match("%.([%w_]+)$")
end

local function get_language_for_file(path, bufnr)
  local lang = detect_lang(bufnr)
  if lang and lang ~= "" then
    return lang
  end
  local ext = file_extension(path or "")
  return ext and ext2lang[ext] or nil
end

local function buf_total_lines(bufnr)
  return vim.api.nvim_buf_line_count(bufnr)
end

-- Extract contiguous leading comment block directly above a node start
local function leading_comment_block(bufnr, start_line_1, lang)
  local max_scan = 20
  local i = start_line_1 - 1 -- 1-based => previous line index
  local lines = {}
  local seen_any = false

  local function get_line(idx)
    if idx < 1 then
      return nil
    end
    if idx > buf_total_lines(bufnr) then
      return nil
    end
    local l = vim.api.nvim_buf_get_lines(bufnr, idx - 1, idx, false)[1]
    return l
  end

  local function is_line_comment(s)
    if not s then
      return false
    end
    local t = s:match("^%s*(.-)%s*$")
    if t == "" then
      return false
    end
    if lang == "lua" then
      return t:match("^%-%-+") ~= nil
    elseif lang == "javascript" or lang == "typescript" or lang == "tsx" or lang == "java" or lang == "go" then
      return t:match("^//+") ~= nil or t:match("^%* *") ~= nil
    elseif lang == "rust" then
      return t:match("^///") ~= nil or t:match("^//!") ~= nil
    else
      return false
    end
  end

  local function ends_with_block_end(s)
    return s and s:match("%*/%s*$") ~= nil
  end
  local function starts_with_block_start(s)
    return s and s:match("^%s*/%*+%**") ~= nil
  end

  local in_block = false
  local block_collected = {}

  local steps = 0
  while i >= 1 and steps < max_scan do
    steps = steps + 1
    local l = get_line(i)
    if not l then
      break
    end
    local trimmed = l:match("^%s*(.-)%s*$")

    if in_block then
      table.insert(block_collected, 1, l)
      if starts_with_block_start(l) then
        for _, bl in ipairs(block_collected) do
          table.insert(lines, 1, bl)
        end
        break
      end
      i = i - 1
    else
      if
        (lang == "javascript" or lang == "typescript" or lang == "tsx" or lang == "java" or lang == "go")
        and ends_with_block_end(l)
      then
        in_block = true
        block_collected = { l }
        i = i - 1
      elseif is_line_comment(trimmed) then
        table.insert(lines, 1, l)
        seen_any = true
        i = i - 1
      else
        if trimmed == "" and not seen_any then
          i = i - 1
        else
          break
        end
      end
    end
  end

  if #lines == 0 then
    return nil
  end
  local cleaned = {}
  for _, l in ipairs(lines) do
    local c = l
    if lang == "lua" then
      c = c:gsub("^%s*%-%-+%s?", "")
    elseif lang == "javascript" or lang == "typescript" or lang == "tsx" or lang == "java" or lang == "go" then
      c = c:gsub("^%s*//+%s?", "")
      c = c:gsub("^%s*/%*%*?%s?", "")
      c = c:gsub("%s*%*/%s*$", "")
      c = c:gsub("^%s*%*%s?", "")
    elseif lang == "rust" then
      c = c:gsub("^%s*///%s?", "")
      c = c:gsub("^%s*//!%s?", "")
      c = c:gsub("^%s*/%*%*?%s?", "")
      c = c:gsub("%s*%*/%s*$", "")
      c = c:gsub("^%s*%*%s?", "")
    end
    table.insert(cleaned, c)
  end
  return table.concat(cleaned, "\n")
end

-- Python docstring: first statement in body as a string
local function python_docstring(func_or_class_node, bufnr)
  if not func_or_class_node or not func_or_class_node.child_by_field_name then
    return nil
  end
  local body = func_or_class_node:child_by_field_name("body")
  if not body then
    return nil
  end
  -- find first named child in the body
  local n = body:named_child_count() or 0
  if n == 0 then
    return nil
  end
  local first = body:named_child(0)
  if not first then
    return nil
  end
  if first:type() ~= "expression_statement" then
    return nil
  end
  local inner = first:named_child(0) or first:child(0)
  if not inner then
    return nil
  end
  if inner:type() ~= "string" then
    return nil
  end
  return node_text(inner, bufnr)
end

local function trim(s)
  return (s or ""):gsub("^%s*(.-)%s*$", "%1")
end

-- Basic textual fallback for function defs (heuristic)
local function fallback_scan(bufnr, lang, max_symbols)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}
  local patterns = {}
  if lang == "lua" then
    patterns = {
      { kind = "function", pat = "^%s*local%s+function%s+([%w_%.:]+)%s*%((.-)%)" },
      { kind = "function", pat = "^%s*function%s+([%w_%.:]+)%s*%((.-)%)" },
    }
  elseif lang == "python" then
    patterns = {
      { kind = "function", pat = "^%s*def%s+([A-Za-z_][%w_]*)%s*%((.-)%)" },
      { kind = "class", pat = "^%s*class%s+([A-Za-z_][%w_]*)%s*%b()?:" },
    }
  elseif lang == "javascript" or lang == "typescript" or lang == "tsx" then
    patterns = {
      { kind = "function", pat = "^%s*function%s+([A-Za-z_$][%w_$]*)%s*%((.-)%)" },
      { kind = "class", pat = "^%s*class%s+([A-Za-z_$][%w_$]*)%s*[%{%w]" },
    }
  elseif lang == "go" then
    patterns = {
      { kind = "function", pat = "^%s*func%s+([A-Za-z_][%w_]*)%s*%((.-)%)" },
    }
  elseif lang == "rust" then
    patterns = {
      { kind = "function", pat = "^%s*fn%s+([A-Za-z_][%w_]*)%s*%((.-)%)" },
    }
  end
  for i, l in ipairs(lines) do
    for _, pp in ipairs(patterns) do
      local name, params = l:match(pp.pat)
      if name then
        local item = {
          kind = pp.kind,
          name = name,
          line = i,
        }
        if params and params ~= "" then
          item.params = params
        end
        table.insert(items, item)
        if #items >= (max_symbols or 200) then
          return items
        end
        break
      end
    end
  end
  return items
end

local function extract_symbols_for_file(file_path, args)
  local bufnr = get_bufnr_for_path(file_path)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return { file = file_path, error = "Failed to load buffer" }
  end

  local lang = get_language_for_file(file_path, bufnr) or ""
  local include_doc = args.include_docstrings ~= false
  local include_ranges = args.include_ranges ~= false
  local include_sigs = args.include_signatures ~= false
  local max_per_file = args.max_symbols_per_file or 200

  local parser, perr = get_parser(bufnr, lang)
  local symbols = {}

  local function push(kind, name_node, params_node, def_node)
    if not name_node or not def_node then
      return
    end
    local name = trim(node_text(name_node, bufnr) or "")
    if name == "" then
      return
    end
    local item = {
      kind = kind,
      name = name,
    }
    if include_sigs and params_node then
      local ptxt = trim(node_text(params_node, bufnr) or "")
      if ptxt ~= "" then
        item.signature = name .. ptxt
        item.params = ptxt
      end
    end
    if include_ranges then
      item.range = make_range(def_node)
      if item.range then
        item.line = item.range.start_line
      end
    end

    if include_doc then
      local doc
      if lang == "python" then
        doc = python_docstring(def_node, bufnr)
      else
        local start_line = (item.range and item.range.start_line) or 1
        doc = leading_comment_block(bufnr, start_line, lang)
      end
      if doc and doc ~= "" then
        if #doc > 800 then
          doc = doc:sub(1, 800) .. " …"
        end
        item.doc = doc
      end
    end

    table.insert(symbols, item)
  end

  local tsq = nil
  local used_any = false
  if parser then
    -- 1) Prefer runtime symbol_index query if present
    local tsq_sym = get_runtime_query(lang)
    if tsq_sym then
      local tree = parser:parse() and parser:parse()[1]
      local root = tree and tree:root()
      if root then
        for _, match in (tsq_sym.iter_matches and tsq_sym:iter_matches(root, bufnr, 0, -1)) or {} do
          local cap = {}
          for id, node in pairs(match) do
            local cname = tsq_sym.captures[id]
            cap[cname] = node
          end
          if cap["func"] and cap["name"] then
            push("function", cap["name"], cap["params"], cap["func"])
          elseif cap["method"] and cap["name"] then
            push("method", cap["name"], cap["params"], cap["method"])
          elseif cap["class"] and cap["name"] then
            push("class", cap["name"], nil, cap["class"])
          end
          if #symbols >= max_per_file then break end
        end
        used_any = used_any or #symbols > 0
      end
    end

    -- 2) Fall back to textobjects (common across many languages if installed)
    if #symbols < max_per_file then
      local function get_query_for_group(lang2, group)
        local ok, ts = pcall(require, "vim.treesitter")
        if not ok then return nil end
        if ts.query and ts.query.get then
          local okq, q = pcall(ts.query.get, lang2, group)
          if okq then return q end
        end
        local okrq, ts_query = pcall(require, "vim.treesitter.query")
        if okrq and ts_query and ts_query.get_query then
          local okq, q = pcall(ts_query.get_query, lang2, group)
          if okq then return q end
        end
        return nil
      end

      local tsq_to = get_query_for_group(lang, "textobjects")
      if tsq_to then
        local function find_name_node(def_node)
          if def_node and def_node.child_by_field_name then
            local nn = def_node:child_by_field_name("name")
            if nn then return nn end
          end
          local wanted = {
            identifier = true,
            function_name = true,
            field_identifier = true,
            property_identifier = true,
          }
          local function walk(n, depth)
            if not n or depth > 3 then return nil end
            if wanted[n:type()] then return n end
            local count = n:named_child_count() or 0
            for i = 0, count - 1 do
              local found = walk(n:named_child(i), depth + 1)
              if found then return found end
            end
            return nil
          end
          return walk(def_node, 0)
        end

        local tree = parser:parse() and parser:parse()[1]
        local root = tree and tree:root()
        if root then
          for _, match in (tsq_to.iter_matches and tsq_to:iter_matches(root, bufnr, 0, -1)) or {} do
            for id, node in pairs(match) do
              local cname = tsq_to.captures[id] or ""
              local kind
              if cname:find("function") then kind = "function" end
              if not kind and cname:find("method") then kind = "method" end
              if not kind and cname:find("class") then kind = "class" end
              if kind then
                local name_node = find_name_node(node)
                if name_node then
                  push(kind, name_node, nil, node)
                end
              end
              if #symbols >= max_per_file then break end
            end
            if #symbols >= max_per_file then break end
          end
          used_any = used_any or #symbols > 0
        end
      end
    end

    -- 3) Fall back to locals (definition.* captures provided by many languages)
    if #symbols < max_per_file then
      local function get_query_for_group(lang2, group)
        local ok, ts = pcall(require, "vim.treesitter")
        if not ok then return nil end
        if ts.query and ts.query.get then
          local okq, q = pcall(ts.query.get, lang2, group)
          if okq then return q end
        end
        local okrq, ts_query = pcall(require, "vim.treesitter.query")
        if okrq and ts_query and ts_query.get_query then
          local okq, q = pcall(ts_query.get_query, lang2, group)
          if okq then return q end
        end
        return nil
      end

      local tsq_loc = get_query_for_group(lang, "locals")
      if tsq_loc then
        local function ascend_to_container(n)
          local want = {
            function_declaration = true,
            function_definition = true,
            local_function = true,
            method_declaration = true,
            function_item = true,
            constructor_declaration = true,
            class_declaration = true,
            class_definition = true,
            interface_declaration = true,
          }
          local steps = 0
          while n and steps < 6 do
            if want[n:type()] then return n end
            n = n:parent()
            steps = steps + 1
          end
          return nil
        end

        local tree = parser:parse() and parser:parse()[1]
        local root = tree and tree:root()
        if root then
          for _, match in (tsq_loc.iter_matches and tsq_loc:iter_matches(root, bufnr, 0, -1)) or {} do
            for id, node in pairs(match) do
              local cname = tsq_loc.captures[id] or ""
              local kind
              if cname:find("definition%.function") then kind = "function" end
              if not kind and cname:find("definition%.method") then kind = "method" end
              if not kind and (cname:find("definition%.class") or cname:find("definition%.interface")) then kind = "class" end
              if not kind and cname:find("definition%.constructor") then kind = "method" end
              if kind then
                local def = ascend_to_container(node) or node
                push(kind, node, nil, def)
              end
              if #symbols >= max_per_file then break end
            end
            if #symbols >= max_per_file then break end
          end
          used_any = used_any or #symbols > 0
        end
      end
    end

    -- 4) Built-in queries as a final Tree-sitter-based fallback
    if not used_any and builtin_queries[lang] then
      local tsq_builtin = select(1, parse_query_for_lang(lang, builtin_queries[lang]))
      if tsq_builtin then
        local tree = parser:parse() and parser:parse()[1]
        local root = tree and tree:root()
        if root then
          for _, match in (tsq_builtin.iter_matches and tsq_builtin:iter_matches(root, bufnr, 0, -1)) or {} do
            local cap = {}
            for id, node in pairs(match) do
              local cname = tsq_builtin.captures[id]
              cap[cname] = node
            end
            if cap["func"] and cap["name"] then
              push("function", cap["name"], cap["params"], cap["func"])
            elseif cap["method"] and cap["name"] then
              push("method", cap["name"], cap["params"], cap["method"])
            elseif cap["class"] and cap["name"] then
              push("class", cap["name"], nil, cap["class"])
            end
            if #symbols >= max_per_file then break end
          end
        end
      end
    end
  end
    end
  end

  if (#symbols == 0) and (args.fallback_to_text ~= false) then
    symbols = fallback_scan(bufnr, lang, max_per_file)
    if include_doc and #symbols > 0 then
      for _, it in ipairs(symbols) do
        local start_line = it.line or 1
        local doc = leading_comment_block(bufnr, start_line, lang)
        if doc and doc ~= "" then
          if #doc > 800 then
            doc = doc:sub(1, 800) .. " …"
          end
          it.doc = doc
        end
      end
    end
  end

  return { file = file_path, language = lang, symbols = symbols, error = (not parser and perr or nil) }
end

local function gather_files(args)
  if type(args.files) == "table" and #args.files > 0 then
    return args.files
  end
  local path = args.path
  if type(path) ~= "string" or trim(path) == "" then
    path = "."
  else
    path = vim.fn.expand(path)
  end
  local cmd = { "rg", "--files", path }
  if type(args.globs) == "table" then
    for _, g in ipairs(args.globs) do
      if type(g) == "string" and g ~= "" then
        table.insert(cmd, "-g")
        table.insert(cmd, g)
      end
    end
  end
  local result = vim.system(cmd, { cwd = vim.fn.getcwd(), text = true }):wait()
  if result.code > 1 then
    return nil, "Error running rg: " .. (result.stderr or "unknown error")
  end
  local files = vim.split(result.stdout or "", "\n", { trimempty = true })
  return files
end

M.run = function(args)
  args = args or {}
  local include_langs = {}
  if type(args.languages) == "table" and #args.languages > 0 then
    for _, l in ipairs(args.languages) do
      include_langs[l] = true
    end
  end

  local files, ferr = gather_files(args)
  if ferr then
    return "SymbolIndex: " .. ferr
  end
  if not files or #files == 0 then
    return "SymbolIndex: No files to process"
  end

  local max_files = args.max_files or 50
  local results = {}
  local fcount, scount = 0, 0

  for _, f in ipairs(files) do
    if fcount >= max_files then
      break
    end
    for _, f in ipairs(files) do
      if fcount >= max_files then break end
      local res = extract_symbols_for_file(f, args)
      if res and type(res) == "table" then
        local lang_ok = true
        if next(include_langs) then
          lang_ok = res.language and include_langs[res.language] or false
        end
        if lang_ok then
          table.insert(results, res)
          fcount = fcount + 1
          if type(res.symbols) == "table" then scount = scount + #res.symbols end
        end
      end
    end

        if type(res.symbols) == "table" then
          scount = scount + #res.symbols
        end
      end
    end
  end

  local payload = { files = results, summary = { files = fcount, symbols = scount } }
  local okj, json = pcall(vim.fn.json_encode, payload)
  local content
  if okj then
    content = utils.make_code_block(json, "json")
  else
    -- Fallback plain text
    local lines = { "SymbolIndex results:" }
    for _, f in ipairs(results) do
      table.insert(lines, string.format("- %s (%s): %d symbols", f.file, f.language or "?", #(f.symbols or {})))
    end
    content = utils.make_code_block(table.concat(lines, "\n"), "txt")
  end

  local display = string.format("SymbolIndex: %d files, %d symbols", fcount, scount)
  return { content = content, display = display }
end

return M
