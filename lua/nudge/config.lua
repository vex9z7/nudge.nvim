local M = {}
local value = { idle_ms = 1200 }

function M.setup(opts)
	value = vim.tbl_deep_extend("force", value, opts or {})
	vim.validate({
		endpoint = { value.endpoint, "string" },
		model = { value.model, "string" },
		language = { value.language, "string" },
		languages = { value.languages, "table" },
		idle_ms = { value.idle_ms, "number" },
	})
end

function M.get()
	return value
end

return M
