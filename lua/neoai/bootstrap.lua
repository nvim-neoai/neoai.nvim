local M = {}

local function gen_id(i)
  return string.format("bootstrap-%d-%d", os.time(), i)
end

-- Build schemas list from configured specs and existing tool registry
local function build_tool_calls(specs, ai_tools)
  local tool_calls, names, spec_map = {}, {}, {}
  for i, spec in ipairs(specs or {}) do
    local name = spec and spec.name
    if type(name) == "string" and name ~= "" then
      -- Verify presence in registry
      local found
      for _, t in ipairs(ai_tools.tools or {}) do
        if t.meta and t.meta.name == name then
          found = true
          break
        end
      end
      if found then
        local okj, argstr = pcall(vim.fn.json_encode, spec.args or {})
        argstr = okj and argstr or "{}"
        local id = gen_id(i)
        table.insert(tool_calls, {
          id = id,
          type = "function",
          ["function"] = { name = name, arguments = argstr },
        })
        table.insert(names, name)
        spec_map[name] = spec.args or {}
      end
    end
  end
  return tool_calls, names, spec_map
end

-- Execute tool calls synchronously and persist tool result messages
local function execute_and_persist(chat, tool_calls, spec_args_map)
  local ai_tools = require("neoai.ai_tools")
  for _, call in ipairs(tool_calls) do
    local call_name = call["function"].name
    local args = spec_args_map[call_name] or {}

    local tool_mod
    for _, t in ipairs(ai_tools.tools or {}) do
      if t.meta and t.meta.name == call_name then
        tool_mod = t
        break
      end
    end

    local meta = { tool_name = call_name }
    local content = ""
    if tool_mod and type(tool_mod.run) == "function" then
      local ok_run, resp = pcall(tool_mod.run, args)
      if ok_run then
        if type(resp) == "table" then
          content = resp.content or ""
          if resp.display and resp.display ~= "" then
            meta.display = resp.display
          end
        else
          content = type(resp) == "string" and resp or tostring(resp) or ""
        end
      else
        content = "Error executing tool " .. call_name .. ": " .. tostring(resp)
        vim.notify(content, vim.log.levels.ERROR)
      end
    else
      content = "Tool not found: " .. tostring(call_name)
      vim.notify(content, vim.log.levels.ERROR)
    end

    if content == "" then
      content = "No response"
    end
    chat.add_message(require("neoai.chat").MESSAGE_TYPES.TOOL, content, meta, call.id)
  end
end

-- Public: run bootstrap preflight on first turn
function M.run_preflight(chat_module, boot_cfg)
  local ai_tools = require("neoai.ai_tools")
  local specs = (boot_cfg and type(boot_cfg.tools) == "table") and boot_cfg.tools or {}
  local tool_calls, names, spec_args_map = build_tool_calls(specs, ai_tools)
  if #tool_calls == 0 then
    return
  end
  -- Persist an assistant message with tool_calls, then persist tool results
  chat_module.add_message(
    require("neoai.chat").MESSAGE_TYPES.ASSISTANT,
    "**Tool call (bootstrap):** " .. table.concat(names, ", "),
    {},
    nil,
    tool_calls
  )
  execute_and_persist(chat_module, tool_calls, spec_args_map)
end

return M
