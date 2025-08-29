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
- In UI mode, this tool shows an inline diff suggestion directly in the file, without opening a separate window. You can accept or reject each hunk interactively:
  - <ct>: accept theirs (apply suggested change)
  - <co>: keep ours (revert suggestion)
  - ]d / [d: next/previous hunk
  - q: cancel review and restore original content
- In headless mode (no UI), the tool auto-applies changes and returns a summary, a `diff` block, and diagnostics.

# LIMITATIONS

- Only works with text files.
- Edits should be non-overlapping and unique within their specified ranges (the tool applies edits sequentially and may cascade if overlaps exist).
- Does not support binary files.
- Line numbers are 1-based; out-of-range values are clamped to file boundaries.