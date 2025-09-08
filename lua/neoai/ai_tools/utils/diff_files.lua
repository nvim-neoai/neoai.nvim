local function read_lines(filepath)
  --- @return table|nil, string|nil: A table of lines from the file or nil and an error message
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

--- @param path1 string: The path to the first file
--- @param path2 string: The path to the second file
local function diff_files(path1, path2)
  if vim.fn.executable("git") == 1 then
    local args = { "git", "diff", "--no-index", "--color=always", path1, path2 }
    local diff = vim.fn.systemlist(args)
    for _, line in ipairs(diff) do
      print(line)
    end
    return
  end

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

return diff_files
