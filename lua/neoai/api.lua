local Job = require("plenary.job")
local conf = require("neoai.config").values.api

local api = {}

-- Stream AI response
--- Stream AI response from API
---@param messages table List of messages formatted for API request
---@param on_chunk fun(content:string) Callback function invoked with each chunk of content received
---@param on_complete fun() Callback function invoked when streaming completes successfully
---@param on_error fun(exit_code:number) Callback function invoked when an error occurs, receives exit code
function api.stream(messages, on_chunk, on_complete, on_error)
  local payload = vim.fn.json_encode({
    model = conf.model,
    temperature = conf.temperature,
    max_completion_tokens = conf.max_completion_tokens,
    top_p = conf.top_p,
    stream = true,
    messages = messages,
  })

  local api_key = "Authorization: Bearer " .. conf.api_key

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
                local delta = decoded.choices and decoded.choices[1] and decoded.choices[1].delta
                local content = delta and delta.content
                if content and content ~= "" then
                  on_chunk(content)
                end
              end
            end)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          on_complete()
        else
          on_error(exit_code)
        end
      end)
    end,
  }):start()
end

return api
