# WHEN TO USE THIS TOOL

- Use when you need to write or overwrite the contents of a file.
- Useful for saving generated or modified content to disk.

# HOW TO USE

- Provide the `file_path` (relative to the current working directory) and the complete `content` to write.
- If the file exists, it will be overwritten. If not, it will be created.
- Always read the file first before overwriting, if it exists.

# FEATURES

- Writes or overwrites files atomically.
- Automatically creates directories as needed.
- Enforces full content replacement (no partial writes).

# LIMITATIONS

- Only works with text files.
- Always overwrites the entire file; no append mode.
- Should not be used to create documentation files unless explicitly requested.
