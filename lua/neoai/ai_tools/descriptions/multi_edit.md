# WHEN TO USE THIS TOOL

- Apply one or more targeted edits to a file without sending the entire file content.
- Create a new file by inserting content relative to a small anchor (see below) or by replacing an empty file.

# HOW TO USE

- Provide the `file_path` and an array of `edits`.
- Each edit requires:
  - `old_string`: The exact text to replace. Minor whitespace differences are tolerated.
  - `new_string`: The replacement text.
  - Optionally, `start_line` and `end_line` (integers, 1-based) to limit the replacement scope to a specific line range.

## Creating a new file

- If the file does not exist yet, you can:
  1. Provide a single edit where `old_string` is an empty string and `new_string` is the full desired content; or
  2. Provide a minimal anchor `old_string` (e.g. a header you plan to include) and `new_string` containing that anchor expanded.

The tool will display an inline diff (UI) or write the file directly (headless).

# FEATURES

- Batch multiple text replacements in one call.
- Whitespace-insensitive matching fallback for robust edits (e.g. tolerant to indentation or line-ending differences).
- Uses in-memory buffer content when available (unsaved changes are respected).
- Ensures edits are applied atomically: nothing is written unless all edits match.
- In UI mode, this tool shows an inline diff suggestion directly in the file. You can accept or reject hunks interactively:
  - <ct>: accept theirs (apply suggested change)
  - <co>: keep ours (revert suggestion)
  - ]d / [d: next/previous hunk
  - q: cancel review and restore original content
- In headless mode (no UI), the tool auto-applies changes and returns a summary, a `diff` block, and diagnostics.

# LIMITATIONS

- Text files only; no binary support.
- Edits should be non-overlapping and unique within their specified ranges (the tool applies edits sequentially and may cascade if overlaps exist).
- Line numbers are 1-based; out-of-range values are clamped to file boundaries.

