# WHEN TO USE THIS TOOL

- Use when you need to search for specific patterns or text in files across your codebase.

# HOW TO USE

- Provide a regular expression as the `query_string` parameter.
- Optionally filter files by pattern using the include parameter (e.g., "\*.js").
- Returns file paths and lines where matches are found.

# FEATURES

- Fast, regex-based search using ripgrep (rg).
- Supports full regex syntax.
- Can filter by file pattern.
- Returns all matching file paths and lines.

# LIMITATIONS

- Only works with text files (not binaries).
- Requires ripgrep (rg) to be installed and available in PATH.
- Large codebases may return many results; refine your query for best performance.
