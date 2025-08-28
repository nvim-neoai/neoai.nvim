local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "MultiEdit",
  description = utils.read_description("multi_edit"),
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format("The path of the file to modify (relative to cwd %s)", vim.fn.getcwd()),
      },
      edits = {
        type = "array",
        description = "Array of edit operations, each containing old_string, new_string, and optional line range",
        items = {
          type = "object",
          properties = {
            old_string = { type = "string", description = "Exact text to replace" },
            new_string = { type = "string", description = "The replacement text" },
            start_line = { type = "integer", description = "(Optional) Start line number for this edit (1-based)" },
            end_line = { type = "integer", description = "(Optional) End line number for this edit (1-based)" },
          },
          required = { "old_string", "new_string" },
        },
      },
    },
    required = { "file_path", "edits" },
    additionalProperties = false,
  },
}

local function validate_edit(edit, index)
  if type(edit.old_string) ~= "string" then
    return string.format("Edit %d: 'old_string' must be a string", index)
  end
  if type(edit.new_string) ~= "string" then
    return string.format("Edit %d: 'new_string' must be a string", index)
  end
  if edit.start_line ~= nil and type(edit.start_line) ~= "number" then
    return string.format("Edit %d: 'start_line' must be a number", index)
  end
  if edit.end_line ~= nil and type(edit.end_line) ~= "number" then
    return string.format("Edit %d: 'end_line' must be a number", index)
  end
  if edit.start_line and edit.end_line and edit.start_line > edit.end_line then
    return string.format("Edit %d: 'start_line' must be <= 'end_line'", index)
  end
  return nil
end

local function split_lines(str)
  return vim.split(str, "\n", { plain = true })
end

-- Shallow copy of an array-like table (lines)
local function copy_lines(t)
  local c = {}
  for i = 1, #t do
    c[i] = t[i]
  end
  return c
end

-- Return diff text between two files. Prefers git --no-index when available.
local function get_diff_text(path1, path2)
  local diff_lines = {}
  if vim.fn.executable("git") == 1 then
    local args = { "git", "diff", "--no-index", "--color=never", "--no-ext-diff", path1, path2 }
    local out = vim.fn.systemlist(args)
    if type(out) == "table" and #out > 0 then
      diff_lines = out
    end
  end

  if #diff_lines == 0 then
    -- Fallback: simple line-by-line diff
    local function read_lines(filepath)
      local lines = {}
      local f = io.open(filepath, "r")
      if not f then
        return {}
      end
      for line in f:lines() do
        table.insert(lines, line)
      end
      f:close()
      return lines
    end

    local a = read_lines(path1)
    local b = read_lines(path2)
    local maxn = math.max(#a, #b)
    table.insert(diff_lines, string.format("--- %s", path1))
    table.insert(diff_lines, string.format("+++ %s", path2))
    for i = 1, maxn do
      local l1 = a[i]
      local l2 = b[i]
      if l1 == l2 then
        table.insert(diff_lines, "  " .. (l1 or ""))
      elseif l1 and not l2 then
        table.insert(diff_lines, "- " .. l1)
      elseif not l1 and l2 then
        table.insert(diff_lines, "+ " .. l2)
      else
        table.insert(diff_lines, "- " .. l1)
        table.insert(diff_lines, "+ " .. l2)
      end
    end
  end

  return table.concat(diff_lines, "\n")
end

-- Get unified diff hunks with zero context using git, or nil if unavailable
local function get_u0_hunks(path1, path2)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local args = { "git", "diff", "--no-index", "--color=never", "--no-ext-diff", "-U0", path1, path2 }
  local out = vim.fn.systemlist(args)
  if type(out) ~= "table" or #out == 0 then
    return nil
  end
  local hunks = {}
  for _, line in ipairs(out) do
    local a_s, a_c, b_s, b_c = line:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@")
    if a_s and b_s then
      a_s = tonumber(a_s)
      b_s = tonumber(b_s)
      a_c = tonumber(a_c) or 1
      b_c = tonumber(b_c) or 1
      table.insert(hunks, { a_start = a_s, a_count = a_c, b_start = b_s, b_count = b_c })
    end
  end
  return hunks
end

-- Build content with Git-style conflict markers from old/new lines and hunks
local function build_conflict_content(old_lines, new_lines, hunks)
  local result = {}

  if not hunks or #hunks == 0 then
    -- Fallback: single conflict for whole file
    table.insert(result, "<<<<<<< HEAD")
    for _, l in ipairs(old_lines) do table.insert(result, l) end
    table.insert(result, "=======")
    for _, l in ipairs(new_lines) do table.insert(result, l) end
    table.insert(result, ">>>>>>> neoai")
    return result
  end

  local prev_a_end = 0
  local prev_b_end = 0

  for _, h in ipairs(hunks) do
    local a_s, a_c = h.a_start, h.a_count
    local b_s, b_c = h.b_start, h.b_count

    -- Unchanged prefix before this hunk
    for i = prev_a_end + 1, math.max(0, a_s - 1) do
      if old_lines[i] ~= nil then
        table.insert(result, old_lines[i])
      end
    end

    -- Conflict block
    table.insert(result, "<<<<<<< HEAD")
    for i = a_s, a_s + a_c - 1 do
      if old_lines[i] ~= nil then table.insert(result, old_lines[i]) end
    end
    table.insert(result, "=======")
    for i = b_s, b_s + b_c - 1 do
      if new_lines[i] ~= nil then table.insert(result, new_lines[i]) end
    end
    table.insert(result, ">>>>>>> neoai")

    prev_a_end = a_s + a_c - 1
    prev_b_end = b_s + b_c - 1
  end

  -- Trailing unchanged lines
  for i = prev_a_end + 1, #old_lines do
    table.insert(result, old_lines[i])
  end

  return result
end

M.run = function(args)
  local rel_path = args.file_path
  local edits = args.edits

  if type(rel_path) ~= "string" then
    return "file_path must be a string"
  end
  if type(edits) ~= "table" then
    return "edits must be an array"
  end

  for i, edit in ipairs(edits) do
    local err = validate_edit(edit, i)
    if err then
      return err
    end
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. rel_path
  local file, err = io.open(abs_path, "r")
  if not file then
    return "Cannot open file: " .. tostring(err)
  end
  local content = file:read("*a")
  file:close()

  local orig_lines = split_lines(content)
  local lines = copy_lines(orig_lines)
  local total_replacements = 0

  for _, edit in ipairs(edits) do
    local old_pat = utils.escape_pattern(edit.old_string)
    local count = 0
    local start_line = edit.start_line or 1
    local end_line = edit.end_line or #lines
    start_line = math.max(1, start_line)
    end_line = math.min(#lines, end_line)

    -- Replace within specified line range
    for idx = start_line, end_line do
      local new_line, c = lines[idx]:gsub(old_pat, edit.new_string)
      if c > 0 then
        lines[idx] = new_line
        count = count + c
      end
    end

    if count == 0 then
      -- No replacements in range: fallback to first occurrence in entire file
      for idx, line in ipairs(lines) do
        if line:find(edit.old_string, 1, true) then
          lines[idx] = line:gsub(old_pat, edit.new_string, 1)
          count = 1
          break
        end
      end
    end

    if count == 0 then
      return string.format("⚠️ No match for '%s'. Fallback to Write tool.", edit.old_string)
    end

    total_replacements = total_replacements + count
  end

  if total_replacements == 0 then
    return string.format("⚠️ No replacements made in %s. Fallback to Write tool.", rel_path)
  end

  -- Compose updated content in memory
  local updated = table.concat(lines, "\n")

  -- Write updated content to temp file (for diff + conflict hunks)
  local tmp_path = abs_path .. ".tmp"
  local out, werr = io.open(tmp_path, "w")
  if not out then
    return "Cannot write to temp file: " .. tostring(werr)
  end
  out:write(updated)
  out:close()

  -- Generate a diff for reporting (headless) and hunks for conflict markers (UI)
  local diff_text = get_diff_text(abs_path, tmp_path)

  -- If headless (no UI), auto-approve and apply, returning summary + diff + diagnostics.
  local uis = vim.api.nvim_list_uis()
  if not uis or #uis == 0 then
    local ok, rename_err = os.rename(tmp_path, abs_path)
    if not ok then
      return "Failed to rename temp file: " .. tostring(rename_err)
    end
    local summary = string.format("✅ Applied %d replacements to %s (auto-approved, headless)", total_replacements, rel_path)
    local diag_tool = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = diag_tool.run({ file_path = rel_path, include_code_actions = false })
    local parts = { summary, "Applied diff:", utils.make_code_block(diff_text, "diff"), diagnostics }
    return table.concat(parts, "\n\n")
  end

  -- UI mode: insert conflict markers inline into the target file and jump to first conflict
  local hunks = get_u0_hunks(abs_path, tmp_path)
  local conflict_lines = build_conflict_content(orig_lines, split_lines(updated), hunks)

  -- Open the target file in a non-AI window and replace its content
  utils.open_non_ai_buffer(abs_path)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, conflict_lines)
  -- Save changes to disk
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("write")
  end)

  -- Jump cursor to first conflict marker
  local first_conflict = 1
  for i, l in ipairs(conflict_lines) do
    if vim.startswith(l, "<<<<<<<") then
      first_conflict = i
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { first_conflict, 0 })

  -- Cleanup temp file
  pcall(os.remove, tmp_path)

  return string.format("✍️ Inserted %d replacement(s) into %s with Git-style conflict markers. Resolve conflicts and save when ready.", total_replacements, rel_path)
end

return M
