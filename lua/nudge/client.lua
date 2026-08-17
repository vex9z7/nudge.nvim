local config = require("nudge.config")
local M = {}

local function visible_text()
	local pending, thinking = "", false
	return function(token, finished)
		pending = pending .. (token or ""):gsub("%z", "")
		local output = {}
		while true do
			if thinking then
				local close = pending:find("</think>", 1, true)
				if not close then
					pending = pending:sub(-7)
					break
				end
				pending, thinking = pending:sub(close + 8), false
			else
				local open = pending:find("<think>", 1, true)
				if open then
					output[#output + 1] = pending:sub(1, open - 1)
					pending, thinking = pending:sub(open + 7), true
				elseif finished then
					output[#output + 1], pending = pending, ""
					break
				else
					output[#output + 1], pending = pending:sub(1, -7), pending:sub(-6)
					break
				end
			end
		end
		return table.concat(output)
	end
end

function M.stream(payload, handlers)
	local partial, stderr = "", {}
	local options = config.get()
	local filter = visible_text()
	return vim.fn.jobstart({
		"curl",
		"--no-buffer",
		"--silent",
		"--show-error",
		"-X",
		"POST",
		options.endpoint,
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. (vim.env[options.api_key_env or "LLAMACPP_API_KEY"] or "local"),
		"-d",
		vim.json.encode(payload),
	}, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			partial = partial .. table.concat(data, "\n")
			for line in partial:gmatch("(.-)\n") do
				if line:sub(1, 6) == "data: " then
					local ok, response = pcall(vim.json.decode, line:sub(7))
					local delta = ok and response.choices and response.choices[1] and response.choices[1].delta
					local token = delta and delta.content
					if type(token) == "string" and handlers.on_token then
						token = filter(token)
						if token ~= "" then
							handlers.on_token(token)
						end
					end
				end
			end
			partial = partial:match("[^\n]*$") or ""
		end,
		on_stderr = function(_, data)
			stderr[#stderr + 1] = table.concat(data, "\n")
		end,
		on_exit = function()
			local tail = filter(nil, true)
			if tail ~= "" and handlers.on_token then
				handlers.on_token(tail)
			end
			handlers.on_exit(table.concat(stderr, " "))
		end,
	})
end

return M
