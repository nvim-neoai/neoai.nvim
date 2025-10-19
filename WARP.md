# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Development Commands

### Testing & Quality
```bash
# Run the plugin test suite
nvim --headless -c "luafile test_neoai.lua" -c "qa!"

# Validate Lua syntax (requires luacheck)
luacheck lua/

# Format code (requires stylua)
stylua lua/ --check
stylua lua/ --config-path .stylua.toml  # if config exists

# Check LSP diagnostics for a file
nvim --headless -c ":lua require('neoai.commands').setup()" -c ":NeoAICheckError lua/neoai/init.lua" -c "qa!"
```

### Git Workflow (per Global Rules)
```bash
# Always check current branch before committing
git branch
git status

# Create feature branch (NEVER commit to main/master)
git checkout -b feature/new-tool-implementation
git checkout -b fix/api-streaming-bug

# Push new branch 
git push -u origin feature/new-tool-implementation
```

## Code Architecture

### Core Plugin Structure
- **`lua/neoai/init.lua`**: Entry point, sets up configuration and commands
- **`lua/neoai/config.lua`**: Configuration management with presets (OpenAI, Anthropic, Groq, Ollama)
- **`lua/neoai/chat.lua`**: Main chat orchestration, session management, UI coordination
- **`lua/neoai/commands.lua`**: Vim user commands (`:NeoAIChat`, `:NeoAINewSession`, etc.)

### AI Tools System (`lua/neoai/ai_tools/`)
Modular tool architecture where each tool implements:
```lua
-- Tool structure (e.g., read.lua, edit.lua)
{
  meta = { name = "ToolName", description = "...", parameters = {...} },
  run = function(args) ... end
}
```

Key tools:
- **`edit.lua`**: Multi-edit operations with LSP integration and auto-save
- **`treesitter_query.lua`**: Structural code queries using Tree-sitter
- **`grep.lua`**: Text search across files using ripgrep
- **`lsp_diagnostic.lua`**: LSP diagnostics collection with debouncing
- **`read.lua`**: File content reading with intelligent context
- **`project_structure.lua`**: Directory tree analysis

### Storage Layer
- **`lua/neoai/storage_json.lua`**: JSON file-based persistence (default)
- **`lua/neoai/storage.lua`**: Storage abstraction layer
- Multi-session support with message history persistence

### API Integration (`lua/neoai/api.lua`)
- Streaming HTTP client using plenary.nvim Job
- Supports multiple providers via configuration presets
- Tool calling integration with OpenAI-compatible APIs
- Real-time response processing with reasoning/content separation

### UI Components
- **`lua/neoai/ui.lua`**: Split-window chat interface with Markdown rendering
- **`lua/neoai/file_picker.lua`**: Telescope integration for `@@` file insertion
- **`lua/neoai/session_picker.lua`**: Telescope-powered session management

## Key Development Workflows

### Adding a New AI Tool
1. Create `lua/neoai/ai_tools/your_tool.lua`
2. Implement `meta` (OpenAI function schema) and `run` function
3. Add tool name to `tool_names` array in `lua/neoai/ai_tools/init.lua`
4. Test with `:NeoAIChat` and verify tool is available to AI

### Adding New Provider Support
1. Add preset configuration in `lua/neoai/config.lua` `presets` table
2. Handle provider-specific streaming response format in `lua/neoai/api.lua`
3. Test with different models and streaming patterns
4. Update README.md with new preset documentation

### Working with Multi-Edit System
The edit tool has complex LSP integration:
- Edits trigger automatic file saving
- LSP diagnostics are collected with debouncing (performance)  
- AI receives diagnostic feedback for iterative improvements
- Inline diff preview system for accept/reject workflow

### Storage Backend Development  
Current JSON storage is simple but could be extended:
- Session and message CRUD operations
- Active session management
- Statistics and metadata tracking

## Local Development Setup

### Prerequisites
- **Neovim**: ≥0.8 (0.9+ recommended for best LSP support)
- **Dependencies**: plenary.nvim, telescope.nvim, nvim-treesitter
- **External Tools**: ripgrep (rg), Tree-sitter parsers for target languages
- **API Keys**: Set via environment variables or direct config

### Environment Configuration
```bash
# Set API keys (recommended approach)
export OPENAI_API_KEY="your_key_here"
export ANTHROPIC_API_KEY="your_key_here"  
export GROQ_API_KEY="your_key_here"

# Development database path
export NEOAI_DB_PATH="$HOME/.local/share/nvim/neoai_dev.json"
```

### Plugin Development Setup
```lua
-- In your Neovim config for development
require("neoai").setup({
  preset = "openai",  -- or "anthropic", "groq", "ollama"
  api = {
    main = {
      api_key = os.getenv("OPENAI_API_KEY"),
      model = "gpt-4",
    },
    small = {
      api_key = os.getenv("OPENAI_API_KEY"), 
      model = "gpt-4o-mini",
    },
  },
  chat = {
    database_path = os.getenv("NEOAI_DB_PATH") or vim.fn.stdpath("data") .. "/neoai_dev.json",
  }
})
```

### Debugging & Development Tips
- Use `:messages` to see error output
- Enable debug payload: `api.main.debug_payload = true`
- Test tools individually: `lua require("neoai.ai_tools.read").run({file_path = "test.lua"})`
- Monitor JSON storage: `cat ~/.local/share/nvim/neoai.json | jq`

## Contributing Safety Reminders

⚠️ **Git Workflow Rules**: Always work on feature branches (`feature/`, `fix/`, `dev/`). Never commit directly to `main` or `master`. Create pull requests for all changes.

⚠️ **Development Focus**: This codebase prioritizes working functionality over extensive documentation/testing unless explicitly requested.

⚠️ **API Keys**: Never commit API keys or sensitive credentials. Use environment variables or local config files that are gitignored.