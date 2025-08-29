# WHEN TO USE THIS TOOL

- Use when you need to write or overwrite the contents of a file.
- Useful for saving generated or modified content to disk.

# HOW TO USE

- Provide the `file_path` (relative to the current working directory) and the complete `content` to write.
- If the file exists, it will be overwritten. If not, it will be created.
- When UI is available and the file already exists, this tool presents an inline diff suggestion first. You can accept/reject hunks interactively:
  - <ct>: accept theirs (apply suggested change)
  - <co>: keep ours (revert suggestion)
  - ]d / [d: next/previous hunk
  - q: cancel review and restore original content
- If UI is not available (headless), the file is written directly.

# FEATURES

- Writes or overwrites files atomically.
- Automatically creates directories as needed.
- Enforces full content replacement (no partial writes).
- Shows inline diff suggestions before overwriting existing files (when UI is available).

# LIMITATIONS

- Only works with text files.
- Always overwrites the entire file; no append mode.
- Should not be used to create documentation files unless explicitly requested.