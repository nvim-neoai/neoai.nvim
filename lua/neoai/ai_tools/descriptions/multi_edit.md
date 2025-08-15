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
- Useful for large-scale or repetitive changes.

# LIMITATIONS

- Only works with text files.
- Edits must be non-overlapping and unique within their specified ranges.
- Does not support binary files.
- Line numbers are 1-based; out-of-range values are clamped to file boundaries.
