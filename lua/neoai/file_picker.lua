local M = {}

function M.select_file()
  local ok, telescope_builtin = pcall(require, "telescope.builtin")
  if not ok then
    vim.notify("neoai: telescope.nvim not found", vim.log.levels.ERROR)
    return
  end

  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  telescope_builtin.find_files({
    attach_mappings = function(_, map)
      map({ "i", "n" }, "<CR>", function(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        local filepath = entry.path or entry.value
        filepath = vim.fn.fnamemodify(filepath, ":.")

        -- Close Telescope first
        actions.close(prompt_bufnr)

        -- Defer insertion until after Telescope finishes closing to avoid cursor races
        vim.schedule(function()
          local bufnr = vim.api.nvim_get_current_buf()
          local cursor = vim.api.nvim_win_get_cursor(0)
          local row, col = cursor[1], cursor[2]

          -- Current line and bounds
          local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, true)[1] or ""
          local line_len = #line
          if col > line_len then col = line_len end

          -- Advance insertion point to the end of the contiguous word to the right (if any)
          local j = col
          while j < line_len do
            local ch = line:sub(j + 1, j + 1)
            if ch and ch:match("[%w_]") then
              j = j + 1
            else
              break
            end
          end
          local insert_col = j + 1
          if insert_col > line_len then insert_col = line_len end

          -- Always insert: space + `filepath` + space
          local insert_text = " `" .. filepath .. "` "
          vim.api.nvim_buf_set_text(bufnr, row - 1, insert_col, row - 1, insert_col, { insert_text })

          -- Place cursor on the trailing space, then append after it
          local space_col = insert_col + #insert_text - 1
          vim.api.nvim_win_set_cursor(0, { row, space_col })

          -- Enter Insert mode after the trailing space (reliable for both mid-line and EOL)
          local a = vim.api.nvim_replace_termcodes("a", true, false, true)
          vim.api.nvim_feedkeys(a, "n", false)
        end)
      end)
      return true
    end,
  })
end

return M
