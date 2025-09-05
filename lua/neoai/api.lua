local Job = require("plenary.job")
local conf = require("neoai.config").values.api
local ai_tools = require("neoai.ai_tools")
local api = {}

-- Track current streaming job
local current_job = nil

local function merge_tables(t1, t2)
  local result = {}
  for k, v in pairs(t1) do
    result[k] = v
  end
  for k, v in pairs(t2) do
    result[k] = v
  end
  return result
end

--- Start streaming completion
--- @param messages table
--- @param on_chunk fun(chunk: table)
--- @param on_complete fun()
--- @param on_error fun(code: integer)
--- @param on_cancel fun()|nil
function api.stream(messages, on_chunk, on_complete, on_error, on_cancel)
  -- Create a new job and mark it as not cancelled

  -- Prepare Responses API payload
  local function to_responses_tools(schemas)
    local out = {}
    for _, sc in ipairs(schemas or {}) do
      if sc and sc["function"] then
        local fn = sc["function"]
        table.insert(out, {
          type = "function",
          name = fn.name,
          description = fn.description,
          parameters = fn.parameters,
        })
      elseif sc and sc.type == "function" and sc.name then
        table.insert(out, sc)
      end
    end
    return out
  end

  local function to_responses_input(msgs)
    local input = {}
    for _, m in ipairs(msgs or {}) do
      local item = { role = m.role, content = m.content }
      if m.role == "tool" and m.tool_call_id then
        item.tool_call_id = m.tool_call_id
      end
      table.insert(input, item)
    end
    return input
  end

  local url = conf.url or "https://api.openai.com/v1/responses"
  if type(url) == "string" and url:find("/chat/completions") then
    url = url:gsub("/chat/completions", "/responses")
  end

  local basic_payload = {
    model = conf.model,
    stream = true,
    input = to_responses_input(messages),
    tools = to_responses_tools(ai_tools.tool_schemas),
    store = false, -- Always prevent server-side storage
  }

  if conf.max_completion_tokens ~= nil then
    basic_payload.max_output_tokens = conf.max_completion_tokens
  end

  -- Ensure callers cannot override store behaviour
  local ak = vim.deepcopy(conf.additional_kwargs or {})
  if ak and ak.store ~= nil then
    ak.store = nil
  end

  local payload = vim.fn.json_encode(merge_tables(basic_payload, ak))
  local api_key_header = conf.api_key_header or "Authorization"
  local api_key_format = conf.api_key_format or "Bearer %s"
  local api_key_value = string.format(api_key_format, conf.api_key)
  local api_key = api_key_header .. ": " .. api_key_value

  -- Track in-flight function calls for Responses streaming
  local pending_calls = {}
  local id_to_index = {}
  local next_index = 0

  local function emit_tool_delta(call_id, name, delta, idx)
    if not call_id then
      return
    end
    local rec = pending_calls[call_id]
    if not rec then
      next_index = next_index + 1
      idx = idx or next_index
      rec = {
        id = call_id,
        index = idx,
        type = "function",
        ["function"] = { name = name or "", arguments = "" },
      }
    else
      idx = rec.index
      rec["function"] = rec["function"] or { name = name or "", arguments = "" }
      if name and name ~= "" then
        rec["function"].name = name
      end
    end

    if delta and delta ~= "" then
      rec["function"].arguments = (rec["function"].arguments or "") .. delta
    end

    pending_calls[call_id] = rec

    on_chunk({
      type = "tool_calls",
      data = {
        {
          index = rec.index,
          id = rec.id,
          type = "function",
          ["function"] = {
            name = rec["function"].name,
            arguments = delta or "",
          },
        },
      },
    })
  end

  current_job = Job:new({
    command = "curl",
    args = {
      "--silent",
      "--no-buffer",
      "--location",
      url,
      "--header",
      "Content-Type: application/json",
      "--header",
      api_key,
      "--data-binary",
      "@-",
    },
    -- Send JSON payload via stdin to avoid hitting argv length limits
    writer = payload,
    on_stdout = function(_, line)
      for _, data_line in ipairs(vim.split(line, "\n")) do
        if vim.startswith(data_line, "data: ") then
          local chunk = data_line:sub(7)
          vim.schedule(function()
            -- Some providers send a terminal sentinel line
            if chunk == "[DONE]" then
              on_complete()
              return
            end

            local ok, decoded = pcall(vim.fn.json_decode, chunk)
            if not (ok and decoded) then
              return
            end

            local handled = false

            -- Handler for OpenAI Responses API-style events
            if decoded.type and type(decoded.type) == "string" then
              local t = decoded.type
              -- Reasoning deltas
              if (t == "response.reasoning_text.delta" or t == "response.reasoning.delta") and decoded.delta then
                on_chunk({ type = "reasoning", data = decoded.delta })
                handled = true
              elseif t == "response.reasoning_text.done" or t == "response.reasoning.done" then
                -- Reasoning segment finished; no-op for now
                handled = true
              end

              -- Content deltas (different providers may use slightly different names)
              if
                t == "response.output_text.delta"
                or t == "response.text.delta"
                or t == "response.delta"
                or t == "message.delta"
                or t == "response.output.delta"
              then
                local text = decoded.delta or decoded.text
                if text and text ~= "" then
                  on_chunk({ type = "content", data = text })
                end
                handled = true
              elseif t == "response.output_text.done" or t == "response.text.done" then
                local text = decoded.text
                if text and text ~= "" then
                  on_chunk({ type = "content", data = text })
                end
                handled = true
              elseif t == "response.completed" or t == "response.done" then
                on_complete()
                handled = true
              end
            end

            if not handled and decoded.type and type(decoded.type) == "string" then
              local t = decoded.type
              -- Function/tool call argument streaming (Responses API)
              if t:match("^response%.function_call") or t:match("^response%.tool_call") then
                local call_id = decoded.call_id or decoded.id or (decoded.item and decoded.item.id)
                local name = decoded.name or (decoded["function"] and decoded["function"].name)
                local idx = decoded.index or decoded.call_index
                if call_id and not id_to_index[call_id] and idx then
                  id_to_index[call_id] = idx
                end
                local delta = decoded.delta or decoded.arguments_delta or decoded.arguments
                emit_tool_delta(call_id, name, delta, id_to_index[call_id])
                handled = true
              end
            end
          end)
        end
      end
    end,
    on_exit = function(j, exit_code)
      vim.schedule(function()
        -- Only act if this exiting job is still the active one
        if current_job == j then
          current_job = nil
          if j._neoai_cancelled then
            if on_cancel then
              on_cancel()
            end
          elseif exit_code ~= 0 then
            on_error(exit_code)
          end
        end
      end)
    end,
  })

  -- Mark job as not cancelled initially
  current_job._neoai_cancelled = false
  current_job:start()
end

--- Cancel current streaming request (if any)
function api.cancel()
  local job = current_job
  if not job then
    return
  end

  -- Mark this specific job as cancelled
  job._neoai_cancelled = true

  -- For curl SSE, closing pipes (shutdown) is not sufficient; send a signal.
  -- Try SIGTERM first; if it doesn't exit quickly, escalate to SIGKILL.
  if type(job.kill) == "function" then
    pcall(function()
      job:kill(15) -- SIGTERM
    end)
  end

  -- Close stdio to avoid dangling handles
  if type(job.shutdown) == "function" then
    pcall(function()
      job:shutdown()
    end)
  end

  -- Safety net: if job is still alive shortly after, force kill
  vim.defer_fn(function()
    if current_job == job and type(job.kill) == "function" then
      pcall(function()
        job:kill(9) -- SIGKILL
      end)
    end
  end, 150)
end

return api
