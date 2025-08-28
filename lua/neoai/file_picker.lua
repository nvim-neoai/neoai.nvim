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
        actions.close(prompt_bufnr)
        local bufnr = vim.api.nvim_get_current_buf()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row, col = cursor[1], cursor[2] + 1
        -- clamp col within line length
        local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, true)[1]
        if col > #line then col = #line end
        local insert_text = "`" .. filepath .. "`"
        vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { insert_text })
        vim.api.nvim_win_set_cursor(0, { row, col + #insert_text })
        -- Keep the input window in Insert mode after selection
        vim.schedule(function()
          pcall(vim.cmd, "startinsert")
        end)
      end)
      return true
    end,
  })
end

return M
