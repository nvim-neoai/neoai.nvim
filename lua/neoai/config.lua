-- Example configuration for NeoAI plugin
-- Copy this to your init.lua or plugin configuration

---@class APIConfig
---@field url string
---@field api_key string
---@field model string
---@field max_completion_tokens number|nil
---@field api_call_delay? number -- Delay in milliseconds between API calls for rate limiting
---@field additional_kwargs? table<string, any>

---@class KeymapConfig
---@field normal table<string, string>
---@field input table<string, string>
---@field chat table<string, string|string[]>
---@field session_picker string

---@class WindowConfig
---@field width number
---@field height_ratio number  -- Fraction of column height for chat window (0..1). 0.8 => 80% chat, 20% input
---@field min_input_lines number -- Minimum lines reserved for input window

---@class ChatConfig
---@field window WindowConfig
---@field auto_scroll boolean
---@field database_path string

---@class Config
---@field api APIConfig
---@field chat ChatConfig
---@field keymaps KeymapConfig
---@field presets table<string, table>
---@field preset string|nil

local config = {}
-- Default configuration
---@type Config
config.defaults = {
  keymaps = {
    input = {
      -- Insert file with @@ trigger in insert mode
      file_picker = "@@",
      close = "<C-c>",
      send_message = "<CR>",
    },
    chat = {
      close = { "<C-c>", "q" },
    },
    normal = {
      open = "<leader>ai",
      toggle = "<leader>at",
      clear_history = "<leader>ac",
    },
    session_picker = "default",
  },
  -- API settings
  api = {
    url = "your-api-url-here",
    api_key = os.getenv("AI_API_KEY") or "<your api key>", -- Support environment variables
    api_key_header = "Authorization", -- Default header
    api_key_format = "Bearer %s", -- Default format
    model = "your-ai-model-here",
    max_completion_tokens = 4096,
    api_call_delay = 0, -- Delay in milliseconds between API calls (0 = no delay)
  },

  -- Chat UI settings
  chat = {
    window = {
      width = 80, -- Chat window column width
      height_ratio = 0.8, -- 80% of column height for chat window
      min_input_lines = 3, -- Ensure input has at least a few lines
    },

    -- Storage settings:
    -- Example: database_path = vim.fn.stdpath("data") .. "/neoai.db"
    --          database_path = vim.fn.stdpath("data") .. "/neoai.json"
    database_path = vim.fn.stdpath("data") .. "/neoai.json",

    -- Display settings:
    auto_scroll = true, -- Auto-scroll to bottom
  },

  presets = {
    groq = {
      api = {
        url = "https://api.groq.com/openai/v1/chat/completions",
        api_key = os.getenv("GROQ_API_KEY") or "<your api key>",
        model = "deepseek-r1-distill-llama-70b",
      },
    },

    openai = {
      api = {
        url = "https://api.openai.com/v1/chat/completions",
        api_key = os.getenv("OPENAI_API_KEY") or "<your api key>",
        model = "o4-mini",
      },
    },

    anthropic = {
      api = {
        url = "https://api.anthropic.com/v1/messages",
        api_key = os.getenv("ANTHROPIC_API_KEY") or "<your api key>",
        api_key_header = "x-api-key",
        api_key_format = "%s",
        model = "claude-3-sonnet-20240229",
      },
    },

    -- Local models
    ollama = {
      api = {
        url = "http://localhost:11434/v1/chat/completions",
        api_key = "", -- No API key needed for local
        model = "llama3.2",
      },
    },
  },
}

-- Setup function
--- Setup NeoAI configuration with user options
---@param opts Config|nil User-defined configuration options
function config.set_defaults(opts)
  opts = opts or {}

  -- Start with base defaults
  local merged = vim.deepcopy(config.defaults)

  -- Apply preset if specified
  if opts.preset then
    if type(opts.preset) ~= "string" then
      vim.notify("NeoAI: preset must be a string", vim.log.levels.ERROR)
      return
    end

    local preset_config = config.defaults.presets[opts.preset]
    if not preset_config then
      vim.notify(
        "NeoAI: Unknown preset '"
          .. opts.preset
          .. "'. Available presets: "
          .. table.concat(vim.tbl_keys(config.defaults.presets), ", "),
        vim.log.levels.ERROR
      )
      return
    end

    -- Apply preset configuration
    merged = vim.tbl_deep_extend("force", merged, preset_config)
  end

  -- Remove preset from opts to avoid it being merged into final config
  local clean_opts = vim.deepcopy(opts)
  clean_opts.preset = nil

  -- Apply user options (these override preset values)
  config.values = vim.tbl_deep_extend("force", merged, clean_opts)

  -- Validate API key
  if config.values.api.api_key == "<your api key>" or config.values.api.api_key == "" then
    vim.notify("NeoAI: Please set your API key in the configuration or environment variable", vim.log.levels.WARN)
  end

  -- Validate required fields
  if not config.values.api.url or not config.values.api.model then
    vim.notify("NeoAI: API URL and model are required", vim.log.levels.ERROR)
    return
  end

  return config.values
end

-- Helper function to list available presets
function config.list_presets()
  return vim.tbl_keys(config.defaults.presets)
end

-- Helper function to get current config
function config.get()
  return config.values
end

return config
