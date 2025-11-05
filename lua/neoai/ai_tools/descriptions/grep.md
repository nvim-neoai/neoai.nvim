# WHEN TO USE THIS TOOL

- Use Grep for raw text searches across multiple files in a project. It is ideal for finding specific strings, function names, or error messages.
- Prefer this tool over reading individual files when you don't know which file contains the information you need.
- For structural code analysis (e.g., "find the function body of `foo`"), prefer the TreeSitterQuery tool.

# HOW TO USE

- Provide a search string as the `query_string` parameter.
- By default, the search is literal (fixed string). Set `use_regex: true` to treat `query_string` as a ripgrep regular expression.
- To search only specific kinds of files, use the `file_type` parameter (e.g., `file_type = "lua"` or `file_type = "ts"`). This respects `.gitignore`.
- To exclude specific file types, use the `exclude_file_type` parameter (e.g., `exclude_file_type = "md"`).
- To search all file types known to `ripgrep` while still respecting `.gitignore`, use `file_type = "all"`.
- If you don't provide any file type filters, `ripgrep` will search all files while respecting all ignore files (`.gitignore`, etc.), which is the recommended default for general searches.

# FEATURES

- Fast, recursive search using `ripgrep` (rg).
- **Respects `.gitignore` and other ignore files by default.**
- Literal search by default to prevent common regex errors. Full regex is supported via `use_regex: true`.
- Supports filtering by file type for inclusion (`file_type`) and exclusion (`exclude_file_type`).
- Returns all matches in `vimgrep` format: `path:line:col:text`.

# LIMITATIONS

- Requires `ripgrep` (rg) to be installed and available in `PATH`.
- Does not search binary files by default.
- Large codebases may return many results; refine your query for best performance.

