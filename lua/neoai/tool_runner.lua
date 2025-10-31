local M = {}

-- Local apply_delay mirroring chat behaviour (without notify chatter)
local function apply_delay(callback)
  local delay = 0
  local ok, cfg = pcall(require, "neoai.config")
  if ok and cfg and type(cfg.get_api) == "function" then
    local ok2, api = pcall(cfg.get_api, "main")
    if ok2 and api and type(api.api_call_delay) == "number" then
      delay = api.api_call_delay
    end
  end
  if delay <= 0 then
    callback()
  else
    vim.defer_fn(function()
      callback()
    end, delay)
  end
end

--- Execute tool calls emitted by the model, persist messages, and handle gating/iteration.
--- @param chat_module table
--- @param tool_schemas table
function M.run_tool_calls(chat_module, tool_schemas)
  local c = chat_module.chat_state
  local MT = chat_module.MESSAGE_TYPES
  local ai_tools = require("neoai.ai_tools")

  if #tool_schemas == 0 then
    vim.notify("No valid tool calls found", vim.log.levels.WARN)
    c.streaming_active = false
    return
  end

  local before_await_id = c._diff_await_id or 0
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
  chat_module.add_message(MT.ASSISTANT, call_title, {}, nil, tool_schemas)
  pcall(vim.notify, "NeoAI tool_runner: executing tool calls: " .. table.concat(call_names, ", "), vim.log.levels.DEBUG)
  local completed = 0

  -- Track whether we should pause for user review after processing tool calls
  local should_gate = false
  local deferred_to_open ---@type string|nil
  local any_deferred = false -- Saw at least one Edit call staged for deferred review

  -- Helper to extract orchestration markers from tool output
  local function parse_markers(text)
    if type(text) ~= "string" or text == "" then
      return nil, nil
    end
    local hash = text:match("NeoAI%-Diff%-Hash:%s*([%w_%-]+)")
    local diag = text:match("NeoAI%-Diagnostics%-Count:%s*(%d+)")
    return hash, (diag and tonumber(diag) or nil)
  end

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
          -- Force Edit calls to run headlessly and defer user review
          if fn.name == "Edit" then
            -- Print the raw JSON arguments for the Edit tool call to :messages
            vim.print("[NeoAI] Edit tool call JSON:", fn.arguments)

            args = args or {}
            args.interactive_review = false
            any_deferred = true
            local file_key0 = (args and args.file_path) or "<unknown>"
            if not deferred_to_open then
              deferred_to_open = file_key0
            end
          end

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
              content = type(resp) == "string" and resp or tostring(resp) or ""
            end
          end
          if content == "" then
            content = "No response"
          end
          chat_module.add_message(MT.TOOL, tostring(content), meta, schema.id)

          -- Forced iteration control: evaluate stop conditions after Edit tool
          if fn.name == "Edit" then
            local file_key = (args and args.file_path) or "<unknown>"
            c._iter_map = c._iter_map or {}
            local st = c._iter_map[file_key] or { count = 0, last_hash = nil }
            st.count = (st.count or 0) + 1

            local diff_hash, diag_count = parse_markers(content)
            local unchanged = (st.last_hash ~= nil and diff_hash ~= nil and st.last_hash == diff_hash)

            local stop = false
            if diag_count ~= nil and diag_count <= 0 then
              stop = true
            end
            if unchanged then
              stop = true
            end
            if st.count >= 3 then
              stop = true
            end

            st.last_hash = diff_hash or st.last_hash
            c._iter_map[file_key] = st

            if stop then
              should_gate = true
              if not deferred_to_open then
                deferred_to_open = file_key
              end
            end
          end

          break
        end
      end
      if not tool_found then
        local err = "Tool not found: " .. fn.name
        vim.notify(err, vim.log.levels.ERROR)
        chat_module.add_message(MT.TOOL, err, {}, schema.id)
      end
      completed = completed + 1
    end
  end

  -- Open the deferred review only when stop conditions are met (diagnostics clean/unchanged/max tries).
  -- Merely staging edits is not sufficient to gate; we keep iterating to improve before surfacing to the user.
  if should_gate and deferred_to_open and deferred_to_open ~= "" then
    local opened = false
    local ok_open, edit_mod = pcall(require, "neoai.ai_tools.edit")
    if ok_open and edit_mod and type(edit_mod.open_deferred_review) == "function" then
      local ok2 = false
      local _, _msg = pcall(function()
        local ok3, _ = edit_mod.open_deferred_review(deferred_to_open)
        ok2 = ok3 and true or false
      end)
      opened = ok2
    end

    if opened then
      c._diff_await_id = (c._diff_await_id or 0) + 1
      local await_id = c._diff_await_id or 0

      chat_module.add_message(
        MT.SYSTEM,
        "Awaiting your review in the inline diff. The assistant will resume once you finish reviewing.",
        {}
      )
      c.streaming_active = false

      c._pending_diff_reviews = (c._pending_diff_reviews or 0) + 1
      local grp_id = vim.api.nvim_create_augroup("NeoAIDiffAwait_" .. tostring(await_id), { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = grp_id,
        pattern = "NeoAIInlineDiffClosed",
        callback = function()
          -- Reset iteration state for the next cycle after the user closes the diff
          c._iter_map = {}
          c._pending_diff_reviews = math.max(0, (c._pending_diff_reviews or 0) - 1)
          if c._pending_diff_reviews == 0 then
            pcall(vim.api.nvim_del_augroup_by_id, grp_id)
            apply_delay(function()
              chat_module.send_to_ai()
            end)
          end
        end,
        once = false,
      })
      return
    end
  end

  -- If we reach here, either we did not gate, or we failed to open a review (e.g., headless). Continue the loop.
  -- If we decided to pause for review, bump the await counter once (no-op for continuation path).
  if should_gate then
    c._iter_map = {}
  end

  local after_await_id = c._diff_await_id or 0
  local new_diffs = math.max(0, after_await_id - before_await_id)
  if new_diffs > 0 then
    -- Already handled above when opened; this is a safety no-op path.
    return
  end

  if completed > 0 then
    apply_delay(function()
      chat_module.send_to_ai()
    end)
  else
    c.streaming_active = false
  end
end

return M
