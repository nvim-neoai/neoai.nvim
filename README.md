# NeoAI.nvim

A powerful AI-enhanced chat interface for Neovim, featuring streaming responses, file operations, semantic code search, and customizable UI.

## Features

- **Interactive Chat UI**: Split-window chat interface with Markdown rendering
- **Streaming Responses**: Real-time assistant replies with response time display
- **Tool Calls**: Automatic invocation of file-based tools (read, write, project structure, multi-edit, LSP diagnostics, semantic search, web search)
- **File Picker**: Quickly insert file paths into prompts using Telescope (`@` trigger)
- **Message History**: Persistent conversation history with save, load, and clear operations
- **Semantic Code Search**: Build and query a vector index of your codebase with `:NeoAIIndex` and `:NeoAISearch`
- **Customizable Configuration**: Configure API provider, model, UI layout, keymaps, and more via `require('neoai').setup()`
- **Multiple Providers & Presets**: Built-in presets for OpenAI, Groq, Anthropic, Ollama (local), or custom endpoints
- **LSP Diagnostics Integration**: Read and display LSP diagnostics alongside file contents

## Installation

### Using lazy.nvim

```lua
{  
  "PhoneMinThu/neoai.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("neoai").setup({
      preset = "openai",      -- or "groq", "anthropic", "ollama"
      api = { api_key = "YOUR_API_KEY" },
    })
  end,
}
```

### Using packer.nvim

```lua
use {
  "PhoneMinThu/neoai.nvim",
  requires = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  config = function()
    require("neoai").setup({
      preset = "openai",
      api = { api_key = "YOUR_API_KEY" },
    })
  end,
}
```

## Configuration

Call `require('neoai').setup(opts)` with any of the following options:

```lua
require("neoai").setup({
  -- Select a built-in preset (openai, groq, anthropic, ollama) or omit for custom
  preset = "openai",

  -- Override API settings if needed
  api = {
    url     = "https://api.openai.com/v1/chat/completions",
    api_key = "YOUR_API_KEY",
    model   = "gpt-4",
    temperature            = 0.7,
    max_completion_tokens  = 4096,
    top_p                  = 1,
    api_key_header         = "Authorization",
    api_key_format         = "Bearer %s",
  },

  -- Chat UI settings
  chat = {
    window = { width = 80 },
    auto_scroll = true,
    save_history = true,
    history_file = vim.fn.stdpath("data") .. "/neoai_chat_history.json",
  },

  -- Override default keymaps (see lua/neoai/config.lua for defaults)
  keymaps = {
    normal = {
      open          = "<leader>ai",
      toggle        = "<leader>at",
      clear_history = "<leader>ac",
    },
    input = {
      file_picker  = "@",     -- insert file path
      send_message = "<CR>",
      close        = "<C-c>",
    },
    chat = {
      close        = {"<C-c>", "q"},
      save_history = "<C-s>",
    },
  },
})
```

## Commands

- `:NeoAIChat`         - Open the chat interface
- `:NeoAIChatToggle`   - Toggle chat interface
- `:NeoAIChatClear`    - Clear current chat session and history file
- `:NeoAIChatSave`     - Save chat history immediately
- `:NeoAICheckError [file]` - Read file contents and show LSP diagnostics
- `:NeoAIIndex`        - Build vector index of your codebase
- `:NeoAISearch <query>` - Query the semantic index for relevant code snippets

## Keymaps

**In Normal Mode** (global):

- `<leader>ai` - Open Chat
- `<leader>at` - Toggle Chat
- `<leader>ac` - Clear Chat History

**In Chat Input Buffer**:

- `<CR>`       - Send Message
- `<C-c>`      - Close Chat
- `@`          - Trigger file picker (inserts `` `@path/to/file` ``)

**In Chat History Buffer**:

- `<C-c>` or `q` - Close Chat
- `<C-s>`       - Save History

## Usage

1. Open chat with `:NeoAIChat` or `<leader>ai`.
2. Type your message in the input box and press `<CR>` to send.
3. Watch streaming assistant responses in the chat pane.
4. Trigger file operations by asking the AI or typing `@` to insert file paths.
5. Invoke semantic code search with `:NeoAISearch your query`.

## UI Layout

```
┌──────────────────────────────────────────────────────────┐
│                       🧠 Chat Box                        │
│  (Displays conversation history between user and AI)     │
├──────────────────────────────────────────────────────────┤
│                    ⌨️ Input Box                          │
│       (User types message here and presses Enter)        │
└──────────────────────────────────────────────────────────┘
```

## Troubleshooting

- Ensure `plenary.nvim` and `telescope.nvim` are installed.
- Check for errors with `:messages`.
- Verify Neovim version (>=0.7 recommended).

For advanced help, open an issue on GitHub.
