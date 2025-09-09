Run a Tree-sitter query over a file or the current buffer to extract structured information without relying on grep or LSP.

## Parameters:
- **query (string, required)**: Tree-sitter s-expression query. Craft this to target specific nodes or patterns.
  - Example (Lua): `(function_declaration name: (identifier) @name)`

## Optional:
- **file_path (string)**: Path to file. Uses the current buffer if omitted.
- **language (string)**: Force the language (e.g., lua, python). Normally auto-detected from buffer.
- **include_text (boolean, default true)**: Include captured node text. *Use this to gain context about where and what your captures represent.*
- **include_ranges (boolean, default true)**: Include 1-based line/column ranges. *Allows for easy location of captures within the source.*
- **captures (string[])**: Only include specified capture names, with or without leading `@`. 
  - *Helps narrow results to specific query parts.*
- **first_only (boolean)**: Return only the first match.
- **max_results (integer)**: Limit the number of returned items (default 500).

## General Tips:
- **Define Clear Objectives**: Ensure that the query you construct aligns with what insights or data you wish to obtain.
- **Capture Specific Information**: Use patterns in your query that translate directly to code elements of interest (e.g., function names, variable declarations).
- **Parameter Utilisation**: Make full use of `include_text` and `include_ranges` to get a more actionable and clear output.
- **Iterate and Refine**: Start with a broad query if needed, but refine it iteratively to focus more precisely on the data you need.

**Output**:
Returns results as a text code block, with one line per capture including capture name, range, and text. If no matches are found, returns 'No matches for query'.

By providing a thorough description with examples and suggestions, this enhanced documentation should help generate more informative and actionable results from the first utilisation.
