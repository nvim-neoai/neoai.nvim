local chat = {}

-- Ensure that the discard_all_diffs function is accessible
local ai_tools = require("neoai.ai_tools")
local prompt = require("neoai.prompt")
local storage = require("neoai.storage")
local uv = vim.loop

-- Helper: get the configured "main" model name (if available)
local function get_main_model_name()
  local ok, cfg = pcall(require, "neoai.config")
  if not ok or not cfg or type(cfg.get_api) ~= "function" then
    return nil
  end
  local ok2, api = pcall(function()
    return cfg.get_api("main")
  end)
  if not ok2 or not api then
    return nil
  end
  local model = api.model
  if type(model) ~= "string" or model == "" then
    return nil
  end
  return model
end

-- Helper: build the Assistant header including the model name when available
local function build_assistant_header(time_str)
  local model = get_main_model_name()
  if model then
    return "**Assistant:** (" .. model .. ") *" .. time_str .. "*"
  else
    return "**Assistant:** *" .. time_str .. "*"
  end
end

-- Safe helper to stop and close a libuv timer without throwing when it's already closing
local function safe_stop_and_close_timer(t)
  if not t then
    return
  end
  -- If handle is already closing, do nothing
  local closing = false
  if uv and uv.is_closing then
    local ok, cl = pcall(uv.is_closing, t)
    closing = ok and cl or false
  end
  if closing then
    return
  end
  -- Stop the timer (may no-op if not started)
  pcall(function()
    if t.stop then
      t:stop()
    end
  end)
  -- Close if not already closing
  if uv and uv.is_closing then
    local ok2, cl2 = pcall(uv.is_closing, t)
    if ok2 and cl2 then
      return
    end
  end
  pcall(function()
    if t.close then
      t:close()
    end
  end)
end

-- Treesitter helpers to avoid crashes during streaming updates of partial Markdown/code
local function ts_suspend(bufnr)
  local ok, ts = pcall(require, "vim.treesitter")
  if ok and ts.stop and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(ts.stop, bufnr)
  end
end

local function ts_resume(bufnr)
  local ok, ts = pcall(require, "vim.treesitter")
  if ok and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    ---@diagnostic disable-next-line: undefined-field
    if ts.start then
      -- Reattach markdown parser
      pcall(ts.start, bufnr, "markdown")
    else
      -- Fallback: re-set filetype to trigger reattach
      pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", "markdown")
    end
  end
end

-- Thinking animation (spinner) helpers
local thinking_ns = vim.api.nvim_create_namespace("NeoAIThinking")
-- Use simple ASCII spinner for broad compatibility
local spinner_frames = { "|", "/", "-", "\\" }

-- Format a duration in seconds into a compact human-friendly string (e.g., 1m 33s)
local function fmt_duration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  local parts = {}
  if h > 0 then
    table.insert(parts, string.format("%dh", h))
  end
  if m > 0 or h > 0 then
    table.insert(parts, string.format("%dm", m))
  end
  table.insert(parts, string.format("%ds", s))
  return table.concat(parts, " ")
end

local function find_last_assistant_header_row()
  local bufnr = chat.chat_state and chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("^%*%*Assistant:%*%*") then
      return i - 1 -- 0-based row index
    end
  end
  return nil
end

local function stop_thinking_animation()
  local st = chat.chat_state and chat.chat_state.thinking or nil
  if not st then
    return
  end
  if st.timer then
    safe_stop_and_close_timer(st.timer)
    st.timer = nil
  end
  if
    st.extmark_id
    and chat.chat_state.buffers
    and chat.chat_state.buffers.chat
    and vim.api.nvim_buf_is_valid(chat.chat_state.buffers.chat)
  then
    pcall(vim.api.nvim_buf_del_extmark, chat.chat_state.buffers.chat, thinking_ns, st.extmark_id)
  end
  st.extmark_id = nil
  st.active = false
end

-- Ensure the thinking status (virt_lines) is visible with minimal scrolling
local function ensure_thinking_visible()
  if not (chat.chat_state and chat.chat_state.config and chat.chat_state.config.auto_scroll) then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  local st = chat.chat_state and chat.chat_state.thinking or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and st and st.extmark_id) then
    return
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, thinking_ns, st.extmark_id, {})
  if not ok or not pos or pos[1] == nil then
    return
  end
  local target = pos[1] + 1 -- 1-based line number of the header/anchor
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      -- Temporarily disable scrolloff to avoid re-centring (common with so=999)
      local orig_so
      local ok_get_so, so = pcall(function()
        return vim.wo[win].scrolloff
      end)
      if ok_get_so then
        orig_so = so
        pcall(function()
          vim.wo[win].scrolloff = 0
        end)
      end

      -- Query the current visible range for this window
      local view_ok, top, bot = pcall(function()
        return vim.api.nvim_win_call(win, function()
          return vim.fn.line("w0"), vim.fn.line("w$")
        end)
      end)

      if view_ok and top and bot then
        if target < top then
          -- Reveal just enough upwards: put target at the top
          pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
          pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("normal! zt")
          end)
        elseif target > bot then
          -- Reveal just enough downwards: put target at the bottom
          pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
          pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("normal! zb")
          end)
        else
          -- Already visible: do nothing
        end
      else
        -- Fallback: align to bottom rather than centring
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
        pcall(vim.api.nvim_win_call, win, function()
          vim.cmd("normal! zb")
        end)
      end

      -- Restore user's original scrolloff
      if orig_so ~= nil then
        pcall(function()
          vim.wo[win].scrolloff = orig_so
        end)
      end
    end
  end
end

-- Capture the current thinking duration and mark it to be announced when streaming begins
local function capture_thinking_duration_for_announce()
  local st = chat.chat_state and chat.chat_state.thinking or nil
  if not st then
    return
  end
  local secs = 0
  if st.start_time then
    secs = os.time() - st.start_time
  end
  st.last_duration_str = fmt_duration(secs)
  st.announce_pending = true
  stop_thinking_animation()
end

local function start_thinking_animation()
  if not (chat.chat_state and chat.chat_state.is_open) then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local row = find_last_assistant_header_row()
  if not row then
    return
  end

  local st = chat.chat_state.thinking
  -- Reset any previous state
  stop_thinking_animation()

  st.active = true
  st.start_time = os.time()
  st.announce_pending = false
  st.last_duration_str = nil

  local text = " Thinking… 0s "
  st.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, thinking_ns, row, 0, {
    virt_lines = {
      { { "", "Comment" } },
      { { text, "Comment" } },
    },
    virt_lines_above = false,
  })

  -- Auto-reveal the thinking status so it is visible without manual scrolling
  ensure_thinking_visible()

  st.timer = vim.loop.new_timer()
  st.timer:start(
    0,
    1000,
    vim.schedule_wrap(function()
      if not st.active then
        return
      end
      if
        not (
          chat.chat_state
          and chat.chat_state.buffers
          and chat.chat_state.buffers.chat
          and vim.api.nvim_buf_is_valid(chat.chat_state.buffers.chat)
        )
      then
        return
      end
      local b = chat.chat_state.buffers.chat
      local elapsed = 0
      if st.start_time then
        elapsed = os.time() - st.start_time
      end
      local t = " Thinking… " .. fmt_duration(elapsed) .. " "
      if st.extmark_id then
        pcall(vim.api.nvim_buf_set_extmark, b, thinking_ns, row, 0, {
          id = st.extmark_id,
          virt_lines = {
            { { "", "Comment" } },
            { { t, "Comment" } },
          },
          virt_lines_above = false,
        })
      end
    end)
  )
end

-- Apply rate limit delay before AI API calls
local function apply_delay(callback)
  local delay = require("neoai.config").get_api("main").api_call_delay or 0
  if delay <= 0 then
    callback()
  else
    vim.notify("NeoAI: Waiting " .. delay .. "ms for rate limit", vim.log.levels.INFO)
    vim.defer_fn(function()
      callback()
    end, delay)
  end
end

-- Ctrl-C cancel listener (global) so it works even if mappings are bypassed
local CTRL_C_NS = vim.api.nvim_create_namespace("NeoAICtrlC")
local CTRL_C_KEY = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)

local function enable_ctrl_c_cancel()
  if not chat.chat_state then
    return
  end
  if chat.chat_state._ctrlc_enabled then
    return
  end
  chat.chat_state._ctrlc_enabled = true
  vim.on_key(function(keys)
    -- Only act when a stream is active
    if not (chat.chat_state and chat.chat_state.streaming_active) then
      return
    end
    if keys ~= CTRL_C_KEY then
      return
    end
    -- Restrict cancellation to chat or input buffers
    local cur = vim.api.nvim_get_current_buf()
    local bchat = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
    local binput = chat.chat_state.buffers and chat.chat_state.buffers.input or nil
    if cur == bchat or cur == binput then
      vim.schedule(function()
        require("neoai.chat").cancel_stream()
      end)
    end
  end, CTRL_C_NS)
end

local function disable_ctrl_c_cancel()
  if chat.chat_state and chat.chat_state._ctrlc_enabled then
    pcall(vim.on_key, nil, CTRL_C_NS)
    chat.chat_state._ctrlc_enabled = false
  end
end

-- Message types
local MESSAGE_TYPES = {
  USER = "user",
  ASSISTANT = "assistant",
  TOOL = "tool",
  SYSTEM = "system",
  THINKING = "thinking",
  ERROR = "error",
}

-- Setup function
function chat.setup()
  ai_tools.setup()

  chat.chat_state = {
    config = require("neoai.config").values.chat,
    windows = {},
    buffers = {},
    current_session = nil,
    sessions = {},
    is_open = false,
    streaming_active = false,
    _timeout_timer = nil,
    _ts_suspended = false,
    thinking = { active = false, timer = nil, extmark_id = nil, frame = 1 },
    _diff_await_id = 0, -- This is necessary for the fix.
    _iter_map = {}, -- Track per-file iteration state for edit+diagnostic loop
  }

  -- Initialise storage backend
  local success = storage.init(chat.chat_state.config)
  assert(success, "NeoAI: Failed to initialise storage")

  -- Load or create session
  chat.chat_state.current_session = storage.get_active_session()
  if not chat.chat_state.current_session then
    chat.new_session()
  end

  -- Load sessions for UI
  chat.chat_state.sessions = storage.get_all_sessions()
end

-- Scroll helper
local function scroll_to_bottom(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, win in pairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_win_set_cursor(win, { line_count, 0 })
      break
    end
  end
end

-- Update chat display
local function update_chat_display()
  if not chat.chat_state.is_open or not chat.chat_state.current_session then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  local lines = {}
  local sess = chat.chat_state.current_session
  assert(sess, "NeoAI: Failed to initialise session")
  local messages = storage.get_session_messages(sess.id)

  table.insert(lines, " **NeoAI Chat** ")
  table.insert(lines, " *Session: " .. (sess.title or "Untitled") .. "* ")
  table.insert(lines, " *ID: " .. sess.id .. " | Messages: " .. #messages .. "* ")
  table.insert(lines, " *Created: " .. sess.created_at .. "* ")
  if #chat.chat_state.sessions > 1 then
    table.insert(
      lines,
      " *Total Sessions: " .. #chat.chat_state.sessions .. " | Use :NeoAISessionList or `<leader>as` to switch* "
    )
  end
  table.insert(lines, "")

  for _, message in ipairs(messages) do
    local prefix = ""
    local ts = message.metadata and message.metadata.timestamp or message.created_at or "Unknown"
    if message.type == MESSAGE_TYPES.USER then
      prefix = "**User:** *" .. ts .. "*"
    elseif message.type == MESSAGE_TYPES.ASSISTANT then
      prefix = build_assistant_header(ts)
      if message.metadata and message.metadata.response_time then
        prefix = prefix:gsub("%*$", " (" .. message.metadata.response_time .. "s)*")
      end
    elseif message.type == MESSAGE_TYPES.TOOL then
      local tooln = (message.metadata and message.metadata.tool_name) or nil
      if tooln and tooln ~= "" then
        prefix = "**Tool Response (" .. tooln .. ")**: *" .. ts .. "*"
      else
        prefix = "**Tool Response:** *" .. ts .. "*"
      end
    elseif message.type == MESSAGE_TYPES.SYSTEM then
      prefix = "**System:** *" .. ts .. "*"
    elseif message.type == MESSAGE_TYPES.ERROR then
      prefix = "**Error:** *" .. ts .. "*"
    end

    table.insert(lines, "---")
    table.insert(lines, prefix)
    table.insert(lines, "")
    -- Prefer display text (if provided) to avoid cluttering the chat UI
    local display_content = message.content or ""
    if message.metadata and message.metadata.display and message.metadata.display ~= "" then
      display_content = message.metadata.display
    end
    for _, line in ipairs(vim.split(display_content, "\n")) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if chat.chat_state.config.auto_scroll then
    scroll_to_bottom(bufnr)
  end
end

-- Add message
---@param type string
---@param content string
---@param metadata table | nil
---@param tool_call_id string | nil
---@param tool_calls any
function chat.add_message(type, content, metadata, tool_call_id, tool_calls)
  if type == MESSAGE_TYPES.USER then
    chat.chat_state.user_feedback = true -- Track that feedback occurred
  end
  metadata = metadata or {}
  metadata.timestamp = metadata.timestamp or os.date("%Y-%m-%d %H:%M:%S")

  local msg_id =
    storage.add_message(chat.chat_state.current_session.id, type, content, metadata, tool_call_id, tool_calls)
  if not msg_id then
    vim.notify("Failed to save message to storage", vim.log.levels.ERROR)
  end

  if chat.chat_state.is_open then
    update_chat_display()
  end
end

-- New session
function chat.new_session(title)
  title = title or ("Session " .. os.date("%Y-%m-%d %H:%M:%S"))
  local session_id = storage.create_session(title, {})
  assert(session_id, "NeoAI: Failed to create new session")

  chat.chat_state.current_session = storage.get_active_session()
  chat.chat_state.sessions = storage.get_all_sessions()

  chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", { session_id = session_id })
  vim.notify("Created new session: " .. title, vim.log.levels.INFO)
end

-- Open/close/toggle
function chat.open()
  local ui = require("neoai.ui")
  local keymaps = require("neoai.keymaps")
  ui.open()
  keymaps.buffer_setup()
  chat.chat_state.is_open = true
  update_chat_display()
end

function chat.close()
  -- Ensure any active thinking animation is stopped when closing the UI
  stop_thinking_animation()
  disable_ctrl_c_cancel()
  require("neoai.ui").close()
  chat.chat_state.is_open = false
end

function chat.toggle()
  if chat.chat_state.is_open then
    chat.close()
  else
    chat.open()
  end
end

-- Send message
function chat.send_message()
  if chat.chat_state.streaming_active and chat.chat_state.user_feedback then
    -- Ensure we do not open any extra confirmation prompts here.
    -- Inline diff UI (utils/inline_diff.lua) is the single source of truth for review/approval.
    vim.notify("Pending diffs handled. Awaiting inline diff review.", vim.log.levels.INFO)
    return
  end

  if chat.chat_state.streaming_active then
    vim.notify("Please wait for the current response to complete", vim.log.levels.WARN)
    return
  end

  -- Normal message handling.
  local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.input, 0, -1, false)
  local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
  if message == "" then
    return
  end

  chat.add_message(MESSAGE_TYPES.USER, message)
  vim.api.nvim_buf_set_lines(chat.chat_state.buffers.input, 0, -1, false, { "" })
  apply_delay(function()
    chat.send_to_ai()
  end)
end

-- Send to AI
function chat.send_to_ai()
  -- Prepare template data: tools and optional AGENTS.md content
  local agents_md = nil
  do
    -- Try to locate AGENTS.md at repo root or current working directory
    local candidate_paths = {}
    -- 1) If inside a git repo, detect its root
    local git_root = nil
    pcall(function()
      local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
      if handle then
        local out = handle:read("*a") or ""
        handle:close()
        out = (out:gsub("\r", ""):gsub("\n", ""))
        if out ~= "" then
          git_root = out
        end
      end
    end)
    local cwd = vim.loop.cwd()
    local roots = {}
    if git_root and git_root ~= "" then
      table.insert(roots, git_root)
    end
    if cwd and cwd ~= git_root then
      table.insert(roots, cwd)
    end

    for _, root in ipairs(roots) do
      table.insert(candidate_paths, root .. "/AGENTS.md")
      table.insert(candidate_paths, root .. "/agents.md")
    end

    for _, path in ipairs(candidate_paths) do
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a") or ""
        f:close()
        content = (content:gsub("^%s+", ""):gsub("%s+$", ""))
        if content ~= "" then
          agents_md = "---\n## 📘 Project AGENTS.md\n\n" .. content .. "\n---"
          break
        end
      end
    end
  end

  local data = {
    tools = chat.format_tools(),
    agents = agents_md or "",
  }

  local system_prompt = prompt.get_system_prompt(data)
  local messages = {
    { role = "system", content = system_prompt },
  }

  local session_msgs = storage.get_session_messages(chat.chat_state.current_session.id, 100)

  -- Bootstrap pre-flight: force selected tool calls before the first real AI turn.
  do
    local boot = (chat.chat_state and chat.chat_state.config and chat.chat_state.config.bootstrap) or nil
    local is_first_turn = (#session_msgs == 2 and session_msgs[2].type == MESSAGE_TYPES.USER)
    if boot and boot.enabled and is_first_turn then
      require("neoai.bootstrap").run_preflight(chat, boot)
      -- Refresh session messages so the subsequent payload includes the bootstrap turn
      session_msgs = storage.get_session_messages(chat.chat_state.current_session.id, 100)
    end
  end

  -- Append recent conversation
  local recent = {}
  for i = #session_msgs, 1, -1 do
    local msg = session_msgs[i]
    if msg.type == MESSAGE_TYPES.USER or msg.type == MESSAGE_TYPES.ASSISTANT or msg.type == MESSAGE_TYPES.TOOL then
      table.insert(recent, 1, msg)
      if #recent >= 100 then
        break
      end
    end
  end

  for _, msg in ipairs(recent) do
    table.insert(messages, {
      role = msg.type,
      content = msg.content,
      tool_calls = msg.tool_calls,
      tool_call_id = msg.tool_call_id,
    })
  end

  if
    chat.chat_state.is_open
    and chat.chat_state.buffers
    and chat.chat_state.buffers.chat
    and vim.api.nvim_buf_is_valid(chat.chat_state.buffers.chat)
  then
    local bufnr = chat.chat_state.buffers.chat
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    table.insert(lines, "---")
    table.insert(lines, build_assistant_header(os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(lines, "")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if chat.chat_state.config.auto_scroll then
      scroll_to_bottom(bufnr)
    end
    start_thinking_animation()
  end

  chat.stream_ai_response(messages)
end

-- Tool call handling
---@param tool_schemas table
function chat.get_tool_calls(tool_schemas)
  return require("neoai.tool_runner").run_tool_calls(chat, tool_schemas)
end

-- Format tools
function chat.format_tools()
  local names = {}
  for _, tool in ipairs(ai_tools.tool_schemas) do
    if tool.type == "function" and tool["function"] and tool["function"].name then
      table.insert(names, tool["function"].name)
    end
  end
  return table.concat(names, ", ")
end

-- Stream AI response
function chat.stream_ai_response(messages)
  local api = require("neoai.api")
  chat.chat_state.streaming_active = true
  enable_ctrl_c_cancel()

  if chat.chat_state.is_open and chat.chat_state.buffers.chat and not chat.chat_state._ts_suspended then
    ts_suspend(chat.chat_state.buffers.chat)
    chat.chat_state._ts_suspended = true
  end

  local reason, content, tool_calls_response = "", "", {}
  local start_time = os.time()
  local saw_first_token = false
  local has_completed = false

  local function human_bytes(n)
    if not n or n <= 0 then
      return "0 B"
    end
    if n < 1024 then
      return string.format("%d B", n)
    elseif n < 1024 * 1024 then
      return string.format("%.1f KB", n / 1024)
    elseif n < 1024 * 1024 * 1024 then
      return string.format("%.2f MB", n / (1024 * 1024))
    else
      return string.format("%.2f GB", n / (1024 * 1024 * 1024))
    end
  end

  local function render_tool_prep_status()
    local per_call = {}
    local total = 0
    for _, tc in ipairs(tool_calls_response) do
      local name = (tc["function"] and tc["function"].name) or (tc.type or "function")
      local args = (tc["function"] and tc["function"].arguments) or ""
      local size = #args
      total = total + size
      table.insert(per_call, string.format("- %s: %s", name ~= "" and name or "function", human_bytes(size)))
    end

    local header = "\nPreparing tool calls…"
    if #per_call > 0 then
      header = header .. string.format(" (total %s)", human_bytes(total))
    end
    local body = table.concat(per_call, "\n")
    local display = header
    if body ~= "" then
      display = display .. "\n" .. body
    end
    return display
  end

  if chat.chat_state._timeout_timer then
    safe_stop_and_close_timer(chat.chat_state._timeout_timer)
    chat.chat_state._timeout_timer = nil
  end

  local timeout_duration_s = require("neoai.config").values.chat.thinking_timeout or 300
  local thinking_timeout_timer = vim.loop.new_timer()
  chat.chat_state._timeout_timer = thinking_timeout_timer

  local function handle_timeout()
    if has_completed then
      return
    end
    has_completed = true

    if not chat.chat_state.streaming_active then
      return
    end
    chat.chat_state.streaming_active = false
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
    stop_thinking_animation()
    disable_ctrl_c_cancel()

    local err_msg = "NeoAI: Timed out after " .. timeout_duration_s .. "s waiting for a response."
    chat.add_message(MESSAGE_TYPES.ERROR, err_msg, { timeout = true })
    update_chat_display()
    vim.notify(err_msg, vim.log.levels.ERROR)

    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end

    require("neoai.api").cancel()
  end

  thinking_timeout_timer:start(timeout_duration_s * 1000, 0, vim.schedule_wrap(handle_timeout))
  api.stream(messages, function(chunk)
    chat.tool_prep_status = nil -- Reset tool preparation status at stream end or during error completion

    if not saw_first_token then
      saw_first_token = true
      capture_thinking_duration_for_announce()
      safe_stop_and_close_timer(thinking_timeout_timer)
      chat.chat_state._timeout_timer = nil
    end

    if chunk.type == "content" and chunk.data ~= "" then
      content = tostring(content) .. chunk.data
      chat.update_streaming_message(reason, tostring(content or ""), false)
    elseif chunk.type == "reasoning" and chunk.data ~= "" then
      reason = reason .. chunk.data
      chat.update_streaming_message(reason, tostring(content), false)
    elseif chunk.type == "tool_calls" then
      if chunk.data and type(chunk.data) == "table" then
        for _, tool_call in ipairs(chunk.data) do
          if tool_call and tool_call.index then
            local found = false
            for _, existing_call in ipairs(tool_calls_response) do
              if existing_call.index == tool_call.index then
                if tool_call["function"] then
                  existing_call["function"] = existing_call["function"] or {}
                  if tool_call["function"].name and tool_call["function"].name ~= "" then
                    existing_call["function"].name = tool_call["function"].name
                  end
                  if tool_call["function"].arguments and tool_call["function"].arguments ~= "" then
                    existing_call["function"].arguments = (existing_call["function"].arguments or "")
                      .. tool_call["function"].arguments
                  end
                end
                found = true
                break
              end
            end
            if not found then
              local complete_tool_call = {
                index = tool_call.index,
                id = tool_call.id,
                type = tool_call.type or "function",
                ["function"] = {
                  name = tool_call["function"] and tool_call["function"].name or "",
                  arguments = tool_call["function"] and tool_call["function"].arguments or "",
                },
              }
              table.insert(tool_calls_response, complete_tool_call)
            end
          end
        end
        local prep_status = render_tool_prep_status()
        chat.update_streaming_message(prep_status, tostring(content or ""), false)
      end
    end
  end, function()
    if has_completed then
      return
    end
    has_completed = true

    if not chat.chat_state.streaming_active then
      return
    end
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
    stop_thinking_animation()

    -- Persist any streamed assistant content before handling tool calls, so it remains visible in the chat.
    if content ~= "" then
      chat.add_message(MESSAGE_TYPES.ASSISTANT, content, { response_time = os.time() - start_time })
    end
    update_chat_display()

    disable_ctrl_c_cancel()

    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end

    if #tool_calls_response > 0 then
      chat.get_tool_calls(tool_calls_response)
    else
      chat.chat_state.streaming_active = false
    end
  end, function(exit_code)
    if has_completed then
      return
    end
    has_completed = true

    if not chat.chat_state.streaming_active then
      return
    end
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
    chat.chat_state.streaming_active = false
    stop_thinking_animation()
    local err_text = "AI error: " .. tostring(exit_code)
    chat.add_message(MESSAGE_TYPES.ERROR, err_text, {})
    update_chat_display()
    -- Also show a notification so the user is immediately aware
    vim.notify("NeoAI: " .. err_text, vim.log.levels.ERROR)
    disable_ctrl_c_cancel()
    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end
    -- Ensure any underlying job is terminated promptly
    pcall(function()
      require("neoai.api").cancel()
    end)
  end, function()
    if not chat.chat_state.streaming_active then
      return
    end
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
  end)
end

-- Update streaming display (shows reasoning and content as they arrive)
---@param reason string | nil
---@param content string | nil
---@param append boolean
function chat.update_streaming_message(reason, content, append)
  if not chat.chat_state.is_open or not chat.chat_state.streaming_active then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local display = ""
  -- Insert the thinking duration announcement (if any) at the very top, just once
  local st_ = chat.chat_state and chat.chat_state.thinking or nil
  if st_ and st_.announce_pending and st_.last_duration_str and st_.last_duration_str ~= "" then
    display = display .. "Thought for " .. st_.last_duration_str .. "\n\n"
    st_.announce_pending = false
  end
  -- Ensure the "Preparing tool calls…" status appears below already streamed text, while
  -- keeping any general reasoning text (when present) above the content as before.
  local prep_status
  if type(reason) == "string" and reason:find("Preparing tool calls") then
    -- Trim any leading newlines so spacing remains tidy when appended below.
    prep_status = reason:gsub("^%s*\n+", "")
    reason = nil
  end

  if reason and reason ~= "" then
    display = display .. reason .. "\n\n"
  end
  if content and content ~= "" then
    display = display .. tostring(content)
  end
  if prep_status and prep_status ~= "" then
    if display ~= "" then
      display = display .. "\n\n" .. prep_status
    else
      display = prep_status
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("^%*%*Assistant:%*%*") then
      local new_lines = {}
      for j = 1, i - 1 do
        table.insert(new_lines, lines[j])
      end
      table.insert(new_lines, build_assistant_header(os.date("%Y-%m-%d %H:%M:%S")))

      table.insert(new_lines, "")
      for _, ln in ipairs(vim.split(display, "\n")) do
        table.insert(new_lines, "  " .. ln)
      end
      table.insert(new_lines, "")
      vim.api.nvim_buf_set_lines(bufnr, append and #lines or 0, -1, false, new_lines)
      if chat.chat_state.config.auto_scroll then
        scroll_to_bottom(bufnr)
      end
      break
    end
  end
end

-- Append content to current stream
---@param reason string | nil
---@param content string | nil
---@param extra string | nil
function chat.append_to_streaming_message(reason, content, extra)
  if not chat.chat_state.is_open or not chat.chat_state.streaming_active then
    return
  end
  local final_content = content or ""
  if type(extra) == "string" and extra ~= "" then
    if final_content ~= "" then
      final_content = final_content .. "\n"
    end
    final_content = final_content .. extra
  end
  chat.update_streaming_message(reason, final_content, true)
end

-- Allow cancelling current stream
function chat.cancel_stream()
  if chat.chat_state.streaming_active then
    chat.chat_state.streaming_active = false
    chat.chat_state.user_feedback = true

    stop_thinking_animation()
    local t = chat.chat_state._timeout_timer
    if t then
      safe_stop_and_close_timer(t)
      chat.chat_state._timeout_timer = nil
    end

    disable_ctrl_c_cancel()

    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end

    if chat.chat_state.is_open then
      update_chat_display()
    end

    local api = require("neoai.api")
    api.cancel()
  end
end

-- Cancel stream if active, otherwise close chat
function chat.cancel_or_close()
  if chat.chat_state.streaming_active then
    chat.cancel_stream()
  else
    chat.close()
  end
end

-- Session info and management
function chat.get_session_info()
  local msgs = storage.get_session_messages(chat.chat_state.current_session.id)
  return {
    id = chat.chat_state.current_session.id,
    title = chat.chat_state.current_session.title,
    created_at = chat.chat_state.current_session.created_at,
    message_count = #msgs,
  }
end

function chat.switch_session(session_id)
  local success = storage.switch_session(session_id)
  if success then
    chat.chat_state.current_session = storage.get_active_session()
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then
      update_chat_display()
    end
  end
  return success
end

function chat.get_all_sessions()
  return storage.get_all_sessions()
end

function chat.delete_session(session_id)
  local sessions = storage.get_all_sessions()
  if #sessions <= 1 then
    vim.notify("Cannot delete the only session", vim.log.levels.WARN)
    return false
  end
  local is_current = chat.chat_state.current_session.id == session_id
  local success = storage.delete_session(session_id)
  if success then
    if is_current then
      local rem = storage.get_all_sessions()
      if #rem > 0 then
        chat.switch_session(rem[1].id)
      else
        chat.new_session()
      end
    end
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then
      update_chat_display()
    end
  end
  return success
end

function chat.rename_session(new_title)
  local success = storage.update_session_title(chat.chat_state.current_session.id, new_title)
  if success then
    chat.chat_state.current_session.title = new_title
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then
      update_chat_display()
    end
    vim.notify("Session renamed to: " .. new_title, vim.log.levels.INFO)
  end
  return success
end

function chat.clear_session()
  local success = storage.clear_session_messages(chat.chat_state.current_session.id)
  if success then
    chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", {})
    if chat.chat_state.is_open then
      update_chat_display()
    end
  end
  return success
end

--- Open chat (if not open) and clear the current session so the user sees a fresh chat
function chat.open_and_clear()
  -- Always attempt to open (ui.open is idempotent and also repairs stale state)
  chat.open()
  return chat.clear_session()
end

function chat.get_stats()
  return storage.get_stats()
end

function chat.lookup_messages(term)
  if term == "" then
    vim.notify("Provide a search term", vim.log.levels.WARN)
    return
  end
  local results = {}
  for _, m in ipairs(storage.get_session_messages(chat.chat_state.current_session.id)) do
    if m.content:find(term, 1, true) then
      table.insert(results, m)
    end
  end
  vim.cmd("botright new")
  vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile, vim.bo.filetype = "nofile", "wipe", false, "markdown"
  local lines = { "# Lookup messages containing '" .. term .. "'", "" }
  if #results == 0 then
    table.insert(lines, "No messages found.")
  else
    for _, m in ipairs(results) do
      local ts = m.metadata and m.metadata.timestamp or m.created_at or "Unknown"
      table.insert(lines, "- **" .. m.type .. "** at *" .. ts .. "*")
      table.insert(lines, "```")
      table.insert(lines, m.content)
      table.insert(lines, "```")
      table.insert(lines, "")
    end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modifiable = false
end

-- Export
chat.MESSAGE_TYPES = MESSAGE_TYPES
return chat
