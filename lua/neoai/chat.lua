local chat = {}

local multi_edit = require("neoai.ai_tools.multi_edit")

-- Ensure that the discard_all_diffs function is accessible
local ai_tools = require("neoai.ai_tools")
local prompt = require("neoai.prompt")
local storage = require("neoai.storage")
local uv = vim.loop

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
  st.frame = 1
  local text = " Thinking " .. spinner_frames[st.frame] .. " "
  st.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, thinking_ns, row, 0, {
    virt_text = { { text, "Comment" } },
    virt_text_pos = "eol",
  })
  st.timer = vim.loop.new_timer()
  st.timer:start(
    0,
    120,
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
      st.frame = (st.frame % #spinner_frames) + 1
      local t = " Thinking " .. spinner_frames[st.frame] .. " "
      if st.extmark_id then
        pcall(vim.api.nvim_buf_set_extmark, b, thinking_ns, row, 0, {
          id = st.extmark_id,
          virt_text = { { t, "Comment" } },
          virt_text_pos = "eol",
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
      prefix = "**Assistant:** *" .. ts .. "*"
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

  vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, lines)
  if chat.chat_state.config.auto_scroll then
    scroll_to_bottom(chat.chat_state.buffers.chat)
  end
end

-- Add message
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
    vim.notify("Pending diffs discarded. Continuing...", vim.log.levels.INFO)

    -- THE FIX PART 1: Invalidate the current waiting period.
    -- By incrementing the ID, we ensure that the old autocmd callback,
    -- which is still holding the *previous* ID, will know it is stale.
    chat.chat_state._diff_await_id = (chat.chat_state._diff_await_id or 0) + 1
    local unique_await_name = "NeoAIInlineDiffAwait_" .. tostring(chat.chat_state._diff_await_id)

    -- Clean up the listener and revert the buffer.
    pcall(vim.api.nvim_del_augroup_by_name, "NeoAIInlineDiffAwait")
    multi_edit.discard_all_diffs()

    -- Reset state flags.
    vim.g.neoai_inline_diff_active = false
    chat.chat_state.user_feedback = false
    chat.chat_state.streaming_active = false

    -- Get the user's new message.
    local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.input, 0, -1, false)
    local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
    if message ~= "" then
      chat.add_message(MESSAGE_TYPES.USER, message)
    end

    -- Explicitly tell the AI it was wrong.
    chat.add_message(
      MESSAGE_TYPES.SYSTEM,
      "The user has DISCARDED the previous changes. The file has been reverted to its original state. You must now address the user's latest feedback and re-evaluate the situation."
    )

    -- Continue the conversation.
    vim.api.nvim_buf_set_lines(chat.chat_state.buffers.input, 0, -1, false, { "" })
    apply_delay(function()
      chat.send_to_ai()
    end)
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
  local data = { tools = chat.format_tools() }

  local system_prompt = prompt.get_system_prompt(data)
  local messages = {
    { role = "system", content = system_prompt },
  }

  local session_msgs = storage.get_session_messages(chat.chat_state.current_session.id, 100)

  -- If this is the first user message, inject a synthetic turn with the project structure
  if #session_msgs == 2 and session_msgs[2].type == MESSAGE_TYPES.USER then
    local project_structure_text = ""
    local ok, ps_tool = pcall(require, "neoai.ai_tools.project_structure")
    if ok and ps_tool and type(ps_tool.run) == "function" then
      local ok_run, ps = pcall(ps_tool.run, { path = nil, max_depth = 2 })
      if ok_run and type(ps) == "string" then
        project_structure_text = ps
      end
    end

    if project_structure_text ~= "" then
      table.insert(messages, {
        role = "user",
        content = "To help me with my request, first provide a summary of the project structure.",
      })
      table.insert(messages, {
        role = "assistant",
        content = "Of course. Here is the project structure:\n\n" .. project_structure_text,
      })
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

  if chat.chat_state.is_open then
    local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.chat, 0, -1, false)
    table.insert(lines, "---")
    table.insert(lines, "**Assistant:** *" .. os.date("%Y-%m-%d %H:%M:%S") .. "*")
    table.insert(lines, "")
    vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, lines)
    if chat.chat_state.config.auto_scroll then
      scroll_to_bottom(chat.chat_state.buffers.chat)
    end
    start_thinking_animation()
  end

  chat.stream_ai_response(messages)
end

-- Tool call handling
function chat.get_tool_calls(tool_schemas)
  if #tool_schemas == 0 then
    vim.notify("No valid tool calls found", vim.log.levels.WARN)
    chat.chat_state.streaming_active = false
    return
  end

  local call_names = {}
  for _, sc in ipairs(tool_schemas) do
    if sc and sc["function"] and sc["function"].name and sc["function"].name ~= "" then
      table.insert(call_names, sc["function"].name)
    end
  end
  local call_title = "**Tool call**"
  if #call_names > 0 then
    call_title = "**Tool call:** " .. table.concat(call_names, ", ")
  end
  chat.add_message(MESSAGE_TYPES.ASSISTANT, call_title, {}, nil, tool_schemas)
  local completed = 0
  for _, schema in ipairs(tool_schemas) do
    if schema.type == "function" and schema["function"] and schema["function"].name then
      local fn = schema["function"]
      local ok, args = pcall(vim.fn.json_decode, fn.arguments or "")
      if not ok then
        args = {}
      end

      local tool_found = false
      for _, tool in ipairs(ai_tools.tools) do
        if tool.meta.name == fn.name then
          tool_found = true
          local resp_ok, resp = pcall(tool.run, args)
          local meta = { tool_name = fn.name }
          local content = ""
          if not resp_ok then
            content = "Error executing tool " .. fn.name .. ": " .. tostring(resp)
            vim.notify(content, vim.log.levels.ERROR)
          else
            if type(resp) == "table" then
              content = resp.content or ""
              if resp.display and resp.display ~= "" then
                meta.display = resp.display
              end
            else
              content = resp or ""
            end
          end
          if content == "" then
            content = "No response"
          end
          chat.add_message(MESSAGE_TYPES.TOOL, content, meta, schema.id)
          break
        end
      end
      if not tool_found then
        local err = "Tool not found: " .. fn.name
        vim.notify(err, vim.log.levels.ERROR)
        chat.add_message(MESSAGE_TYPES.TOOL, err, {}, schema.id)
      end
      completed = completed + 1
    end
  end

  if vim.g.neoai_inline_diff_active then
    chat.add_message(
      MESSAGE_TYPES.SYSTEM,
      "Awaiting your review in the inline diff. The assistant will resume once you finish.",
      {}
    )

    -- THE FIX PART 2: Create a new, unique waiting period.
    chat.chat_state._diff_await_id = (chat.chat_state._diff_await_id or 0) + 1
    local unique_await_name = "NeoAIInlineDiffAwait_" .. tostring(chat.chat_state._diff_await_id)
    local current_await_id = chat.chat_state._diff_await_id
    local grp = vim.api.nvim_create_augroup(unique_await_name, { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = grp,
      pattern = "NeoAIInlineDiffClosed",
      once = true,
      callback = function(ev)
        if chat.chat_state._diff_await_id ~= current_await_id then
          return
        end
        local action = ev and ev.data and ev.data.action or "closed"
        local path = ev and ev.data and ev.data.path or ""
        local msg = "Inline diff finished (" .. action .. ")"
        if path ~= "" then
          msg = msg .. ": " .. path
        end
        chat.add_message(MESSAGE_TYPES.SYSTEM, msg, {})
        vim.g.neoai_inline_diff_active = false
        apply_delay(function()
          chat.send_to_ai()
        end)
      end,
    })
    local current_await_id = chat.chat_state._diff_await_id

    local grp = vim.api.nvim_create_augroup(unique_await_name, { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = grp,
      pattern = "NeoAIInlineDiffClosed",
      once = true,
      callback = function(ev)
        -- This guard clause is now robust. The stale callback will hold an old ID
        -- and will be blocked from running, preventing the race condition.
        -- Confirm ID consistency to prevent race conditions.
        if chat.chat_state._diff_await_id ~= current_await_id then
          return
        end

        local action = ev and ev.data and ev.data.action or "closed"
        local path = ev and ev.data and ev.data.path or ""
        local msg = "Inline diff finished (" .. action .. ")"
        if path ~= "" then
          msg = msg .. ": " .. path
        end
        chat.add_message(MESSAGE_TYPES.SYSTEM, msg, {})
        -- After user feedback, ensure we await user resolution of diffs correctly.
        vim.g.neoai_inline_diff_active = false
        -- Reset state flags to prepare for new user interaction.
        apply_delay(function()
          chat.send_to_ai()
        end)
      end,
    })
    return
  end

  if completed > 0 then
    apply_delay(function()
      chat.send_to_ai()
    end)
  else
    chat.chat_state.streaming_active = false
  end
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
  local tool_prep_seen = false
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

    local header = "Preparing tool calls…"
    if #per_call > 0 then
      header = header .. string.format(" (total %s)", human_bytes(total))
    end
    local body = table.concat(per_call, "\n")
    local display = header
    if body ~= "" then
      display = display .. "\n" .. body
    end
    chat.update_streaming_message(reason, display)
  end

  if chat.chat_state._timeout_timer then
    safe_stop_and_close_timer(chat.chat_state._timeout_timer)
    chat.chat_state._timeout_timer = nil
  end

  local timeout_duration_s = require("neoai.config").values.chat.thinking_timeout or 200
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
    if not saw_first_token then
      saw_first_token = true
      stop_thinking_animation()
      safe_stop_and_close_timer(thinking_timeout_timer)
      chat.chat_state._timeout_timer = nil
    end

    if chunk.type == "content" and chunk.data ~= "" then
      content = content .. chunk.data
      chat.update_streaming_message(reason, content)
    elseif chunk.type == "reasoning" and chunk.data ~= "" then
      reason = reason .. chunk.data
      chat.update_streaming_message(reason, content)
    elseif chunk.type == "tool_calls" then
      if chunk.data and type(chunk.data) == "table" then
        tool_prep_seen = true
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
        render_tool_prep_status()
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

    -- If no tool calls are pending, it means this is a final text response from the AI.
    -- In this case, save the content as the assistant's message.
    -- If tool calls ARE pending, we do nothing here and let get_tool_calls handle the UI.
    if #tool_calls_response == 0 then
      if content ~= "" then
        chat.add_message(MESSAGE_TYPES.ASSISTANT, content, { response_time = os.time() - start_time })
      end
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
    chat.add_message(MESSAGE_TYPES.ERROR, "AI error: " .. tostring(exit_code), {})
    update_chat_display()
    disable_ctrl_c_cancel()
    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end
  end, function()
    if not chat.chat_state.streaming_active then
      return
    end
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
  end)
end

-- Update streaming display (shows reasoning and content as they arrive)
function chat.update_streaming_message(reason, content)
  if not chat.chat_state.is_open or not chat.chat_state.streaming_active then
    return
  end
  local display = ""
  if reason and reason ~= "" then
    display = display .. "<think>\n" .. reason .. "\n</think>\n\n"
  end
  if content and content ~= "" then
    display = display .. content
  end
  local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.chat, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("^%*%*Assistant:%*%*") then
      local new_lines = {}
      for j = 1, i - 1 do
        table.insert(new_lines, lines[j])
      end
      table.insert(new_lines, "**Assistant:** *" .. os.date("%Y-%m-%d %H:%M:%S") .. "*")
      table.insert(new_lines, "")
      for _, ln in ipairs(vim.split(display, "\n")) do
        table.insert(new_lines, "  " .. ln)
      end
      table.insert(new_lines, "")
      vim.api.nvim_buf_set_lines(chat.chat_state.buffers.chat, 0, -1, false, new_lines)
      if chat.chat_state.config.auto_scroll then
        scroll_to_bottom(chat.chat_state.buffers.chat)
      end
      break
    end
  end
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
  local was_open = chat.chat_state.is_open
  local ok = chat.clear_session()
  if not was_open then
    chat.open()
  end
  return ok
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
