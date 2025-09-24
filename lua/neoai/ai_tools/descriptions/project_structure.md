# WHEN TO USE THIS TOOL

- Use when you need to inspect and return the directory tree of a given path.

# HOW TO USE

- Provide a `path` (relative or absolute).
- Optionally set `preferred_depth` (default 3).
- Set `adaptive` to true to adapt depth to repo size (default true).
  - If total files <= `small_file_threshold` (default 50), the listing expands fully.
  - If total files >= `large_file_threshold` (default 400), depth is clamped (typically to 2).
- Returns a plaintext tree of files/folders up to the effective depth. Collapsed folders show a summary, e.g. `… (N dirs, M files)`.

# FEATURES

- Inspects directory structure recursively via ripgrep (respects .gitignore).
- Adaptive depth to keep small repos fully visible and large repos concise.
- Ignores common directories based on ripgrep defaults.

# LIMITATIONS

- May still be slow on extremely large monorepos (bounded by ripgrep speed).
- Only returns a textual tree (not a structured object).
