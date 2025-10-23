# AGENTS.md

This document is consumed by the NeoAI coding agent at runtime. It is automatically injected into the system prompt when present, so please keep it accurate and concise.

Note: Update this file whenever you change topics covered here (overview, build/test commands, code style, testing instructions, security considerations, PR/commit guidelines, deployment steps). Only include information that materially affects contributors and the agent.

---

## Project overview
NeoAI.nvim is a Neovim plugin that provides a powerful AI-enhanced chat interface with streaming responses, multi-session storage, and an extensible tool system (ProjectStructure, Read, Edit, TreeSitterQuery, Grep, LspDiagnostic, LspCodeAction). It coordinates automated file edits with inline diff review and leverages LSP diagnostics for iterative improvements.

Key components:
- lua/neoai/chat.lua — Chat UI, message orchestration, tool invocation, response streaming
- lua/neoai/prompt.lua — Template loading and interpolation for the system prompt
- lua/neoai/prompts/system_prompt.md — System instructions and placeholders (%tools, %agents)
- lua/neoai/ai_tools/** — Tool implementations and their descriptions
- lua/neoai/tool_runner.lua — Orchestrates tool calls
- lua/neoai/storage*.lua — Session/message persistence
- lua/neoai/commands.lua — User commands

The system prompt automatically includes a list of available tools and, if present, the contents of this AGENTS.md.

### Edit + Diagnostics feedback loop (important)
- Edit tool calls are run in deferred mode (no inline UI shown immediately). The resulting diffs are staged internally and the assistant pauses immediately for review.
- After each edit, the plugin fetches LSP diagnostics for the edited buffer and emits machine-readable markers (diff hash, diagnostics count).
- The tool runner opens an inline diff review as soon as there are staged changes. The assistant does not continue until the review is closed. If the UI cannot open (e.g., headless), the assistant pauses and informs the user.
- Previously the runner waited for certain stop conditions before surfacing a review; this has been changed to avoid proceeding while changes are staged.
- This ensures we never “continue with changes staged”.

---

## Dev environment tips
- Use a local path in your Neovim plugin manager (e.g., lazy.nvim) to load this repository directly during development.
- Required dependencies: plenary.nvim, telescope.nvim, and optionally nvim-treesitter for TreeSitterQuery; ripgrep (rg) for Grep/ProjectStructure.
- Recommended Neovim: v0.8+.
- Configure two API profiles in setup: api.main and api.small. The main model is currently used for chat responses.
- Logging: prefer vim.notify with appropriate severity (DEBUG/INFO/WARN/ERROR) for internal diagnostics; keep noise minimal by default.

---

## Build and test commands
- Build: none required (Lua plugin).
- Quick manual test: launch Neovim with this plugin loaded and run:
  - :NeoAIChat — open the chat UI
  - :NeoAIChatToggle — toggle
  - :NeoAIChatClear — clear current session
  - :NeoAISessionList — pick/switch sessions
  - :NeoAIStats — show storage/session stats
  - :NeoAICheckError [file] — read file and show diagnostics
- Headless examples in test_neoai.lua are legacy and may not reflect current modules; prefer manual testing as above.

---

## Code style guidelines
- Lua modules return a local table (local M = {} … return M) and use clear, descriptive local helpers.
- Add concise EmmyLua annotations for public functions and non-trivial locals.
- Maintain British English in prompts, user-visible strings, and documentation.
- Prefer clarity and correctness over brevity; be precise with naming and types.
- Use vim.notify for user-facing notices; avoid excessive logging.
- Keep system prompts and tool descriptions terse and action-oriented.
- When adding or modifying tools, update their description files under lua/neoai/ai_tools/descriptions.

---

## Testing instructions
- Functional testing checklist:
  - Open chat (:NeoAIChat) and send a short message; confirm streaming, headers with model name, and timings.
  - Exercise the file picker trigger (type @@ in input) and verify inserted paths.
  - Ask the agent to read a file and then apply a small edit; review the inline diff and accept/reject.
  - After edits, confirm LSP diagnostics are shown and that the assistant can iterate on fixes.
  - Run :NeoAIStats to verify storage is initialised and session info looks sane.
- Optional: verify TreeSitterQuery and Grep tools on representative files.

---

## Security considerations
- Never hard-code or commit API keys. Load them via user config; do not log secrets.
- Edits are potentially destructive. Always surface diffs for review; avoid auto-applying irreversible changes.
- Be mindful when running tree-sitter queries or ripgrep across large workspaces; keep queries targeted.
- Respect .gitignore via ripgrep defaults; do not leak or process large binary artefacts.
- Network usage depends on configured provider; avoid sending unnecessary content.

---

## AGENTS.md maintenance policy
- This file is auto-included into the system prompt at runtime.
- If you change any of the topics addressed here (overview, commands, code style, testing, security, PR process), update this file as part of the same change.
- Do not bloat this file; include information that materially improves the agent’s effectiveness working on this repository.

