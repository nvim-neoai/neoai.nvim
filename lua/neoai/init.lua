-- lua/neoai/init.lua
local M = {}

--- Setup NeoAI plugin with user configuration
--- Always register commands; never hard-error out of setup.
---@param opts Config|nil
---@return table|nil
function M.setup(opts)
  -- 1) Create user commands FIRST so they exist even if config/boot fails
  do
    local ok_cmds, commands = pcall(require, "neoai.commands")
    if ok_cmds and type(commands.setup) == "function" then
      pcall(commands.setup) -- no notifications here; commands are idempotent
    end
  end

  -- 2) Apply configuration (non-fatal)
  local cfg_mod
  do
    local ok_cfg, mod_or_err = pcall(require, "neoai.config")
    if not ok_cfg then
      -- keep commands; stop initialisation here
      return nil
    end
    cfg_mod = mod_or_err
    local ok_set, values = pcall(cfg_mod.set_defaults, opts or {})
    if not ok_set or not values then
      -- invalid config; keep commands; skip the rest
      return nil
    end
  end

  -- 3) DO NOT run chat.setup() at startup anymore; defer to first use.
  -- If chat.setup() does heavy init and can fail, we avoid triggering it here.

  -- 4) Preload bootstrap safely (optional)
  pcall(require, "neoai.bootstrap")

  -- 5) Optional keymaps (guarded, no errors)
  pcall(function()
    local km = require("neoai.keymaps")
    if type(km.setup) == "function" then
      km.setup()
    end
  end)

  -- Return resolved config if callers want it
  return (cfg_mod and cfg_mod.get and cfg_mod.get()) or nil
end

-- Keep a trivial wrapper if code elsewhere expects this
function M.create_commands()
  local ok_cmds, commands = pcall(require, "neoai.commands")
  if ok_cmds and type(commands.setup) == "function" then
    pcall(commands.setup)
  end
end

return M
