# WHEN TO USE THIS TOOL

- Use when you want to retrieve and format LSP diagnostics for a file or buffer.
- Use to get code actions at the current cursor position.

# HOW TO USE

- Provide `file_path` (optional) to specify the file (defaults to current buffer).
- Set `include_code_actions` to true to also retrieve code actions.

# FEATURES

- Retrieves and formats LSP diagnostics.
- Can also list available code actions.
- Integrates with Neovim's LSP client.

# LIMITATIONS

- Requires an active LSP client for the file/buffer.
- Only works with files supported by the LSP server.
