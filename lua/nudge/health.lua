local M = {}

function M.check()
	local health = vim.health
	local options = require("nudge.config").get()
	health.start("nudge.nvim")
	if vim.fn.executable("curl") == 1 then
		health.ok("curl is available")
	else
		health.error("curl is required", "Install curl and restart Neovim.")
	end
	if options.endpoint and options.model and options.languages and options.language then
		health.ok("setup is configured")
	else
		health.error(
			"setup is incomplete",
			"Call require('nudge').setup with endpoint, model, language, and languages."
		)
	end
	if options.api_key_env and vim.env[options.api_key_env] then
		health.ok("API key found in $" .. options.api_key_env)
	elseif options.api_key_env then
		health.warn(
			"$" .. options.api_key_env .. " is unset",
			"This is fine only for endpoints accepting Bearer local."
		)
	end
end

return M
