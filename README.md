# NeoAI.nvim

A powerful AI chat interface for Neovim with message history, thinking process visualization, and streaming responses.

## Features

- **Interactive Chat UI**: Full-featured chat interface with floating windows
- **Message History**: Persistent conversation history with automatic saving
- **Thinking Process**: See how the AI processes your requests step by step
- **Streaming Responses**: Real-time response streaming for better user experience
- **Multiple AI Providers**: Support for OpenAI, Groq, Anthropic, and local models
- **Syntax Highlighting**: Beautiful syntax highlighting for chat messages
- **Session Management**: Create new sessions, save/load history
- **Customizable UI**: Configurable window size, borders, and keymaps

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "your-username/neoai.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("neoai").setup({
      api = {
        api_key = "your-api-key-here",
      },
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "your-username/neoai.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("neoai").setup({
      api = {
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
    api_key = "your-api-key-here",
    model = "deepseek-r1-distill-llama-70b",
    temperature = 0.4,
  },
  chat = {
    window = {
      width = 80,
      height = 30,
      border = "rounded",
    },
    show_thinking = true,
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
      height = 30,
      border = "rounded", -- "none", "single", "double", "rounded", "solid", "shadow"
      title = " NeoAI Chat ",
      title_pos = "center",
    },
    
    -- History settings
    history_limit = 100,
    save_history = true,
    history_file = vim.fn.stdpath("data") .. "/neoai_chat_history.json",
    
    -- Display settings
    show_thinking = true,
    auto_scroll = true,
  },
})
```

### Using Presets

```lua
-- Use OpenAI
require("neoai.config").setup(
  vim.tbl_deep_extend("force", 
    require("neoai.config").presets.openai, 
    { api = { api_key = "your-openai-key" } }
  )
)

-- Use Ollama (local)
require("neoai.config").setup(
  require("neoai.config").presets.ollama
)
```

## Usage

### Commands

- `:NeoAIChat` - Open the chat interface
- `:NeoAIChatToggle` - Toggle chat interface
- `:NeoAIChatClear` - Clear chat history
- `:NeoAIChatSave` - Save chat history
- `:NeoAIChatLoad` - Load chat history
- `:AI <message>` - Send message directly (streaming)
- `:AINORMAL <message>` - Send message directly (non-streaming)

### Keymaps

**In Chat Interface:**
- `<Enter>` - Send message
- `<C-c>` or `q` - Close chat
- `<C-n>` - New session
- `<C-s>` - Save history

**Example Keymaps:**
```lua
vim.keymap.set("n", "<leader>ai", ":NeoAIChat<CR>", { desc = "Open NeoAI Chat" })
vim.keymap.set("n", "<leader>at", ":NeoAIChatToggle<CR>", { desc = "Toggle NeoAI Chat" })
vim.keymap.set("n", "<leader>ac", ":NeoAIChatClear<CR>", { desc = "Clear NeoAI Chat" })
```

### Chat Interface Layout

```
┌─── NeoAI Chat ────────────────────────────────────────────────────────────┐
│ === NeoAI Chat Session ===                                                │
│ Session ID: 1704067200                                                    │
│ Created: 2024-01-01 10:00:00                                             │
│ Messages: 4                                                               │
│                                                                           │
│ User: 2024-01-01 10:00:05                                                │
│   What is machine learning?                                              │
│                                                                           │
│ Assistant: 2024-01-01 10:00:07 (2s)                                      │
│   Machine learning is a subset of artificial intelligence...            │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
┌─── Thinking ──────────────────────────────────────────────────────────────┐
│ === AI Thinking Process ===                                              │
│                                                                           │
│ Step 1 [2024-01-01 10:00:05]:                                           │
│   Processing user message: What is machine learning?                     │
│                                                                           │
│ Step 2 [2024-01-01 10:00:05]:                                           │
│   Preparing API request with 2 messages                                  │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
┌─── Input (Press Enter to send, Ctrl+C to close) ─────────────────────────┐
│                                                                           │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

## API Provider Setup

### Groq (Default)

1. Sign up at [Groq Console](https://console.groq.com/)
2. Get your API key
3. Configure:

```lua
require("neoai").setup({
  api = {
    url = "https://api.groq.com/openai/v1/chat/completions",
    api_key = "your-groq-api-key",
    model = "deepseek-r1-distill-llama-70b",
  },
})
```

### OpenAI

```lua
require("neoai").setup({
  api = {
    url = "https://api.openai.com/v1/chat/completions",
    api_key = "your-openai-api-key",
    model = "gpt-4-turbo-preview",
  },
})
```

### Anthropic

```lua
require("neoai").setup({
  api = {
    url = "https://api.anthropic.com/v1/messages",
    api_key = "your-anthropic-api-key",
    model = "claude-3-sonnet-20240229",
  },
})
```

### Local Models (Ollama)

1. Install [Ollama](https://ollama.ai/)
2. Pull a model: `ollama pull llama3.2`
3. Configure:

```lua
require("neoai").setup({
  api = {
    url = "http://localhost:11434/v1/chat/completions",
    api_key = "not-needed",
    model = "llama3.2",
  },
})
```

## Advanced Features

### Message History

- Automatically saves conversation history to `~/.local/share/nvim/neoai_chat_history.json`
- Loads previous session on startup
- Supports multiple sessions
- Configurable history limit

### Thinking Process

When `show_thinking` is enabled, you can see:
- Message processing steps
- API request preparation
- Response streaming status
- Error handling

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

## Changelog

### v1.0.0
- Initial release
- Chat interface with floating windows
- Message history with persistence
- Thinking process visualization
- Streaming responses
- Multiple AI provider support
- Syntax highlighting
- Session management
