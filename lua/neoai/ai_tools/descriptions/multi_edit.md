# WHEN TO USE THIS TOOL

- Use when you need to make multiple text replacements in a single file in one operation.

# HOW TO USE

- Provide the `file_path` and an array of `edits`.
- Each edit requires:
  - `old_string`: The exact text to replace.
  - `new_string`: The replacement text.
  - Optionally, `start_line` and `end_line` (integers, 1-based) to limit the replacement scope to a specific line range.

# FEATURES

- Batch multiple text replacements in one call.
- Scope replacements to a specific line range using `start_line` and `end_line`.
- Ensures all edits are applied atomically.
- In UI mode, writes changes directly into the target file using Git-style conflict markers (<<<<<<<, =======, >>>>>>>) so you can resolve them inline with your normal workflow. Neovim highlights these markers naturally. The cursor jumps to the first conflict for convenience. No separate diff window, no blocking wait, and no special keymaps.
- In headless mode (no UI), auto-applies changes like before, returning a summary, the diff, and diagnostics.

# LIMITATIONS

- Only works with text files.
- Edits should be non-overlapping and unique within their specified ranges (the tool applies edits sequentially and may cascade if overlaps exist).
- Does not support binary files.
- Line numbers are 1-based; out-of-range values are clamped to file boundaries.
