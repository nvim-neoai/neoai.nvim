# WHEN TO USE THIS TOOL

- Use when you need to make multiple text replacements in a single file in one operation.

# HOW TO USE

- Provide the `file_path` and an array of `edits` (each with `old_string` and `new_string`).
- Each edit specifies the exact text to replace and its replacement.

# FEATURES

- Batch multiple text replacements in one call.
- Ensures all edits are applied atomically.
- Useful for large-scale or repetitive changes.

# LIMITATIONS

- Only works with text files.
- Edits must be non-overlapping and unique.
- Does not support binary files.
