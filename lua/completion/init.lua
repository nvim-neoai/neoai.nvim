---@alias Role "user" | "system" | "assistant"

---@class completions.TextContent
---@field type "text"
---@field text string

---@class completions.ImageURL
---@field url string

---@class completions.ImageContent
---@field type "image_url"
---@field image_url completions.ImageURL

---@class completions.Message
---@field role Role
---@field content string | completions.TextContent[] | completions.ImageContent[]

---@class completions.Config
---@field url string
---@field api_key string
---@field model string
---@field temperature number|nil
---@field max_completion_tokens number|nil
---@field top_p number|nil

---Read file content
---@param path string
---@return string|nil
local function get_prompt(path)
	local file, err = io.open(path, "r")
	if not file then
		print("Failed to open file:", err)
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

---@param config completions.Config
---@param messages completions.Message[]
local function api_call(config, messages)
	local Job = require("plenary.job")

	local payload = vim.fn.json_encode({
		model = config.model,
		temperature = config.temperature,
		max_completion_tokens = config.max_completion_tokens,
		top_p = config.top_p,
		messages = messages,
	})

	local api_key = "Authorization: Bearer " .. config.api_key

	-- Buffer setup: reuse if unnamed & unmodified
	local reuse_buf = vim.api.nvim_buf_get_name(0) == "" and not vim.bo.modified
	local buf

	if reuse_buf then
		buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" }) -- clear
	else
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

		vim.cmd("rightbelow vsplit")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	end

	Job:new({
		command = "curl",
		args = {
			"--location",
			config.url,
			"--header",
			"Content-Type: application/json",
			"--header",
			api_key,
			"--data",
			payload,
		},
		on_exit = function(j, return_val)
			local raw_json = table.concat(j:result(), "\n")

			vim.schedule(function()
				local ok, decoded = pcall(vim.fn.json_decode, raw_json)
				if ok and decoded and decoded.choices and decoded.choices[1] then
					local result = decoded.choices[1].message.content
					local lines = vim.split(result or "", "\n", { plain = true })

					-- Set buffer content
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

					-- ✅ Avoid E37 on closing
					vim.api.nvim_buf_set_option(buf, "modified", false)
				else
					vim.notify("Failed to decode JSON:\n" .. raw_json, vim.log.levels.ERROR)
				end
			end)
		end,
	}):start()

	return {}
end

---@param config completions.Config
---@param messages completions.Message[]
local function api_stream_to_buffer(config, messages)
	local Job = require("plenary.job")

	local payload = vim.fn.json_encode({
		model = config.model,
		temperature = config.temperature,
		max_completion_tokens = config.max_completion_tokens,
		top_p = config.top_p,
		stream = true,
		messages = messages,
	})

	local api_key = "Authorization: Bearer " .. config.api_key

	-- Detect if current buffer is unnamed and unmodified
	local reuse_buf = vim.api.nvim_buf_get_name(0) == "" and not vim.bo.modified
	local buf

	if reuse_buf then
		buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" }) -- clear it
	else
		-- Create new buffer
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

		-- Open in right split
		vim.cmd("rightbelow vsplit")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	end

	-- Your output lines table
	local output_lines = { "" }

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
									for s in content:gmatch("[^\n]*\n?") do
										if s:sub(-1) == "\n" then
											output_lines[#output_lines] = output_lines[#output_lines] .. s:sub(1, -2)
											table.insert(output_lines, "")
										else
											output_lines[#output_lines] = output_lines[#output_lines] .. s
										end
									end
									vim.api.nvim_buf_set_lines(buf, 0, -1, false, output_lines)
								end
							end
						end)
					end
				end
			end
		end,
		on_exit = function()
			vim.schedule(function()
				table.insert(output_lines, "")
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, output_lines)
				vim.api.nvim_buf_set_option(buf, "modified", false)
			end)
		end,
	}):start()
end

---@type completions.Config
local config = {
	url = "https://api.groq.com/openai/v1/chat/completions",
	api_key = "<your api key>",
	model = "deepseek-r1-distill-llama-70b",
	temperature = 0.4,
	max_completion_tokens = 4096,
	top_p = 0.9,
}

local M = {}
M.config = config

---@param args completions.Config
M.setup = function(args)
	M.config = vim.tbl_deep_extend("force", M.config, args or {})
end

local function get_plugin_dir()
	local info = debug.getinfo(1, "S")
	return info.source:sub(2):match("(.*/)")
end

local system_prompt_path = get_plugin_dir() .. "system_prompt.md"
local system_prompt = get_prompt(system_prompt_path)

assert(type(system_prompt) == "string", "Prompt template not found or invalid.")

---@param user_input string
M.text_input = function(user_input)
	---@type completions.Message[]
	local messages = {
		{
			role = "system",
			content = system_prompt,
		},
	}
	---@type completions.Message
	local user_message = {
		role = "user",
		content = {
			{
				type = "text",
				text = user_input,
			},
		},
	}

	table.insert(messages, user_message)
	local response = api_call(M.config, messages)
	return response
end

---@param user_input string
M.text_input_stream = function(user_input)
	---@type completions.Message[]
	local messages = {
		{
			role = "system",
			content = system_prompt,
		},
	}
	---@type completions.Message
	local user_message = {
		role = "user",
		content = {
			{
				type = "text",
				text = user_input,
			},
		},
	}

	table.insert(messages, user_message)
	local response = api_stream_to_buffer(M.config, messages)
	return response
end

vim.api.nvim_create_user_command("AINORMAL", function(opts)
	local response = M.text_input(opts.args)
	return response
end, {
	nargs = 1,
})

vim.api.nvim_create_user_command("AI", function(opts)
	local response = M.text_input_stream(opts.args)
	return response
end, {
	nargs = 1,
})

return M
