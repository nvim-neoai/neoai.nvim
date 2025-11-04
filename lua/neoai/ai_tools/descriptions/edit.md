# WHEN TO USE THIS TOOL

- Apply one or more targeted edits to a file without sending the entire file content.
- Create a new file when it does not exist. Parent directories are created automatically when writing to disk (fallback).

# HOW TO USE

- Provide `file_path` and an array of `edits`.
- Each edit has:
  - `old_string`: The text to replace. Matching is robust to case and minor whitespace differences and uses multiple strategies (exact, trimmed, anchors, shrinking window, cross-line whitespace-collapsed substring, Tree-sitter when available, and normalised text). Provide a distinctive, contiguous block from the file. The order of edits is not important.
  - `new_string`: The replacement text. If `old_string` cannot be found but `new_string` is already present, the edit is treated as already applied and is skipped (idempotent behaviour).
- Insertion: set `old_string` to an empty string to insert new content without an explicit anchor. By default, the first such insertion goes to the top of the file; subsequent insertions (in the same run) append to the end.

## General File Handling

- Uses in-memory buffer content when available (unsaved changes are respected).
- Automatically normalises line endings for consistent processing (CRLF/CR → LF).
- Preserves indentation: the replacement block is dedented to its minimal common indent, then re-indented to match the base indent of the target region, keeping relative indentation intact.
- If the file does not exist, the tool can create it. When writing to disk (fallback), parent directories are created automatically.

The tool will attempt to display an inline diff (UI). If a UI is not available, it writes the file content directly (headless).

# FEATURES

- Order-invariant, multi-pass application (up to 3 passes):
  - Finds non-overlapping matches left-to-right per pass.
  - Overlapping or unresolved edits are deferred to the next pass.
  - Edits already present are skipped without error.
  - Unapplied edits after the final pass are reported but do not block applied ones.
- Whitespace-insensitive and case-tolerant matching fallbacks for robust edits.
- Uses current, unsaved buffer content when available.
- Inline diff UI:
  - Review and accept/reject hunks interactively:
    - <ct>: accept theirs (apply suggested change)
    - <co>: keep ours (revert suggestion)
    - ]d / [d: next/previous hunk
    - q: cancel review and restore original content
- Headless behaviour (no UI attached):
  - Automatically applies changes, writes to disk, and returns:
    - A summary
    - A unified `diff` block
    - LSP diagnostics
    - Machine-readable markers: `NeoAI-Diff-Hash` and `NeoAI-Diagnostics-Count`

# OPERATION MODES

- Inline mode: Utilises Neovim UI to show and apply diffs interactively.
- Headless mode: If no UI is attached, applies and writes changes automatically.

# LIMITATIONS

- Text files only; no binary manipulation.
- Ambiguous or duplicate contexts can cause matches to be skipped or deferred. Provide sufficiently distinctive `old_string` blocks to avoid ambiguity.
- Some edits may remain unapplied after the final pass; they are reported with previews for troubleshooting.
