local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "Write",
  description = utils.read_description("write"),
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format(
          "The path of the file to write to (relative to the current working directory %s)",
          vim.fn.getcwd()
        ),
      },
      content = {
        type = "string",
        description = "The content to write to the file. ALWAYS provide the COMPLETE intended content of the file, without any truncation or omissions. You MUST include ALL parts of the file, even if they haven't been modified.",
      },
    },
    required = { "file_path", "content" },
    additionalProperties = false,
  },
}

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
  vim.api.nvim_buf_set_name(buf, title or "NeoAI Write Diff")

  -- Provide simple instructions in the winbar
  pcall(vim.api.nvim_set_option_value, "winbar", " Review diff: y=apply, n=reject, q=cancel ", { win = win })

  vim.bo.modifiable = true
  local lines = vim.split(diff_text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "(No differences)" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
  local file_path = args.file_path
  local content = args.content

  if type(file_path) ~= "string" or type(content) ~= "string" then
    return "file_path and content are required"
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. file_path

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(abs_path, ":h")
  vim.fn.mkdir(dir, "p")

  -- Write proposed content to a temp file for diff + potential apply
  local tmp_path = abs_path .. ".tmp"
  local tf, terr = io.open(tmp_path, "w")
  if not tf then
    return string.format("Failed to open temp file %s for writing: %s", tmp_path, terr)
  end
  tf:write(content)
  tf:close()

  -- Generate a diff for user review (original vs proposed)
  local diff_text = get_diff_text(abs_path, tmp_path)

  -- If headless (no UI), auto-approve and apply, returning summary + diff + diagnostics.
  local uis = vim.api.nvim_list_uis()
  if not uis or #uis == 0 then
    local ok, rename_err = os.rename(tmp_path, abs_path)
    if not ok then
      return "Failed to rename temp file: " .. tostring(rename_err)
    end
    local summary = string.format("✅ Wrote %s (auto-approved, headless)", file_path)
    local diag_tool = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = diag_tool.run({ file_path = file_path, include_code_actions = false })
    local parts = { summary, "Applied diff:", utils.make_code_block(diff_text, "diff"), diagnostics }
    return table.concat(parts, "\n\n")
  end

  -- Show the diff in a scratch buffer to allow scrolling/inspection
  local buf, win = show_diff_buffer(diff_text, "NeoAI Write Diff: " .. file_path)

  -- Non-blocking review flow: map y/n/q in the diff buffer and wait for a decision
  local decision ---@type nil|boolean
  local timed_out = false

  local function approve()
    decision = true
  end
  local function reject()
    decision = false
  end

  -- Buffer-local keymaps for approval/rejection
  local map_opts = { buffer = buf, nowait = true, silent = true, noremap = true }
  vim.keymap.set("n", "y", approve, map_opts)
  vim.keymap.set("n", "Y", approve, map_opts)
  vim.keymap.set("n", "n", reject, map_opts)
  vim.keymap.set("n", "N", reject, map_opts)
  vim.keymap.set("n", "q", reject, map_opts)
  vim.keymap.set("n", "<Esc>", reject, map_opts)

  -- If the buffer is closed/hidden, treat as rejection
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload", "BufHidden" }, {
    buffer = buf,
    once = true,
    callback = function()
      if decision == nil then
        decision = false
      end
    end,
  })

  -- Allow up to 10 minutes to review; keep UI responsive
  local ok_wait = vim.wait(600000, function()
    return decision ~= nil
  end, 100)
  if not ok_wait and decision == nil then
    timed_out = true
    decision = false
  end

  if decision then
    -- User approved: apply by renaming temp file over original
    local ok, rename_err = os.rename(tmp_path, abs_path)
    close_bufwin(buf, win)
    if not ok then
      return "Failed to rename temp file: " .. tostring(rename_err)
    end

    -- Open updated file outside AI UI and report diagnostics
    utils.open_non_ai_buffer(abs_path)

    local summary = string.format("✅ Successfully wrote and opened: %s", file_path)
    local diag_tool = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = diag_tool.run({ file_path = file_path, include_code_actions = false })

    return summary .. "\n\n" .. diagnostics
  else
    -- User denied: ask for a reason (blocks only after explicit denial), then do not apply changes
    close_bufwin(buf, win)

    local response = {}

    if timed_out then
      -- No explicit decision; do not prompt for a reason
      table.insert(response, "❌ Changes rejected for " .. file_path .. " (timed out waiting for approval)")
    else
      -- Explicit rejection: prompt for reason
      local reason = vim.fn.input("Reason for rejecting changes (sent back to the AI): ") or ""
      table.insert(response, "❌ Changes rejected for " .. file_path)
      if reason ~= "" then
        table.insert(response, "Reason: " .. reason)
      end
    end

    -- Clean up temp file (after capturing reason if any)
    pcall(os.remove, tmp_path)

    table.insert(response, "Proposed diff:")
    table.insert(response, utils.make_code_block(diff_text, "diff"))
    return table.concat(response, "\n\n")
  end
end

return M
