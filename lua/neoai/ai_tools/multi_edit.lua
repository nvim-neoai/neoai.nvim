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

-- Show diff text in a scratch buffer for user review; returns {bufnr, winid}
local function show_diff_buffer(diff_text, title)
  vim.cmd("botright new")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.bo.filetype = "diff"
  vim.api.nvim_buf_set_name(buf, title or "NeoAI MultiEdit Diff")
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(diff_text, "\n"))
  vim.bo.modifiable = false
  return buf, win
end

-- Close a window and wipe buffer safely
local function close_bufwin(buf, win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
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

  local lines = split_lines(content)
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

  -- Write updated content to temp file (for diff + potential apply)
  local tmp_path = abs_path .. ".tmp"
  local out, werr = io.open(tmp_path, "w")
  if not out then
    return "Cannot write to temp file: " .. tostring(werr)
  end
  out:write(updated)
  out:close()

  -- Generate a diff for user review
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

  -- Show the diff in a scratch buffer to allow scrolling/inspection
  local buf, win = show_diff_buffer(diff_text, "NeoAI MultiEdit Diff: " .. rel_path)

  -- Ask for approval
  local confirm = vim.fn.input("Approve these changes to " .. rel_path .. "? [y/N]: ")
  confirm = (confirm or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

  if confirm == "y" or confirm == "yes" then
    -- User approved: apply by renaming temp file over original
    local ok, rename_err = os.rename(tmp_path, abs_path)
    close_bufwin(buf, win)
    if not ok then
      return "Failed to rename temp file: " .. tostring(rename_err)
    end

    -- Open updated file outside AI UI and report diagnostics
    utils.open_non_ai_buffer(abs_path)

    local summary = string.format("✅ Applied %d replacements to %s", total_replacements, rel_path)
    local diag_tool = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = diag_tool.run({ file_path = rel_path, include_code_actions = false })

    return summary .. "\n\n" .. diagnostics
  else
    -- User denied: ask for reason to pass back to AI and do not apply changes
    close_bufwin(buf, win)
    local reason = vim.fn.input("Please enter a brief reason for denial (sent back to the AI): ") or ""
    -- Clean up temp file
    pcall(os.remove, tmp_path)

    local response = {}
    table.insert(response, "❌ Changes rejected for " .. rel_path)
    if reason ~= "" then
      table.insert(response, "Reason: " .. reason)
    end
    table.insert(response, "Proposed diff:")
    table.insert(response, utils.make_code_block(diff_text, "diff"))
    return table.concat(response, "\n\n")
  end
end

return M
