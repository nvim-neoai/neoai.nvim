Run a Tree-sitter query over a file or the current buffer to extract structured information without relying on grep or LSP.

Parameters:
- query (string, required): Tree-sitter s-expression query. Example (Lua):
  (function_declaration name: (identifier) @name)

Optional:
- file_path (string): Path to file. Uses current buffer if omitted.
- language (string): Force the language (e.g., lua, python). Normally auto-detected from buffer.
- include_text (boolean, default true): Include captured node text.
- include_ranges (boolean, default true): Include 1-based line/column ranges.
- captures (string[]): Only include specified capture names, with or without leading @.
- first_only (boolean): Return only the first match.
- max_results (integer): Limit the number of returned items (default 500).

Returns results as a text code block with one line per capture, including capture name, range, and trimmed text. If no matches are found, returns 'No matches for query'.
