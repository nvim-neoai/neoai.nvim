# NeoAI.nvim

A powerful AI chat interface for Neovim with message history and streaming responses.

## Features

- **Interactive Chat UI**: Full-featured chat interface with floating windows
- **Message History**: Persistent conversation history with automatic saving and instant clearing
- **Thinking Process**: See how the AI processes your requests step by step
- **Tool Call Process**: See how the AI processes tool calls
- **Streaming Responses**: Real-time response streaming for better user experience
- **Multiple AI Providers**: Support for OpenAI, Groq, Anthropic, and local models
- **Syntax Highlighting**: Beautiful syntax highlighting for chat messages
- **Session Management**: Create new sessions, save/load history
- **Customizable UI**: Configurable window size and keymaps

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "PhoneMinThu/neoai.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("neoai").setup({
      api = {
        preset = "chosen-preset-here",
        api_key = "your-api-key-here",
      },
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "PhoneMinThu/neoai.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("neoai").setup({
      api = {
        preset = "chosen-preset-here",
        api_key = "your-api-key-here",
      },
    })
  end,
}
```

## Configuration

### Basic Setup

```lua
require("neoai").setup({
  api = {
    url = "your-api-url-here",
    api_key = "your-api-key-here",
    model = "deepseek-r1-distill-llama-70b",
    temperature = 0.4,
  },
  chat = {
    window = {
      width = 80,
    },
    auto_scroll = true,
  },
})
```

### Full Configuration

```lua
require("neoai").setup({
  -- API settings
  api = {
    url = "https://api.groq.com/openai/v1/chat/completions",
    api_key = "your-api-key-here",
    model = "deepseek-r1-distill-llama-70b",
    temperature = 0.4,
    max_completion_tokens = 4096,
    top_p = 0.9,
  },

  -- Chat UI settings
  chat = {
    window = {
      width = 80,
    },

    -- History settings
    history_limit = 100,
    save_history = true,
    history_file = vim.fn.stdpath("data") .. "/neoai_chat_history.json",

    -- Display settings
    auto_scroll = true,
  },
})
```

### Using Presets

```lua
-- Use OpenAI preset
require("neoai").setup({
  preset = "openai",
  api = { api_key = "your-openai-key" },
})
```

```lua
-- Use Ollama (local) preset
require("neoai").setup({
  preset = "ollama",
})
```

### Customizing API Key Header/Format

Some providers require a custom API key header or format. You can set these fields in your config or preset:

```lua
require("neoai").setup({
  api = {
    api_key = "your-key-here",
    api_key_header = "x-api-key",      -- For Anthropic
    api_key_format = "%s",             -- For Anthropic (no Bearer)
    -- ...other fields...
  },
})
```

Or, when using a preset (Anthropic example):

```lua
require("neoai").setup({
  preset = "anthropic",
  api = {
    api_key = "your-anthropic-api-key",
    -- api_key_header and api_key_format are set by the preset
  },
})
```

- `api_key_header` (default: `"Authorization"`): The HTTP header name for the API key.
- `api_key_format` (default: `"Bearer %s"`): The format string for the API key value. Use `"%s"` for plain keys.

## Usage

### Commands

- `:NeoAIChat` - Open the chat interface
- `:NeoAIChatToggle` - Toggle chat interface
- `:NeoAIChatClear` - Clear chat history (history file is updated immediately)
- `:NeoAIChatSave` - Save chat history
- `:NeoAIChatLoad` - Load chat history

### Keymaps

**Default Keymaps:**

- `<CR>` (Enter) — Send message (input box)
- `<C-c>` — Close chat (input and chat boxes)
- `q` — Close chat (chat box)
- `<C-s>` — Save history (chat box)
- `<leader>ai` - Open Chat
- `<leader>at` - Toggle Chat
- `<leader>ac` - Clear History

Keymaps are configured in the setup function under the `keymaps` field. See `lua/neoai/config.lua` for all defaults.

### Chat Interface Layout

```
┌──────────────────────────────────────────────────────────┐
│                       🧠 Chat Box                        │
│  (Displays conversation history between user and AI)     │
├──────────────────────────────────────────────────────────┤
│                    ⌨️ Input Box                          │
│       (User types message here and presses Enter)        │
└──────────────────────────────────────────────────────────┘
```

## API Provider Setup

### Groq (Default)

1. Sign up at [Groq Console](https://console.groq.com/)
2. Get your API key
3. Configure:

```lua
require("neoai").setup({
  preset = "groq",
  api = {
    api_key = "your-groq-api-key",
  },
})
```

### OpenAI

```lua
require("neoai").setup({
  preset = "openai",
  api = {
    api_key = "your-openai-api-key",
  },
})
```

### Anthropic

```lua
require("neoai").setup({
  preset = "anthropic",
  api = {
    api_key = "your-anthropic-api-key",
  },
})
```

### Local Models (Ollama)

1. Install [Ollama](https://ollama.ai/)
2. Pull a model: `ollama pull llama3.2`
3. Configure:

```lua
require("neoai").setup({
  preset = "ollama",
})
```

## Advanced Features

### Message History

- Automatically saves conversation history to `~/.local/share/nvim/neoai_chat_history.json`
- Loads previous session on startup (creates a new session only if none exists)
- Clearing chat history updates the file immediately
- Supports multiple sessions
- Configurable history limit

### AI Context Window

- Only the last 10 user/assistant messages are sent to the AI for context by default (configurable in code)
- If you want the AI to always remember certain facts, increase this limit or add facts to the system prompt

### Streaming Responses

- Real-time response display
- Shows response time
- Graceful error handling
- Auto-scrolling to latest content

## Troubleshooting

### Common Issues

1. **API Key Not Set**
   - Make sure to set your API key in the configuration
   - Check that the key is valid and has proper permissions

2. **Network Issues**
   - Verify internet connection
   - Check if the API endpoint is accessible
   - Try with a different model

3. **Chat Not Opening**
   - Ensure plenary.nvim is installed
   - Check for Lua errors with `:messages`
   - Verify your Neovim version (requires 0.7+)

### Debug Mode

Enable debug logging:

```lua
require("neoai").setup({
  debug = true,
  -- other config...
})
```

### Check Dependencies

```lua
:checkhealth neoai
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

MIT License - see LICENSE file for details
