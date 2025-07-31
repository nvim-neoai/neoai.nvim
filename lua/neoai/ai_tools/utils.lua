local M = {}

---
-- Reads the description markdown for a given tool name from the descriptions/ directory.
---@param tool_name string: The base name of the tool (e.g., 'grep', 'read')
---@return string: The contents of the markdown file, or an empty string if not found.
function M.read_description(tool_name)
  local info = debug.getinfo(1, "S").source:sub(2)
  local base = info:match("(.*/)") or "./"
  local path = base .. "descriptions/" .. tool_name .. ".md"
  local file = io.open(path, "r")
  if not file then return "" end
  local content = file:read("*a")
  file:close()
  return content
end


-- Opens or reloads the file in a window outside the AI chat UI
function M.open_non_ai_buffer(path)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if not name:match("^neoai://") then
      vim.api.nvim_set_current_win(win)
      vim.cmd("edit " .. path)
      return
    end
  end
  -- Fallback: open in current window
  vim.cmd("edit " .. path)
end

-- Escapes a Lua pattern so it can be used as a literal in gsub
function M.escape_pattern(s)
  return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Wraps text in a markdown code block with optional language identifier
function M.make_code_block(text, lang)
  lang = lang or "txt"
  return string.format("```%s\n%s\n```", lang, text)
end

local function read_lines(filepath)
  local lines = {}
  local file = io.open(filepath, "r")
  if not file then
    return nil, "Cannot open " .. filepath
  end
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()
  return lines
end

-- Shows a unified diff like git between two files
function M.diff_files(path1, path2)
  -- Use git diff if available
  if vim.fn.executable("git") == 1 then
    local args = { "git", "diff", "--no-index", "--color=always", path1, path2 }
    local diff = vim.fn.systemlist(args)
    for _, line in ipairs(diff) do
      print(line)
    end
    return
  end

  -- Fallback to manual line-by-line diff
  local lines1, err1 = read_lines(path1)
  local lines2, err2 = read_lines(path2)

  if not lines1 then
    print(err1)
    return
  end
  if not lines2 then
    print(err2)
    return
  end

  local max = math.max(#lines1, #lines2)
  for i = 1, max do
    local l1 = lines1[i]
    local l2 = lines2[i]
    if l1 == l2 then
      print("  " .. (l1 or ""))
    elseif l1 and not l2 then
      print("- " .. l1)
    elseif not l1 and l2 then
      print("+ " .. l2)
    else
      print("- " .. l1)
      print("+ " .. l2)
    end
  end
end

return M
