# WHEN TO USE THIS TOOL

- Prefer TreeSitterQuery for structural extraction. Use this only when you need LSP-provided code actions.

# HOW TO USE

- Provide an optional `file_path` to specify the file (defaults to current buffer).
- Optionally provide `action_index` to execute a specific code action; otherwise, lists available actions.

# FEATURES

- Lists and applies LSP code actions.
- Supports specifying file and action index.
- Integrates with Neovim's LSP client.

# LIMITATIONS

- Requires an active LSP client for the file/buffer.
- Only works with files supported by the LSP server.
