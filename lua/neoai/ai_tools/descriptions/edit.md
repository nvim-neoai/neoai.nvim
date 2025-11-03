# WHEN TO USE THIS TOOL

- Apply one or more targeted edits to a file without sending the entire file content.
- Create a new file if it does not exist; the tool can create necessary directories if specified.

# HOW TO USE

- Provide the `file_path` and an array of `edits`.
- Each edit operation MUST use base64 fields:
  - `old_b64`: Base64-encoded exact text to replace. If the decoded string is empty, this is treated as an insertion at the beginning of the file.
  - `new_b64`: Base64-encoded replacement text.
- Base64: RFC 4648. Whitespace is ignored; URL-safe variants (- and _) are accepted. Padding is optional.

## General File Handling

- The tool creates directories if they do not exist, determined by `ensure_dir` (default: true).
- Handles file creation if it doesn't exist by considering empty decoded `old_b64` as an insertion anchor or creating from scratch.
- Automatically normalises line endings for consistent processing.

The tool will display an inline diff (UI) or write the file directly (headless).

# FEATURES

- Robust against JSON escaping issues: all payloads are base64-encoded, so embedded newlines/quotes/control characters are safe.
- Batch multiple text replacements in one call, order-invariant application with overlap resolution.
- Whitespace-insensitive matching fallback for robust edits (tolerant to indentation or line-ending differences).
- Uses in-memory buffer content when available (unsaved changes are respected).
- Idempotent behaviour: if the old block is not found but the new block already exists, the edit is skipped as already applied.
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

# ERROR SURFACING

- Invalid base64 is reported with the position of the first bad character or quartet.
- Decoding failures abort the entire tool call with a clear message.

# LIMITATIONS

- Text files only; no binary file manipulation.
- Edits should be non-overlapping and unique within their ranges.
- Requires Neovim APIs and appropriate permissions.

