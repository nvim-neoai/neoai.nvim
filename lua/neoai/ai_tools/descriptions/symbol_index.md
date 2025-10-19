Index functions, methods, and classes across files using Tree-sitter with safe fallbacks. Useful for quick semantic overviews and for feeding into small-model triage.

How it finds symbols:
- First tries to load a runtime Tree-sitter query: queries/<lang>/symbol_index.scm (via vim.treesitter.query.get).
- If none is found, falls back to a built-in query for common languages.
- If Tree-sitter is unavailable or fails for a file, falls back to simple textual heuristics.

Parameters:
- path (string, optional): Root path to scan. Defaults to cwd.
- files (string[], optional): Explicit list of files to scan. Overrides path/globs.
- globs (string[], optional): Ripgrep -g patterns to include (e.g. ["**/*.lua", "**/*.py"]).
- languages (string[], optional): Limit to these languages; omit to index any detected languages.
- include_docstrings (boolean, default true): Include docstrings or leading comment blocks.
- include_ranges (boolean, default true): Include 1-based ranges for each symbol.
- include_signatures (boolean, default true): Include basic signatures (name + parameter list where available).
- max_files (number, default 50): Limit number of files processed.
- max_symbols_per_file (number, default 200): Limit number of symbols per file.
- fallback_to_text (boolean, default true): Use textual heuristics if Tree-sitter is unavailable or fails.

Output:
- JSON code block with an object: { files: [{ file, language, symbols: [{ kind, name, signature?, params?, doc?, range?, line? }], error? }], summary: { files, symbols } }
- If JSON encoding fails, a plaintext summary is returned instead.

Notes:
- Provide your own per-language query by placing a symbol_index.scm under queries/<lang>/.
- Python docstrings are extracted as the first string literal expression inside the function/class body.
- Other languages use leading comment blocks above the definition (//, /** */, --, ///, //! as applicable).
- You can extend or override language support entirely via runtime queries; built-ins are only a convenience fallback.


