# WHEN TO USE THIS TOOL

- Use when you need to search for specific patterns or text in files across your codebase.

# HOW TO USE

- Provide a search string as the `query_string` parameter.
- By default, the search is literal (fixed string). Set `use_regex: true` to treat `query_string` as a ripgrep regular expression.
- Optionally filter files by glob using the `glob` parameter (e.g., "*.lua", "**/*.ts").
- Returns file paths and lines where matches are found, in vimgrep format: `path:line:col:text`.

# FEATURES

- Fast search using ripgrep (rg).
- Literal search by default to avoid regex parse errors; full regex supported when `use_regex` is true.
- Can filter by file glob.
- Returns all matching file paths and lines.

# LIMITATIONS

- Only works with text files (not binaries).
- Requires ripgrep (rg) to be installed and available in PATH.
- Large codebases may return many results; refine your query for best performance.

