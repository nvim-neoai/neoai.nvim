local utils = require("neoai.ai_tools.utils")
-- The finder module now handles all search logic.
local finder = require("neoai.ai_tools.utils.find")

local M = {}

-- State to hold original content of the buffer being edited.
local active_edit_state = {}

-- Accumulator for deferred, end-of-loop reviews. Keyed by absolute path.
-- Each entry: { baseline = {lines...}, latest = {lines...} }
local deferred_reviews = {}

--[[
  UTILITY FUNCTIONS (with improved indentation handling)
--]]
local function split_lines(str)
  return vim.split(str, "\n", { plain = true })
end

local function normalise_eol(s)
  return (s or ""):gsub("\r\n", "\n"):gsub("\r", "")
end

local function strip_cr(lines)
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("\r$", "")
  end
end

-- Compute the leading whitespace string for a given line.
local function leading_ws(s)
  return (s or ""):match("^%s*") or ""
end

-- Compute minimal indent length (in characters) among non-empty lines.
local function min_indent_len(lines)
  local min_len
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local len = #leading_ws(l)
      if not min_len or len < min_len then
        min_len = len
      end
    end
  end
  return min_len or 0
end

-- Find the line index (1-based) within a range that has the minimal indent.
local function range_min_indent_line(lines, s, e)
  local min_len, min_idx
  for i = s, math.max(s, e) do
    local l = lines[i]
    if l and l:match("%S") then
      local len = #leading_ws(l)
      if not min_len or len < min_len then
        min_len = len
        min_idx = i
      end
    end
  end
  return min_len or 0, min_idx
end

-- Remove up to `n` leading whitespace characters (spaces or tabs) from a line.
local function remove_leading_ws_chars(line, n)
  if n <= 0 then
    return line
  end
  local i, removed = 1, 0
  while removed < n and i <= #line do
    local ch = line:sub(i, i)
    if ch == " " or ch == "\t" then
      i = i + 1
      removed = removed + 1
    else
      break
    end
  end
  return line:sub(i)
end

-- Dedent lines by their minimal common indentation while preserving relative indentation.
local function dedent(lines)
  local n = min_indent_len(lines)
  if n <= 0 then
    return vim.deepcopy(lines)
  end
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("%S") then
      out[i] = remove_leading_ws_chars(l, n)
    else
      out[i] = ""
    end
  end
  return out
end

local function unified_diff(old_lines, new_lines)
  local old_str = table.concat(old_lines or {}, "\n")
  local new_str = table.concat(new_lines or {}, "\n")
  ---@diagnostic disable-next-line: missing-fields
  local diff = vim.diff(old_str, new_str, { result_type = "unified", algorithm = "histogram" })
  return diff or "(no changes)"
end

-- This function is called from chat.lua to close an open diffview window.
function M.discard_all_diffs()
  -- ... (function is unchanged)
  local ok, diff_utils = pcall(require, "neoai.ai_tools.utils")
  if ok and diff_utils and diff_utils.inline_diff and diff_utils.inline_diff.close then
    diff_utils.inline_diff.close()
  end
  local bufnr = active_edit_state.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, active_edit_state.original_lines)
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
  end
  active_edit_state = {}
  return "All pending edits discarded and buffer reverted."
end

-- NEW: Simplified schema. No more line numbers from the AI.
M.meta = {
  name = "Edit",
  description = utils.read_description("edit")
      .. " Edits may be provided in any order; the engine applies them order-invariantly and resolves overlaps.",
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format("The path of the file to modify or create (relative to cwd %s)", vim.fn.getcwd()),
      },
      edits = {
        type = "array",
        description =
        "Array of edit operations, each containing old_b64 and new_b64 (base64, RFC 4648). Order is not required.",
        items = {
          type = "object",
          properties = {
            old_b64 = {
              type = "string",
              description =
              "Base64-encoded exact text to replace (empty decoded string means insert at beginning of file)",
            },
            new_b64 = { type = "string", description = "Base64-encoded replacement text" },
          },
          required = { "old_b64", "new_b64" },
        },
      },
    },
    required = { "file_path", "edits" },
    additionalProperties = false,
  },
}

--- Validate an edit operation (base64-only fields).
---@param edit table: The edit operation.
---@param index integer: The index of the edit operation.
---@return string|nil: An error message if validation fails, otherwise nil.
local function validate_edit(edit, index)
  if type(edit.old_b64) ~= "string" then
    return string.format("Edit %d: 'old_b64' must be a string (base64)", index)
  end
  if type(edit.new_b64) ~= "string" then
    return string.format("Edit %d: 'new_b64' must be a string (base64)", index)
  end
  return nil
end

--- Execute the edit operations on a file.
---@param args table: A table containing the file path and edits.
---@return string: A status message.
M.run = function(args)
  if type(args) ~= "table" then
    return string.format("Edit tool: ignored call; arguments must be an object/table (got %s)", type(args))
  end

  local rel_path = args.file_path
  local edits = args.edits

  -- Gracefully ignore partial calls without spamming errors.
  if type(rel_path) ~= "string" or type(edits) ~= "table" then
    local keys = {}
    if type(args) == "table" then
      for k, _ in pairs(args) do
        table.insert(keys, tostring(k))
      end
      table.sort(keys)
    end
    local preview = ""
    pcall(function() preview = vim.inspect(args) end)
    return string.format(
      "Edit tool: ignored call; expected 'file_path' (string) and 'edits' (array). Args keys: [%s]. Args preview: %s",
      table.concat(keys, ", "),
      preview
    )
  end

  for i, edit in ipairs(edits) do
    local err = validate_edit(edit, i)
    if err then
      local msg = "Edit tool error: " .. err
      vim.notify(msg, vim.log.levels.ERROR, { title = "NeoAI" })
      return msg
    end
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. rel_path

  local content
  local bufnr_from_list
  do
    local target = vim.fn.fnamemodify(abs_path, ":p")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if vim.fn.fnamemodify(name, ":p") == target then
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          content = table.concat(lines, "\n")
          bufnr_from_list = b
          break
        end
      end
    end
    if content == nil then
      local file = io.open(abs_path, "r")
      if file then
        content = file:read("*a") or ""
        file:close()
      else
        content = ""
      end
    end
  end

  local orig_lines = split_lines(normalise_eol(content))
  strip_cr(orig_lines)

  -- Order-invariant, multi-pass application logic
  local working_lines = vim.deepcopy(orig_lines)
  local total_replacements = 0
  local skipped_already_applied = 0

  -- Base64 codec (RFC 4648) with URL-safe support and whitespace tolerance
  local function b64_normalise(s)
    s = tostring(s or "")
    -- remove whitespace and convert URL-safe
    s = s:gsub("%s+", ""):gsub("%-", "+"):gsub("_", "/")
    -- pad with '=' to multiple of 4
    local m = #s % 4
    if m == 2 then
      s = s .. "=="
    elseif m == 3 then
      s = s .. "="
    elseif m ~= 0 and #s > 0 then
      -- if m==1 this is invalid, keep as-is and decoder will error
    end
    return s
  end
  local b64_map = {}
  do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #alphabet do b64_map[alphabet:sub(i, i)] = i - 1 end
  end
  local function b64_decode(str)
    local s = b64_normalise(str)
    -- validate characters
    local invalid_pos = s:find("[^A-Za-z0-9%+/=]")
    if invalid_pos then
      return nil, string.format("Invalid base64 character at position %d", invalid_pos)
    end
    if #s == 0 then return "", nil end
    local out = {}
    local i = 1
    while i <= #s do
      local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
      if not c2 then return nil, "Truncated base64 input" end
      local v1, v2 = b64_map[c1], b64_map[c2]
      if not v1 or not v2 then return nil, string.format("Invalid base64 quartet starting at %d", i) end
      local v3 = c3 == "=" and nil or b64_map[c3]
      local v4 = c4 == "=" and nil or b64_map[c4]
      if c3 and c3 ~= "=" and not v3 then return nil, string.format("Invalid base64 quartet starting at %d", i) end
      if c4 and c4 ~= "=" and not v4 then return nil, string.format("Invalid base64 quartet starting at %d", i) end
      -- arithmetic computation to avoid bit library dependency
      local b1 = (v1 * 4) + math.floor(v2 / 16)
      table.insert(out, string.char(b1))
      if v3 ~= nil then
        local b2 = ((v2 % 16) * 16) + math.floor(v3 / 4)
        table.insert(out, string.char(b2))
      end
      if v3 ~= nil and v4 ~= nil then
        local b3 = ((v3 % 4) * 64) + v4
        table.insert(out, string.char(b3))
      end
      i = i + 4
    end
    return table.concat(out), nil
  end

  -- Preprocess edits into a pending list with decoded, split, normalised lines
  local pending = {}
  for i, edit in ipairs(edits) do
    local raw_old = normalise_eol(edit.old_string)
    local is_insert = (raw_old == "")
    local old_lines = is_insert and {} or split_lines(raw_old)
    -- Robustness in case old_lines becomes {""}
    if (not is_insert) and #old_lines == 1 and old_lines[1] == "" then
      is_insert = true
      old_lines = {}
    end
    local new_lines = split_lines(normalise_eol(edit.new_string))
    strip_cr(old_lines)
    strip_cr(new_lines)
    table.insert(pending, {
      index = i,
      old_lines = old_lines,
      new_lines = new_lines,
      kind = is_insert and "insert" or "replace",
    })
  end

  local function apply_replacement_at(working, s, e, new_lines)
    -- Determine base indent from minimal-indented non-empty line within [s,e]
    local base_indent = ""
    if s and e and s >= 1 and e >= s then
      local _, idx = range_min_indent_line(working, s, e)
      if idx and working[idx] then
        base_indent = leading_ws(working[idx])
      else
        base_indent = leading_ws(working[s] or "")
      end
    else
      base_indent = leading_ws(working[s] or "")
    end

    local adjusted_new = {}
    local dedented = dedent(new_lines)
    for k, line in ipairs(dedented) do
      if line:match("%S") then
        adjusted_new[k] = base_indent .. line
      else
        adjusted_new[k] = ""
      end
    end

    local num_to_remove = e - s + 1
    if num_to_remove < 0 then
      num_to_remove = 0
    end
    for _ = 1, num_to_remove do
      table.remove(working, s)
    end
    for j, line in ipairs(adjusted_new) do
      table.insert(working, s - 1 + j, line)
    end
  end

  local max_passes = 3
  local pass = 0
  while #pending > 0 and pass < max_passes do
    pass = pass + 1
    local next_pending = {}

    -- Collect candidate matches for replacements
    local candidates = {}
    for _, item in ipairs(pending) do
      if item.kind == "replace" then
        local s, e = finder.find_block_location(working_lines, item.old_lines, 1, nil)
        if s then
          table.insert(candidates, { item = item, s = s, e = e })
        else
          -- Idempotency: treat as already applied if new block exists
          local ns, _ = finder.find_block_location(working_lines, item.new_lines, 1, nil)
          if ns then
            skipped_already_applied = skipped_already_applied + 1
          else
            table.insert(next_pending, item)
          end
        end
      else
        -- Insert handled after replacements
        table.insert(next_pending, item)
      end
    end

    -- Resolve overlapping matches: sort by start, pick non-overlapping
    table.sort(candidates, function(a, b)
      if a.s == b.s then
        return (a.e - a.s) < (b.e - b.s)
      end
      return a.s < b.s
    end)

    local selected = {}
    local last_end = 0
    for _, c in ipairs(candidates) do
      if c.s > last_end then
        table.insert(selected, c)
        last_end = c.e
      else
        -- Defer overlapping candidates
        table.insert(next_pending, c.item)
      end
    end

    -- Apply selected replacements left-to-right; re-locate just before applying
    for _, c in ipairs(selected) do
      local s_now, e_now = finder.find_block_location(working_lines, c.item.old_lines, 1, nil)
      if s_now then
        apply_replacement_at(working_lines, s_now, e_now, c.item.new_lines)
        total_replacements = total_replacements + 1
      else
        table.insert(next_pending, c.item)
      end
    end

    -- Handle insertions (empty decoded old block): insert at top in pass 1, else append at end
    local inserts = {}
    for _, item in ipairs(next_pending) do
      if item.kind == "insert" then
        table.insert(inserts, item)
      end
    end
    if #inserts > 0 then
      -- Remove inserts from next_pending
      local filtered = {}
      local to_insert_map = {}
      for _, it in ipairs(inserts) do
        to_insert_map[it] = true
      end
      for _, it in ipairs(next_pending) do
        if not to_insert_map[it] then
          table.insert(filtered, it)
        end
      end
      next_pending = filtered

      for _, ins in ipairs(inserts) do
        -- For lack of a precise anchor, choose beginning on first pass, end otherwise
        local pos = (pass == 1) and 1 or (#working_lines + 1)
        -- No indentation context for pure insertion; use dedented content as-is
        local dedented = dedent(ins.new_lines)
        for j = #dedented, 1, -1 do
          table.insert(working_lines, pos, dedented[j])
        end
        total_replacements = total_replacements + 1
      end
    end

    pending = next_pending
  end

  if #pending > 0 then
    -- Build a helpful error including a preview of the first pending block
    local first = pending[1]
    local preview_old = utils.make_code_block(table.concat(first.old_lines or {}, "\n"), "") or ""
    local preview_new = utils.make_code_block(table.concat(first.new_lines or {}, "\n"), "") or ""
    local verbose = table.concat({
      "Some edits could not be applied after multiple passes.",
      string.format("Unapplied edits remaining: %d", #pending),
      "Example (decoded) old block:",
      preview_old,
      "Example (decoded) new block:",
      preview_new,
    }, "\n\n")
    vim.notify("NeoAI Edit warning:\n" .. verbose, vim.log.levels.WARN, { title = "NeoAI" })
    -- Continue with applied changes; do not hard-fail the whole run
  end

  if total_replacements == 0 then
    if skipped_already_applied > 0 then
      return string.format("No changes needed in %s (%d edit(s) already applied).", rel_path, skipped_already_applied)
    end
    return string.format("No replacements made in %s.", rel_path)
  end

  local updated_lines = working_lines

  -- Update the deferred review accumulator for this file (baseline preserved from first edit)
  do
    local entry = deferred_reviews[abs_path]
    if entry == nil then
      deferred_reviews[abs_path] = { baseline = vim.deepcopy(orig_lines), latest = vim.deepcopy(updated_lines) }
    else
      entry.latest = vim.deepcopy(updated_lines)
      deferred_reviews[abs_path] = entry
    end
  end

  -- With a UI available, always open the inline diff and return diagnostics to drive the AI loop.
  -- If inline diff application fails (e.g., no UI), fall back to writing the file.
  local ok, msg = utils.inline_diff.apply(abs_path, orig_lines, updated_lines)
  if ok then
    active_edit_state = {
      bufnr = bufnr_from_list or vim.fn.bufadd(abs_path),
      original_lines = orig_lines,
    }

    -- Run diagnostics immediately and include a unified diff so the AI can self-correct before user review.
    local diff_text = unified_diff(orig_lines, updated_lines)
    local lsp_diag = require("neoai.ai_tools.lsp_diagnostic")
    local diagnostics = lsp_diag.run({ file_path = abs_path, include_code_actions = false })

    -- Compute diagnostics count on the target buffer (reflecting patched content)
    local diag_count = 0
    local target_buf = active_edit_state.bufnr
    if target_buf then
      pcall(lsp_diag.await_count, { bufnr = target_buf, timeout_ms = 1500 })
      if vim.api.nvim_buf_is_loaded(target_buf) then
        diag_count = #vim.diagnostic.get(target_buf)
      end
    end

    -- Provide machine-readable markers for the orchestrator
    local function simple_hash(s)
      s = s or ""
      local h1, h2 = 0, 0
      for i = 1, #s do
        local b = string.byte(s, i)
        h1 = (h1 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
      end
      return string.format("%08x%08x_%d", h1, h2, #s)
    end
    local diff_hash = simple_hash(diff_text)

    local parts = {
      msg,
      string.format(
        "Edits summary: applied %d, skipped %d (already applied)",
        total_replacements,
        skipped_already_applied
      ),
      "Applied diff:",
      utils.make_code_block(diff_text, "diff"),
      diagnostics,
      string.format("NeoAI-Diff-Hash: %s", diff_hash),
      string.format("NeoAI-Diagnostics-Count: %d", diag_count),
    }
    -- Do not autosave here; wait for the user to review and write or cancel in the inline diff UI.
    return table.concat(parts, "\n\n")
  else
    -- Fallback write logic (ensures directories exist). Useful if the inline diff cannot be shown.
    local dir = vim.fn.fnamemodify(abs_path, ":h")
    pcall(vim.fn.mkdir, dir, "p")

    local f, ferr = io.open(abs_path, "w")
    if f then
      f:write(table.concat(updated_lines, "\n"))
      f:close()
      return string.format("Wrote %s (inline diff failed: %s)", rel_path, msg or "unknown error")
    end
    return msg or ("Failed to open inline diff and could not write file: " .. tostring(ferr))
  end
end

--- Open an accumulated, deferred inline diff review for the given file.
--- Shows a single review comparing the original baseline (before the first edit in the loop)
--- to the latest content after the AI's iterations.
---@param file_path string: Relative or absolute path to the file
---@return boolean, string
function M.open_deferred_review(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return false, "Invalid file path"
  end
  local abs_path = file_path
  if not abs_path:match("^/") and not abs_path:match("^%a:[/\\]") then
    abs_path = vim.fn.getcwd() .. "/" .. file_path
  end
  local entry = deferred_reviews[abs_path]
  if not entry or not entry.baseline or not entry.latest then
    return false, "No pending deferred review for this file"
  end

  -- If there are no differences, do not open the UI.
  local function lines_equal(a, b)
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if a[i] ~= b[i] then
        return false
      end
    end
    return true
  end
  if lines_equal(entry.baseline, entry.latest) then
    deferred_reviews[abs_path] = nil
    return false, "No changes to review"
  end

  local ok, msg = utils.inline_diff.apply(abs_path, entry.baseline, entry.latest)
  if ok then
    -- Prepare discard support: allow reverting to baseline if requested
    active_edit_state = {
      bufnr = vim.fn.bufadd(abs_path),
      original_lines = entry.baseline,
    }
    -- Clear the accumulator now that the review is open
    deferred_reviews[abs_path] = nil
  end
  return ok, msg
end

--- Clear any stored deferred review for a file (if present).
---@param file_path string
function M.clear_deferred_review(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return
  end
  local abs_path = file_path
  if not abs_path:match("^/") and not abs_path:match("^%a:[/\\]") then
    abs_path = vim.fn.getcwd() .. "/" .. file_path
  end
  deferred_reviews[abs_path] = nil
end

return M
