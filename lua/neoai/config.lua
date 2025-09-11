-- Example configuration for NeoAI plugin
-- Copy this to your init.lua or plugin configuration

---@class APIConfig
---@field url string
---@field api_key string
---@field model string
---@field max_completion_tokens number|nil
---@field api_key_header string|nil
---@field api_key_format string|nil
---@field api_call_delay number|nil
---@field additional_kwargs? table<string, any>

---@class APISet
---@field main APIConfig
---@field small APIConfig

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
---@field thinking_timeout number|nil

---@class Config
---@field api APISet
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
  -- API settings (two labelled models are required)
  api = {
    main = {
      url = "your-api-url-here",
      api_key = os.getenv("AI_API_KEY") or "<your api key>", -- Support environment variables
      api_key_header = "Authorization", -- Default header
      api_key_format = "Bearer %s", -- Default format
      model = "your-main-model-here",
      max_completion_tokens = 4096,
      api_call_delay = 0,
    },
    small = {
      url = "your-api-url-here",
      api_key = os.getenv("AI_API_KEY") or "<your api key>",
      api_key_header = "Authorization",
      api_key_format = "Bearer %s",
      model = "your-small-model-here",
      max_completion_tokens = 4096,
      api_call_delay = 0,
    },
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

    -- Streaming/response handling
    thinking_timeout = 300, -- seconds
  },

  presets = {
    groq = {
      api = {
        main = {
          url = "https://api.groq.com/openai/v1/chat/completions",
          api_key = os.getenv("GROQ_API_KEY") or "<your api key>",
          model = "deepseek-r1-distill-llama-70b",
        },
        small = {
          url = "https://api.groq.com/openai/v1/chat/completions",
          api_key = os.getenv("GROQ_API_KEY") or "<your api key>",
          model = "llama-3.1-8b-instant", -- example small
        },
      },
    },

    openai = {
      api = {
        main = {
          url = "https://api.openai.com/v1/chat/completions",
          api_key = os.getenv("OPENAI_API_KEY"),
          model = "gpt-5",
          max_completion_tokens = 128000,
          additional_kwargs = {
            temperature = 1,
            reasoning_effort = "high",
          },
        },
        small = {
          url = "https://api.openai.com/v1/chat/completions",
          api_key = os.getenv("OPENAI_API_KEY"),
          model = "gpt-5-mini",
          max_completion_tokens = 128000,
          additional_kwargs = {
            temperature = 1,
          },
        },
      },
    },

    anthropic = {
      api = {
        main = {
          url = "https://api.anthropic.com/v1/messages",
          api_key = os.getenv("ANTHROPIC_API_KEY") or "<your api key>",
          api_key_header = "x-api-key",
          api_key_format = "%s",
          model = "claude-3-5-sonnet-20241022",
        },
        small = {
          url = "https://api.anthropic.com/v1/messages",
          api_key = os.getenv("ANTHROPIC_API_KEY") or "<your api key>",
          api_key_header = "x-api-key",
          api_key_format = "%s",
          model = "claude-3-5-haiku-20241022",
        },
      },
    },

    -- Local models
    ollama = {
      api = {
        main = {
          url = "http://localhost:11434/v1/chat/completions",
          api_key = "", -- No API key needed for local
          model = "llama3.1:70b",
        },
        small = {
          url = "http://localhost:11434/v1/chat/completions",
          api_key = "",
          model = "llama3.2:1b",
        },
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

  -- Validation: require both labelled APIs
  local apis = config.values.api or {}
  local function missing(path)
    vim.notify("NeoAI: Missing required config: " .. path, vim.log.levels.ERROR)
  end

  if type(apis) ~= "table" then
    missing("api")
    return
  end
  if type(apis.main) ~= "table" then
    missing("api.main")
    return
  end
  if type(apis.small) ~= "table" then
    missing("api.small")
    return
  end

  -- Validate keys for both
  for label, a in pairs({ main = apis.main, small = apis.small }) do
    if a.api_key == "<your api key>" then
      vim.notify(
        "NeoAI: Please set your API key for api." .. label .. " or use environment variables",
        vim.log.levels.WARN
      )
    end
    if not a.url or a.url == "" then
      missing("api." .. label .. ".url")
      return
    end
    if not a.model or a.model == "" then
      missing("api." .. label .. ".model")
      return
    end
    a.api_key_header = a.api_key_header or "Authorization"
    a.api_key_format = a.api_key_format or "Bearer %s"
    a.max_completion_tokens = a.max_completion_tokens or 4096
    a.api_call_delay = a.api_call_delay or 0
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

--- Get API config by label ("main" or "small"). Defaults to "main".
---@param which string|nil
---@return APIConfig
function config.get_api(which)
  which = which or "main"
  local apis = (config.values and config.values.api) or {}
  local conf = apis[which]
  if not conf then
    vim.notify("NeoAI: Unknown API label '" .. tostring(which) .. "'", vim.log.levels.ERROR)
    return apis.main or {}
  end
  return conf
end

return config
