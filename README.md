# NeoAI.nvim

A powerful AI-enhanced chat interface for Neovim, featuring streaming responses, multi-session support, file operations, and customisable UI. Inspired by Cline and Kilo VSCode extensions.

## Features

- **Multi-Session Support**: Create, switch, rename, and delete multiple chat sessions
- **Persistent Storage**: Chat history is saved using a JSON file, based on your configuration
- **Interactive Chat UI**: Split-window chat interface with Markdown rendering
- **Session Management**: Telescope-powered session picker for easy navigation
- **Streaming Responses**: Real-time assistant replies with response time display
- **Tool Calls**: Automatic invocation of file-based tools (read, write, project structure, multi-edit, LSP diagnostics, semantic search, web search)
- **File Picker**: Quickly insert file paths into prompts using Telescope (`@@` double-at trigger)
- **Message History**: Persistent conversation history across sessions
- **Customisable Configuration**: Configure API provider, model, UI layout, keymaps, and more via `require('neoai').setup()`
- **API Call Delay**: Configurable delay between API calls to handle rate limiting from AI providers
- **Multiple Providers & Presets**: Built-in presets for OpenAI, Groq, Anthropic, Ollama (local), or custom endpoints
- **LSP Diagnostics Integration**: Read and display LSP diagnostics alongside file contents

## Installation

### Using lazy.nvim

```lua
{
  "nvim-neoai/neoai.nvim",
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
  "nvim-neoai/neoai.nvim",
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

- Call `require('neoai').setup(opts)` with any of the following options:

```lua
require("neoai").setup({
  -- Select a built-in preset (openai, groq, anthropic, ollama) or omit for custom
  preset = "openai",

  -- Override API settings if needed
  api = {
    url     = "https://api.openai.com/v1/chat/completions",
    api_key = "YOUR_API_KEY",
    model   = "gpt-4",
    -- Delay between AI API calls (ms) to handle rate limiting
    api_call_delay = 0, -- default: 0 ms (no delay)
    max_completion_tokens  = 4096,
    api_key_header         = "Authorization",
    api_key_format         = "Bearer %s",
  },

  -- Chat UI settings
  chat = {
    window = { width = 80 },
    auto_scroll = true,

    -- Storage settings (multi-session features)
    database_path = vim.fn.stdpath("data") .. "/neoai.json",
  },

  -- Override default keymaps (see lua/neoai/config.lua for defaults)
  keymaps = {
    normal = {
      open          = "<leader>ai",
      toggle        = "<leader>at",
      clear_history = "<leader>ac",
    },
    input = {
      file_picker  = "@@",    -- insert file path (double-at trigger)
      send_message = "<CR>",
      close        = "<C-c>",
    },
    chat = {
      close        = {"<C-c>", "q"},
    },
    -- `telescope`, `default`
    session_picker = "default"  },
})
```

- Multiple models config
  - api key are setup in `~/.config/nvim/lua/config/env.lua` (default neovim config location)

```lua
local openai_config = function()
  local OPENAI_API_KEY = require("config.env").OPENAI_API_KEY
  require("neoai").setup({
    preset = "openai",
    api = {
      model = "o4-mini",
      api_key = OPENAI_API_KEY,
      max_completion_tokens = 4096 * 2,
      api_call_delay = 5000,
      additional_kwargs = {
        reasoning_effort = "medium",
      },
    },
    chat = {
      database_path = vim.fn.stdpath("data") .. "/neoai.db",
    },
  })
end

local groq_config = function()
  local GROQ_API_KEY = require("config.env").GROQ_API_KEY
  require("neoai").setup({
    preset = "groq",
    api = {
      model = "openai/gpt-oss-20b",
      api_key = GROQ_API_KEY,
      max_completion_tokens = 8192,
      api_call_delay = 5000,
      additional_kwargs = {
        reasoning_effort = "medium",
      },
    },
    chat = {
      database_path = vim.fn.stdpath("data") .. "/neoai.db",
    },
  })
end

return {
  {
    "nvim-neoai/neoai.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    config = openai_config,
  },
}

```

## Persistent Storage Options

NeoAI supports two persistent storage backends for chat sessions and message history:

- **JSON file**: If you set `database_path` to a `.json` file (e.g. `neoai.json`), NeoAI will use a plain JSON file for storage (no dependencies required).

**Example:**

```lua
chat = {
  -- Use JSON file storage (no dependencies)
  -- database_path = vim.fn.stdpath("data") .. "/neoai.json",
}
```

## Commands

### Basic Commands

- `:NeoAIChat` - Open the chat interface
- `:NeoAIChatToggle` - Toggle chat interface
- `:NeoAIChatClear` - Clear current chat session messages

### Session Management Commands

- `:NeoAISessionList` - Interactive session picker (Telescope-powered)
- `:NeoAINewSession [title]` - Create new chat session
- `:NeoAISwitchSession <id>` - Switch to specific session by ID
- `:NeoAIDeleteSession <id>` - Delete session by ID
- `:NeoAIRenameSession <title>` - Rename current session
- `:NeoAIStats` - Show database statistics and session info

## Keymaps

**In Normal Mode** (global):

- `<leader>ai` - Open Chat
- `<leader>at` - Toggle Chat
- `<leader>ac` - Clear Chat Session
- `<leader>as` - Session List (Telescope picker)
- `<leader>an` - New Session
- `<leader>aS` - Show Statistics

**In Chat Input Buffer**:

- `<CR>` - Send Message
- `<C-c>` - Close Chat
- `@@` - Trigger file picker (inserts `` `path/to/file` `` in backticks)

**In Chat History Buffer**:

- `<C-c>` or `q` - Close Chat

## Usage

### Basic Chat Usage

1. Open chat with `:NeoAIChat` or `<leader>ai`.
2. Type your message in the input box and press `<CR>` to send.
3. Watch streaming assistant responses in the chat pane.
4. Trigger file operations by asking the AI or typing `@@` to insert file paths.

### 📁 File Picker Usage

NeoAI includes a convenient file picker integration powered by Telescope:

- **Trigger**: Type `@@` (double-at) in the chat input buffer
- **Function**: Opens Telescope file picker to browse and select files
- **Result**: Selected file path is inserted as `` `path/to/file` `` (in backticks) at cursor position
- **Use case**: Quickly reference files in your prompts for AI analysis, editing, or discussion

**Example workflow:**

1. Type: "Please review this file: @@"
2. Telescope opens, select your file (e.g., `src/main.js`)
3. Result: "Please review this file: `` `src/main.js` ``"
4. Send message for AI to analyse the file

**Why `@@` (double-at)?**

- Allows typing single `@` symbols normally (common in code, emails, etc.)
- Only triggers file picker when you specifically need it
- Prevents accidental popup when typing regular text

### 🔄 Multi-Session Workflow

---

#### 🆕 Create Sessions

Use the command:

```vim
:NeoAINewSession "Project Setup"
```

to create a named session with its own conversation context.

---

#### 🔀 Switch Sessions

Press `<leader>as` to open the interactive session picker (via Telescope).

---

#### ⚙️ Manage Sessions

In the session picker:

- `<Enter>` – Switch to selected session
- `<C-d>` – Delete session
- `<C-r>` – Rename session
- `<C-n>` – Create new session

---

#### 💾 Persistent Context

Each session retains its own conversation history and prompt context.  
All sessions are automatically saved to persistent JSON file. 

### Session Management Tips

- Use descriptive session names like "Bug Fix #123", "Feature Development", "Code Review"
- Sessions are sorted by last activity, so recently used sessions appear first
- The active session is clearly marked in the session picker
- Database statistics are available via `:NeoAIStats`

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

## Licence

This project is licensed under the [MIT Licence](LICENCE).
