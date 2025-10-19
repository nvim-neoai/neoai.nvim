local Job = require("plenary.job")
local conf = require("neoai.config").get_api("main")
local tool_schemas = require("neoai.ai_tools").tool_schemas
local api = {}

-- Track current streaming job
--- @type Job|nil  -- Current streaming job
local current_job = nil

--- Merges two tables into a new one.
--- @param t1 table  -- The first table
--- @param t2 table  -- The second table
--- @return table  -- The merged table
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
--- @param on_error fun(err: integer|string)
--- @param on_cancel fun()|nil
function api.stream(messages, on_chunk, on_complete, on_error, on_cancel)
  -- Track if we've already reported an error to avoid duplicate notifications
  local error_reported = false
  -- Buffer non-SSE stdout to recover JSON error bodies when the server doesn't stream
  local non_sse_buf = {}
  local http_status -- captured from curl --write-out
  -- Create a new job and mark it as not cancelled

  local basic_payload = {
    model = conf.model,
    max_completion_tokens = conf.max_completion_tokens,
    stream = true,
    messages = messages,
    tools = tool_schemas,
  }

  local payload = vim.fn.json_encode(merge_tables(basic_payload, conf.additional_kwargs or {}))

  -- Optional debug: show the exact JSON payload being sent to curl
  if conf.debug_payload then
    vim.notify("NeoAI: Sending JSON payload to curl (stream):\n" .. payload, vim.log.levels.DEBUG, { title = "NeoAI" })
  end

  local api_key_header = conf.api_key_header or "Authorization"
  local api_key_format = conf.api_key_format or "Bearer %s"
  local api_key_value = string.format(api_key_format, conf.api_key)
  local api_key = api_key_header .. ": " .. api_key_value

  current_job = Job:new({
    command = "curl",
    args = {
      "--silent",
      "--show-error", -- ensure errors are printed even in silent mode
      "--no-buffer",
      "--location",
      conf.url,
      "--header",
      "Content-Type: application/json",
      "--header",
      api_key,
      "--data-binary",
      "@-",
      -- Always emit the HTTP status code at the end so we can report it if no JSON error was parsed
      "--write-out",
      "\nHTTPSTATUS:%{http_code}\n",
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
              if not error_reported then
                on_complete()
              end
              return
            end

            local ok, decoded = pcall(vim.fn.json_decode, chunk)
            if not (ok and decoded) then
              return
            end

            -- Detect SSE error payloads and surface immediately
            if not error_reported and type(decoded) == "table" then
              local err_msg
              if type(decoded.error) == "table" then
                err_msg = decoded.error.message or decoded.error.type or vim.inspect(decoded.error)
              elseif decoded.error ~= nil then
                err_msg = tostring(decoded.error)
              elseif decoded.message and not decoded.choices and not decoded.delta then
                err_msg = decoded.message
              end
              if err_msg and err_msg ~= "" then
                error_reported = true
                on_error("API error: " .. tostring(err_msg))
                return
              end
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

            if not handled then
              -- Fallback handler for OpenAI Chat Completions-compatible streams
              local choice = decoded.choices and decoded.choices[1]
              if choice then
                local delta = choice.delta or {}
                local content = delta and delta.content
                local tool_calls = delta and delta.tool_calls
                local reasons = delta and delta.reasoning

                -- Emit both reasoning and content if present in the same delta
                if reasons and reasons ~= vim.NIL and reasons ~= "" then
                  on_chunk({ type = "reasoning", data = reasons })
                end
                if content and content ~= vim.NIL and content ~= "" then
                  on_chunk({ type = "content", data = content })
                end
                if tool_calls then
                  on_chunk({ type = "tool_calls", data = tool_calls })
                end

                local finished_reason = choice.finish_reason
                if finished_reason == "stop" or finished_reason == "tool_calls" then
                  on_complete()
                end
              end
            end
          end)
        else
          -- Non-SSE output: capture HTTP status and buffer any JSON body to surface real error messages
          local trimmed = vim.trim(data_line)
          -- Capture the emitted HTTP status code from curl
          local st = trimmed:match("^HTTPSTATUS:(%d+)$")
          if st then
            http_status = tonumber(st)
          else
            -- Accumulate non-SSE lines; many providers return a single-line JSON error but we guard for multi-line too
            if trimmed ~= "" then
              table.insert(non_sse_buf, trimmed)
            end
            if not error_reported then
              local aggregated = table.concat(non_sse_buf, "\n")
              local agg_trim = vim.trim(aggregated)
              local first = agg_trim:sub(1, 1)
              if first == "{" or first == "[" then
                local ok, decoded = pcall(vim.fn.json_decode, agg_trim)
                if ok and decoded then
                  local err_msg
                  if type(decoded.error) == "table" then
                    err_msg = decoded.error.message or decoded.error.type or vim.inspect(decoded.error)
                  elseif decoded.error ~= nil then
                    err_msg = tostring(decoded.error)
                  elseif type(decoded) == "table" and decoded.message and not decoded.choices then
                    -- Some providers return { message = "...", type = "..." } on errors
                    err_msg = decoded.message
                  end
                  if err_msg and err_msg ~= "" then
                    error_reported = true
                    vim.schedule(function()
                      local prefix = http_status and ("HTTP " .. tostring(http_status) .. ": ") or ""
                      on_error(prefix .. "API error: " .. tostring(err_msg))
                    end)
                  end
                end
              end
            end
          end
        end
      end
    end,
    on_stderr = function(_, line)
      if not line or line == "" then
        return
      end
      -- With --show-error, curl writes human-readable errors here. Surface immediately for network/transport errors.
      if not error_reported then
        error_reported = true
        vim.schedule(function()
          on_error("curl error: " .. tostring(line))
        end)
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
          else
            -- If curl failed at the transport level
            if exit_code ~= 0 then
              on_error(exit_code)
            else
              -- Transport OK but we may still have an HTTP error without a parsed body
              if not error_reported and http_status and http_status >= 400 then
                on_error("HTTP " .. tostring(http_status) .. " error")
              end
            end
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
--- Cancels the current streaming request if one exists.
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
