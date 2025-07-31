# WHEN TO USE THIS TOOL

- Use when you need to read the contents of a specific file.
- Helpful for examining source code, configuration files, or log files.
- Perfect for looking at text-based file formats.

# HOW TO USE

- Provide the absolute path to the file you want to read.
- Optionally specify an offset to start reading from a specific line.
- Optionally specify a limit to control how many lines are read.

# FEATURES

- Displays file contents with line numbers for easy reference.
- Can read from any position in a file using the offset parameter.
- Handles large files by limiting the number of lines read.

# LIMITATIONS

- Maximum file size is 250KB.
- Default reading limit is 2000 lines.
- Cannot display binary files or images.
- Images can be identified but not displayed.
