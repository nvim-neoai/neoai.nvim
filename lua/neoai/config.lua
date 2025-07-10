-- Example configuration for NeoAI plugin
-- Copy this to your init.lua or plugin configuration

local M = {}

-- Default configuration
M.defaults = {
	-- API settings
	api = {
		url = "https://api.groq.com/openai/v1/chat/completions",
		api_key = "<your api key>", -- Set this to your actual API key
		model = "deepseek-r1-distill-llama-70b",
		temperature = 0.4,
		max_completion_tokens = 4096,
		top_p = 0.9,
	},

	-- Chat UI settings
	chat = {
		window = {
			width = 80, -- Chat window width
			height = 30, -- Chat window height
			border = "rounded", -- Border style: "none", "single", "double", "rounded", "solid", "shadow"
			title = " NeoAI Chat ",
			title_pos = "center", -- "left", "center", "right"
		},

		-- History settings
		history_limit = 100,
		save_history = true,
		history_file = vim.fn.stdpath("data") .. "/neoai_chat_history.json",

		-- Display settings
		show_thinking = true, -- Show AI thinking process
		auto_scroll = true, -- Auto-scroll to bottom

		-- Keymaps (you can customize these)
		keymaps = {
			close = { "<C-c>", "q" },
			new_session = "<C-n>",
			save_history = "<C-s>",
			send_message = "<CR>",
		},
	},

	-- Additional features
	features = {
		code_highlighting = true, -- Enable code syntax highlighting in responses
		markdown_rendering = true, -- Enable markdown rendering
		auto_save_on_exit = true, -- Auto-save history when closing Neovim
	},
}

-- Setup function
function M.setup(opts)
	local config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	-- Validate API key
	if config.api.api_key == "<your api key>" then
		vim.notify("NeoAI: Please set your API key in the configuration", vim.log.levels.WARN)
	end

	-- Setup the plugin
	require("neoai").setup(config)

	return config
end

-- Preset configurations for different providers
M.presets = {
	groq = {
		api = {
			url = "https://api.groq.com/openai/v1/chat/completions",
			model = "deepseek-r1-distill-llama-70b",
			temperature = 0.4,
		},
	},

	openai = {
		api = {
			url = "https://api.openai.com/v1/chat/completions",
			model = "gpt-4-turbo-preview",
			temperature = 0.3,
		},
	},

	anthropic = {
		api = {
			url = "https://api.anthropic.com/v1/messages",
			model = "claude-3-sonnet-20240229",
			temperature = 0.2,
		},
	},

	-- Local models
	ollama = {
		api = {
			url = "http://localhost:11434/v1/chat/completions",
			model = "llama3.2",
			temperature = 0.5,
		},
	},
}

return M
