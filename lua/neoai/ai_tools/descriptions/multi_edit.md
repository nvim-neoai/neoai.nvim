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
- Shows a diff preview of proposed changes and asks for explicit approval before applying.
- If denied, collects a brief reason and returns it (with the diff) to the AI for follow-up.
- In headless mode (no UI), auto-approves and applies changes, returning a summary, the diff, and diagnostics.

# LIMITATIONS

- Only works with text files.
- Edits should be non-overlapping and unique within their specified ranges (the tool applies edits sequentially and may cascade if overlaps exist).
- Does not support binary files.
- Line numbers are 1-based; out-of-range values are clamped to file boundaries.