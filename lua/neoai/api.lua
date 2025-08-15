local Job = require("plenary.job")
local conf = require("neoai.config").values.api
local tool_schemas = require("neoai.ai_tools").tool_schemas
local api = {}

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

function api.stream(messages, on_chunk, on_complete, on_error)
  local basic_payload = {
    model = conf.model,
    max_completion_tokens = conf.max_completion_tokens,
    stream = true,
    messages = messages,
    tools = tool_schemas,
  }

  local payload = vim.fn.json_encode(merge_tables(basic_payload, conf.additional_kwargs or {}))
  local api_key_header = conf.api_key_header or "Authorization"
  local api_key_format = conf.api_key_format or "Bearer %s"
  local api_key_value = string.format(api_key_format, conf.api_key)
  local api_key = api_key_header .. ": " .. api_key_value

  Job:new({
    command = "curl",
    args = {
      "--silent",
      "--no-buffer",
      "--location",
      conf.url,
      "--header",
      "Content-Type: application/json",
      "--header",
      api_key,
      "--data",
      payload,
    },
    on_stdout = function(_, line)
      for _, data_line in ipairs(vim.split(line, "\n")) do
        if vim.startswith(data_line, "data: ") then
          local chunk = data_line:sub(7)
          if chunk ~= "[DONE]" then
            vim.schedule(function()
              local ok, decoded = pcall(vim.fn.json_decode, chunk)
              if ok and decoded then
                local finished_reason = decoded.choices and decoded.choices[1] and decoded.choices[1].finish_reason
                local delta = decoded.choices and decoded.choices[1] and decoded.choices[1].delta
                local content = delta and delta.content
                local tool_calls = delta and delta.tool_calls
                local reasons = delta and delta.reasoning

                if content and content ~= vim.NIL and content ~= "" then
                  on_chunk({ type = "content", data = content })
                elseif tool_calls then
                  on_chunk({ type = "tool_calls", data = tool_calls })
                elseif reasons and reasons ~= vim.NIL and reasons ~= "" then
                  on_chunk({ type = "reasoning", data = reasons })
                end

                if finished_reason == "stop" or finished_reason == "tool_calls" then
                  on_complete()
                end
              end
            end)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          on_error(exit_code)
        end
      end)
    end,
  }):start()
end

return api
