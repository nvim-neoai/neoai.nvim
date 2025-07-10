local M = {}

-- Dependencies
local completion = require("completion")

-- Chat state
local chat_state = {
	config = {},
	windows = {},
	buffers = {},
	history = {},
	thinking_history = {},
	current_session = nil,
	is_open = false,
}

-- Message types
local MESSAGE_TYPES = {
	USER = "user",
	ASSISTANT = "assistant",
	SYSTEM = "system",
	THINKING = "thinking",
	ERROR = "error",
}

-- Setup function
function M.setup(config)
	chat_state.config = vim.tbl_deep_extend("force", {
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
	}, config or {})

	-- Load history on startup
	if chat_state.config.save_history then
		M.load_history()
	end

	-- Create new session
	M.new_session()
end

-- Create new chat session
function M.new_session()
	chat_state.current_session = {
		id = os.time(),
		messages = {},
		thinking = {},
		created_at = os.date("%Y-%m-%d %H:%M:%S"),
	}

	-- Add system message
	M.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", {
		timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		session_id = chat_state.current_session.id,
	})
end

-- Add message to current session
function M.add_message(type, content, metadata)
	if not chat_state.current_session then
		M.new_session()
	end

	local message = {
		type = type,
		content = content,
		timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		metadata = metadata or {},
	}

	table.insert(chat_state.current_session.messages, message)

	-- Update UI if open
	if chat_state.is_open then
		M.update_chat_display()
	end

	-- Auto-save if enabled
	if chat_state.config.save_history then
		M.save_history()
	end
end

-- Add thinking step
function M.add_thinking(content, step)
	if not chat_state.current_session then
		M.new_session()
	end

	local thinking = {
		content = content,
		step = step or 1,
		timestamp = os.date("%Y-%m-%d %H:%M:%S"),
	}

	table.insert(chat_state.current_session.thinking, thinking)

	-- Update UI if open and thinking is enabled
	if chat_state.is_open and chat_state.config.show_thinking then
		M.update_thinking_display()
	end
end

-- Open chat window
function M.open()
	if chat_state.is_open then
		return
	end

	-- Create chat buffer
	chat_state.buffers.chat = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(chat_state.buffers.chat, "buftype", "nofile")
	vim.api.nvim_buf_set_option(chat_state.buffers.chat, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(chat_state.buffers.chat, "filetype", "neoai-chat")
	vim.api.nvim_buf_set_option(chat_state.buffers.chat, "wrap", true)

	-- Create input buffer
	chat_state.buffers.input = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(chat_state.buffers.input, "buftype", "nofile")
	vim.api.nvim_buf_set_option(chat_state.buffers.input, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(chat_state.buffers.input, "filetype", "neoai-input")

	-- Create thinking buffer (if enabled)
	if chat_state.config.show_thinking then
		chat_state.buffers.thinking = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "buftype", "nofile")
		vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "filetype", "neoai-thinking")
		vim.api.nvim_buf_set_option(chat_state.buffers.thinking, "wrap", true)
	end

	-- Calculate window dimensions
	local width = chat_state.config.window.width
	local height = chat_state.config.window.height
	local win_width = vim.api.nvim_get_option("columns")
	local win_height = vim.api.nvim_get_option("lines")

	local col = math.floor((win_width - width) / 2)
	local row = math.floor((win_height - height) / 2)

	local thinking_height = math.floor(height * 0.25)

	-- Create chat window
	local chat_height = height - 5
	if chat_state.config.show_thinking then
		chat_height = math.floor(height * 0.6)
	end

	chat_state.windows.chat = vim.api.nvim_open_win(chat_state.buffers.chat, true, {
		relative = "editor",
		width = width,
		height = chat_height,
		col = col,
		row = row,
		border = chat_state.config.window.border,
		title = chat_state.config.window.title,
		title_pos = chat_state.config.window.title_pos,
	})

	-- Create thinking window (if enabled)
	if chat_state.config.show_thinking then
		chat_state.windows.thinking = vim.api.nvim_open_win(chat_state.buffers.thinking, false, {
			relative = "editor",
			width = width,
			height = thinking_height,
			col = col,
			row = row + chat_height + 1,
			border = chat_state.config.window.border,
			title = " Thinking ",
			title_pos = "center",
		})
	end

	-- Create input window
	local input_row = row + chat_height + (chat_state.config.show_thinking and thinking_height + 2 or 1)
	chat_state.windows.input = vim.api.nvim_open_win(chat_state.buffers.input, false, {
		relative = "editor",
		width = width,
		height = 3,
		col = col,
		row = input_row,
		border = chat_state.config.window.border,
		title = " Input (Press Enter to send, Ctrl+C to close) ",
		title_pos = "center",
	})

	-- Set up key mappings
	M.setup_keymaps()

	-- Update display
	M.update_chat_display()
	if chat_state.config.show_thinking then
		M.update_thinking_display()
	end

	-- Focus input window
	vim.api.nvim_set_current_win(chat_state.windows.input)

	chat_state.is_open = true
end

-- Close chat window
function M.close()
	if not chat_state.is_open then
		return
	end

	-- Close windows
	for _, win in pairs(chat_state.windows) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	-- Clear state
	chat_state.windows = {}
	chat_state.buffers = {}
	chat_state.is_open = false
end

-- Toggle chat window
function M.toggle()
	if chat_state.is_open then
		M.close()
	else
		M.open()
	end
end

-- Setup key mappings
function M.setup_keymaps()
	-- Input buffer mappings
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.input,
		"n",
		"<CR>",
		":lua require('neoai.chat').send_message()<CR>",
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.input,
		"i",
		"<CR>",
		"<Esc>:lua require('neoai.chat').send_message()<CR>",
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.input,
		"n",
		"<C-c>",
		":lua require('neoai.chat').close()<CR>",
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.input,
		"i",
		"<C-c>",
		"<Esc>:lua require('neoai.chat').close()<CR>",
		{ noremap = true, silent = true }
	)

	-- Chat buffer mappings
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.chat,
		"n",
		"<C-c>",
		":lua require('neoai.chat').close()<CR>",
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.chat,
		"n",
		"q",
		":lua require('neoai.chat').close()<CR>",
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.chat,
		"n",
		"<C-n>",
		":lua require('neoai.chat').new_session()<CR>",
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		chat_state.buffers.chat,
		"n",
		"<C-s>",
		":lua require('neoai.chat').save_history()<CR>",
		{ noremap = true, silent = true }
	)

	-- Thinking buffer mappings (if enabled)
	if chat_state.config.show_thinking and chat_state.buffers.thinking then
		vim.api.nvim_buf_set_keymap(
			chat_state.buffers.thinking,
			"n",
			"<C-c>",
			":lua require('neoai.chat').close()<CR>",
			{ noremap = true, silent = true }
		)
		vim.api.nvim_buf_set_keymap(
			chat_state.buffers.thinking,
			"n",
			"q",
			":lua require('neoai.chat').close()<CR>",
			{ noremap = true, silent = true }
		)
	end
end

-- Send message
function M.send_message()
	if not chat_state.is_open then
		return
	end

	-- Get input
	local lines = vim.api.nvim_buf_get_lines(chat_state.buffers.input, 0, -1, false)
	local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")

	if message == "" then
		return
	end

	-- Add user message
	M.add_message(MESSAGE_TYPES.USER, message)

	-- Clear input
	vim.api.nvim_buf_set_lines(chat_state.buffers.input, 0, -1, false, { "" })

	-- Send to AI
	M.send_to_ai(message)
end

-- Send message to AI
function M.send_to_ai(message)
	-- Build message history for API
	local messages = {}

	-- Add system prompt
	local system_prompt = M.get_system_prompt()
	table.insert(messages, {
		role = "system",
		content = system_prompt,
	})

	-- Add conversation history (last 10 messages to avoid context limit)
	local recent_messages = {}
	local count = 0
	for i = #chat_state.current_session.messages, 1, -1 do
		local msg = chat_state.current_session.messages[i]
		if msg.type == MESSAGE_TYPES.USER or msg.type == MESSAGE_TYPES.ASSISTANT then
			table.insert(recent_messages, 1, msg)
			count = count + 1
			if count >= 10 then
				break
			end
		end
	end

	-- Convert to API format
	for _, msg in ipairs(recent_messages) do
		table.insert(messages, {
			role = msg.type,
			content = msg.content,
		})
	end

	-- Add thinking step
	M.add_thinking("Processing user message: " .. message, 1)
	M.add_thinking("Preparing API request with " .. #messages .. " messages", 2)

	-- Call API with streaming
	M.stream_ai_response(messages)
end

-- Stream AI response
function M.stream_ai_response(messages)
	local Job = require("plenary.job")
	local config = completion.config

	local payload = vim.fn.json_encode({
		model = config.model,
		temperature = config.temperature,
		max_completion_tokens = config.max_completion_tokens,
		top_p = config.top_p,
		stream = true,
		messages = messages,
	})

	local api_key = "Authorization: Bearer " .. config.api_key

	-- Add thinking step
	M.add_thinking("Starting streaming response from AI", 3)

	-- Initialize response tracking
	local response_content = ""
	local response_start_time = os.time()

	Job:new({
		command = "curl",
		args = {
			"--silent",
			"--no-buffer",
			"--location",
			config.url,
			"--header",
			"Content-Type: application/json",
			"--header",
			api_key,
			"--data",
			payload,
		},
		on_stdout = function(_, line)
			for _, data_line in ipairs(vim.split(line, "\n")) do
				if vim.startswith(data_line, "data: ") then
					local chunk = data_line:sub(7)
					if chunk ~= "[DONE]" then
						vim.schedule(function()
							local ok, decoded = pcall(vim.fn.json_decode, chunk)
							if ok and decoded then
								local delta = decoded.choices and decoded.choices[1] and decoded.choices[1].delta
								local content = delta and delta.content
								if content and content ~= "" then
									response_content = response_content .. content

									-- Update assistant message in real-time
									M.update_streaming_message(response_content)

									-- Add thinking step for significant chunks
									if #content > 10 then
										M.add_thinking("Received chunk: " .. content:sub(1, 50) .. "...", 4)
									end
								end
							end
						end)
					end
				end
			end
		end,
		on_exit = function(_, exit_code)
			vim.schedule(function()
				if exit_code == 0 and response_content ~= "" then
					-- Add final assistant message
					M.add_message(MESSAGE_TYPES.ASSISTANT, response_content, {
						response_time = os.time() - response_start_time,
					})

					-- Add thinking step
					M.add_thinking("Response completed successfully", 5)
				else
					-- Add error message
					M.add_message(MESSAGE_TYPES.ERROR, "Failed to get response from AI", {
						exit_code = exit_code,
					})

					-- Add thinking step
					M.add_thinking("Response failed with exit code: " .. exit_code, 5)
				end

				-- Update display
				M.update_chat_display()
				if chat_state.config.show_thinking then
					M.update_thinking_display()
				end
			end)
		end,
	}):start()
end

-- Update streaming message display
function M.update_streaming_message(content)
	if not chat_state.is_open then
		return
	end

	-- Get current display lines
	local lines = vim.api.nvim_buf_get_lines(chat_state.buffers.chat, 0, -1, false)

	-- Find the last "Assistant:" line and update it
	for i = #lines, 1, -1 do
		if lines[i]:match("^Assistant:") then
			-- Replace lines from this point
			local new_lines = {}
			for j = 1, i - 1 do
				table.insert(new_lines, lines[j])
			end

			-- Add streaming response
			table.insert(new_lines, "Assistant: " .. os.date("%H:%M:%S"))
			local content_lines = vim.split(content, "\n")
			for _, line in ipairs(content_lines) do
				table.insert(new_lines, "  " .. line)
			end
			table.insert(new_lines, "")

			-- Update buffer
			vim.api.nvim_buf_set_lines(chat_state.buffers.chat, 0, -1, false, new_lines)

			-- Auto-scroll if enabled
			if chat_state.config.auto_scroll then
				M.scroll_to_bottom(chat_state.buffers.chat)
			end

			break
		end
	end
end

-- Update chat display
function M.update_chat_display()
	if not chat_state.is_open or not chat_state.current_session then
		return
	end

	local lines = {}

	-- Add session header
	table.insert(lines, "=== NeoAI Chat Session ===")
	table.insert(lines, "Session ID: " .. chat_state.current_session.id)
	table.insert(lines, "Created: " .. chat_state.current_session.created_at)
	table.insert(lines, "Messages: " .. #chat_state.current_session.messages)
	table.insert(lines, "")

	-- Add messages
	for _, message in ipairs(chat_state.current_session.messages) do
		local prefix = ""
		if message.type == MESSAGE_TYPES.USER then
			prefix = "User: " .. message.timestamp
		elseif message.type == MESSAGE_TYPES.ASSISTANT then
			prefix = "Assistant: " .. message.timestamp
			if message.metadata.response_time then
				prefix = prefix .. " (" .. message.metadata.response_time .. "s)"
			end
		elseif message.type == MESSAGE_TYPES.SYSTEM then
			prefix = "System: " .. message.timestamp
		elseif message.type == MESSAGE_TYPES.ERROR then
			prefix = "Error: " .. message.timestamp
		end

		table.insert(lines, prefix)

		-- Add message content
		local content_lines = vim.split(message.content, "\n")
		for _, line in ipairs(content_lines) do
			table.insert(lines, "  " .. line)
		end
		table.insert(lines, "")
	end

	-- Update buffer
	vim.api.nvim_buf_set_lines(chat_state.buffers.chat, 0, -1, false, lines)

	-- Auto-scroll if enabled
	if chat_state.config.auto_scroll then
		M.scroll_to_bottom(chat_state.buffers.chat)
	end
end

-- Update thinking display
function M.update_thinking_display()
	if not chat_state.is_open or not chat_state.config.show_thinking or not chat_state.current_session then
		return
	end

	local lines = {}

	-- Add thinking header
	table.insert(lines, "=== AI Thinking Process ===")
	table.insert(lines, "")

	-- Add thinking steps (last 10)
	local thinking_steps = chat_state.current_session.thinking
	local start_idx = math.max(1, #thinking_steps - 9)

	for i = start_idx, #thinking_steps do
		local step = thinking_steps[i]
		table.insert(lines, "Step " .. step.step .. " [" .. step.timestamp .. "]:")
		table.insert(lines, "  " .. step.content)
		table.insert(lines, "")
	end

	-- Update buffer
	vim.api.nvim_buf_set_lines(chat_state.buffers.thinking, 0, -1, false, lines)

	-- Auto-scroll if enabled
	if chat_state.config.auto_scroll then
		M.scroll_to_bottom(chat_state.buffers.thinking)
	end
end

-- Scroll to bottom of buffer
function M.scroll_to_bottom(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for _, win in pairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == bufnr then
			vim.api.nvim_win_set_cursor(win, { line_count, 0 })
			break
		end
	end
end

-- Get system prompt
function M.get_system_prompt()
	local prompt = [[
You are NeoAI, an AI assistant integrated into Neovim. You provide helpful, accurate, and concise responses to user queries.

Key characteristics:
- Be helpful and informative
- Provide code examples when relevant
- Explain complex concepts clearly
- Be concise but thorough
- Adapt to the user's level of expertise

Current context:
- Environment: Neovim plugin
- Session: Chat interface
- User can see your thinking process
]]

	return prompt
end

-- Clear chat history
function M.clear_history()
	if chat_state.current_session then
		chat_state.current_session.messages = {}
		chat_state.current_session.thinking = {}
	end

	-- Update display
	if chat_state.is_open then
		M.update_chat_display()
		if chat_state.config.show_thinking then
			M.update_thinking_display()
		end
	end

	vim.notify("Chat history cleared")
end

-- Save history to file
function M.save_history()
	if not chat_state.config.save_history then
		return
	end

	local history_data = {
		sessions = { chat_state.current_session },
		saved_at = os.date("%Y-%m-%d %H:%M:%S"),
		version = "1.0",
	}

	local file = io.open(chat_state.config.history_file, "w")
	if file then
		file:write(vim.fn.json_encode(history_data))
		file:close()
		vim.notify("Chat history saved to " .. chat_state.config.history_file)
	else
		vim.notify("Failed to save chat history", vim.log.levels.ERROR)
	end
end

-- Load history from file
function M.load_history()
	if not chat_state.config.save_history then
		return
	end

	local file = io.open(chat_state.config.history_file, "r")
	if file then
		local content = file:read("*a")
		file:close()

		local ok, data = pcall(vim.fn.json_decode, content)
		if ok and data and data.sessions and #data.sessions > 0 then
			chat_state.current_session = data.sessions[1] -- Load most recent session
			vim.notify("Chat history loaded from " .. chat_state.config.history_file)
		end
	end
end

-- Get current session info
function M.get_session_info()
	if not chat_state.current_session then
		return nil
	end

	return {
		id = chat_state.current_session.id,
		created_at = chat_state.current_session.created_at,
		message_count = #chat_state.current_session.messages,
		thinking_count = #chat_state.current_session.thinking,
	}
end

-- Export functions
M.MESSAGE_TYPES = MESSAGE_TYPES

return M
