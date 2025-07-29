# NeoAI.nvim

A powerful AI-enhanced chat interface for Neovim, featuring streaming responses, multi-session support, SQLite storage, file operations, and customizable UI. Inspired by Cline and Kilo VSCode extensions.

## Features

- **Multi-Session Support**: Create, switch, rename, and delete multiple chat sessions
- **Persistent Storage**: Chat history is saved using either SQLite (if lsqlite3 is available) or a JSON file, based on your configuration
- **Interactive Chat UI**: Split-window chat interface with Markdown rendering
- **Session Management**: Telescope-powered session picker for easy navigation
- **Streaming Responses**: Real-time assistant replies with response time display
- **Tool Calls**: Automatic invocation of file-based tools (read, write, project structure, multi-edit, LSP diagnostics, semantic search, web search)
- **File Picker**: Quickly insert file paths into prompts using Telescope (`@` trigger)
- **Message History**: Persistent conversation history across sessions
- **Customizable Configuration**: Configure API provider, model, UI layout, keymaps, and more via `require('neoai').setup()`
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
    max_completion_tokens  = 4096,
    api_key_header         = "Authorization",
    api_key_format         = "Bearer %s",
  },

  -- Chat UI settings
  chat = {
    window = { width = 80 },
    auto_scroll = true,

    -- Storage settings (multi-session features)
    -- Use a .db extension for SQLite (requires lsqlite3), or .json for file-based storage.
    -- If you set a .db path but lsqlite3 is not available, NeoAI will automatically fall back to a .json file with the same base name.
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
      file_picker  = "@",     -- insert file path
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

## Persistent Storage Options

NeoAI supports two persistent storage backends for chat sessions and message history:

- **SQLite**: If you set `database_path` to a `.db` file (e.g. `neoai.db`), NeoAI will use SQLite for storage (requires the `lsqlite3` Lua module).
- **JSON file**: If you set `database_path` to a `.json` file (e.g. `neoai.json`), NeoAI will use a plain JSON file for storage (no dependencies required).

**Automatic Fallback:**
If you set a `.db` path but `lsqlite3` is not available, NeoAI will automatically fall back to a `.json` file with the same base name (e.g. `neoai.db` → `neoai.json`). This ensures you always have persistent storage, even if SQLite is not available.

**Example:**

```lua
chat = {
  -- Use SQLite (requires lsqlite3)
  database_path = vim.fn.stdpath("data") .. "/neoai.db",

  -- Or use JSON file storage (no dependencies)
  -- database_path = vim.fn.stdpath("data") .. "/neoai.json",
}
```

### 🛠 Installing `lsqlite3` for SQLite Support

> To use SQLite storage, you need to install the `lsqlite3` Lua module.

- **Install `luarocks`** (if not already installed):

```bash
sudo apt install luarocks
```

- **Install `lsqlite3` using `luarocks`**:
  - 📦 **Local install** (recommended):

    ```bash
    luarocks install lsqlite3 --local
    ```

    Add this to your shell profile (e.g., `~/.zshrc` or `~/.bashrc`):

    ```sh
    export LUA_CPATH="$HOME/.luarocks/lib/lua/5.1/?.so;;"
    ```

  - 🧨 **System-wide install** (YOLO):
    ```bash
    sudo luarocks install lsqlite3
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
- `@` - Trigger file picker (inserts `` `@path/to/file` ``)

**In Chat History Buffer**:

- `<C-c>` or `q` - Close Chat

## Usage

### Basic Chat Usage

1. Open chat with `:NeoAIChat` or `<leader>ai`.
2. Type your message in the input box and press `<CR>` to send.
3. Watch streaming assistant responses in the chat pane.
4. Trigger file operations by asking the AI or typing `@` to insert file paths.

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
All sessions are automatically saved to persistent storage (SQLite or JSON file, depending on your configuration).

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

## License

This project is licensed under the [MIT License](LICENSE).
