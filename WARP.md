# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Development Commands

### Testing
```bash
# Run complete test suite (multi-edit tools and session management)
nvim --headless -c "luafile test_neoai.lua" -c "qa!"

# Interactive plugin testing - load plugin and test manually
nvim -c "lua require('neoai').setup({preset = 'ollama'})"
```

### Plugin Development
```bash
# Reload plugin modules during development (in Neovim)
:lua package.loaded['neoai'] = nil
:lua require('neoai').setup({preset = 'openai'})

# Test specific AI tools
:lua require('neoai.ai_tools.read').run({file_path = 'README.md'})
:lua require('neoai.ai_tools.write').run({file_path = 'test.txt', content = 'hello'})

# Verify storage backends
:lua print(require('neoai.storage').get_backend())
```

### Debugging
```bash
# Check for runtime errors
:messages

# Enable verbose logging for API calls
:lua vim.g.neoai_debug = true

# Test individual components
:NeoAIStats  # Check storage and session information
```

## Architecture Overview

NeoAI.nvim is a multi-session AI chat plugin with a modular architecture:

### Core Subsystems
- **Entry Point** (`lua/neoai/init.lua`)
  - Plugin setup and module initialization
  - Exposes main API and creates user commands

- **Chat Engine** (`lua/neoai/chat.lua`)
  - Manages chat state, sessions, and message flow
  - Handles streaming responses and tool invocation
  - Coordinates with UI for display updates

- **UI Layer** (`lua/neoai/ui.lua`)
  - Split-window chat interface
  - Input buffer and chat history display
  - Window management and focus handling

- **API Communication** (`lua/neoai/api.lua`)
  - HTTP streaming via curl/plenary.job
  - Parses SSE (Server-Sent Events) responses
  - Handles tool_calls, content, and reasoning chunks

- **Storage Abstraction** (`lua/neoai/storage.lua`)
  - Unified interface for persistent storage
  - Auto-fallback from SQLite to JSON
  - Session and message management

- **Storage Backends**
  - **SQLite** (`lua/neoai/database.lua`) - Requires lsqlite3
  - **JSON** (`lua/neoai/storage_json.lua`) - No dependencies

- **AI Tools System** (`lua/neoai/ai_tools/`)
  - Dynamic tool registration and schema generation
  - Tools: read, write, multi_edit, project_structure, grep, lsp_diagnostic, lsp_code_action
  - OpenAI function calling compatibility

- **Configuration System** (`lua/neoai/config.lua`)
  - Preset system (openai, groq, anthropic, ollama)
  - Environment variable support
  - Deep merge of user options

- **Commands & UI** 
  - **Commands** (`lua/neoai/commands.lua`) - User command registration
  - **Keymaps** (`lua/neoai/keymaps.lua`) - Key binding setup
  - **Session Picker** (`lua/neoai/session_picker.lua`) - Telescope integration
  - **File Picker** (`lua/neoai/file_picker.lua`) - @@ file insertion

## Critical Technical Insights

### Storage System
- **Auto-fallback mechanism**: If `.db` extension is used but lsqlite3 unavailable, automatically switches to `.json` with same base name
- **Storage interface**: All backends implement same methods (create_session, add_message, etc.)
- **Session state**: Current session stored in `chat.chat_state.current_session`

### Tool System Architecture
- **Dynamic registration**: Tools auto-loaded from `ai_tools/` directory in `init.lua`
- **Schema generation**: Each tool provides `meta` (OpenAI function schema) and `run` (execution function)
- **Tool execution flow**: API response → tool_calls parsed → tool.run() called → result added as tool message → continue conversation
- **Tool call handling**: `chat.lua:get_tool_calls()` processes multiple tools concurrently

### API Streaming Implementation
- **curl-based streaming**: Uses plenary.job to stream curl responses
- **SSE parsing**: Looks for `data: ` prefixed lines, ignores `[DONE]`
- **Chunk types**: content, tool_calls, reasoning (for thinking models)
- **Timeout handling**: 60-second inactivity timeout with automatic cleanup

### Configuration & Presets
- **Environment variables**: Auto-detects `OPENAI_API_KEY`, `GROQ_API_KEY`, etc.
- **Preset merging**: Deep merge order is defaults → preset → user options
- **API key validation**: Warns if still set to placeholder values
- **Rate limiting**: Configure `api_call_delay` (milliseconds) to add delays between API calls for rate limit compliance

### UI State Management
- **Buffer management**: Separate buffers for chat history and input
- **Window state**: Stored in `chat.chat_state.windows` and `chat.chat_state.buffers`
- **Auto-scroll**: Configurable scroll-to-bottom on new messages
- **Markdown rendering**: Chat history uses Markdown filetype for syntax highlighting

### File Operations
- **File picker integration**: `@@` trigger opens Telescope, inserts backtick-wrapped paths
- **Tool file handling**: Read/write tools automatically append LSP diagnostics
- **Path resolution**: All file operations relative to `vim.fn.getcwd()`

### Key Extension Points
- **Adding new AI tools**: Create module in `ai_tools/` with `meta` and `run` functions
- **New storage backend**: Implement storage interface methods
- **Custom API providers**: Override `api` config with custom URL/headers/format
- **UI customization**: Modify keymaps, window layout, auto-scroll behavior

### Development Gotchas
- **Module reloading**: Use `package.loaded['module'] = nil` before re-requiring
- **Storage initialization**: Must happen before any chat operations
- **Streaming state**: Check `chat.chat_state.streaming_active` before new requests
- **Tool argument parsing**: Tool arguments come as JSON strings, may need pcall for json_decode
- **Buffer management**: UI buffers are recreated on open/close, don't cache buffer numbers
