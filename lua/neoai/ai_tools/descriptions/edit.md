# WHEN TO USE THIS TOOL

- Apply one or more targeted edits to a file without sending the entire file content.
- Create a new file if it does not exist, the tool can create necessary directories if specified.

# HOW TO USE

- Provide the `file_path` and an array of `edits`.
- Parameters for each edit operation are as follows:
  - `old_string`: The text to replace. Matching is robust to case and minor whitespace differences and uses multiple strategies (exact, trimmed, anchors, shrinking window, Tree-sitter when available, and normalised text). Provide a distinctive, contiguous block from the file. Keep edits in the order they appear top-to-bottom in the file.
  - `new_string`: The replacement text.

## General File Handling

- The tool creates directories if they do not exist, determined by `ensure_dir` (default: true).
- Handles file creation if it doesn't exist by considering `old_string` as an insertion anchor or creating from scratch if empty.
- Automatically normalises line endings for consistent processing.

The tool will display an inline diff (UI) or write the file directly (headless).

# FEATURES

- Batch multiple text replacements in one call, ensuring atomic application where none are written unless all match (utilising whitespace insensitivity for robust edits).
- Whitespace-insensitive matching fallback for robust edits (e.g. tolerant to indentation or line-ending differences).
- Uses in-memory buffer content when available (unsaved changes are respected).
- Ensures edits are applied atomically: nothing is written unless all edits match.
- Search behaviour: edits are applied sequentially with a forward scan from the previous match location. If a match is not found ahead, the tool performs a wrap-around search from the top of the file up to the previous location.
- In UI mode, this tool shows an inline diff suggestion directly in the file. You can accept or reject hunks interactively:
  - <ct>: accept theirs (apply suggested change)
  - <co>: keep ours (revert suggestion)
  - ]d / [d: next/previous hunk
  - q: cancel review and restore original content
- In headless mode (no UI), the tool auto-applies changes and returns a summary, a `diff` block, and diagnostics.

# OPERATION MODES

- Operates in two modes depending on the availability of Neovim's UI components:
  - **Inline mode**: Utilises Neovim UI for applying diffs interactively.
  - **Headless mode**: Automatically approve and apply changes without requiring user interaction.
# LIMITATIONS

- Currently supports text files only; no binary file manipulation.
- Edits should be non-overlapping and unique within their ranges (applies sequentially with cascade potential on overlaps).
- Relies on Neovim APIs for some operations and assumes access to necessary utilities and permissions.
- Line numbers are 1-based; specified out-of-range line parameters are clamped to file boundaries.

