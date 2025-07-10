local M = {}

-- Import modules
local chat = require("neoai.chat")
local completion = require("completion")

-- Default configuration
M.config = {
	-- Chat UI settings
	chat = {
		window = {
			width = 80,
			height = 30,
			border = "rounded",
			title = " NeoAI Chat ",
			title_pos = "center",
		},
		history_limit = 100,
		save_history = true,
		history_file = vim.fn.stdpath("data") .. "/neoai_chat_history.json",
		show_thinking = true,
		auto_scroll = true,
	},
	-- API settings (inherit from completion module)
	api = completion.config,
}

-- Setup function
function M.setup(opts)
	-- Merge user config with defaults
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Setup completion module
	completion.setup(M.config.api)

	-- Setup chat module
	chat.setup(M.config.chat)

	-- Create user commands
	M.create_commands()
end

-- Create user commands
function M.create_commands()
	-- Chat commands
	vim.api.nvim_create_user_command("NeoAIChat", function()
		chat.open()
	end, { desc = "Open NeoAI Chat" })

	vim.api.nvim_create_user_command("NeoAIChatToggle", function()
		chat.toggle()
	end, { desc = "Toggle NeoAI Chat" })

	vim.api.nvim_create_user_command("NeoAIChatClear", function()
		chat.clear_history()
	end, { desc = "Clear NeoAI Chat History" })

	vim.api.nvim_create_user_command("NeoAIChatSave", function()
		chat.save_history()
	end, { desc = "Save NeoAI Chat History" })

	vim.api.nvim_create_user_command("NeoAIChatLoad", function()
		chat.load_history()
	end, { desc = "Load NeoAI Chat History" })

	-- Keep existing commands for backward compatibility
	vim.api.nvim_create_user_command("AINORMAL", function(opts)
		completion.text_input(opts.args)
	end, { nargs = 1, desc = "AI completion (non-streaming)" })

	vim.api.nvim_create_user_command("AI", function(opts)
		completion.text_input_stream(opts.args)
	end, { nargs = 1, desc = "AI completion (streaming)" })
end

-- Expose modules
M.chat = chat
M.completion = completion

return M
