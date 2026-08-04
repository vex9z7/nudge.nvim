local config = require("nudge.config")
local M = {}

function M.stream(payload, handlers)
	local partial, stderr = "", {}
	local options = config.get()
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
					local token = delta and (delta.content or delta.reasoning_content)
					if type(token) == "string" and handlers.on_token then
						handlers.on_token(token)
					end
				end
			end
			partial = partial:match("[^\n]*$") or ""
		end,
		on_stderr = function(_, data)
			stderr[#stderr + 1] = table.concat(data, "\n")
		end,
		on_exit = function()
			handlers.on_exit(table.concat(stderr, " "))
		end,
	})
end

return M
