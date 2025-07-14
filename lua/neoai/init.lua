local neoai = {}

-- Import modules
local chat = require("neoai.chat")

-- Setup function
--- Setup NeoAI plugin with user configuration
---@param opts Config|nil User-defined configuration options
---@return Config Merged configuration
function neoai.setup(opts)
  -- Setup config
  require("neoai.config").set_defaults(opts)

  -- Setup chat module
  chat.setup()

  -- Create user commands
  neoai.create_commands()

  require("neoai.ai_tools").setup()
  require("neoai.keymaps").setup()

  return neoai.config
end

-- Create user commands
function neoai.create_commands()
  local commands = require("neoai.commands")
  commands.setup()
end

-- Expose modules
neoai.chat = chat

return neoai
