local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "ProjectStructure",
  description = utils.read_description("project_structure"),
  parameters = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Relative path to inspect (default: current working directory)",
      },
      max_depth = {
        type = "number",
        description = "Maximum recursion depth (default: unlimited)",
      },
    },
    required = {},
    additionalProperties = false,
  },
}

M.run = function(args)
  local uv = vim.loop
  local cwd = vim.fn.getcwd()
  local base = args.path and (cwd .. "/" .. args.path) or cwd
  local max_depth = args.max_depth or math.huge

  -- util helpers
  local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
  end

  local function escape_lua_pattern(s)
    -- Escape Lua pattern magic characters by prefixing them with '%'
    local magic = {
      ["^"] = true,
      ["$"] = true,
      ["("] = true,
      [")"] = true,
      ["%"] = true,
      ["."] = true,
      ["["] = true,
      ["]"] = true,
      ["+"] = true,
      ["-"] = true,
      ["*"] = true,
      ["?"] = true,
    }
    return (s:gsub(".", function(c)
      if magic[c] then
        return "%" .. c
      end
      return c
    end))
  end

  local function norm_rel(p)
    if not p or p == "" or p == "." then
      return ""
    end
    p = p:gsub("^%./", "")
    p = p:gsub("/+$", "")
    return p
  end

  -- Convert a gitignore glob (without leading ! or trailing / handling) into a Lua pattern
  -- Implements: ** (any, including /), * (any except /), ? (single except /)
  local function glob_to_lua(glob)
    -- Handle ** first using a placeholder to avoid clashing with single * escaping
    local placeholder = "\0__GLOBSTAR__\0"
    glob = glob:gsub("%*%*", placeholder)
    glob = escape_lua_pattern(glob)
    glob = glob:gsub(placeholder, ".*")
    -- Replace escaped single-char globs (escaped by escape_lua_pattern) with Lua patterns
    glob = glob:gsub("%%%*", "[^/]*")
    glob = glob:gsub("%%%?", "[^/]")

    return glob
  end

  -- Pattern object fields:
  --  pattern (string): Lua pattern for the core expression (no anchors)
  --  dir_only (boolean): matches directories only
  --  anchored (boolean): if true, pattern is anchored to 'base' dir
  --  contains_slash (boolean): true if original glob contained '/'
  --  base (string): relative directory (from cwd) where this .gitignore lives ("" for root)
  --  negative (boolean): if true, negates (unignore) when matched
  local function parse_pattern(line, base_rel)
    local negative = false
    if line:sub(1, 1) == "!" then
      negative = true
      line = line:sub(2)
    end

    line = trim(line)
    if line == "" or line:sub(1, 1) == "#" then
      return nil
    end

    -- Directory-only if ends with '/'
    local dir_only = false
    if line:sub(-1) == "/" then
      dir_only = true
      -- Remove trailing slashes
      line = line:gsub("/+$", "")
      if line == "" then
        -- "/" alone is not meaningful here
        return nil
      end
    end

    -- Anchored to the directory of the .gitignore file if pattern starts with '/'
    local anchored = false
    if line:sub(1, 1) == "/" then
      anchored = true
      line = line:gsub("^/+", "")
    end

    local contains_slash = line:find("/") ~= nil
    local patt = glob_to_lua(line)

    return {
      pattern = patt,
      dir_only = dir_only,
      anchored = anchored,
      contains_slash = contains_slash,
      base = base_rel or "",
      negative = negative,
      original = line,
    }
  end

  local function parse_ignore_file(filepath, base_rel)
    local patterns = {}
    if uv.fs_stat(filepath) then
      local lines = vim.fn.readfile(filepath)
      for _, raw in ipairs(lines) do
        raw = trim(raw)
        if raw ~= "" and not raw:match("^#") then
          local p = parse_pattern(raw, base_rel)
          if p then
            table.insert(patterns, p)
          end
        end
      end
    end
    return patterns
  end

  -- Check whether a path is under a base prefix (relative path semantics)
  local function under_base(relpath, base_rel)
    if base_rel == nil or base_rel == "" then
      return true
    end
    return relpath == base_rel or relpath:sub(1, #base_rel + 1) == (base_rel .. "/")
  end

  -- Returns true if relpath should be ignored per the list of patterns.
  -- Implements: last match wins; directory-only rules; anchored rules relative to their .gitignore dir.
  local function matches_any_pattern(relpath, name, is_dir, patterns)
    local ignored = false
    for i = #patterns, 1, -1 do
      local p = patterns[i]
      -- Scope: only applies under its base directory
      if under_base(relpath, p.base) then
        -- Directory-only patterns should only match directories
        if not p.dir_only or is_dir then
          if p.anchored then
            -- Anchored to p.base
            local prefix = (p.base ~= "" and (escape_lua_pattern(p.base) .. "/") or "")
            local full_lua = "^" .. prefix .. p.pattern .. "$"
            if relpath:match(full_lua) then
              ignored = not p.negative
              return ignored
            end
          else
            if p.contains_slash then
              -- Unanchored path pattern => can match at base root or any subdirectory within its base
              if relpath:match("^" .. p.pattern .. "$") or relpath:match(".*/" .. p.pattern .. "$") then
                ignored = not p.negative
                return ignored
              end
            else
              -- No slash => matches basename anywhere under base
              if name:match("^" .. p.pattern .. "$") then
                ignored = not p.negative
                return ignored
              end
            end
          end
        end
      end
    end
    return ignored
  end

  -- Build initial patterns: sensible defaults + root .git/info/exclude + root .gitignore
  local patterns = {}

  -- Default ignores (treated like unanchored, directory names)
  local default_dirs = { ".git", "node_modules", ".venv", "venv", "myenv", "pyenv" }
  for _, d in ipairs(default_dirs) do
    table.insert(patterns, {
      pattern = escape_lua_pattern(d),
      dir_only = true,
      anchored = false,
      contains_slash = false,
      base = "",
      negative = false,
      original = d,
    })
  end

  -- Root-level excludes
  local info_exclude = cwd .. "/.git/info/exclude"
  for _, p in ipairs(parse_ignore_file(info_exclude, "")) do
    table.insert(patterns, p)
  end

  local root_gitignore = cwd .. "/.gitignore"
  for _, p in ipairs(parse_ignore_file(root_gitignore, "")) do
    table.insert(patterns, p)
  end

  local lines = {}

  -- Recursive scanner
  local function scan(dir_abs, rel_dir, prefix, depth, inherited_patterns)
    if depth > max_depth then
      return
    end

    local handle = uv.fs_scandir(dir_abs)
    if not handle then
      return
    end

    -- Merge patterns with any local .gitignore in this directory
    local merged = {}
    if inherited_patterns then
      for i = 1, #inherited_patterns do
        merged[#merged + 1] = inherited_patterns[i]
      end
    end

    local base_rel_for_this_dir = rel_dir or ""
    local local_gitignore = dir_abs .. "/.gitignore"
    for _, p in ipairs(parse_ignore_file(local_gitignore, base_rel_for_this_dir)) do
      merged[#merged + 1] = p
    end

    while true do
      local name, t = uv.fs_scandir_next(handle)
      if not name then
        break
      end

      local is_dir = (t == "directory")
      local rel_child
      if base_rel_for_this_dir == "" then
        rel_child = name
      else
        rel_child = base_rel_for_this_dir .. "/" .. name
      end
      local full = dir_abs .. "/" .. name

      if not matches_any_pattern(rel_child, name, is_dir, merged) then
        local symbol = is_dir and "📁 " or "📄 "
        table.insert(lines, prefix .. symbol .. name)
        if is_dir then
          scan(full, rel_child, prefix .. "    ", depth + 1, merged)
        end
      end
    end
  end

  -- Start scanning
  local initial_rel = norm_rel(args.path)
  table.insert(lines, "🔍 Project structure for: " .. (args.path or "."))
  scan(base, initial_rel, "", 1, patterns)

  return "```txt\n" .. table.concat(lines, "\n") .. "\n```"
end

return M
