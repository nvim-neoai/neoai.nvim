# WHEN TO USE THIS TOOL

- Use when you need to inspect and return the directory tree of a given path.

# HOW TO USE

- Provide a `path` (relative or absolute) and optional `max_depth` for recursion.
- Returns a plaintext listing of files and folders up to the specified depth.

# FEATURES

- Inspects directory structure recursively.
- Can limit recursion depth.
- Ignores common directories (e.g., .git, node_modules).

# LIMITATIONS

- May be slow on very large directories.
- Ignores some directories by default.
- Only returns a plaintext listing (not a tree object).
